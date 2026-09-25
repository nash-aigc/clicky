import AppKit
import AVFoundation
// 工程开着 `MemberImportVisibility`，`@Published` 的 `init(wrappedValue:)` 定义在
// Combine 里，不显式 import 就会被判成「成员不可见」而不是「少了个 import」。
import Combine

/// 录音的采集管线：麦克风 → 16kHz 单声道 PCM16 → 同时落盘和上行。
///
/// **刻意 `nonisolated`。** `AVAudioEngine` 的 tap 闭包跑在实时音频线程上，
/// 那里任何一次 `await` 到主线程、任何一次锁等待都会造成丢音。所以这一层不碰
/// `@MainActor` 的任何东西，只通过闭包把「一块 PCM」和「一个电平值」往外送，
/// 由调用方自己决定怎么切回主线程。
///
/// 重采样到 16kHz 是必须的：麦克风给的是 48kHz 立体声，而识别服务要 16kHz
/// 单声道，落盘的 WAV 也按 16kHz 写 —— 这样**文件里的字节和发出去的字节完全
/// 相同**，整场录音可以原样重放给服务端复现一次识别。
nonisolated final class LongFormAudioCapture {

    /// 目标格式：识别服务要的 16kHz / 单声道 / 16bit。
    static let targetSampleRate = 16000
    static let targetChannelCount = 1
    static let targetBitsPerSample = 16

    /// 每块音频的时长。100ms 是服务端文档建议的分片粒度，也是「实时」的粒度：
    /// 再长一点，跑马灯的字就会一顿一顿地蹦出来。
    static let chunkMilliseconds = 100

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    /// 当前转换器是按哪种输入格式建的。格式一变就重建 —— 见 `handleInputBuffer`。
    private var converterInputFormat: AVAudioFormat?
    private var isRunning = false

    /// 一块 PCM（16kHz 单声道 PCM16）。在音频线程上调用。
    var onPCMChunk: ((Data) -> Void)?
    /// 平滑后的电平（0…1）和「这一刻是否在说话」。在音频线程上调用。
    var onLevel: ((Double, Bool) -> Void)?
    /// 音频链路的一行诊断。**在音频线程上调用**，接收方必须只做非阻塞的事。
    var onDiagnostic: ((String) -> Void)?

    /// 累计收到多少块、其中有多少块是**整块全零**。
    ///
    /// 这两个计数是为一个具体的失败模式加的：实测三个录音全是纯静音（峰值 0），
    /// 而时长完全正确（6.5 / 3.8 / 5.0 秒）。时长对说明 tap 在正常出帧，出的是零。
    /// 光看「有没有数据」分不出「没插麦克风」「没权限」「引擎拿不到设备」这三种，
    /// 所以这里分别记：块数、零块数、以及第一块的真实峰值。
    private var receivedBufferCount = 0
    private var silentBufferCount = 0
    private var hasReportedFirstBuffer = false

    /// 判定「在说话」的电平门槛。**作用在归一化之后的电平上。**
    ///
    /// 早先这里直接比 0.25（从项目里持续监听那套抄来的原始电平门槛）。实测证明
    /// 那在这条链路上是错的：2026-09-25 用内置麦克风跑本 App 自有的引擎，正常
    /// 说话时每 100ms 一块的**原始**峰值只有 0.009–0.010，平滑后约 0.03 ——
    /// 而 0.25 是另一条链路（`VoicePlaybackEngine` + VPIO）的标定，两者增益差
    /// 一个数量级。照抄的结果是门槛永远够不着，按钮一次都不会动。
    static let speechLevelThreshold = 0.35

    /// 这条链路的「满刻度」原始电平。把实测的说话峰值当尺子，而不是继续猜一个
    /// 绝对值 —— 见 `normalizedLevel(for:)`。
    static let rawSpeechFullScaleLevel = 0.045

    /// 原始平滑电平 → 显示用的 0…1。
    ///
    /// 除以一个**实测出来的**满刻度，而不是继续调那个绝对门槛。理由是绝对门槛
    /// 换一个麦克风、换一次增益就失效，而这条链路的增益和项目里那条 VPIO 链路
    /// 本来就不同（实测差一个数量级）。满刻度这个数字有出处：说话峰值
    /// 0.009–0.010 是实测的，留了约 4 倍余量给大声说话。
    static func normalizedLevel(forRawLevel rawLevel: Double) -> Double {
        min(max(rawLevel / rawSpeechFullScaleLevel, 0), 1)
    }

    private var smoothedLevel: Double = 0

    func start() throws {
        guard !isRunning else { return }

        let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                         sampleRate: Double(Self.targetSampleRate),
                                         channels: AVAudioChannelCount(Self.targetChannelCount),
                                         interleaved: false)!

        let inputNode = engine.inputNode
        let declaredFormat = inputNode.outputFormat(forBus: 0)
        // 把取到的格式原样报出去。采样率/声道都可能是 0（没设备 / 没权限 /
        // 被别的进程占着），而它们失败的方式都是静音 —— 不打印就分不出来。
        onDiagnostic?("引擎声明的输入格式 采样率=\(declaredFormat.sampleRate) 声道=\(declaredFormat.channelCount)")
        guard declaredFormat.sampleRate > 0 else {
            throw LongFormRecorderError.microphoneUnavailable
        }

        // **不把这个格式钉给 tap。** 用 `format: nil` 让引擎按它**实际交付**的
        // 格式回调，转换器在第一次收到 buffer 时按那个真实格式建（见
        // `handleInputBuffer`）。
        //
        // 这不是风格偏好，是这次「录出来全是零」最可能的原因：输入设备的格式会在
        // 另一个引擎开启语音处理时被整个换掉 —— 这个项目里实测过 48kHz/9 声道
        // 对 44.1kHz/1 声道。而钉死的格式一旦对不上，`AVAudioEngine` **不报错**，
        // 只交付静音：时长正确、内容全零，正是观测到的现象。
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buffer, _ in
            self?.handleInputBuffer(buffer, targetFormat: targetFormat)
        }

        engine.prepare()
        try engine.start()
        isRunning = true
        onDiagnostic?("引擎已启动 运行中=\(engine.isRunning) 输入总线格式=\(engine.inputNode.outputFormat(forBus: 0).sampleRate)Hz")
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil
        smoothedLevel = 0
    }

    /// 实时线程。这里只做三件事：重采样、算电平、把结果送出去。
    private func handleInputBuffer(_ buffer: AVAudioPCMBuffer, targetFormat: AVAudioFormat) {
        // 转换器按**实际交付的**格式惰性建立，格式变了就重建。
        // 这样上面那个「钉死格式 → 静默出零」的失败模式在结构上不可能发生。
        if converter == nil || converterInputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: targetFormat)
            converterInputFormat = buffer.format
            onDiagnostic?("转换器按实际交付格式建立：\(buffer.format.sampleRate)Hz "
                          + "\(buffer.format.channelCount)ch 帧容量=\(buffer.frameCapacity)")
        }
        guard let converter else { return }

        // 重采样。输出容量按采样率比放大一点，再留几十帧余量给转换器的内部延迟。
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var suppliedInput = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            if suppliedInput {
                outStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, output.frameLength > 0,
              let samples = output.int16ChannelData?[0] else { return }

        let sampleCount = Int(output.frameLength)

        // 电平：RMS × 10.2，平滑取 max(新值, 旧值 × 0.72)。
        // 这两个数字都是从项目里已有的标定抄过来的，不要各写一套。
        var sumOfSquares: Double = 0
        var peak: Int32 = 0
        for index in 0..<sampleCount {
            let raw = samples[index]
            let magnitude = raw >= 0 ? Int32(raw) : -Int32(raw)
            if magnitude > peak { peak = magnitude }
            let value = Double(raw) / 32768.0
            sumOfSquares += value * value
        }
        let rms = (sumOfSquares / Double(max(sampleCount, 1))).squareRoot()
        let instantLevel = min(rms * 10.2, 1.0)
        smoothedLevel = max(instantLevel, smoothedLevel * 0.72)
        // 交给外面的是**归一化后**的电平：原始值在这条链路上只有 0.01 量级，
        // 直接拿去驱动 UI 的话按钮永远不动。见 `normalizedLevel(forRawLevel:)`。
        let level = Self.normalizedLevel(forRawLevel: smoothedLevel)
        let isSpeaking = level >= Self.speechLevelThreshold

        // 采样级的仪表。第一次和之后每 50 块各报一行 —— 只报「有没有数据」
        // 分不出静音是哪一种失败，峰值能。
        receivedBufferCount += 1
        if peak == 0 { silentBufferCount += 1 }
        if !hasReportedFirstBuffer || receivedBufferCount % 50 == 0 {
            hasReportedFirstBuffer = true
            onDiagnostic?(String(format: "第 %d 块：%d 帧 峰值=%d/32768 (%.3f) 累计零块=%d/%d",
                                 receivedBufferCount, sampleCount, peak,
                                 Double(peak) / 32768.0, silentBufferCount, receivedBufferCount))
        }

        onLevel?(level, isSpeaking)
        onPCMChunk?(Data(bytes: samples, count: sampleCount * MemoryLayout<Int16>.size))
    }
}

/// 最近几秒的音频，供重连时「接缝重喂」。
///
/// 为什么需要：轮换连接会在音频流上留一个接缝。原来的保证是「只在静音处轮换」——
/// 静音处没有词可丢。但强制轮换（连接跑太久、不能无限跑下去）会打破这个前提：
/// 断在句子中间时，那半句就永远没了。
///
/// 重喂几秒**重叠**音频，再用服务端给的毫秒时间戳把重复那段丢掉，接缝就补回来了。
/// 宁可重、不可丢 —— 重复的段有确定的方法识别，丢掉的词没有任何办法找回。
nonisolated final class RecentAudioRing {
    private let lock = NSLock()
    private var chunks: [Data] = []
    private var totalByteCount = 0
    private let maximumByteCount: Int

    init(maximumSeconds: Double, bytesPerSecond: Int) {
        maximumByteCount = Int(maximumSeconds * Double(bytesPerSecond))
    }

    func append(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        chunks.append(data)
        totalByteCount += data.count
        while totalByteCount > maximumByteCount, let oldest = chunks.first {
            totalByteCount -= oldest.count
            chunks.removeFirst()
        }
    }

    func snapshot() -> [Data] {
        lock.lock(); defer { lock.unlock() }
        return chunks
    }
}

nonisolated enum LongFormRecorderError: Error, CustomStringConvertible {
    case microphoneUnavailable
    case cannotBuildConverter
    case missingAPIKey
    case cannotCreateStorage(String)

    var description: String {
        switch self {
        case .microphoneUnavailable: return "拿不到麦克风输入（权限或设备问题）"
        case .cannotBuildConverter: return "无法建立 16kHz 重采样器"
        case .missingAPIKey: return "还没填 API Key"
        case .cannotCreateStorage(let detail): return "无法创建录音文件：\(detail)"
        }
    }
}

/// 长录音的编排器。
///
/// ## 和现有语音管线的关系：**没有关系**
///
/// 用户对这件事的要求是明确的：独立接线，跟面板里任何功能都不相干。所以这里
/// 不复用 `BuddyDictationManager`、`VoicePlaybackEngine`、`BailianTTSClient`
/// 中的任何一个，也**不复用它们的音频引擎** —— 理由是具体的而不是洁癖：
/// `BuddyDictationManager` 只有**一份**连续监听窗口（一个 `isContinuousListening`
/// 标志、一个回调槽、一份 utterance 状态），录音要连续跑几小时，一旦共用，
/// 对话页和录音会互相把对方的窗口抢掉。录音也不需要回声消除、不需要 VPIO、
/// 不需要时间拉伸，共用只会继承它那一串前置条件。
///
/// ## 长会话的三个设计要点
///
/// 1. **音频直接落盘，永不累积在内存。** 3 小时是 345 MB，攒着必然出事。
/// 2. **连接是可替换的。** 单次连接能活多久官方没给上限，所以设计上不依赖它：
///    每 20 分钟在**静音处**主动轮换一次，断了就重连。小时版按音频时长计费，
///    轮换本身不花钱。
/// 3. **文本靠毫秒水位续接，不靠文本相似度。** 识别器会改写文本，毫秒不会。
@MainActor
final class LongFormRecorderController: ObservableObject {

    static let shared = LongFormRecorderController()

    enum Phase: Equatable {
        case idle
        case starting
        case recording
        case stopping
    }

    // MARK: - 对外状态（刘海 UI 与设置页读这些）

    @Published private(set) var phase: Phase = .idle
    /// 平滑后的麦克风电平（0…1）。右侧停止按钮的**大小**跟着它走。
    @Published private(set) var audioLevel: Double = 0
    /// 此刻是否有人在说话。停止按钮只在说话时变化，静音时冻结 —— 用户的要求。
    @Published private(set) var isSpeechDetected: Bool = false
    @Published private(set) var elapsedSeconds: Double = 0
    @Published private(set) var connectionState: VolcengineRealtimeASRClient.ConnectionState = .idle
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var connectionRotationCount: Int = 0
    /// 当前这一场转录的写入器；空闲时为 nil。刘海跑马灯读它的 `liveLineText`。
    @Published private(set) var transcriptWriter: LongFormTranscriptWriter?
    /// 跑马灯当前显示的那一行：**已经落盘的最近一段 + 当前这句**。
    ///
    /// 必须带上已落盘的尾巴。只显示「当前这句」的话，每次断句（服务端静音判停）
    /// 都会把整行换掉 —— 用户看到的就是「之前的话突然全没了，然后出现新的」。
    /// 实测日志：24.5 秒里有 3 个段，也就是屏幕会整行闪 3 次。连续追加才是对的：
    /// 新字从右边进，旧字往左走。
    @Published private(set) var liveTranscriptLine: String = ""

    /// 已落盘文本的尾部窗口。只留尾巴是因为屏幕上本来也只看得见最后几十个字，
    /// 而全文可能有几万字 —— 把全文拼进这一行会让每帧的布局开销随会话长度增长，
    /// 正是「录得越久越卡」的成因。
    private var committedTranscriptTail: String = ""
    private static let committedTailCharacterLimit = 90

    // MARK: - 展开面板与编辑

    /// 有没有一场还没结束的会话。挂断之后它仍然是 `true` —— 面板要留着、
    /// 绿色音波要留着，点它就是接着录。真正结束它的是 `finishCurrentSession()`。
    @Published private(set) var isSessionActive = false

    /// 展开态：点刘海下面那行文字切换。展开后窗口向下长，看得到之前的文本。
    @Published var isTranscriptExpanded = false

    /// 完全用于显示/编辑的那一份全文。
    ///
    /// **一整段连续文本，段与段之间不加换行** —— 用户的原话是「文本之间不要换行，
    /// 因为文字是连续的。现在只能显示、只能编辑某一行，体验太差了」。所以这里
    /// 不再有「行」这个概念，展开面板里是**一个可编辑的整体**，点哪改哪。
    @Published private(set) var transcriptPlainText = ""

    /// 用户正在编辑时的草稿。`nil` 表示没在编辑。
    @Published var transcriptDraftText: String?

    /// **当前这句还没定稿的实时文本。**
    ///
    /// 展开面板的文字原来只读 `transcriptPlainText`，而那个**只在 `isDefinite` 时
    /// 才追加** —— `isDefinite` 表示服务端判定这句话说完了（要 800ms 静音 + 处理），
    /// 所以在面板里看到的是**定稿的句子**，比刘海那一行的实时部分晚约 3 秒。
    /// 刘海那一行读的是这个字段，所以跟手；两条路读的是**不同的数据**。
    ///
    /// 面板现在也读它，两边同源。
    @Published private(set) var livePartialText: String = ""

    /// 跑马灯那一行用的文本。**只增不减** —— 这一条是硬要求，不是风格。
    ///
    /// 位移公式是 `可用宽度 − 文字宽度`，所以**文字一旦变短，屏幕上就会向右跳**。
    /// 而 `liveTranscriptLine`（已落盘尾巴 `suffix(90)` + 当前段）在**每次定稿**时
    /// 都会变短 —— 最多短掉整整一句。视窗是 64 字时这件事数学上不可见
    /// （64 ≤ 90，定稿前后逐字相同）；而视窗放大到 160 字之后它就露出来了：
    /// 每定稿一句，文字向右跳一下。用户报的「偶尔突然向右、文字从左跳到右」
    /// 就是它，出现次数正好等于定稿次数。
    ///
    /// `transcriptPlainText` 与 `livePartialText` 都**只追加**（定稿时前者接上本段、
    /// 后者清空，净增量仍是正），所以这个拼接不会变短。
    var marqueeText: String { transcriptPlainText + livePartialText }

    /// 面板里应该显示的全部文字：**（用户改过的正文 或 已落盘正文）+ 当前这句**。
    ///
    /// 两层都要在：
    /// - 草稿存在时用它（用户的编辑优先），否则用已落盘的正文；
    /// - **实时部分永远加在末尾** —— 展开那一版错在「一旦有草稿就再也不看实时部分」，
    ///   而展开会立刻建草稿，所以面板永远只显示定稿的句子。
    var transcriptDisplayText: String {
        (transcriptDraftText ?? transcriptPlainText) + livePartialText
    }

    /// 用户在面板里改完了。`edited` 是**屏幕上那份**，末尾带着实时部分 ——
    /// 把那段剥掉再存：实时部分由 `livePartialText` 负责，存进草稿会在下一次定稿时
    /// 被重复计入。
    func applyEditedTranscript(_ edited: String) {
        var stored = edited
        let partial = livePartialText
        if !partial.isEmpty, stored.hasSuffix(partial) {
            stored.removeLast(partial.count)
        }
        transcriptDraftText = stored
    }

    var isEditingTranscript: Bool { transcriptDraftText != nil }

    /// 正在收尾（末包已发，等服务端把最后一段判成 definite）。
    ///
    /// 用户的要求：「用户点击转写结束，或者用户使用快捷键结束，这个时候应该在左侧
    /// 显示"转写中"三个字，右侧显示倒计时多少秒」。所以停止之后刘海**不立刻消失**，
    /// 而是进入这个状态。
    @Published private(set) var isFinalizingTranscript = false
    /// 倒计时剩余秒数。
    @Published private(set) var finalizeSecondsRemaining = 0

    /// 正在走「自定义风格」那一步（转写已完成、模型正在重写）。
    ///
    /// 用户的要求：「如果用户勾选了自定义风格……那么在转写完成之后，要进入另外一个
    /// 动画界面，叫做 AI 润色。左侧……显示"AI 润色中"……这个文字是绿色的。右侧是
    /// 一个随机动画」。
    @Published private(set) var isPolishingTranscript = false
    private var finalizeCountdownTask: Task<Void, Never>?

    /// 「取消」的代次。`completeStop` 在**每一个 await 之后**核对它是否变过 ——
    /// 变过就说明用户按了取消，整条链立刻放弃（不粘贴、不收尾）。
    ///
    /// 为什么要代次而不是 `Task.isCancelled`：润色那一步是 `await` 一个网络请求，
    /// 而取消是用户在另一个入口按下来的，两者不在同一条任务链上。代次是唯一能
    /// 跨入口说的「这件事已经作废了」。
    private var cancellationGeneration = 0

    /// 停止那一刻抓到的屏幕（JPEG）。没开「屏幕截图」时是 nil。
    private var polishScreenshotJPEG: Data?

    /// 最近 8 秒音频，重连时重喂用。见 `RecentAudioRing`。
    private let recentAudio = RecentAudioRing(
        maximumSeconds: 8,
        bytesPerSecond: LongFormAudioCapture.targetSampleRate * 2)   // 16k 单声道 16bit

    /// 新连接开头这段（毫秒）里回来的文字是**重喂的重叠**，一律丢掉。
    /// 服务端的时间轴在新连接上从零重计，所以这个数是「重喂了多久」。
    private var seamSuppressionMilliseconds = 0

    /// 抓当前主屏，缩到 1600px 长边、JPEG 0.7 —— 和「看与截图」页那两个设置同一个
    /// 量级，够模型看清内容又不会把请求撑大。
    private static func captureMainDisplayJPEG() -> Data? {
        guard let cgImage = CGDisplayCreateImage(CGMainDisplayID()) else { return nil }
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.7])
    }

    /// 这一步到底会不会真的走模型。界面用它决定要不要进入「AI 润色中」相位 ——
    /// 判据必须和 `polishIfConfigured` 里的 guard **完全一致**，否则会出现
    /// 「闪了一下 AI 润色中但其实什么都没做」。
    private func shouldRunPolishStep() -> Bool {
        let settings = AppSettingsStore.snapshot()
        guard settings.recordingPolishEnabled else { return false }
        let styles = RecordingPolishStyleStore.shared.enabledStyles()
        return !styles.isEmpty || polishScreenshotJPEG != nil
    }

    /// 按「自定义风格」重写一遍转写原文。
    ///
    /// **没勾选任何风格、也没勾截图时原样返回** —— 用户明确要求这种情况下必须和以前
    /// 完全一致，一步都不多走（不建请求、不动文本）。
    private func polishIfConfigured(rawText: String) async -> String {
        let settings = AppSettingsStore.snapshot()
        guard settings.recordingPolishEnabled else { return rawText }
        let styles = RecordingPolishStyleStore.shared.enabledStyles()
        let screenshot = polishScreenshotJPEG
        guard !styles.isEmpty || screenshot != nil else { return rawText }
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return rawText }

        let prompt = RecordingPolishClient.buildPrompt(
            styles: styles, transcript: trimmed, hasScreenshot: screenshot != nil)
        publishDiagnostic("自定义风格：\(styles.count) 条风格 + 截图\(screenshot != nil ? "有" : "无")，开始重写")
        do {
            let result = try await RecordingPolishClient.polish(
                prompt: prompt, screenshotJPEG: screenshot, settings: settings)
            publishDiagnostic("自定义风格：重写完成，\(result.count) 字（原文 \(trimmed.count) 字）")
            return result
        } catch {
            // **失败就用原文。** 用户要的是「整理一下再给我」，整理失败时他最需要的
            // 仍然是他说过的内容 —— 把原文丢掉换成一句报错，是把一次小失败变成一次
            // 内容丢失。
            publishDiagnostic("自定义风格失败，改用原文：\(error)")
            lastErrorMessage = "自定义风格失败，已用原文：\(error.localizedDescription)"
            return rawText
        }
    }

    /// 末包发出 → 最后一段定稿，大约要几秒。
    ///
    /// **实测值，不是估的。** 2026-09-25 的 24.5 秒真实录音里
    /// `录音结束：77 字，24.5 秒` 与 `已执行粘贴` 落在同一秒内，说明服务端对末包的
    /// 定稿响应在 1 秒量级 —— 内容在流式过程中已经陆续回来了，末包只是让最后半句
    /// 定稿。所以给 3 秒上限：多数情况 1–2 秒就结束，偶尔慢一点也不会出现
    /// 「倒计时走完了还在转」。这个数字会在下一轮用更长的录音再校一次。
    static let estimatedFinalizeSeconds = 3

    /// 刚复制过，用来让复制按钮闪一下对勾。
    @Published private(set) var didJustCopyTranscript = false

    /// 左侧 Record 区域的动作：展开 + 进入编辑。
    ///
    /// 用户改过一次设计：编辑入口原来放在转写那一行上，但「不太容易点，容易误触」，
    /// 所以移到了左侧 —— 那里是一块明确的、够大的目标。再点一次收起。
    func toggleTranscriptEditor() {
        if isTranscriptExpanded {
            collapseTranscriptEditor()
        } else {
            isTranscriptExpanded = true
            // **展开不建草稿。** 建了的话，显示就从「正文 + 实时部分」切成「草稿」，
            // 而草稿只装定稿的内容 —— 实时部分再也不显示。用户看到的「展开后不实时、
            // 晚很久」就是这个。草稿只在用户真的动手改的那一刻才建
            // （见 `applyEditedTranscript`）。
        }
    }

    /// 收起编辑窗。
    ///
    /// **关窗不是「把窗口藏起来」，它可能是这一场的结束。** 用户 2026-09-25 的原话：
    /// 「这时用户按住 ESC，**弹窗消失，录音结束**，转写内容自动传递到剪贴板，不粘贴」，
    /// 以及「点击停止，然后窗口关闭后，**刘海也必须退出**，因为录音已经结束了」。
    ///
    /// 所以按录音还在不在跑分两条：
    /// - **还在录** → 只是把窗口收起来，继续转写（用户：「如果在转写过程中用户点击了
    ///   编辑，按住 ESC 可以继续转写」）；
    /// - **已经停了**（含收尾倒计时中）→ 关窗就是结束：内容**无条件**进剪贴板，然后
    ///   整个会话收掉，刘海跟着退出。
    ///
    /// 原来这里只做了第一件事的一半 —— 把窗口收起来，却从不结束会话，所以
    /// `isSessionActive` 一直是 true，刘海挂着不走。
    func collapseTranscriptEditor() {
        saveTranscriptDraft()
        isTranscriptExpanded = false

        guard !isRecording else { return }

        // 「即便用户没有点击复制，也要传递到剪贴板」—— 挂在关窗这个唯一收口上，
        // 而不是挂在复制按钮上，否则没点过复制的那一场就永远进不了剪贴板。
        copyTranscriptToClipboard()
        // 不粘贴：用户定的规则里，粘贴只发生在「窗口没开 + 按快捷键停止」那一种情况。
        finishCurrentSession()
    }

    /// 保存草稿。`⌘S` 和折叠都走它 —— 用户的原话是「即便没有保存也会自动保存」，
    /// 所以不保存也不会丢，`⌘S` 只是个让人安心的显式动作。
    func saveTranscriptDraft() {
        guard let draft = transcriptDraftText else { return }
        transcriptPlainText = draft
        transcriptDraftText = nil
        writePlainTextFile(draft)
    }

    /// 结束编辑：把草稿写回 `.txt`。**写回的是给人看、给剪贴板用的那一份**；
    /// `.jsonl` 保留识别器的原始输出不动，因为它是「当时到底听到了什么」的记录，
    /// 被编辑过就不再是证据了。
    func commitEditingAndSave() {
        saveTranscriptDraft()
    }

    func copyTranscriptToClipboard() {
        // 编辑中就以草稿为准 —— 用户改了还没保存，复制的应该是他眼前看到的那份。
        let text = transcriptDraftText ?? transcriptPlainText
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        didJustCopyTranscript = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            self?.didJustCopyTranscript = false
        }
    }

    private func writePlainTextFile(_ text: String) {
        guard let session = currentSession else {
            publishDiagnostic("写回失败：currentSession 已经是 nil")
            return
        }
        let url = session.transcriptFileURL(inFolder: folderURL)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            let written = (try? String(contentsOf: url, encoding: .utf8))?.count ?? -1
            // **写回之后立刻读回来核对。** 只看「写了没有」不够 —— 用户报的
            // 「润色没生效」正是「日志说写成功、文件里还是原文」这一种。
            publishDiagnostic("写回 \(url.lastPathComponent)：送入 \(text.count) 字，读回 \(written) 字")
        } catch {
            publishDiagnostic("写回失败：\(error)")
        }
    }

    /// 结束这一场：让面板消失，下次录音从头开始。
    func finishCurrentSession() {
        isTranscriptExpanded = false
        transcriptDraftText = nil
        isSessionActive = false
        currentSession = nil
        transcriptPlainText = ""
        livePartialText = ""
        committedTranscriptTail = ""
        liveTranscriptLine = ""
    }
    /// 最近若干行诊断，设置页和排查时看。
    @Published private(set) var recentDiagnostics: [String] = []

    var isRecording: Bool { phase == .recording || phase == .starting }

    /// 已录时长，`mm:ss`。左边那颗翼在录音时显示的就是它 ——
    /// 用户的要求：「把 record 这个单词替换成时间，显示当前用户已经录制了多长时间」。
    var formattedElapsedTime: String {
        let total = Int(elapsedSeconds.rounded(.down))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    // MARK: - 内部

    private let capture = LongFormAudioCapture()
    private var audioWriter: RecordingAudioWriter?
    private var asrClient: VolcengineRealtimeASRClient?
    private var currentSession: RecordingSession?
    private var folderURL: URL = RecordingLibraryStore.defaultFolderURL

    private var elapsedTimer: Timer?
    private var rotationTimer: Timer?
    private var startedAt: Date?
    private var lastSpeechAt: Date?
    private var lastConnectionStartedAt: Date?
    private var hasReportedMissingKey = false

    private init() {
        capture.onPCMChunk = { [weak self] pcm in
            // 音频线程 → 落盘 + 上行。两者都不碰主线程：`RecordingAudioWriter`
            // 是 nonisolated 的，`asrClient.enqueue` 只是投递到它自己的串行队列。
            //
            // 这里读的是 `audioWriterBox` / `audioClient` 那两个
            // `nonisolated(unsafe)` 桥接属性，而不是同名的 `@MainActor` 存储属性 ——
            // 实时音频线程上访问 MainActor 属性是编译不过的，而且真跑起来就是丢音。
            self?.audioWriterBox?.tryAppend(pcm)
            self?.audioClient?.enqueue(audio: pcm)
            // 留着给重连重喂用。环形缓冲自己带锁，音频线程上调是安全的。
            self?.recentAudio.append(pcm)
        }
        capture.onLevel = { [weak self] level, isSpeaking in
            Task { @MainActor in
                guard let self else { return }
                self.audioLevel = level
                self.isSpeechDetected = isSpeaking
                if isSpeaking { self.lastSpeechAt = Date() }
            }
        }
        capture.onDiagnostic = { [weak self] line in
            // 这一条来自音频线程：只投递，绝不在那里碰文件或锁。
            Task { @MainActor in self?.publishDiagnostic(line) }
        }
    }

    /// 落盘一份诊断日志。
    ///
    /// **放 `Application Support`，不放录音目录（桌面）。** 桌面是 macOS 的
    /// TCC 保护范围，出了这个 App 谁都读不到它 —— 实测：录音目录里的文件在同一
    /// 台机器上几分钟前还能读、之后就被「Operation not permitted」挡住，连关掉
    /// 沙箱也不行。诊断日志的全部意义是能被读出来，所以它必须放在不受 TCC 管
    /// 的地方（和 `AppSettings.json` 同一层）。
    private var diagnosticLogURL: URL?

    private static var diagnosticsFileURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask).first!
        return support.appendingPathComponent("Clicky/录音诊断.log")
    }

    private func appendDiagnosticToFile(_ line: String) {
        guard let url = diagnosticLogURL else { return }
        let stamp = ISO8601DateFormatter().string(from: Date())
        guard let data = "[\(stamp)] \(line)\n".data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }

    /// 音频线程与主线程之间的桥。`@MainActor` 的存储属性在实时线程上读不到，
    /// 这两个 `nonisolated(unsafe)` 的引用就是那条通道；它们只在开始/结束时被
    /// 主线程写入，音频线程只读，所以没有数据竞争。
    private nonisolated(unsafe) var audioWriterBox: RecordingAudioWriter?
    private nonisolated(unsafe) var audioClient: VolcengineRealtimeASRClient?

    private func publishDiagnostic(_ line: String) {
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        recentDiagnostics.append("[\(stamp)] \(line)")
        if recentDiagnostics.count > 40 { recentDiagnostics.removeFirst(recentDiagnostics.count - 40) }
        appendDiagnosticToFile(line)
        NSLog("[LongForm] \(line)")
    }

    // MARK: - 开始 / 停止

    func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            // **已经有一场没结束的会话就接着录，不是新开一场。**
            //
            // 原来这里调的是无参的 `startRecording()`，它无条件新建会话。而停止之后
            // （收尾期间 `phase == .stopping`，`isRecording` 已经是 false）再按一次
            // 快捷键就会凭空开一场全新录音 —— 用户报的「倒计时结束后又进入了一个
            // 全新的录音状态」就是这个。
            startRecording(resumingCurrentSession: isSessionActive)
        }
    }

    /// 停止的那一刻编辑窗是不是开着的。
    ///
    /// **判据必须是「停止瞬间」的状态，不是「这一场里有没有打开过」。**
    /// 用户的原话：「转写过程中用户点击展开按钮，展开弹窗后手动点击停止录音按钮，
    /// 此时无论是否手动编辑，弹窗都继续存在」。用「曾经打开过」的话，只要展开看过
    /// 一次，此后每一次停止都会把面板留下 —— 表现出来就是「点了停止却不退出」。
    private var isEditorOpenAtStopTime = false

    /// 开始录音。
    ///
    /// - Parameter resumingCurrentSession: `true` 时**接着上一段录** —— 复用同一个会话
    ///   id、同一个 `.wav`、同一份转录文件，音频和文字都追加在后面。这是挂断后点
    ///   绿色音波的行为：用户要的是「录制的内容继续追加」，不是新开一场。
    func startRecording(resumingCurrentSession: Bool = false) {
        guard phase == .idle else { return }
        let isResuming = resumingCurrentSession && currentSession != nil

        let settings = AppSettingsStore.snapshot()
        let apiKey = settings.recordingServiceAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            lastErrorMessage = LongFormRecorderError.missingAPIKey.description
            publishDiagnostic("拒绝开始：设置里没有 API Key")
            playErrorSound()
            return
        }

        phase = .starting
        lastErrorMessage = nil
        connectionRotationCount = 0
        isEditorOpenAtStopTime = false
        if !isResuming {
            committedTranscriptTail = ""
            liveTranscriptLine = ""
            transcriptPlainText = ""
            livePartialText = ""
            transcriptDraftText = nil
        }

        let sessionID = isResuming ? (currentSession?.id ?? Self.makeSessionID()) : Self.makeSessionID()
        folderURL = RecordingLibraryStore.resolvedFolderURL(fromSettingsPath: settings.recordingSaveFolderPath)
        diagnosticLogURL = Self.diagnosticsFileURL

        // 麦克风权限：**这是「录出来全是零」的第一个嫌疑**。macOS 在没授权时
        // 不会让 `AVAudioEngine` 报错 —— 它照样按正确的时间长度交付缓冲区，
        // 只是内容全零。所以不显式查一次，就分不出「没权限」和「没设备」。
        let micStatus: String
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: micStatus = "已授权"
        case .denied: micStatus = "已拒绝"
        case .restricted: micStatus = "受限"
        case .notDetermined: micStatus = "还没问过"
        @unknown default: micStatus = "未知"
        }
        publishDiagnostic("麦克风权限：\(micStatus)")

        do {
            try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)

            let audioWriter = try RecordingAudioWriter(
                fileURL: folderURL.appendingPathComponent("\(sessionID).wav"),
                sampleRate: LongFormAudioCapture.targetSampleRate,
                channelCount: LongFormAudioCapture.targetChannelCount,
                bitsPerSample: LongFormAudioCapture.targetBitsPerSample,
                appendingToExistingFile: isResuming)
            let transcriptWriter = try LongFormTranscriptWriter(
                folder: folderURL, sessionID: sessionID,
                appendingToExistingFile: isResuming)

            // 接着录：把已经落盘的全文接回来，编辑区和跑马灯都不从零开始。
            // `.txt` 里是一句一行，而编辑区要的是**连续的一整段**，所以换行去掉。
            if isResuming {
                let existing = (try? String(contentsOf: transcriptWriter.plainTextFileURL,
                                            encoding: .utf8)) ?? ""
                let flattened = existing.replacingOccurrences(of: "\n", with: "")
                transcriptPlainText = flattened
                committedTranscriptTail = String(flattened.suffix(Self.committedTailCharacterLimit))
                liveTranscriptLine = committedTranscriptTail
            }

            self.audioWriter = audioWriter
            self.audioWriterBox = audioWriter
            self.transcriptWriter = transcriptWriter

            // 接着录：保留会话 id 和时间轴，只把这次的计数接上去。
            // 新开一场才重建整条记录。
            if isResuming, var existing = currentSession {
                existing.endedAt = nil
                existing.endedCleanly = false
                existing.lastErrorMessage = nil
                currentSession = existing
            } else {
                currentSession = RecordingSession(
                    id: sessionID,
                    startedAt: Date(),
                    endedAt: nil,
                    recordedSeconds: 0,
                    characterCount: 0,
                    segmentCount: 0,
                    endedCleanly: false,
                    connectionRotationCount: 0,
                    resourceID: settings.recordingEffectiveResourceID,
                    sampleRate: LongFormAudioCapture.targetSampleRate,
                    channelCount: LongFormAudioCapture.targetChannelCount,
                    bitsPerSample: LongFormAudioCapture.targetBitsPerSample,
                    lastErrorMessage: nil)
            }

            let client = VolcengineRealtimeASRClient(configuration: makeASRConfiguration(from: settings))
            wireClientCallbacks(client)
            self.asrClient = client
            self.audioClient = client
            client.connect()

            try capture.start()

            startedAt = Date()
            lastSpeechAt = Date()
            lastConnectionStartedAt = Date()
            isSessionActive = true
            phase = .recording
            publishDiagnostic("开始录音 \(sessionID) · 档位 \(settings.recordingEffectiveResourceID)")
            startTimers()
            SoundEffectPlayer.shared.play(.listeningStarted)
        } catch {
            publishDiagnostic("开始失败：\(error)")
            lastErrorMessage = error.localizedDescription
            teardownStorage()
            phase = .idle
            playErrorSound()
        }
    }

    func stopRecording() {
        guard phase == .recording || phase == .starting else { return }
        phase = .stopping
        stopTimers()

        // 记下**此刻**编辑窗开没开 —— 停止之后去往哪条分支全看它。
        isEditorOpenAtStopTime = isTranscriptExpanded

        // **抓屏必须在「停止」这一秒**，不能等收尾完再抓 —— 用户的原话是
        // 「每一次录音结束、也就是停止录音的那一刻，用户按下按钮或快捷键的那一秒，
        // 自动抓取当前屏幕的截图」。晚几百毫秒，屏幕上可能已经换了个样。
        polishScreenshotJPEG = AppSettingsStore.snapshot().recordingPolishCapturesScreenshot
            ? Self.captureMainDisplayJPEG() : nil

        // 音效**在点下去的这一帧就响**，不等后台收尾。
        // 用户的要求：「用户点击停止按钮时，有一个音效」。原来它是放在
        // `completeStop` 里的，而那要等末包定稿（最多 4 秒）—— 听起来就是慢半拍。
        SoundEffectPlayer.shared.play(.sessionHungUp)

        // 停止之后刘海**不立刻消失**：左侧变「转写中」，右侧走倒计时，等末包定稿
        // 回来再收。用户的要求就是这个（「这个时候应该在左侧显示'转写中'三个字，
        // 右侧显示倒计时多少秒」）。
        isFinalizingTranscript = true
        finalizeSecondsRemaining = Self.estimatedFinalizeSeconds
        finalizeCountdownTask?.cancel()
        finalizeCountdownTask = Task { @MainActor [weak self] in
            while true {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, self.isFinalizingTranscript else { return }
                if self.finalizeSecondsRemaining > 0 { self.finalizeSecondsRemaining -= 1 }
            }
        }

        capture.stop()

        // 末包必须发 —— 服务端收到它才会把最后一句判成 definite（实测如此）。
        // 等它回完再收尾，否则用户说的最后几个字进不了落盘的那一份。
        let client = asrClient
        client?.finishAndAwaitFinalResult(timeoutSeconds: 2.5) { [weak self] in
            Task { @MainActor in await self?.completeStop() }
        }
        // 兜底：万一回调因为任何原因没来，2 秒后也必须把界面放掉。
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 6_500_000_000)
            guard let self, self.phase == .stopping else { return }
            await self.completeStop()
        }
    }

    /// 放弃这一场。
    ///
    /// 和 `stopRecording()` 是**两条不同的路**：停止是「我说完了」—— 要发末包、
    /// 等最后一句定稿、进剪贴板；放弃是「算了」—— 不发末包、不等定稿、**不进剪贴板、
    /// 不粘贴**，整块直接收掉。
    ///
    /// 入口有两个（用户 2026-09-25）：
    /// - **转写中（倒计时还在走）点那个数字** → 取消；
    /// - **录音中双击音波** → 取消。单击一次是「停止录音、进入转写」，所以
    ///   「单击两次 = 停止 + 取消」，和双击等价。
    ///
    /// **已经落盘的文件保留。** 「放弃这次任务」放弃的是这一次流程，不是用户的录音 ——
    /// 删录音是这个界面永远不该做的事（历史页里也只提供「打开」和「在访达中显示」）。
    func cancelCurrentRecording() {
        guard phase != .idle || isSessionActive else { return }

        // 先作废正在跑的那条收尾链 —— 它可能正卡在润色的网络请求里。
        cancellationGeneration += 1
        isPolishingTranscript = false
        // 退出音效。用户：「在用户点击退出或按 ESC 退出时，播放退出音效」。
        // 用比「完成」更沉的那一条，让人一听就知道是撤回而不是做完了。
        SoundEffectPlayer.shared.play(.recordingCancelled)
        publishDiagnostic("用户取消了这一场：录音和已转写的部分都保留，不进剪贴板")
        finalizeCountdownTask?.cancel()
        finalizeCountdownTask = nil
        isFinalizingTranscript = false
        finalizeSecondsRemaining = 0

        capture.stop()
        stopTimers()
        asrClient?.cancel()          // 不发末包
        try? audioWriter?.finalize()
        transcriptWriter?.finalize()

        // 已经录到的东西照常写进历史，只是这一场标成「被放弃」。
        var session = currentSession
        session?.endedAt = Date()
        session?.endedCleanly = false
        session?.recordedSeconds = audioWriter?.recordedDurationSeconds ?? 0
        session?.characterCount = transcriptWriter?.committedCharacterCount ?? 0
        session?.segmentCount = transcriptWriter?.committedSegmentCount ?? 0
        session?.connectionRotationCount = connectionRotationCount
        session?.lastErrorMessage = "用户取消了这一场"
        if let session {
            writeMetadata(session)
            RecordingLibraryStore.shared.upsert(session)
        }

        teardownStorage()
        phase = .idle
        audioLevel = 0
        isSpeechDetected = false
        elapsedSeconds = 0
        connectionState = .idle
        finishCurrentSession()
    }

    /// 收尾：落盘、写元数据、剪贴板、粘贴。**必须幂等** —— 有个兜底定时器也会
    /// 走到这里。
    private func completeStop() async {
        guard phase == .stopping else { return }
        phase = .idle
        isFinalizingTranscript = false
        finalizeCountdownTask?.cancel()
        finalizeCountdownTask = nil
        finalizeSecondsRemaining = 0

        let settings = AppSettingsStore.snapshot()
        let transcript = transcriptWriter
        let text = transcript?.readFullTextFromDisk() ?? ""

        try? audioWriter?.finalize()
        transcript?.finalize()

        var session = currentSession
        session?.endedAt = Date()
        session?.endedCleanly = true
        session?.recordedSeconds = audioWriter?.recordedDurationSeconds ?? 0
        session?.characterCount = transcript?.committedCharacterCount ?? text.count
        session?.segmentCount = transcript?.committedSegmentCount ?? 0
        session?.connectionRotationCount = connectionRotationCount
        session?.lastErrorMessage = lastErrorMessage
        if let session {
            writeMetadata(session)
            RecordingLibraryStore.shared.upsert(session)
        }

        publishDiagnostic("录音结束：\(text.count) 字，\(String(format: "%.1f", session?.recordedSeconds ?? 0)) 秒")

        SoundEffectPlayer.shared.play(.sessionHungUp)

        // 音效已经在 `stopRecording` 里、点下去的那一帧响过了，这里不再响一次。
        // **转写完成的音效和停止转写的音效必须是两个。**
        // 停止那一下已经在 `stopRecording` 里响过 `.sessionHungUp` 了；这里是
        // 「转写完成」—— 用 `.answerFinished`（agent-done 那个），是一声「好了」。
        // 用户的要求：「用户点击停止撰写的音效和转写完成的音效不能是同一个」。
        SoundEffectPlayer.shared.play(.answerFinished)

        // **自定义风格：转写成功后重写一遍。**
        //
        // 用户的规则：「整个流程都发生在转写成功之后……只要在设置页面勾选了该按钮，
        // 都要走这样一个流程」。而「没勾选任何风格、也没勾截图」时必须**和以前完全
        // 一样** —— 原文直接就是最终内容，一步都不多走。
        // 只有**真的要走模型**时才进入这个相位 —— `polishIfConfigured` 在没勾选任何
        // 风格、也没勾截图时一步都不走，那种情况下不该闪一下「AI 润色中」。
        let willPolish = shouldRunPolishStep()
        if willPolish { isPolishingTranscript = true }
        let generationBeforePolish = cancellationGeneration
        let polished = await polishIfConfigured(rawText: text)
        isPolishingTranscript = false
        // 用户在润色期间按了取消 → 这条路到此为止。录音文件和已转写的文本**照常保留**
        // （它们早就落盘了），只是不再往下走：不粘贴、不进剪贴板、不收尾。
        guard generationBeforePolish == cancellationGeneration else {
            publishDiagnostic("润色期间被取消，已保留录音与已转写内容")
            return
        }
        if polished != text {
            transcriptPlainText = polished
            writePlainTextFile(polished)
        }

        // 停止之后去往哪一条分支，由「停止的那一刻编辑窗开没开」决定。
        // 没开 = 纯快捷键/按钮停止：粘贴，然后把刘海整个收掉（用户要的「必须退出」）。
        // 开着 = 面板留着、音波转绿，等用户看完再关。
        // **最终内容 = 润色结果**（没勾选风格时就是原文）。
        //
        // 这一步原来是有的，我在重构 `completeStop` 时把它删掉了 —— 于是
        // `pasteIntoFrontmostApplication()` 读到的永远是剪贴板里的**旧内容**，
        // 而润色结果既没进剪贴板也没被粘出去。用户看到「转写没生效」就是这个：
        // 日志写着「重写完成，121 字」，粘出来的却还是 143 字的原文。
        let finalText = polished
        if settings.recordingCopiesToClipboard || settings.recordingPastesAfterStop {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(finalText, forType: .string)
        }

        let shouldKeepPanel = isEditorOpenAtStopTime
        if !shouldKeepPanel {
            if settings.recordingPastesAfterStop { pasteIntoFrontmostApplication(finalText) }
            finishCurrentSession()
        }

        teardownStorage()
        audioLevel = 0
        isSpeechDetected = false
        elapsedSeconds = 0
        connectionState = .idle
    }

    private func teardownStorage() {
        asrClient?.cancel()
        asrClient = nil
        audioClient = nil
        audioWriter = nil
        audioWriterBox = nil
        transcriptWriter = nil
        startedAt = nil
        // `currentSession` 与 `transcriptLines` **刻意不清**：挂断之后面板还在、
        // 绿色音波还在，点它就是接着这一场往下录（音频和文字都追加）。
        // 真正结束这一场的是 `finishCurrentSession()`。
    }

    // MARK: - 剪贴板与粘贴

    /// 把焦点还给用户当时正在用的 App，然后按一次 ⌘V。
    ///
    /// 刘海面板是**非激活**窗口，所以录音全程用户的那个 App 一直是前台 ——
    /// 但保险起见还是显式取一次并激活：用户可能在录音期间手动切过窗口，那他想
    /// 粘到的就是切过去的那个。
    private func pasteIntoFrontmostApplication(_ textToPaste: String) {
        let frontmost = NSWorkspace.shared.frontmostApplication
        let ownBundleID = Bundle.main.bundleIdentifier
        if let frontmost, frontmost.bundleIdentifier != ownBundleID {
            frontmost.activate()
        }
        // 给目标 App 一点时间接受激活，否则按键会发给还在前台的我们。
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            // **直接把最终文本传进去**，不再回读剪贴板 —— 回读的那一版在剪贴板没被
            // 写过时会粘出上一次的东西，而那正是这个 bug 藏了这么久的原因。
            let didSend = MacosUseController.pasteKeepingClipboard(textToPaste)
            publishDiagnostic(didSend ? "已执行粘贴" : "粘贴未送出（可能缺辅助功能权限）")
        }
    }

    // MARK: - 连接管理

    private func makeASRConfiguration(from settings: AppSettings) -> VolcengineRealtimeASRClient.Configuration {
        let hotwords = settings.recordingHotwords
            .components(separatedBy: CharacterSet(charactersIn: ",，\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return VolcengineRealtimeASRClient.Configuration(
            apiKey: settings.recordingServiceAPIKey.trimmingCharacters(in: .whitespacesAndNewlines),
            resourceID: settings.recordingEffectiveResourceID,
            language: settings.recordingLanguage,
            hotwords: Array(hotwords.prefix(50)))
    }

    private func wireClientCallbacks(_ client: VolcengineRealtimeASRClient) {
        client.onSegment = { [weak self] segment in
            guard let self, let transcript = self.transcriptWriter else { return }
            // **重喂回来的重叠段，丢掉。** 判据用服务端自己的毫秒时间戳：
            // 新连接的时间轴从零重计，所以 `endMilliseconds <= 重喂时长` 的那些
            // 都是我们已经落过盘的话。靠文本判重做不到这件事（重喂的段被重新识别，
            // 用词会有细微差别），靠时间戳可以。
            if segment.endMilliseconds <= self.seamSuppressionMilliseconds { return }
            if segment.isDefinite {
                // **只有真的落盘了才往下走。** `commit` 会判重（服务端在句末会把
                // 同一段再发一次），返回 false 表示这一段已经被写过了 —— 原来不判
                // 返回值就追加，屏幕上每句都出现两遍。
                guard transcript.commit(segment: segment) else { return }
                // 落盘的那句并入尾巴，屏幕上继续往左走，不清空。
                self.committedTranscriptTail = String(
                    (self.committedTranscriptTail + segment.text)
                        .suffix(Self.committedTailCharacterLimit))
                self.liveTranscriptLine = self.committedTranscriptTail
                // 全文那份：**不加分隔符**，段与段直接相接 —— 文字是连续的。
                self.transcriptPlainText += segment.text
                // 这一句已经进了正文，实时部分就清空（它本来就是这个段的内容）。
                self.livePartialText = ""
                // 用户正在编辑时不覆盖他的草稿，只在末尾接上新的内容。
                if self.transcriptDraftText != nil {
                    self.transcriptDraftText? += segment.text
                }
            } else {
                transcript.updateLiveLine(segment.text)
                self.liveTranscriptLine = self.committedTranscriptTail + segment.text
                // **面板也读实时部分** —— 这就是「展开后能不能实时」的全部差别。
                self.livePartialText = segment.text
            }
        }
        client.onStateChange = { [weak self] state in
            guard let self else { return }
            let previous = self.connectionState
            self.connectionState = state
            if case .disconnected(let reason) = state, self.phase == .recording {
                self.publishDiagnostic("连接断开：\(reason)")
                self.handleUnexpectedDisconnect()
            }
            if case .failed(let message) = state, self.phase == .recording {
                self.lastErrorMessage = message
                self.handleUnexpectedDisconnect()
            }
            _ = previous
        }
        client.onDiagnostic = { [weak self] line in
            self?.publishDiagnostic(line)
        }
    }

    /// 意外断线：把没定稿的那句先留在磁盘上，然后重连。
    ///
    /// 先留一句再重连是必要的 —— 用户说到一半断线，重连后服务端会重新识别那几秒，
    /// 但如果重连本身失败，那句就永远没了。留一个「未定稿」标记，用户至少能在
    /// 文本文件里看到自己说过什么。
    private func handleUnexpectedDisconnect() {
        guard phase == .recording else { return }
        transcriptWriter?.commitLiveLineAsUnfinished()

        let settings = AppSettingsStore.snapshot()
        guard settings.recordingAutoReconnects else {
            publishDiagnostic("自动重连已关闭，录音停止")
            stopRecording()
            return
        }
        // 退避一下再重连，避免服务端侧限流时打成一串失败。
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard let self, self.phase == .recording else { return }
            self.reconnect()
        }
    }

    private func reconnect() {
        guard phase == .recording else { return }
        let settings = AppSettingsStore.snapshot()
        let client = asrClient ?? VolcengineRealtimeASRClient(configuration: makeASRConfiguration(from: settings))
        client.updateConfiguration(makeASRConfiguration(from: settings))
        wireClientCallbacks(client)
        asrClient = client
        audioClient = client
        connectionRotationCount += 1
        lastConnectionStartedAt = Date()

        // **连接先建、重叠音频后灌。** 顺序不能反：客户端的 `enqueue` 在 `task`
        // 还是 nil 时会把这块音频直接丢掉，而 `task` 要 `connect()` 里才建。
        client.connect()

        // 重喂最近这几秒。新连接会重新识别它们，回来的文字由
        // `seamSuppressionMilliseconds` 按服务端自己的毫秒时间戳丢掉 —— 所以接缝
        // 落在句子中间也不丢词，只是多花几秒的上行。
        let overlap = recentAudio.snapshot()
        let overlapByteCount = overlap.reduce(0) { $0 + $1.count }
        let overlapMilliseconds = overlapByteCount / 2 * 1000 / LongFormAudioCapture.targetSampleRate
        seamSuppressionMilliseconds = overlapMilliseconds
        for chunk in overlap { client.enqueue(audio: chunk) }
        publishDiagnostic("重连第 \(connectionRotationCount) 次"
            + (overlapMilliseconds > 0 ? "，重喂 \(overlapMilliseconds) 毫秒重叠音频" : ""))
    }

    // MARK: - 定时器

    private func startTimers() {
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let startedAt = self.startedAt else { return }
                self.elapsedSeconds = Date().timeIntervalSince(startedAt)
            }
        }
        rotationTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.considerRotation() }
        }
    }

    private func stopTimers() {
        elapsedTimer?.invalidate(); elapsedTimer = nil
        rotationTimer?.invalidate(); rotationTimer = nil
    }

    /// 主动轮换：到点了、且**此刻是静音**，才换连接。
    ///
    /// 「只在静音处换」是这段逻辑的全部意义：换连接会在音频流上留一个接缝，
    /// 而静音处的接缝上没有词可丢。它不是优化，是把「未知的连接上限」翻译成
    /// 「已知的、无声的小块」。
    private func considerRotation() {
        guard phase == .recording else { return }
        let minutes = AppSettingsStore.snapshot().recordingRotationMinutes
        guard minutes > 0, let lastConnectionStartedAt else { return }
        guard Date().timeIntervalSince(lastConnectionStartedAt) >= Double(minutes) * 60 else { return }
        let elapsed = Date().timeIntervalSince(lastConnectionStartedAt)
        let isQuiet = lastSpeechAt.map { Date().timeIntervalSince($0) >= 1.5 } ?? true

        // **硬上限：到了间隔的两倍，不管有没有静音都要换。**
        //
        // 原来只有「静音才换」这一条，于是**连续说 20 分钟以上、中间从不停顿 1.5 秒
        // 的用户，轮换永远不会发生** —— 连接会无限跑下去，而单条连接能活多久官方
        // 没有给上限。有了硬上限，「3 小时不断」才不依赖「用户会偶尔停顿」这个假设。
        // 代价是接缝可能落在句子中间，而那条由上面的「重喂 + 时间戳抑制」接住。
        let isOverHardLimit = elapsed >= Double(minutes) * 60 * 2
        guard isQuiet || isOverHardLimit else { return }

        publishDiagnostic(isQuiet
            ? "到达轮换间隔（\(minutes) 分钟）且在静音处，换一条连接"
            : "连接已跑满 \(Int(elapsed / 60)) 分钟（上限 \(minutes * 2) 分钟），强制换连接")
        transcriptWriter?.commitLiveLineAsUnfinished()
        reconnect()
    }

    // MARK: - 落盘辅助

    private func writeMetadata(_ session: RecordingSession) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(session) else { return }
        let url = session.metadataFileURL(inFolder: folderURL)
        do {
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            publishDiagnostic("写元数据失败：\(error)")
        }
    }

    private func playErrorSound() {
        SoundEffectPlayer.shared.play(.errorSurprised)
    }

    /// `2026-09-25-190412-A3F2`。时间在前，用户在访达里按名字排序就是按时间排序。
    private static func makeSessionID() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let suffix = String(format: "%04X", Int.random(in: 0..<0x10000))
        return "\(formatter.string(from: Date()))-\(suffix)"
    }
}

/// `RecordingAudioWriter.append` 会抛，但音频线程上没法处理错误 —— 而且丢了
/// 一块音频也没有补救办法。所以这里吞掉它并记一行日志：录音继续进行，用户至少
/// 还能拿到其余部分，比整个停掉好。
private extension RecordingAudioWriter {
    func tryAppend(_ pcm: Data) {
        do { try append(pcm) }
        catch { NSLog("[LongForm] 写音频失败：\(error)") }
    }
}
