import AppKit
import AVFoundation
// 工程开着 `MemberImportVisibility`，`@Published` 的 `init(wrappedValue:)` 定义在
// Combine 里，不显式 import 就会被判成「成员不可见」而不是「少了个 import」。
import Combine

/// 摄像头小窗摆在屏幕的哪儿。
///
/// 用户 2026-09-26：「当用户的纸上文字很小、需要把纸拿得很近时，由于小窗位于上方
/// 附近，会导致用户看不到小窗里的内容。通过移动小窗位置，既能让用户看到小窗内容，
/// 也能让摄像头更清晰地拍摄文字。」
///
/// 对齐语义是用户定的：「左侧对齐、底部对齐、右侧居中」—— 也就是左中（垂直居中）、
/// 底中（水平居中）、右中（垂直居中），外加回到刘海下面的原位。
nonisolated enum CameraStripPlacement: String, CaseIterable, Equatable {
    case belowNotch
    case left
    case bottom
    case right

    var displayName: String {
        switch self {
        case .belowNotch: return "刘海下"
        case .left: return "左中"
        case .bottom: return "底中"
        case .right: return "右中"
        }
    }
}

/// 小窗标题栏上的一个可点控件。
///
/// **它同时是「命中矩形」的键和「动作」的键。** 小窗所在的那块窗口永远点击穿透
/// （见 `NotchRecordingOverlayController` 里 `cameraStripPanels` 的注释），所以这些
/// 控件收不到真实点击 —— 全部由全局鼠标监听按矩形派发。视图那侧也挂同名动作，
/// 是为了万一窗口哪天变成可交互的，两条路不会分家。
nonisolated enum CameraStripControl: String, CaseIterable, Hashable {
    case mirror
    case toggleCollapse
    case restore
    case moveLeft
    case moveDown
    case moveRight
    case close
}

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

    /// 采集走 **AUHAL**，不是 `AVAudioEngine`。见 `start()` 里那段说明。
    private var halUnit: AudioUnit?
    private var halRenderBuffer: AVAudioPCMBuffer?
    private var captureTargetFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    /// 当前转换器是按哪种输入格式建的。格式一变就重建 —— 见 `handleInputBuffer`。
    private var converterInputFormat: AVAudioFormat?
    private var isRunning = false

    /// **候选输入设备队列** —— 控制器在起采之前排好，`start()` 只用第一个。
    ///
    /// 为什么要一串而不是一个：2026-09-26 实测，内置麦克风会被**别的软件**搞成
    /// 「对谁都只给数字零」，之后连启动都返回 `kAudioHardwareNotRunningError`；
    /// 而同一时刻、同一份代码，iPhone 连续互通那个麦克风录得到真实声音（峰值
    /// 984/32768）。所以稳的做法不是赌某一个设备，而是**换到那个能给样本的**。
    ///
    /// 队列由 `LongFormRecorderController.inputDeviceCandidates(for:)` 排序：
    /// 用户选定的 → 系统默认 → 其余真设备。
    var candidateInputDevices: [AudioInputDevice] = []
    private var candidateDeviceIndex = 0
    /// 本场换过几次设备。**只给日志和界面看**，不参与任何判断。
    private(set) var inputDeviceSwitchCount = 0

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
    /// **连续**零块。和累计是两件事：真正的录音里，说话间隙也会有零块，
    /// 而「一直零下去」只有一种解释。告警判据是这一个。
    private var consecutiveSilentBufferCount = 0
    private var hasReportedFirstBuffer = false

    /// 「被压掉的声音」那一路的计数。判据与动作见 `onAbnormallyQuietInput`。
    ///
    /// 用「这一段一直在安静」而不是「连续几块」来门控：**一段安静里只报一次** ——
    /// 报第二次要等中间出现过一块响的（修好了自然会响；修不好也不该每两秒刷一行）。
    private var quietWindowsSinceReport = 0
    private var hasReportedQuietInputThisStretch = false
    /// 本窗口（约 1 秒）内见过的最高峰值，窗口结束时结算。
    private var quietWindowPeak: Double = 0

    /// 起采时绑到的设备 **id** —— 自愈时要修的正是它。
    ///
    /// 不解析 `boundInputDeviceName` 那个字符串（"名字 [id=N]"）：那是给人和日志看的，
    /// 拿它反推 id 是在两个地方维护同一份真相。
    private var boundInputDeviceID: AudioDeviceID = kAudioObjectUnknown

    /// 起采时绑到的设备名，**记下来给告警用**。
    ///
    /// 不在告警那一刻重新查：那时候查到的可能已经不是当初绑的那一个了
    ///（设备可以中途被拔掉），而告警要回答的正是「我当时绑的是谁」。
    private var boundInputDeviceName = "（还没绑定）"

    /// 实测的块速率：**每秒 90 块**（850 块跨 9.386 秒），也就是一块 ≈ 11ms。
    ///
    /// 这个数字原先写着「一块约 100ms」—— **错了约 9 倍**，而它一路把给用户看的
    /// 文案也带错了（「连续十秒没有任何声音」其实只过了 1.1 秒）。一块是 16kHz 下
    /// 171 帧，171 / 16000 = 10.7ms，和实测吻合。
    static let buffersPerSecond = 90.0

    /// 连续多少块**全零**才判定「这个设备根本没在交付采样」。90 块 ≈ 1 秒。
    ///
    /// 判据是「精确的零」，不是「安静」—— 这两件事必须分清：
    /// 健康设备**永远有底噪**（实测安静房间里 188 块里只有 0~3 块全零、峰值
    /// 246/32768），坏掉的设备是**一个 bit 都不动**（187/187 块全零、录音里
    /// 850 块零块 0 个）。所以「连续一秒的精确零」只有一种解释：设备不产出采样。
    /// 用它当换设备的判据是安全的 —— 用户只是停一下不说话，绝不会触发。
    static let silentBufferAlarmThreshold = 90

    /// 连续全零到阈值时喊一次，请控制器**换一个输入设备**。参数是当时绑的设备名。
    ///
    /// **在音频线程上调用**（和 `onDiagnostic` 一样），所以接收方必须立刻返回，
    /// 把真正的工作甩到别的线程 —— 换设备要停 unit、重新认设备、重启，实测慢的时候
    /// 是秒级，那些都不能在实时线程上做，也不该占主线程。
    ///
    /// 它取代了原来的 `onSilentInputDetected`：原来只是**报**一句「这段录下来会是空的」，
    /// 现在是先**修**（换设备接着录），修不动了才报。
    var onSilentInputNeedsDeviceSwitch: ((String) -> Void)?

    // MARK: - 「被压掉的声音」：判据与回调（2026-09-26 新增）

    /// 一个「安静窗口」有多少块：90 块 ≈ 1 秒，和 `silentBufferAlarmThreshold` 同一基准。
    static let quietWindowBufferCount = 90

    /// 一个窗口（约 1 秒）里的峰值低于这个数，就**值得去看一眼**输入音量。
    ///
    /// 依据全是实测：健康房间里**底噪**的窗内峰值是 246/32768 ≈ 0.0075，说话是
    /// 0.009~0.010 一块；而 2026-09-26 那次故障的窗内峰值是 0.002~0.003。
    ///
    /// **这个门槛不是判据，只是「去看一眼」的触发器 —— 真正决定修不修的是输入音量
    /// 本身（`healInputGainIfNeeded`），它没有余量问题。** 2026-09-26 的实测逼出了
    /// 这条分工：把音量打回 0.20 之后，房间底噪的窗内峰值是 0.004~0.005 —— 而当初
    /// 故障时（用户**在说话**）只有 0.002~0.003。两者是交叉的，所以任何电平门槛都
    /// 只能当"去看一眼"的理由，不能当"确实坏了"的判据。0.006 取在健康底噪
    /// (0.0075) 之下、坏状态 (0.002~0.005) 之上。
    static let quietWindowPeakThreshold = 0.006

    /// 连续几个这样的窗口才动手（2 个 ≈ 2 秒）。留出「刚按下、还没开口」的余量：
    /// 说第一句话之前的房间，就是要多安静有多安静。
    static let quietWindowAlarmCount = 2

    /// 连续两秒窗内峰值都低到不像话 → 请控制器**去看一眼系统输入音量**（低了就修）。
    ///
    /// **「精确的零」和「被压掉的声音」是两种失败，判据不能共用 —— 这是这一段最该
    /// 记住的一条。**（2026-09-26 的教训）
    ///
    ///   * 精确的零 = 这个设备根本没在交付采样 → 换设备
    ///     （`onSilentInputNeedsDeviceSwitch`，判据见 `silentBufferAlarmThreshold`）。
    ///   * 异常安静 = 采样在交付、只是被压掉了（系统输入音量 0.275 ≈ -30dB，
    ///     窗内峰值 0.002~0.003）→ **绝不能换设备**：换哪一个都一样安静，而且会平白
    ///     把正在录的这一场切开。只能去查音量。
    ///
    /// 两个参数：当时绑的设备（要修的是它）、以及触发时的窗内峰值（给日志和告警用）。
    /// **在音频线程上调用**，接收方必须立刻返回，把 CoreAudio 读写甩到别的线程。
    var onAbnormallyQuietInput: ((AudioDeviceID, Double) -> Void)?

    /// 绑好设备之后回一句「绑到了谁」。**静态是因为绑定函数是静态的**
    ///（它没有实例，而起采路径上第一个用到它的地方在实例建好之前）。
    /// 控制器启动时装上，用来填设置页里「这一场实际用的」那一行。
    nonisolated(unsafe) static var onBoundInputDeviceName: ((String) -> Void)?

    /// 同一个时刻再回一句**绑的是哪个 id** —— 控制器要用它去读音量、去修。
    ///
    /// 音量是**设备的**属性，不是这一场的属性：绑到谁就要读谁、修谁。分开回一句
    /// 而不是让控制器去解析 `onBoundInputDeviceName` 那个 "名字 [id=N]" 字符串 ——
    /// 那等于在两个地方维护同一份真相。
    nonisolated(unsafe) static var onBoundInputDeviceID: ((AudioDeviceID) -> Void)?

    /// 起采之前，让共享语音引擎让出硬件。
    ///
    /// ## 实测结论：**这个办法不够，别把它当成修好了**（2026-09-26）
    ///
    /// 机制：开着语音处理（VPIO）的引擎会把硬件 IO 重配成一套语音处理格式，别的引擎
    /// 就捡到那个格式、拿不到音频。独立探针复现过 —— 先起一个开 VPIO 的引擎，同一个
    /// 录音引擎立刻从 1 声道变成 3 声道，峰值 0.0007 对 0.077。
    ///
    /// 但**把引擎放掉并不能还原**，同一条探针量到的：
    ///
    /// | 进程状态 | 钉到 id=88 之后声明的格式 |
    /// |---|---|
    /// | 从没开过 VPIO | **1 声道 @48kHz** ✅ |
    /// | 开过一次 VPIO，stop + 关掉语音处理 | **2 声道 @44.1kHz** ❌ |
    /// | 紧接着再建一个引擎 | **2 声道 @44.1kHz** ❌（进程级，不是引擎级） |
    ///
    /// 也就是**一旦本进程开过语音处理，此后 `AVAudioEngine` 的输入节点就再也拿不到
    /// 那个真实的单声道麦克风** —— 钉设备没用、放掉引擎没用、新建引擎也没用。
    /// App 里实测同样：重启后第一场录音是 `声道=1 · 设备=MacBook Pro麦克风 [id=88]`、
    /// 转写正常；之后只要语音管线跑过一次，再录就是 `声道=3`、峰值恒 0。
    ///
    /// 所以这一行留着（无害），但**真正的修法不在这里**：要么让录音不走
    /// `AVAudioEngine`（直接 AUHAL，绕开进程级的聚合体），要么把采集挪出这个进程。
    /// 两者都还没做。眼下能兜住的是紧随其后的那条「格式和设备对不上」告警 ——
    /// 它至少把静音变成一句能读到的原因。
    nonisolated(unsafe) static var releaseSharedAudioEngine: (() -> Void)?

    /// 「声明的格式和钉住的设备对不上」——这一场注定是静音，而且**在第一个音频块
    /// 之前就知道**。控制器装它来填设置页那行告警。
    nonisolated(unsafe) static var onFormatMismatchDetected: ((String) -> Void)?

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

    /// 目标格式的对象形态 —— 采集、转换、落盘要的是同一个东西，只是
    /// `targetSampleRate` 那三个数字是给服务端和文件头用的，这个是给转换器用的。
    ///
    /// **提到静态**是因为起采被拆成了两半（`start()` 选设备、`bindAndStartCapture`
    /// 建单元），换设备时会再进来一次 —— 每进来一次就各建一个没有意义。
    static let targetAVAudioFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                                   sampleRate: Double(targetSampleRate),
                                                   channels: AVAudioChannelCount(targetChannelCount),
                                                   interleaved: false)!

    func start() throws {
        guard !isRunning else { return }

        // **采集走 AUHAL，不走 `AVAudioEngine`。**
        //
        // ## 为什么必须换掉（2026-09-26，根因确认）
        //
        // `AVAudioEngine` 的输入节点**根本不听你设的设备**。官方技术文档 TN2091
        // 《Device input using the HAL Output Audio Unit》，以及另一个踩过同一个坑的
        // 项目（`larshurrelb/quicktalk-app`）写在它 CLAUDE.md 里的实测记录：
        //
        //   `AVAudioEngine.start()` **silently** rebinds its input to a system
        //   `CADefaultDeviceAggregate`… Setting `kAudioOutputUnitProperty_CurrentDevice`
        //   on `engine.inputNode` **succeeds, reads back correctly, survives
        //   `prepare()` — and is thrown away by `start()`.**
        //
        // 这一条解释了这个功能反复坏掉的全部现象：
        //
        // - 日志里 `设备=MacBook Pro麦克风 [id=88]` 是对的 —— 因为那是在 start **之前**
        //   读的；start 之后就变成聚合体了。
        // - 聚合体的**组成**由系统动态决定：只有麦克风时 1 声道（能录）；
        //   麦克风 + 语音引擎的语音处理时 3 声道（**纯静音**）。
        // - 所以「冷启动能用、说过话就不能用」，所以「放掉引擎、关语音处理都没用」
        //   —— 问题从来不是污染，是 `start()` 每次都会重绑。
        // - 所以它会「时好时坏」—— 聚合体取决于当时还有谁在用音频。
        //
        // AUHAL（`kAudioUnitSubType_HALOutput`）在 `AudioUnitInitialize` **之前**
        // 认下设备，之后一直保持。探针实测：干净状态与语音处理跑过之后**都是**
        // `48000Hz 1ch`、回调 375 次、峰值正常 —— 不再随别人变。
        guard let firstDevice = candidateInputDevices.first ?? Self.chosenInputDevice() else {
            onDiagnostic?("AUHAL 失败①：系统里找不到任何输入设备")
            throw LongFormRecorderError.microphoneUnavailable
        }
        // 队列可能只有一个（用户明确选了某个设备）—— 也要补进去，好让
        // `switchToNextCandidateDevice()` 知道「已经试过谁」。
        if candidateInputDevices.isEmpty { candidateInputDevices = [firstDevice] }
        inputDeviceSwitchCount = 0

        // **起不来也要往后换。** 原来只有「起来了、但一直给零」会换设备（看门狗那条），
        // 而**起不来**是直接抛错、整场结束 —— 2026-09-26 用户撞到的正是这一种
        //（设备报 3 声道 → 客户端格式建不出来 → `AUHAL 失败④` → 连续七次「开始失败」）。
        // 两个失败面必须共用同一套「顺着候选队列往后试」。
        //
        // 用户明确选了设备时队列只有一个（见 `inputDeviceCandidates`），所以这里对
        // 「他选的那个」仍然是不换的 —— 试一次、起不来就照旧报错。
        //
        // 已知代价（写在这里免得下次惊讶）：`AudioOutputUnitStart` 在设备被系统卡死时
        // 会**阻塞约 10 秒**才返回错误（实测 14:44:10 → 14:44:20），而这一段跑在主线程上
        //（`start()` 一直如此）。三个候选都撞上就是半分钟 —— 但那是「设备整个死了」的
        // 极端情形；本次这个格式建不出来的故障是**当秒就返回**的（15:10:02 起七次都在同秒）。
        var lastStartError: Error = LongFormRecorderError.microphoneUnavailable
        for candidateIndex in candidateInputDevices.indices {
            candidateDeviceIndex = candidateIndex
            let candidate = candidateInputDevices[candidateIndex]
            do {
                try bindAndStartCapture(on: candidate)
                if candidateIndex > 0 {
                    inputDeviceSwitchCount += candidateIndex
                    onDiagnostic?("🔁 前 \(candidateIndex) 个设备起不来，已改用"
                                  + "「\(candidate.name) [id=\(candidate.id)]」")
                }
                return
            } catch {
                lastStartError = error
                onDiagnostic?("设备「\(candidate.name) [id=\(candidate.id)]」起不来：\(error)")
            }
        }
        throw lastStartError
    }

    /// **在指定设备上**建 AUHAL 并起采 —— `start()` 与换设备共用这一份。
    ///
    /// 拆出来的理由就是这个顺序**错一步都是静默失败**：`SetRenderCallback` 装错时
    /// 每一步都返回 0、格式也读得到，但回调一次都不触发。两处各写一遍必然漂。
    private func bindAndStartCapture(on device: AudioInputDevice) throws {
        let boundName = "\(device.name) [id=\(device.id)]"
        boundInputDeviceName = boundName
        // 换了设备，上一个设备的连续静音计数、转换器和它的输入格式都必须重来 ——
        // 留着旧的会让「这个设备一开始就是零」被上一次的计数直接判死。
        consecutiveSilentBufferCount = 0
        converter = nil
        converterInputFormat = nil
        Self.onBoundInputDeviceName?(boundName)
        Self.onBoundInputDeviceID?(device.id)

        var componentDescription = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0)
        guard let halComponent = AudioComponentFindNext(nil, &componentDescription) else {
            onDiagnostic?("AUHAL 失败②：AudioComponentFindNext 找不到 HALOutput")
            throw LongFormRecorderError.microphoneUnavailable
        }
        var newUnit: AudioUnit?
        let instanceStatus = AudioComponentInstanceNew(halComponent, &newUnit)
        guard instanceStatus == noErr, let unit = newUnit else {
            onDiagnostic?("AUHAL 失败③：AudioComponentInstanceNew 返回 \(instanceStatus)")
            throw LongFormRecorderError.microphoneUnavailable
        }

        // 开输入（element 1）、关输出（element 0）—— TN2091 的第一段。
        var enableInput: UInt32 = 1
        var disableOutput: UInt32 = 0
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO,
                             kAudioUnitScope_Input, 1, &enableInput,
                             UInt32(MemoryLayout<UInt32>.size))
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO,
                             kAudioUnitScope_Output, 0, &disableOutput,
                             UInt32(MemoryLayout<UInt32>.size))
        // 认设备。**必须在 AudioUnitInitialize 之前** —— 这就是它和 AVAudioEngine
        // 的全部区别，也是它不会被丢掉的原因。
        var deviceID = device.id
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                             kAudioUnitScope_Global, 0, &deviceID,
                             UInt32(MemoryLayout<AudioDeviceID>.size))

        // 设备格式在 element 1 的 **Input scope** 上（TN2091：那是唯一读得到硬件格式的地方）。
        var hardwareFormat = AudioStreamBasicDescription()
        var hardwareFormatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat,
                             kAudioUnitScope_Input, 1, &hardwareFormat, &hardwareFormatSize)

        // 我们这一侧的格式设在 element 1 的 **Output scope** 上（AUHAL 自带转换器），
        // 而且**永远只要 1 个声道** —— 这一行是一个真实故障的修复，别再改回去。
        //
        // ## 为什么不能跟着设备的声道数建（2026-09-26 实测）
        //
        // 设备会报**多声道**：系统一旦进入语音处理 / 聚合体状态，内置麦自己就从
        // `1ch` 变成 `3ch`（探针实测：`MacBook Pro麦克风 [id=91]，3 声道`；
        // 更早那次是 `9ch`）。而**3 声道的 `AVAudioFormat` 根本建不出来**
        //（非交错格式要求一个合法的声道布局，1~2 声道能推断、3 声道不能），
        // 于是 `guard let clientAVFormat` 失败 → `AUHAL 失败④` → **整场录音起不来**。
        // 用户看到的就是「录音又无法使用了」（日志：连续 7 次 `开始失败`）。
        //
        // 而我们**本来只要一个声道**：目标是 16kHz 单声道，多声道到了下游那个
        // `AVAudioConverter` 里也一样要被混成单声道。所以在这里就取单声道，
        // 顺带把「设备报几个声道」这件事从这条路上彻底去掉 —— 1ch / 2ch / 3ch / 9ch
        // 走的都是同一段代码。
        //
        // 实测（2026-09-26，设备正处于 3 声道状态）：按 1 声道建格式 → `OSStatus=0`、
        // 起采成功、188 块里零块 0 个、拿到真实样本。
        var clientFormat = AudioStreamBasicDescription(
            mSampleRate: hardwareFormat.mSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
                | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32, mReserved: 0)
        AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat,
                             kAudioUnitScope_Output, 1, &clientFormat,
                             UInt32(MemoryLayout<AudioStreamBasicDescription>.size))

        guard let clientAVFormat = AVAudioFormat(streamDescription: &clientFormat),
              let renderBuffer = AVAudioPCMBuffer(pcmFormat: clientAVFormat,
                                                  frameCapacity: 8192) else {
            onDiagnostic?("AUHAL 失败④：客户端格式建不出来（\(clientFormat.mSampleRate)Hz \(clientFormat.mChannelsPerFrame)ch）")
            AudioComponentInstanceDispose(unit)
            throw LongFormRecorderError.microphoneUnavailable
        }
        halRenderBuffer = renderBuffer
        captureTargetFormat = Self.targetAVAudioFormat
        halUnit = unit

        // ★ **输入侧的回调是 `SetInputCallback`，不是 `SetRenderCallback`。**
        // 这里错了三次：装成 SetRenderCallback 时每一步都返回 0（成功）、格式也读得到，
        // 但**回调一次都不触发**。TN2091 写的是
        // `kAudioOutputUnitProperty_SetInputCallback` + `kAudioUnitScope_Global, 0`，
        // 回调里自己用 `AudioUnitRender` 去拉。
        var inputCallback = AURenderCallbackStruct(
            inputProc: longFormHALInputCallback,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback,
                             kAudioUnitScope_Global, 0, &inputCallback,
                             UInt32(MemoryLayout<AURenderCallbackStruct>.size))

        let initStatus = AudioUnitInitialize(unit)
        guard initStatus == noErr else {
            onDiagnostic?("AUHAL 失败⑤：AudioUnitInitialize 返回 \(initStatus)")
            AudioComponentInstanceDispose(unit)
            throw LongFormRecorderError.microphoneUnavailable
        }
        let startStatus = AudioOutputUnitStart(unit)
        guard startStatus == noErr else {
            onDiagnostic?("AUHAL 失败⑥：AudioOutputUnitStart 返回 \(startStatus)")
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
            throw LongFormRecorderError.microphoneUnavailable
        }

        isRunning = true
        boundInputDeviceID = device.id
        onDiagnostic?("AUHAL 已启动 · 设备=\(boundName) · "
                      + "\(hardwareFormat.mSampleRate)Hz \(hardwareFormat.mChannelsPerFrame)ch")
    }

    /// 实时线程：AUHAL 说「有数据了」，拉进 buffer 再交给同一条管线。
    ///
    /// **`AudioUnitRender` 的 bus 号是 element **1**（输入在 1 上）。** 拉完直接复用
    /// 原来的 `handleInputBuffer`，所以重采样、落盘、上行、电平四件事一行都不用改。
    nonisolated func halInputCallbackFired(
        actionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        timeStamp: UnsafePointer<AudioTimeStamp>,
        busNumber: UInt32,
        frameCount: UInt32
    ) -> OSStatus {
        guard let unit = halUnit,
              let renderBuffer = halRenderBuffer,
              let targetFormat = captureTargetFormat else { return noErr }
        renderBuffer.frameLength = frameCount
        var flags = actionFlags.pointee
        var bufferList = renderBuffer.mutableAudioBufferList
        let status = AudioUnitRender(unit, &flags, timeStamp, busNumber, frameCount, bufferList)
        guard status == noErr else { return status }
        handleInputBuffer(renderBuffer, targetFormat: targetFormat)
        return noErr
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        if let unit = halUnit {
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }
        halUnit = nil
        halRenderBuffer = nil
        captureTargetFormat = nil
        converter = nil
        smoothedLevel = 0
    }

    /// **换到候选队列里的下一个设备，同一场录音接着录。**
    ///
    /// 返回新绑上的设备名；没有下一个、或者都起不来，返回 nil。
    ///
    /// 顺序有讲究：先 `stop()` —— 它里面第一件事就是 `AudioOutputUnitStop`，而它会
    /// 等在途的输入回调跑完，所以返回之后 dispose 掉 unit 是安全的（`stop()` 一直是
    /// 这个用法：`stopRecording` 也是在采集正跑着的时候调它）。然后才动 `halUnit`。
    ///
    /// **这个方法不保证自己不在音频线程上** —— 调用方（控制器）负责把它甩到后台队列，
    /// 理由见 `onSilentInputNeedsDeviceSwitch`。
    func switchToNextCandidateDevice() -> String? {
        guard isRunning else { return nil }
        let previousDeviceName = boundInputDeviceName
        stop()

        while candidateDeviceIndex + 1 < candidateInputDevices.count {
            candidateDeviceIndex += 1
            let candidate = candidateInputDevices[candidateDeviceIndex]
            do {
                try bindAndStartCapture(on: candidate)
                inputDeviceSwitchCount += 1
                onDiagnostic?("🔁 输入设备已自动换到「\(candidate.name) [id=\(candidate.id)]」"
                              + "（原来的「\(previousDeviceName)」连续 "
                              + "\(Self.silentBufferAlarmThreshold) 块不产出采样）")
                return boundInputDeviceName
            } catch {
                // 这个也起不来就继续往后试 —— 队列里可能还有别的。
                onDiagnostic?("换到「\(candidate.name)」失败：\(error)")
            }
        }
        onDiagnostic?("输入设备换不动了：候选 \(candidateInputDevices.count) 个都试过，"
                      + "眼下没有能用的。")
        return nil
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
        if peak == 0 { consecutiveSilentBufferCount += 1 } else { consecutiveSilentBufferCount = 0 }

        // **连续静音就说出来 —— 计数器早就在数，只是从来没人看。**
        //
        // 实测 2026-09-26：麦克风送来的全是 0 时界面一切正常、文件照写、
        // 服务端不停超时重连，**117 秒一个字都没有，全程不报任何错**，
        // 用户唯一的线索是「它不转了」，而那时已经太晚。
        // **精确的零不是「安静」，是「这个设备没在交付采样」**（判据的理由见
        // `silentBufferAlarmThreshold`）。所以这里不再只是喊一声：先请控制器换设备
        //（换得动就接着录，用户无感），换不动了它才把这件事交给用户看。
        if consecutiveSilentBufferCount == Self.silentBufferAlarmThreshold {
            let device = boundInputDeviceName
            let silentSeconds = Double(consecutiveSilentBufferCount) / Self.buffersPerSecond
            onDiagnostic?(String(format: "⚠️ 连续 %d 块（约 %.1f 秒）没有任何声音 · 设备=%@"
                                 + " —— 这个设备不产出采样，换下一个试试。",
                                 consecutiveSilentBufferCount, silentSeconds, device))
            // 归零：换过去的那个也可能不产出采样，那还要能再报一次；不归零则每来
            // 一块都会喊一次。
            consecutiveSilentBufferCount = 0
            onSilentInputNeedsDeviceSwitch?(device)
        }

        // **异常安静那一路**（判据与「为什么不换设备」见 `onAbnormallyQuietInput`）。
        //
        // 它和上面那条共用「窗口」这个概念，但判的是完全不同的东西：上面问「有没有
        // 采样」，这里问「采样里有没有够大的声音」。2026-09-26 那次故障只踩中这一条。
        quietWindowPeak = max(quietWindowPeak, Double(peak) / 32768.0)
        if receivedBufferCount % Self.quietWindowBufferCount == 0 {
            if quietWindowPeak < Self.quietWindowPeakThreshold {
                quietWindowsSinceReport += 1
            } else {
                // 出现过一块响的 —— 说明声音回来了（可能正是自愈生效了），
                // 也说明这一段的告警可以重新武装。
                quietWindowsSinceReport = 0
                hasReportedQuietInputThisStretch = false
            }
            let observedWindowPeak = quietWindowPeak
            quietWindowPeak = 0
            if !hasReportedQuietInputThisStretch,
               quietWindowsSinceReport >= Self.quietWindowAlarmCount {
                hasReportedQuietInputThisStretch = true
                let quietSeconds = Double(Self.quietWindowAlarmCount * Self.quietWindowBufferCount)
                    / Self.buffersPerSecond
                onDiagnostic?(String(format: "⚠️ 连续 %.0f 秒峰值都低于 %.3f（本窗口 %.4f）· 设备=%@"
                                     + " —— 设备在出样本，但声音被压得很低；去查系统输入音量。",
                                     quietSeconds, Self.quietWindowPeakThreshold,
                                     observedWindowPeak, boundInputDeviceName))
                onAbnormallyQuietInput?(boundInputDeviceID, observedWindowPeak)
            }
        }

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
    /// 采到的格式和钉住的设备对不上 —— **这一场注定是静音，所以根本不开录。**
    /// 带的那句话是给用户看的（含「怎么办」），不是给日志看的。
    case inputFormatMismatch(String)

    var description: String {
        switch self {
        case .microphoneUnavailable: return "拿不到麦克风输入（权限或设备问题）"
        case .cannotBuildConverter: return "无法建立 16kHz 重采样器"
        case .missingAPIKey: return "还没填 API Key"
        case .cannotCreateStorage(let detail): return "无法创建录音文件：\(detail)"
        case .inputFormatMismatch(let message): return message
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
/// 「声音被压掉了」自愈的结果 —— 在后台线程算出来，交给主线程去写日志、
/// 去决定要不要告诉用户。
///
/// `logLines` 与 `userMessage` 分开是有意的：**跑了体检、发现一切正常**也要留一行日志
///（否则事后分不清「当时没查」和「查了、是好的」），但那件事不该弹给用户看 ——
/// 用户还没开口的房间本来就该是安静的。只有**真的改动了系统状态**才给他一句。
nonisolated struct QuietInputHealResult: Sendable {
    var logLines: [String]
    var userMessage: String?
}

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

    // MARK: - 麦克风的实际状态（设置页「麦克风」那一节读这两个）

    /// 最近一场录音**实际绑到**的设备名。nil = 还没录过。
    ///
    /// 和设置页里用户「选的那个」是两件事：选了不等于绑上了（设备可能被拔掉、
    /// 可能被别的进程占着），而用户要看的正是**真正用的那个**。
    @Published private(set) var lastBoundInputDeviceName: String?

    /// 最近一场连续静音的告警。nil = 没有过。
    @Published private(set) var lastSilentInputWarning: String?
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

    /// 录音期间持续抓摄像头帧的会话。**每一轮录音都新建一个。**
    ///
    /// 不能跨轮次复用一个：`AVCaptureSession` 重复 `addInput` 时 `canAddInput`
    /// 会返回 false，而那是**静默失败** —— 第二轮开始摄像头就再也起不来了。
    /// 用户实测的「关掉摄像头之后，下一轮再提就没反应」就是这个。
    private var cameraSession = RecordingCameraSession()

    /// 这一轮会话里抓到的帧。停止时一并交给润色。
    private var cameraFrames: [Data] = []

    /// 用户在这一轮里按过「退出抓帧」。**只作用于本轮** —— 下一轮录音重新按关键词激活。
    private var hasUserStoppedCameraThisSession = false

    /// 摄像头小窗要显示的东西。**单独一个对象** —— 见 `CameraPreviewModel` 的注释：
    /// 挂在控制器上会让 12 帧/秒变成「每秒重建整条刘海 12 次」。

    /// 小窗收起来了没有。**收起来只是收成一条标题栏**，入口永远在 ——
    /// 早期版本把「缩起来」做成整条消失，用户点一下就再也叫不回来。
    @Published var isCameraPreviewCollapsed = false

    /// 小窗现在摆在哪。
    ///
    /// **每场会话开始抓帧时复位成「刘海下面」**（见 `considerStartingCameraCapture`）——
    /// 用户挪窗是因为当时正举着纸，换一场会话那个情境就没了；复位也让 ⌘Enter 的
    /// 切换行为永远可预测（「在刘海下面就往下，不在就还原」）。
    @Published var cameraStripPlacement: CameraStripPlacement = .belowNotch

    /// 小窗展开成大图了没有。
    ///
    // 清晰度不再是这里的一个属性：它是用户在「录音」设置页选的
    //（`recordingCameraUsesHighResolution`），`considerStartingCameraCapture`
    // 起采时直接读设置写进 `cameraSession`。这里曾经有一个
    // `isCameraPreviewExpanded` 派生量，它随小窗开合走 —— 用户 2026-09-26 明确要求
    // 把清晰度做成**用户可选的参数**，两个真相源必然漂，所以那个属性删掉了。

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

    /// 转写里出现了摄像头就开抓；用户按过退出就这一轮都不再开。
    ///
    /// **判据跟着转写实时走，不是等到停止才判。** 用户的原话：「转写时能够识别到
    /// 摄像头这个文本，才需要抓取关键帧」「当能够在文本上识别到'摄像头'这三个字……
    /// 就按照一秒一帧来抓」。
    ///
    /// 这也顺带躲开了「停止那一刻最后一句还没定稿」那个竞态 —— 判据在整段录音里
    /// 反复检查，不是只看某一个瞬间。
    private func considerStartingCameraCapture() {
        guard phase == .recording else { return }
        let settings = AppSettingsStore.snapshot()
        guard settings.recordingPolishCapturesCamera else { return }
        guard !hasUserStoppedCameraThisSession else { return }
        guard !isCameraCapturing else { return }
        let spoken = transcriptPlainText + livePartialText
        let triggerKeywords = settings.recordingCameraTriggerKeywordList
        guard Self.transcriptMentionsCamera(spoken, keywords: triggerKeywords) else { return }

        // **这一段的参数全部来自「录音」设置页，一个都不写死。**
        //
        // 帧率、清晰度、留几帧都是用户在设置里选的，所以只能在这里读 —— 而且必须
        // 在读完之后**立刻**写进 `cameraSession`，因为它从 `queue` 上读这些值，
        // 而下面那句 `start()` 里的 `queue.async` 就是那道屏障（见
        // `RecordingCameraSession` 里那条「起采之前写好，起采之后只读」的约定）。
        cameraSession.previewFramesPerSecond = settings.recordingCameraPreviewFramesPerSecond
        cameraSession.modelFramesPerSecond = settings.recordingCameraModelFramesPerSecond
        cameraSession.setHighResolution(settings.recordingCameraUsesHighResolution)
        let maximumRetainedFrameCount = settings.recordingCameraMaximumFrameCount

        isCameraCapturing = true
        // 每一轮抓帧都从「刘海下面」开始 —— 用户挪窗是因为当时举着纸，
        // 那个情境不会跨会话。也让 ⌘Enter 的切换行为永远可预测。
        cameraStripPlacement = .belowNotch
        publishDiagnostic("转写里出现触发词（\(triggerKeywords.joined(separator: " / "))）"
                          + "→ 开始抓帧：画面 \(settings.recordingCameraPreviewFramesPerSecond) 帧/秒，"
                          + "送模型 \(settings.recordingCameraModelFramesPerSecond) 帧/秒，"
                          + "留 \(maximumRetainedFrameCount) 帧")
        // **预览帧只更新那个独立的小模型。**
        // 不经 `@Published` 走控制器 —— 走了的话整条刘海每秒重建几十次。
        cameraSession.onPreviewFrame = { [weak self] image in
            Task { @MainActor in self?.cameraPreviewModel.update(frame: image) }
        }
        cameraSession.onModelFrame = { [weak self] jpeg in
            Task { @MainActor in
                guard let self else { return }
                self.cameraFrames.append(jpeg)
                if self.cameraFrames.count > maximumRetainedFrameCount {
                    self.cameraFrames.removeFirst()
                }
                // 抓一帧、绿点闪一下、数字加一 —— 这三个都挂在预览模型上，
                // 所以它们不牵动刘海那条带。
                self.cameraPreviewModel.update(capturedFrameCount: self.cameraSession.capturedFrameCount)
            }
        }
        cameraSession.onFailure = { [weak self] reason in
            Task { @MainActor in self?.publishDiagnostic("摄像头抓帧失败：\(reason)") }
        }
        cameraSession.start()
    }

    /// 用户按了「退出抓帧」。**只作用于当前这一轮**，下一轮录音还会按关键词重新激活。
    func stopCameraCaptureForThisSession() {
        guard isCameraCapturing else { return }
        hasUserStoppedCameraThisSession = true
        isCameraCapturing = false
        cameraSession.stop()
        publishDiagnostic("用户退出了抓帧，本轮不再抓（下一轮录音仍会按关键词激活）")
    }

    /// 小窗标题栏上任何一个控件的**唯一入口**。全局监听和视图都调它。
    ///
    /// 七个动作放在一处而不是散在命中判定里，是因为命中判定只该回答「点到了哪个
    /// 控件」，「点到之后干什么」是另一件事 —— 上一版三个按钮的动作就写在那个
    /// 全局监听的分支里，再加四个会让那个闭包变成一团。
    func handleCameraStripControl(_ control: CameraStripControl) {
        switch control {
        case .mirror:
            cameraPreviewModel.isMirrored.toggle()
        case .toggleCollapse:
            // 动画归视图所有（`NotchCameraPreviewStrip` 上挂了 `.animation(_:value:)`）——
            // 这个控制器是纯数据层，为了一个 `withAnimation` 去 import SwiftUI 不值得。
            isCameraPreviewCollapsed.toggle()
        case .restore:
            setCameraStripPlacement(.belowNotch)
        case .moveLeft:
            setCameraStripPlacement(.left)
        case .moveDown:
            setCameraStripPlacement(.bottom)
        case .moveRight:
            setCameraStripPlacement(.right)
        case .close:
            stopCameraCaptureForThisSession()
        }
    }

    /// ⌘Enter 做的事：**切换**，不是「向下」。
    ///
    /// 用户 2026-09-26：「如果摄像头还在刘海下面，那么点击 Enter，它自动放到屏幕底部；
    /// 如果摄像头放在底部、左边或右边，无论哪个位置，只要它不在刘海下面，那么用户
    /// 点击 Enter，自动把摄像头恢复到原位置。」
    ///
    /// 和 `.moveDown` 是**两个不同的动词** —— 那个恒去底部，这个来回切。合并的话
    /// 「在底部时按 ⌘Enter」就永远回不去。
    func toggleCameraStripPlacement() {
        setCameraStripPlacement(cameraStripPlacement == .belowNotch ? .bottom : .belowNotch)
    }

    /// 位置变化都要从这里走，这样诊断日志一定记得打 ——
    /// 那一行是验证时唯一能核对「按钮到底有没有生效」的数字依据。
    private func setCameraStripPlacement(_ placement: CameraStripPlacement) {
        guard cameraStripPlacement != placement else { return }
        let previous = cameraStripPlacement
        cameraStripPlacement = placement
        publishDiagnostic("摄像头小窗位置 \(previous.displayName) → \(placement.displayName)")
    }

    /// 正在抓帧。刘海下面的小窗读它决定要不要显示。
    @Published private(set) var isCameraCapturing = false

    /// 小窗的预览数据。见 `CameraPreviewModel`。
    let cameraPreviewModel = CameraPreviewModel()

    /// 转写里有没有说出**触发短语**。
    ///
    /// **刻意不用裸的「摄像头」。** 用户 2026-09-26：「不能单纯是'摄像头'，因为很有
    /// 可能我说的话或者我平时的任务跟摄像头也是有关系的」。开会、写文档、聊天时说到
    /// 这个词太正常了，而每一次误触发都会开一次摄像头、发一批图。
    ///
    /// 所以要求是**精准的整词**：`123摄像头` 或 `打开摄像头`。这两串在日常句子里
    /// 不会偶然出现，而只在用户真的要用的时候说出来。
    ///
    /// 这也解释了它为什么必须是「整词包含」而不是「关键词 + 上下文判断」——
    /// 判断要花一次模型调用，而触发与否决定的是**要不要开摄像头**，那件事必须在
    /// 本地、在毫秒内定下来。
    /// 转写里有没有出现用户自己配的触发词。
    ///
    /// **关键词来自设置，不写死。** 用户在「录音」设置页里可以改成任何词 ——
    /// 判据仍然是**精确子串**（两个方向都小写化），不是「摄像头」这三个字：
    /// 光说「摄像头」不抓帧，日常对话里太容易带出来，而抓帧是有成本的。
    ///
    /// 传进来而不是自己去读设置，是为了让**同一段转写只读一次设置** ——
    /// `considerStartingCameraCapture` 里那几个参数必须来自同一次快照，
    /// 否则用户正好在判定的那一瞬改了设置，就会出现「按旧词触发、按新参数抓帧」。
    private static func transcriptMentionsCamera(_ text: String, keywords: [String]) -> Bool {
        guard !keywords.isEmpty else { return false }
        let lowered = text.lowercased()
        return keywords.contains { lowered.contains($0) }
    }

    /// 这一步到底会不会真的走模型。界面用它决定要不要进入「AI 润色中」相位 ——
    /// 判据必须和 `polishIfConfigured` 里的 guard **完全一致**，否则会出现
    /// 「闪了一下 AI 润色中但其实什么都没做」。
    private func shouldRunPolishStep() -> Bool {
        let settings = AppSettingsStore.snapshot()
        guard settings.recordingPolishEnabled else { return false }
        let styles = RecordingPolishStyleStore.shared.enabledStyles()
        return !styles.isEmpty || polishScreenshotJPEG != nil || !cameraFrames.isEmpty
    }

    /// 按「自定义风格」重写一遍转写原文。
    ///
    /// **没勾选任何风格、也没勾截图时原样返回** —— 用户明确要求这种情况下必须和以前
    /// 完全一致，一步都不多走（不建请求、不动文本）。
    private func polishIfConfigured(rawText: String, cameraFrames: [Data]) async -> String {
        let settings = AppSettingsStore.snapshot()
        guard settings.recordingPolishEnabled else { return rawText }
        let styles = RecordingPolishStyleStore.shared.enabledStyles()
        let screenshot = polishScreenshotJPEG
        guard !styles.isEmpty || screenshot != nil || !cameraFrames.isEmpty else { return rawText }
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return rawText }

        let prompt = RecordingPolishClient.buildPrompt(
            styles: styles, transcript: trimmed,
            hasScreenshot: screenshot != nil, cameraFrameCount: cameraFrames.count)
        publishDiagnostic("自定义风格：\(styles.count) 条风格 + 截图\(screenshot != nil ? "有" : "无")"
            + " + 摄像头\(cameraFrames.count) 帧，开始重写")
        do {
            let result = try await RecordingPolishClient.polish(
                prompt: prompt, screenshotJPEG: screenshot,
                cameraFrames: cameraFrames, settings: settings)
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

    /// 只写「润色文本」那一份。原文的 `.txt` 由 `LongFormTranscriptWriter` 在录制
    /// 过程中逐句写成，任何后处理都不该覆盖它。
    private func writePolishedTextFile(_ text: String) {
        guard let session = currentSession else {
            publishDiagnostic("写回失败：currentSession 已经是 nil")
            return
        }
        let url = session.polishedTranscriptFileURL(inFolder: folderURL)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            let written = (try? String(contentsOf: url, encoding: .utf8))?.count ?? -1
            publishDiagnostic("写润色文本 \(url.lastPathComponent)：送入 \(text.count) 字，读回 \(written) 字")
        } catch {
            publishDiagnostic("写润色文本失败：\(error)")
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

    // MARK: - 重新转写（网络断了、转写丢字之后重跑一遍）

    /// 正在重新转写的那几条录音（设置页的历史行据此显示进度）。
    @Published private(set) var retranscribingRecordingIDs: Set<String> = []

    /// **把一条已经录好的录音，重新喂给识别器跑一遍。**
    ///
    /// 用户 2026-09-26 要它的理由很具体：「网络问题或者其他的问题，他可能是断开了，然后
    /// 用户可以通过这样的历史点击重新进行一个重新撰写。」
    ///
    /// 走的**就是录音那一条链**，只换了音频来源：同一个 `VolcengineRealtimeASRClient`、
    /// 同一份设置解析出来的配置、同一个 `LongFormTranscriptWriter`。落盘的那份 `.wav`
    /// 本来就是上行字节流的原样副本（那条注释写着"可以原样重放给服务端、完整复现一次
    /// 识别"），所以这条路不需要任何转码。
    ///
    /// **旧的转写不删，改名留档**（`.txt` → `.txt.superseded`）。重跑也可能中途失败，
    /// 而"识别了一半就断"正是用户来点这个按钮的原因 —— 把上一份直接覆盖掉，等于让他
    /// 连那半份也丢了。
    func retranscribe(recordingID: String) async {
        guard !retranscribingRecordingIDs.contains(recordingID) else { return }
        guard !isRecording else {
            lastErrorMessage = "正在录音，等这一场结束再重新转写。"
            return
        }
        let settings = AppSettingsStore.snapshot()
        folderURL = RecordingLibraryStore.resolvedFolderURL(fromSettingsPath: settings.recordingSaveFolderPath)
        guard let session = RecordingLibraryStore.shared.allSessions().first(where: { $0.id == recordingID }) else {
            lastErrorMessage = "找不到这条录音（\(recordingID)）。"
            return
        }
        let audioURL = session.audioFileURL(inFolder: folderURL)
        guard let audioData = try? Data(contentsOf: audioURL), audioData.count > 44 else {
            lastErrorMessage = "这条录音的音频文件读不出来：\(audioURL.lastPathComponent)"
            return
        }

        retranscribingRecordingIDs.insert(recordingID)
        lastErrorMessage = nil
        // 转录写到一个**临时名字**上，跑完整了才顶替正式那两个文件 ——
        // 半路失败时屏幕上的历史和磁盘上的原文都还是完整的。
        let scratchSessionID = "\(recordingID)-retranscribing"
        defer { retranscribingRecordingIDs.remove(recordingID) }

        do {
            let writer = try LongFormTranscriptWriter(folder: folderURL,
                                                      sessionID: scratchSessionID,
                                                      appendingToExistingFile: false)
            let client = VolcengineRealtimeASRClient(configuration: makeASRConfiguration(from: settings))
            var segmentCount = 0
            var characterCount = 0
            client.onSegment = { segment in
                guard writer.commit(segment: segment) else { return }
                segmentCount += 1
                characterCount += segment.text.count
            }
            client.onDiagnostic = { [weak self] line in
                self?.publishDiagnostic("重新转写[\(recordingID)] \(line)")
            }
            client.connect()
            // 握手要先走完，否则前几块音频会被服务端丢掉（与录音那条路同一个理由）。
            try? await Task.sleep(for: .milliseconds(600))

            // 44 字节是 `RecordingAudioWriter` 自己写的 WAV 头；跳过去就是当初上行的那串字节。
            let pcmPayload = audioData.dropFirst(44)
            let chunkSize = 3_200          // 100ms @ 16kHz 单声道 PCM16
            var offset = pcmPayload.startIndex
            while offset < pcmPayload.endIndex {
                let end = pcmPayload.index(offset, offsetBy: chunkSize, limitedBy: pcmPayload.endIndex)
                    ?? pcmPayload.endIndex
                client.enqueue(audio: Data(pcmPayload[offset..<end]))
                offset = end
                // **不按实时速度喂**（12 秒的录音就应该 12 秒内跑完，3 小时的不该等 3 小时），
                // 但也不一次全灌进去 —— 每块之间让出一点点，服务端那边是流式解码。
                try? await Task.sleep(for: .milliseconds(Self.retranscribeChunkPacingMilliseconds))
            }

            // 末包一发服务端就关连接，定稿走 `onSegment`（与录音那条路同一个收口），
            // 所以这里只等"它结束了"，文字一律从落盘的那份读。
            await withCheckedContinuation { continuation in
                client.finishAndAwaitFinalResult(timeoutSeconds: 8.0) {
                    continuation.resume()
                }
            }
            writer.finalize()

            let newText = (try? String(contentsOf: writer.plainTextFileURL, encoding: .utf8)) ?? ""
            guard !newText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                lastErrorMessage = "重新转写没有拿到任何文字 —— 这条录音可能是静音的（长度 \(Int(session.recordedSeconds)) 秒）。"
                return
            }

            // 顶替：旧的先改名留档，再把新的搬过去。
            let textURL = session.transcriptFileURL(inFolder: folderURL)
            let jsonlURL = session.segmentFileURL(inFolder: folderURL)
            // **两个 `.superseded` 都要先清掉**：`moveItem` 在目标已存在时是失败的，
            // 而第二次重新转写同一条录音时那两个名字上还躺着上一次的留档 ——
            // 结果就是 `.txt` 换新了、`.jsonl` 悄悄留在旧的那份上（实测踩到）。
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: textURL.path + ".superseded"))
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: jsonlURL.path + ".superseded"))
            try? FileManager.default.moveItem(at: textURL, to: URL(fileURLWithPath: textURL.path + ".superseded"))
            try? FileManager.default.moveItem(at: jsonlURL, to: URL(fileURLWithPath: jsonlURL.path + ".superseded"))
            try FileManager.default.moveItem(at: writer.plainTextFileURL, to: textURL)
            try? FileManager.default.moveItem(at: writer.segmentFileURL, to: jsonlURL)

            var updated = session
            updated.characterCount = newText.count
            updated.segmentCount = segmentCount
            updated.endedCleanly = true
            updated.lastErrorMessage = nil
            RecordingLibraryStore.shared.upsert(updated)
            publishDiagnostic("重新转写完成：\(recordingID) · \(segmentCount) 段 · \(newText.count) 字")
        } catch {
            lastErrorMessage = "重新转写失败：\(error.localizedDescription)"
            publishDiagnostic("重新转写失败：\(recordingID) · \(error)")
        }
    }

    /// 每块音频之间的让位（毫秒）：**20 = 5 倍实时速度**（一块 100ms 的音频，20ms 发出去）。
    ///
    /// 这个数是被实测逼出来的，不是拍的：**0（尽快喂完）会坏**。2026-09-26 实测一条
    /// 49 秒的录音，`上行 1523KB`（整个文件都发出去了）而服务端回的自报位置只有
    /// `音频位置662ms`，定稿出来的是一句「这个。」—— 15 个字，而原文 109 个字。
    /// 流式识别是按到达速率解码的，灌得比它解得快，中间那一大段就被跳过了。
    ///
    /// 5 倍是**下限**的估计：真按实时（100）喂，一条 3 小时的录音要等 3 小时，那这个按钮
    /// 等于没用。要用更快的倍数，先在这台机器上拿一条长录音量一遍"服务端自报位置 ≈ 音频
    /// 总长"，别凭感觉调。
    private static let retranscribeChunkPacingMilliseconds = 20

    // MARK: - 录音 → Notion 笔记（2026-09-27）

    /// 检测到关键词了吗 —— 刘海左侧那两颗按钮据此出现。
    @Published private(set) var showsNotionNoteButtons = false
    /// 用户点了「取消笔记」（或那个唯一按钮）。**取消之后这一场就按普通录音处理**。
    @Published private(set) var notionNoteCancelled = false
    /// 已经写进 Notion 了 —— 那个位置换成「已保存笔记 ✓」，点它打开页面。
    @Published private(set) var notionNoteSaved = false
    /// **正在保存**（第三态）：刘海那条带子整个收掉，只留最左边那颗按钮显示「保存中…」
    ///（用户 2026-09-27：「然后这个刘海他就应该消失…只保留最左侧这个…保存中」）。
    @Published private(set) var isSavingNotionNote = false
    /// 那两个按钮上要显示的错误（保存失败时说出来，不静默）。
    @Published private(set) var notionNoteFailure: String?

    private var notionKeywordTimer: Timer?
    /// 保存成功之后等这么久再把整块带子收掉（用户要「在原取消按钮位置显示 5 秒」）。
    private static let notionNoteSavedLingerSeconds: Double = 5
    /// 检测节奏：开始后 **2 秒**第一次，之后**每 3 秒**一次（用户第 4 条）。
    private static let notionKeywordFirstCheckSeconds: Double = 2
    private static let notionKeywordCheckIntervalSeconds: Double = 3
    /// 开始跑那条检测循环。**只有开了总闸才起表** —— 关着时连表都没有。
    private func startNotionKeywordWatch() {
        guard AppSettingsStore.snapshot().notionNoteEnabled else { return }
        notionKeywordTimer?.invalidate()
        showsNotionNoteButtons = false
        notionNoteCancelled = false
        notionNoteSaved = false
        notionNoteFailure = nil
        notionWantsClipboard = false
        notionClipboardCancelled = false
        notionScreenCancelled = false
        notionReferenceScreenshots = []
        notionScreenMentionsHandled = 0
        // 先 2 秒一次，之后每 3 秒 —— 用一个一次性的表接上重复的表，语义最直白。
        notionKeywordTimer = Timer.scheduledTimer(
            withTimeInterval: Self.notionKeywordFirstCheckSeconds, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.checkNotionKeywords()
                self.notionKeywordTimer = Timer.scheduledTimer(
                    withTimeInterval: Self.notionKeywordCheckIntervalSeconds, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.checkNotionKeywords() }
                }
            }
        }
    }

    private func stopNotionKeywordWatch() {
        notionKeywordTimer?.invalidate()
        notionKeywordTimer = nil
    }

    /// **「剪贴板」那颗**：这一场不参考剪贴板了。
    ///
    /// 用户 2026-09-27：「点击这个按钮之后…就进入正常的 notion 笔记的保存，也就是说用户的
    /// 录音当做一个笔记，而不当做一个目标、不当做任务来处理」—— 所以取消的是**参考材料**，
    /// 这一场照旧存成笔记。
    func cancelNotionClipboardReference() {
        notionClipboardCancelled = true
        publishDiagnostic("用户点了「剪贴板」：这一场不参考剪贴板")
    }

    /// **「屏幕」那颗**：这一场不参考屏幕（已截的图也不再送）。
    func cancelNotionScreenReference() {
        notionScreenCancelled = true
        notionReferenceScreenshots = []
        publishDiagnostic("用户点了「屏幕」：这一场不参考屏幕内容")
    }

    /// 点「已保存笔记」= 打开那一页（用户第 7 条）。
    func openNotionNotePage() {
        let settings = AppSettingsStore.snapshot()
        let configured = settings.notionNoteOpenURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = configured.isEmpty
            ? NotionNoteClient.normalizedPageID(settings.notionNotePageID).map {
                "https://www.notion.so/" + $0.replacingOccurrences(of: "-", with: "")
              }
            : configured
        guard let target, let url = URL(string: target) else { return }
        NSWorkspace.shared.open(url)
    }

    /// 只看**开头与末尾各 100 字**（用户 2026-09-27 放宽后的话：「开头可能是前 100 个字…
    /// 就是前这么 10 句话，或者前 15 秒钟。都可以」）。
    private static let notionKeywordEdgeCharacterCount = 100

    /// 参考材料：说了「参考剪贴板 / 复制内容」这类词就把剪贴板拿来当材料。
    @Published private(set) var notionWantsClipboard = false
    /// 参考材料：说到「参考屏幕」时**当场**截下来的图（说几次截几张）。
    @Published private(set) var notionReferenceScreenshots: [Data] = []
    /// 用户按需取消掉的参考（按钮点了就置真，随后不再采集）。
    @Published private(set) var notionClipboardCancelled = false
    @Published private(set) var notionScreenCancelled = false

    /// 该不该在刘海左侧显示第二 / 第三颗按钮。
    var showsClipboardButton: Bool {
        showsNotionNoteButtons && notionWantsClipboard && !notionClipboardCancelled && !notionNoteSaved
    }
    var showsScreenButton: Bool {
        showsNotionNoteButtons && !notionReferenceScreenshots.isEmpty
            && !notionScreenCancelled && !notionNoteSaved
    }

    /// **开头与末尾**各 100 字里，有没有命中这一组关键词的任意一个。
    ///
    /// 比较前把空格与标点全去掉：转写是 AI 出来的，标点常常与嘴里说的不一致
    ///（用户第 4 条：「检测时去除空格和标点符号」）。
    nonisolated static func transcriptMentions(_ keywords: [String],
                                               in transcriptText: String,
                                               edgeCharacterCount: Int) -> Bool {
        func normalized(_ text: String) -> String { text.filter { $0.isLetter || $0.isNumber } }
        let normalizedTranscript = normalized(transcriptText)
        guard !normalizedTranscript.isEmpty else { return false }
        let head = String(normalizedTranscript.prefix(edgeCharacterCount))
        let tail = String(normalizedTranscript.suffix(edgeCharacterCount))
        for keyword in keywords {
            let needle = normalized(keyword)
            guard !needle.isEmpty else { continue }
            if head.contains(needle) || tail.contains(needle) { return true }
        }
        return false
    }

    private func checkNotionKeywords() {
        let settings = AppSettingsStore.snapshot()
        guard settings.notionNoteEnabled, !notionNoteCancelled, !notionNoteSaved else { return }
        let transcript = transcriptPlainText + livePartialText
        let window = Self.notionKeywordEdgeCharacterCount

        // ① 总开关：说了「保存笔记」这类词，这件事才存在。
        if !showsNotionNoteButtons {
            let noteKeywords = settings.notionNoteKeywords.split(separator: "\n").map(String.init)
            if Self.transcriptMentions(noteKeywords, in: transcript, edgeCharacterCount: window) {
                showsNotionNoteButtons = true
                publishDiagnostic("检测到 Notion 关键词，刘海左侧显示按钮")
            } else {
                return   // 总开关没开，后面两组都不看
            }
        }

        // ② 参考剪贴板：说了「复制内容 / 选中内容」这类词。
        if !notionWantsClipboard, !notionClipboardCancelled {
            let clipboardKeywords = settings.notionClipboardKeywords.split(separator: "\n").map(String.init)
            if Self.transcriptMentions(clipboardKeywords, in: transcript, edgeCharacterCount: window) {
                notionWantsClipboard = true
                publishDiagnostic("检测到「参考剪贴板」，剪贴板内容将作为参考材料")
            }
        }

        // ③ 参考屏幕：**说到就当场截一张**（说几次截几张）。这里用的是**刚刚新出现的**
        //    那段文字 —— 每命中一次就多一张，所以只在文本变长时才可能再截。
        if !notionScreenCancelled {
            let screenKeywords = settings.notionScreenKeywords.split(separator: "\n").map(String.init)
            let mentionCount = Self.transcriptMentionCount(screenKeywords, in: transcript,
                                                           edgeCharacterCount: window)
            if mentionCount > notionScreenMentionsHandled {
                let newMentions = mentionCount - notionScreenMentionsHandled
                notionScreenMentionsHandled = mentionCount
                for _ in 0..<newMentions { captureNotionReferenceScreenshot() }
            }
        }
    }

    /// 命中次数（不是"有没有命中"）—— 用户说几次「参考屏幕」就要几张图。
    nonisolated static func transcriptMentionCount(_ keywords: [String],
                                                   in transcriptText: String,
                                                   edgeCharacterCount: Int) -> Int {
        func normalized(_ text: String) -> String { text.filter { $0.isLetter || $0.isNumber } }
        let normalizedTranscript = normalized(transcriptText)
        guard !normalizedTranscript.isEmpty else { return 0 }
        let head = String(normalizedTranscript.prefix(edgeCharacterCount))
        let tail = String(normalizedTranscript.suffix(edgeCharacterCount))
        var count = 0
        for keyword in keywords {
            let needle = normalized(keyword)
            guard !needle.isEmpty else { continue }
            count += head.components(separatedBy: needle).count - 1
            count += tail.components(separatedBy: needle).count - 1
        }
        return count
    }

    /// 已经处理过的「参考屏幕」提及次数（避免同一句话反复截图）。
    private var notionScreenMentionsHandled = 0

    private func captureNotionReferenceScreenshot() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let captures = try? await CompanionScreenCaptureUtility.captureAllScreensAsJPEG() else {
                self.publishDiagnostic("「参考屏幕」要截图，但这次截不到")
                return
            }
            // 只用主屏那一张：用户说的是"当前的屏幕"，而多屏会一下子塞好几张。
            guard let primary = captures.first?.imageData else { return }
            self.notionReferenceScreenshots.append(primary)
            self.publishDiagnostic("「参考屏幕」：已截第 \(self.notionReferenceScreenshots.count) 张")
        }
    }

    /// 「保存」：用户明确点了保存。什么都不点等于这个（用户第 3 条：默认保存）。    /// 「保存」：用户明确点了保存。什么都不点等于这个（用户第 3 条：默认保存）。
    func confirmNotionNote() {
        notionNoteCancelled = false
        publishDiagnostic("用户点了保存笔记")
    }

    /// 「取消」：这一场按**普通录音**处理，不写 Notion。
    ///
    /// **取消是彻底的**（用户 2026-09-27：「只要用户点击取消，就完全的取消，甚至取消后后台的
    /// 这个什么一秒钟检测一次这个代码…就直接取消掉」）：按钮收掉、检测表停掉、并且
    /// `notionNoteCancelled` 一旦为真就**再也不会让按钮回来**（哪怕用户最后又说了一次关键词）。
    func cancelNotionNote() {
        notionNoteCancelled = true
        showsNotionNoteButtons = false
        stopNotionKeywordWatch()
        publishDiagnostic("用户取消了笔记：按钮收掉、检测停掉，这一场按普通录音处理")
    }

    /// **点那颗按钮** —— 三种状态各自的意思。控制器（全局监听）接走点击之后调它，
    /// 因为面板是点击穿透的，SwiftUI 那层收不到。
    func handleNotionNoteButtonTap() {
        if notionNoteSaved {
            openNotionNotePage()
        } else if !isSavingNotionNote {
            cancelNotionNote()
        }
    }

    /// 把这一场整理成一页笔记写进 Notion。
    ///
    /// 两步：**先让模型按用户那套提示词整理**（独立的一套服务商配置），再交给
    /// `NotionNoteClient` 按形状写进去。整理失败就**只存原文**——用户至少拿到录音，
    /// 而不是什么都没发生。
    private func saveNotionNote(rawText: String) async {
        let settings = AppSettingsStore.snapshot()
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            notionNoteFailure = "这一场没有文字，没写成笔记"
            return
        }
        // **参考材料**：只有用户说了「复制内容 / 选中内容」或「参考屏幕」才去读 ——
        // 没说要读的时候连剪贴板都不碰（用户第 8 条那一族的分寸：不该参考的绝不参考）。
        var reference = NotionNoteReference()
        if !notionClipboardCancelled && notionWantsClipboard {
            reference = NotionNoteReferenceGatherer.readClipboard()
        }
        if !notionScreenCancelled {
            reference.screenScreenshots = notionReferenceScreenshots
        }
        publishDiagnostic("Notion 参考材料：\(reference.logLine)")
        let hasReference = !reference.isEmpty

        var summary = "录音笔记"
        var outline = trimmed
        var formatted: [NotionNoteClient.RichBlock] = []
        do {
            // **两条分支的提示词在这里分家**（见 `NotionNoteReference.buildPrompt`）：
            // 有材料时用户的话是"指令"，没有材料时用户的话是"要被整理的笔记本身"。
            let reply = try await RecordingPolishClient.organizeNotionNote(
                prompt: NotionNoteReferenceGatherer.buildPrompt(
                    transcript: trimmed,
                    reference: reference,
                    formattingPrompt: settings.notionNotePrompt),
                screenshotJPEG: reference.clipboardImageJPEG,
                referenceImages: reference.screenScreenshots,
                settings: settings)
            let parsed = Self.parseNotionNoteReply(reply)
            summary = parsed.summary
            outline = parsed.outline
            formatted = Self.richBlocks(fromMarkdown: parsed.formatted)
            publishDiagnostic("Notion 整理完成：总结 \(summary.count) 字 · 大纲 \(outline.count) 字 · 排版块 \(formatted.count) 个")
        } catch {
            publishDiagnostic("Notion 整理失败（只存原文）：\(error.localizedDescription)")
            outline = trimmed
        }
        _ = hasReference   // 分支已在提示词里体现；这里留一个显式的名字给读代码的人。

        let title = Self.notionNoteTitle(for: Date())
        let request = NotionNoteClient.SaveRequest(
            title: title,
            summary: summary,
            outline: outline,
            formattedBlocks: formatted.isEmpty
                ? [.paragraph([.init(text: trimmed)])]
                : formatted,
            rawLines: trimmed.split(separator: "\n").map(String.init).isEmpty
                ? [trimmed] : trimmed.split(separator: "\n").map(String.init))
        do {
            let url = try await NotionNoteClient().save(request)
            notionNoteSaved = true
            notionNoteFailure = nil
            publishDiagnostic("已保存到 Notion：\(url)")
        } catch {
            notionNoteFailure = error.localizedDescription
            publishDiagnostic("Notion 保存失败：\(error.localizedDescription)")
        }
    }

    /// `2026年3月27日 06:13` —— 用户给的格式。
    nonisolated static func notionNoteTitle(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月d日 HH:mm"
        return formatter.string(from: date)
    }

    /// 把模型那三段输出切开。**切不开时不猜**：整段当排版，大纲留一句说明。
    nonisolated static func parseNotionNoteReply(_ reply: String)
        -> (summary: String, outline: String, formatted: String) {
        func section(_ name: String, next: [String]) -> String? {
            guard let start = reply.range(of: "【\(name)】") else { return nil }
            let after = reply[start.upperBound...]
            var end = after.endIndex
            for marker in next {
                if let r = after.range(of: "【\(marker)】"), r.lowerBound < end { end = r.lowerBound }
            }
            return String(after[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let summary = section("总结", next: ["大纲", "排版"]) ?? ""
        let outline = section("大纲", next: ["排版"])
        let formatted = section("排版", next: [])
        return (summary.isEmpty ? "录音笔记" : summary,
                outline ?? reply.trimmingCharacters(in: .whitespacesAndNewlines),
                formatted ?? reply.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Markdown → Notion 块。**只认用户点名的那几种**，认不出的一律普通段落（不丢内容）。
    nonisolated static func richBlocks(fromMarkdown markdown: String) -> [NotionNoteClient.RichBlock] {
        var blocks: [NotionNoteClient.RichBlock] = []
        for rawLine in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("### ") { blocks.append(.heading(level: 3, text: String(line.dropFirst(4)))); continue }
            if line.hasPrefix("## ") { blocks.append(.heading(level: 2, text: String(line.dropFirst(3)))); continue }
            if line.hasPrefix("# ") { blocks.append(.heading(level: 1, text: String(line.dropFirst(2)))); continue }
            if line == "---" || line == "***" { blocks.append(.divider); continue }
            if line.hasPrefix("> ") { blocks.append(.quote(spans(fromInline: String(line.dropFirst(2))))); continue }
            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                blocks.append(.bulleted(spans(fromInline: String(line.dropFirst(2))))); continue
            }
            if line.hasPrefix("|"), line.hasSuffix("|") {
                let cells = line.dropFirst().dropLast().split(separator: "|").map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                // 分隔行（`|---|---|`）丢掉，它不是内容。
                if cells.allSatisfy({ $0.allSatisfy { $0 == "-" || $0 == ":" } }) { continue }
                blocks.append(.tableRow(cells)); continue
            }
            blocks.append(.paragraph(spans(fromInline: line)))
        }
        return blocks
    }

    /// 行内样式：`**加粗**`、`` `代码` ``、`{红}` 这类**后置颜色标记**（提示词里就是这么要求的）。
    nonisolated static func spans(fromInline line: String) -> [NotionNoteClient.RichSpan] {
        var spans: [NotionNoteClient.RichSpan] = []
        var buffer = ""
        var bold = false
        var code = false
        func flush() {
            guard !buffer.isEmpty else { return }
            spans.append(.init(text: buffer, bold: bold, code: code))
            buffer = ""
        }
        var index = line.startIndex
        while index < line.endIndex {
            let rest = line[index...]
            if rest.hasPrefix("**") {
                flush(); bold.toggle(); index = line.index(index, offsetBy: 2); continue
            }
            if rest.hasPrefix("`") {
                flush(); code.toggle(); index = line.index(index, offsetBy: 1); continue
            }
            if rest.hasPrefix("{") {
                // 颜色标记写在被标记内容的**后面**：`重点内容{红}`。
                if let close = rest.firstIndex(of: "}") {
                    let name = String(rest[rest.index(after: index)..<close])
                    if let color = Self.notionColor(named: name) {
                        flush()
                        if var last = spans.popLast() {
                            last.color = color
                            spans.append(last)
                        }
                        index = line.index(after: close)
                        continue
                    }
                }
            }
            buffer.append(line[index])
            index = line.index(after: index)
        }
        flush()
        return spans.isEmpty ? [.init(text: line)] : spans
    }

    nonisolated static func notionColor(named name: String) -> String? {
        switch name {
        case "红", "红色": return "red"
        case "蓝", "蓝色": return "blue"
        case "绿", "绿色": return "green"
        case "黄", "黄色": return "yellow"
        case "橙", "橙色": return "orange"
        case "紫", "紫色": return "purple"
        case "灰", "灰色": return "gray"
        case "棕", "棕色": return "brown"
        case "粉", "粉色": return "pink"
        default: return nil
        }
    }

    /// 结束这一场：让面板消失，下次录音从头开始。
    func finishCurrentSession() {
        stopNotionKeywordWatch()
        showsNotionNoteButtons = false
        notionNoteCancelled = false
        notionNoteSaved = false
        notionNoteFailure = nil
        isSavingNotionNote = false
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
        AppSupportDirectory.folderURLOrHome.appendingPathComponent("录音诊断.log")
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

    /// **刘海右侧那颗按钮被点了一下** —— 收起态的全局监听与展开态的 SwiftUI 按钮都走这里。
    ///
    /// 用户 2026-09-26：「刘海屏右侧的录音按钮，在录音时点击它应停止录音并进入转写模式，
    /// 现在点击没有功能，需要让它点击后自动停止录音」。
    ///
    /// 四态一一对应，**没有任何一条会掉到"开始录音"上去**：
    ///
    ///   * 润色中 / 倒计时中 → **放弃这一场**（已经转写的文字与录音文件都保留，只是不进剪贴板、
    ///     不粘贴 —— 这正是他要的「点击数字自动取消转写，但已转写的内容或录音文件必须保留」）；
    ///   * 录音中 → 停止并进入转写；
    ///   * 其它 → 开始录（接着上一场）。
    ///
    /// **这一处必须唯一。** 原来这份判断在两个地方各写了一遍（收起态监听的闭包、展开态那颗
    /// SwiftUI 按钮），而两处的「润色中」那一支都误留了一段**构造视图**的代码
    ///（`ShimmeringPolishText(text:)`）—— 它既不取消也不 `return`，于是往下**掉进了"开始录音"**
    /// ✗。这就是"点了没反应、甚至更糟"的来源：一处逻辑写两遍，错也只错在其中一遍，而
    /// 用户看到的是同一个按钮。
    func handleWingButtonTap() {
        publishDiagnostic("右侧按钮被点：润色=\(isPolishingTranscript) 倒计时=\(isFinalizingTranscript) 录音=\(isRecording) 会话=\(isSessionActive)")
        if isPolishingTranscript || isFinalizingTranscript {
            cancelCurrentRecording()
        } else if isRecording {
            stopRecording()
        } else {
            startRecording(resumingCurrentSession: isSessionActive)
        }
    }

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
            return
        }

        // 把「绑到了谁」和「连续静音了」接进这一层：设置页读的是控制器上的
        // 两个 @Published，而不是去问那个音频对象。
        LongFormAudioCapture.onBoundInputDeviceName = { [weak self] name in
            Task { @MainActor in self?.lastBoundInputDeviceName = name }
        }
        LongFormAudioCapture.onBoundInputDeviceID = { [weak self] deviceID in
            Task { @MainActor in self?.boundInputDeviceID = deviceID }
        }
        LongFormAudioCapture.onFormatMismatchDetected = { [weak self] message in
            Task { @MainActor in self?.lastErrorMessage = message }
        }
        // **换设备不能在这条线程上做。** `onSilentInputNeedsDeviceSwitch` 是从音频线程
        // 调上来的（回调那头要求「立刻返回」），而换设备要停 unit、重新认设备、重启 ——
        // 实测慢的时候是秒级。所以甩到后台队列，回来再更新界面。
        let captureForDeviceSwitch = capture
        capture.onSilentInputNeedsDeviceSwitch = { [weak self] previousDevice in
            Task.detached(priority: .userInitiated) {
                let newDevice = captureForDeviceSwitch.switchToNextCandidateDevice()
                await MainActor.run {
                    self?.handleInputDeviceSwitchResult(newDevice,
                                                        previousDevice: previousDevice)
                }
            }
        }
        // **异常安静 → 去看系统输入音量，低了就修。**
        //
        // 与上面那条是两个不同的动作，别合并：换设备解决的是「设备不给采样」，
        // 而音量被压掉时换哪个设备都一样安静、还会平白把正在录的这一场切开。
        // 2026-09-26 用户报的那次（只能录一句 / 字幕卡顿 / 转写后没有）根因就是它。
        capture.onAbnormallyQuietInput = { [weak self] deviceID, observedPeak in
            Task.detached(priority: .userInitiated) {
                let result = LongFormRecorderController.healInputGainIfNeeded(
                    onDeviceID: deviceID,
                    reason: String(format: "录音中途声音极小（窗内峰值 %.4f）", observedPeak))
                await MainActor.run { self?.reportQuietInputHeal(result) }
            }
        }

        phase = .starting
        lastErrorMessage = nil
        connectionRotationCount = 0
        isEditorOpenAtStopTime = false

        // **判重窗口每一轮都必须清零 —— 这一行修的是「按下录音后前 8 秒屏幕上一个字
        // 都没有」那个 bug。**
        //
        // 这个字段的用途是：重连时重喂了 N 毫秒的旧音频，那段被重新识别、回来的文字
        // 是重复的，按服务端自己的毫秒时间戳丢掉。**它只在重连那一处被写过**
        //（`beginConnection`），从来没有人清回来 —— 而**每一场录音服务端的时间轴都是
        // 从 0 重计的**。于是自从第一场重连之后，**之后每一场录音开头 N 毫秒识别到的
        // 字全部被当成重复丢掉**。
        //
        // 用户实测的现象：按下录音后整整 8 秒屏幕上完全空白，第 8 秒才开始出字。
        // 8 秒 = 那次重连重喂的 **7898 毫秒**（`RecentAudioRing` 存 8 秒）。
        //
        // 日志里能同时看到「2 秒就到了字」和「屏幕全白」并不矛盾：诊断行打在**客户端**
        //（`VolcengineRealtimeASRClient.publishSegment`），而丢段发生在它**下游一层**
        //（`client.onSegment` 里那个 `endMilliseconds` 判断）。查这个 bug 时一度量错
        // 了地方 —— 量在下游的截断点之前，得到的数字自然是「一切正常」。
        //
        // 和下面摄像头那段是同一类错误：一个「本轮有效」的标志忘了在本轮开头复位。
        seamSuppressionMilliseconds = 0

        // **摄像头状态每一轮都必须重置。** 少了这一段，「用户退出抓帧」那个标志会
        // 一直挂着，之后**每一轮**录音都再也不抓 —— 用户实测：「关闭录音，开启全新的
        // 录音之后再触发关键词，没有效果」。
        //
        // 而且不能只重置标志：`AVCaptureSession` 重复 `addInput` 会被静默拒绝
        // （`canAddInput` 返回 false，不报错），所以每一轮要换一个**全新**的采集会话。
        hasUserStoppedCameraThisSession = false
        isCameraCapturing = false
        cameraFrames = []
        cameraPreviewModel.reset()
        cameraSession = RecordingCameraSession()
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

            // 起采之前先把候选设备排好：用户选定的 → 系统默认 → 其余真设备。
            // 第一个不产出采样时，看门狗会顺着这个队列往后换。见
            // `AudioInputDeviceCatalog` 和 `LongFormAudioCapture.candidateInputDevices`。
            let inputCandidates = Self.inputDeviceCandidates(for: settings)
            capture.candidateInputDevices = inputCandidates
            // **起录前体检**：在用户开口之前就修掉「静音 / 音量被压到极低」，并留下
            // 一行「设备是谁、什么状态」。理由见 `preflightInputDeviceCheck` ——
            // 2026-09-26 那次故障的根因（系统输入音量 0.275）在这一步就是已知的。
            if let firstCandidate = inputCandidates.first {
                preflightInputDeviceCheck(firstCandidate)
            }
            try capture.start()

            startedAt = Date()
            lastSpeechAt = Date()
            lastConnectionStartedAt = Date()
            isSessionActive = true
            // **整场录音期间对外声明「我在录」。** 别的子系统（语音引擎）据此
            phase = .recording
            startInputGainWatch()
            startNotionKeywordWatch()
            publishDiagnostic("开始录音 \(sessionID) · 档位 \(settings.recordingEffectiveResourceID)"
                          + " · 判重窗口 \(seamSuppressionMilliseconds)ms")
            startTimers()
        } catch {
            publishDiagnostic("开始失败：\(error)")
            lastErrorMessage = error.localizedDescription
            teardownStorage()
        phase = .idle
        }
    }

    /// 起采时按这个顺序试设备：**用户选定的 → 系统默认 → 其余真设备**。
    ///
    /// 为什么这么排：用户明确选过就以他为准（不选就是「跟系统默认」—— 那是绝大多数
    /// 情况，也是本机现在的状态）；系统默认之后是兜底。兜底这一层是**实测换来的**：
    /// 2026-09-26 内置麦被别的软件搞成「对谁都只给零、然后连起都起不来」的那一刻，
    /// iPhone 连续互通那个麦克风是好的 —— 换过去，同一份代码就录到了真实声音
    /// （峰值 984/32768）。
    ///
    /// **虚拟设备不参与兜底。** 环回声卡（录屏软件那种）天然不产出采样：没人往里送
    /// 声音时它就是精确的零，会被看门狗当成坏设备换掉。但用户如果**在设置里明确选了**
    /// 它（比如就是想录系统声音），那以他为准 —— 这时候换设备对他是帮倒忙。
    static func inputDeviceCandidates(for settings: AppSettings) -> [AudioInputDevice] {
        if let chosenDevice = AudioInputDeviceCatalog.device(withUID: settings.recordingInputDeviceUID) {
            return [chosenDevice]
        }
        let allDevices = AudioInputDeviceCatalog.allInputDevices()
        var ordered: [AudioInputDevice] = []
        if let systemDefault = allDevices.first(where: \.isSystemDefault) {
            ordered.append(systemDefault)
        }
        for device in allDevices where !device.isVirtual {
            if !ordered.contains(where: { $0.id == device.id }) {
                ordered.append(device)
            }
        }
        return ordered
    }

    /// 自动换设备的结果。
    ///
    /// 成功：这一场接着录，用户只会在设置页看到一行说明 —— 正是「有问题它自己修」。
    /// 失败：**这是唯一该让用户知道的情况**，而且必须说清三件事 —— 哪一段没了、
    /// 谁占着麦克风、以及这不是他做错了什么。
    private func handleInputDeviceSwitchResult(_ newDeviceName: String?, previousDevice: String) {
        guard let newDeviceName else {
            // 候选队列只有一个，说明**用户明确选了那个设备**（见 `inputDeviceCandidates`）。
            // 这时候不能替他停：他可能就是要那个 —— 虚拟环回声卡本来就是「没人往里送
            // 声音时是零」，为了录系统声音选它是正当用法。所以只报，把判断权留给他。
            let userChoseTheDevice = !AppSettingsStore.snapshot().recordingInputDeviceUID.isEmpty
            if !userChoseTheDevice {
                // 没选过（跟系统默认）而所有候选都死了：这一场注定是空的，收尾并说明，
                // 比让他录 20 分钟的静音、最后拿到一个 0 字的结果更有用。
                // 采集这时已经停了（`switchToNextCandidateDevice` 里 stop 掉了）。
                stopRecording()
            }
            let holders = microphoneHolderDisplayNames()
            let holderSentence = holders.isEmpty
                ? "眼下没有别的程序在开麦，问题出在这个设备本身"
                : "现在开着麦克风的是：\(holders.joined(separator: "、"))"
            // 兜底那一句是**唯一**该告诉用户怎么做的场合：换设备是我们能自己做的，
            // 而设备整个被系统卡死时，只有退出占用者或重启音频系统能解 —— 不说，
            // 用户就卡在这里了。
            let recoverySentence = "要立刻恢复：退出上面那个 App，"
                + "或者在终端里跑 `sudo killall coreaudiod`（重启音频系统，约 2 秒）。"
            let message = userChoseTheDevice
                ? "你选的「\(previousDevice)」不产出采样，这一段录下来是空的。"
                    + "\(holderSentence)。（这一场按你的选择继续录，没有换成别的设备。）"
                : "「\(previousDevice)」不产出采样，而且没有别的输入设备能顶上。"
                    + "\(holderSentence)。这一段录下来是空的。\(recoverySentence)"
            lastSilentInputWarning = message
            lastErrorMessage = message
            return
        }
        lastBoundInputDeviceName = newDeviceName
        lastSilentInputWarning =
            "「\(previousDevice)」不产出采样，已自动换到 \(newDeviceName) 接着录。"
    }

    // MARK: - 起录前体检 + 「被压掉的声音」自愈（2026-09-26）

    /// 低于这个输入音量就认为「这台机器现在录不到人说话」，体检时直接调上去。
    /// 0.5 是保守值：实测那次故障是 0.275，而正常机器的输入音量在 0.7~1.0 之间。
    static let lowInputVolumeThreshold: Float = 0.5
    /// 体检／自愈时把过低的输入音量调到这个值。1.0 = 系统那条滑杆拉满。
    static let healedInputVolume: Float = 1.0

    /// 上一次起录时的设备摘要（名字 + id + 声道数），用来发现「设备换了」。
    private var lastPreflightDeviceSummary: String?
    /// 当前绑着的输入设备 id（由 `LongFormAudioCapture.onBoundInputDeviceID` 填）。
    /// 录制期间的例行复查读它、修它。
    private var boundInputDeviceID: AudioDeviceID = kAudioObjectUnknown
    /// 录制期间的例行复查表。**只在录音期间存在**，见 `startInputGainWatch`。
    private var inputGainWatchTimer: Timer?

    /// **起录前体检**：记一行「绑到了谁、它现在什么状态」，并修掉两种一眼能看出的坏状态。
    ///
    /// 为什么值得每次起录花这几个 CoreAudio 读：2026-09-26 那次故障里，系统输入音量是
    /// 0.275 —— 而这件事**在用户开口之前就已经是已知的**，只要有人去看。修在开头，
    /// 用户就不必先录一段没人听得见的音、再由服务端超时告诉他。
    ///
    /// 做三件事：
    ///   1. 静音 → 打开；音量低于 `lowInputVolumeThreshold` → 调到 1.0。都记一行日志。
    ///   2. 设备与上一场不同（名字 / id / 声道数变了）→ 单独记一行「设备变了」。
    ///      2026-09-26 同一天里内置麦克风从 `[id=88] 1 声道` 变成 `[id=91] 3 声道`，
    ///      而这条变化当时只能靠人一行行翻录音日志才看得出来。
    ///   3. 一切正常也记一行 —— **「正常」也要留下证据**，否则事后无法区分
    ///      「当时没查」和「当时查了、是好的」。
    private func preflightInputDeviceCheck(_ device: AudioInputDevice) {
        let channelCount = AudioInputDeviceCatalog.inputChannelCount(of: device.id)
        let volumeBefore = AudioInputDeviceCatalog.inputVolume(of: device.id)
        let isMuted = AudioInputDeviceCatalog.isInputMuted(of: device.id)

        var healingNotes: [String] = []
        if isMuted == true {
            let didUnmute = AudioInputDeviceCatalog.setInputMuted(false, on: device.id)
            healingNotes.append(didUnmute
                                ? "输入本来是静音的，已替你打开"
                                : "输入处于静音状态，而且打不开（这个设备不让改）")
        }
        if let volumeBefore, volumeBefore < Self.lowInputVolumeThreshold {
            let didRaise = AudioInputDeviceCatalog.setInputVolume(Self.healedInputVolume, on: device.id)
            if didRaise {
                healingNotes.append(String(format: "输入音量只有 %.2f（衰减约 %.0fdB），已调到 %.2f",
                                           volumeBefore, -20 * log10(Double(max(volumeBefore, 0.001))),
                                           Self.healedInputVolume))
            } else {
                healingNotes.append(String(format: "输入音量只有 %.2f，而且改不动（这个设备不让改）",
                                           volumeBefore))
            }
        }

        let deviceSummary = "\(device.name) [id=\(device.id)] \(channelCount)ch"
        publishDiagnostic("🎙️ 起录体检 · 设备=\(deviceSummary) · "
                          + "音量=\(volumeBefore.map { String(format: "%.2f", $0) } ?? "读不到") · "
                          + "静音=\(isMuted.map { $0 ? "是" : "否" } ?? "读不到")")
        if let previousSummary = lastPreflightDeviceSummary, previousSummary != deviceSummary {
            publishDiagnostic("🔀 输入设备和上一场不一样了：\(previousSummary) → \(deviceSummary)")
        }
        lastPreflightDeviceSummary = deviceSummary
        healingNotes.forEach { publishDiagnostic("🩺 \($0)") }
        if !healingNotes.isEmpty {
            lastSilentInputWarning = "起录前体检：" + healingNotes.joined(separator: "；")
                + "。如果你是有意调低的，在「系统设置 → 声音 → 输入」里可以改回去。"
        }
    }

    /// 「声音被压掉了」的自愈：读绑定设备的输入音量与静音状态，能修就修。
    ///
    /// 顺序有讲究：**先看静音，再看音量** —— 设备被静音时音量读数没有意义。
    /// 两样都正常时**什么都不改**：那种情况大概率只是房间真的安静（或者用户还没开口），
    /// 替用户改系统状态是越权 —— 但要把这件事写进日志（见 `QuietInputHealResult`）。
    ///
    /// `nonisolated static`：它由音频线程那侧的回调甩到 detached task 上跑，里面全是
    /// 可能阻塞的 HAL 调用，不该占主线程（和输出静音那套同一个理由）。
    nonisolated static func healInputGainIfNeeded(onDeviceID deviceID: AudioDeviceID,
                                                  reason: String) -> QuietInputHealResult {
        let isMuted = AudioInputDeviceCatalog.isInputMuted(of: deviceID)
        let volumeBefore = AudioInputDeviceCatalog.inputVolume(of: deviceID)

        if isMuted == true, AudioInputDeviceCatalog.setInputMuted(false, on: deviceID) {
            return QuietInputHealResult(
                logLines: ["🩺 \(reason) —— 输入的静音被打开了，接着录。"],
                userMessage: "这一场的声音极小：麦克风当时是静音状态，我已经替你打开。")
        }
        if let volumeBefore, volumeBefore < lowInputVolumeThreshold,
           AudioInputDeviceCatalog.setInputVolume(healedInputVolume, on: deviceID) {
            let decibels = -20 * log10(Double(max(volumeBefore, 0.001)))
            return QuietInputHealResult(
                logLines: [String(format: "🩺 %@ —— 输入音量只有 %.2f（衰减约 %.0fdB），已调到 %.2f。",
                                  reason, volumeBefore, decibels, healedInputVolume)],
                userMessage: String(format: "这一场的声音极小：系统输入音量只有 %.0f%%，我已经调到 100%%。",
                                    Double(volumeBefore) * 100))
        }
        return QuietInputHealResult(
            logLines: ["🩺 \(reason) —— 但输入没静音、音量也正常（\(volumeBefore.map { String(format: "%.2f", $0) } ?? "音量读不到")），"
                       + "设备在出样本，先照常录；如果你确实在说话，检查麦克风是否被挡住或离得太远。"],
            userMessage: nil)
    }

    /// 把自愈结果写进日志，并在需要时告诉用户一句。
    ///
    /// 去重不在这一层：**一段安静里只报一次**由采集侧门控
    ///（`hasReportedQuietInputThisStretch`，见 `onAbnormallyQuietInput`）——
    /// 那一层才知道「声音回来了没有」，在这里按时间猜是第二份真相。
    private func reportQuietInputHeal(_ result: QuietInputHealResult) {
        result.logLines.forEach { publishDiagnostic($0) }
        if let userMessage = result.userMessage {
            lastSilentInputWarning = userMessage
        }
    }

    /// **录制期间的例行复查**：每 5 秒读一次当前绑定设备的输入音量，低了就修。
    ///
    /// 为什么要有它，而不是只靠「异常安静」那条电平触发器：2026-09-26 实测证明
    /// 电平门槛没有余量 —— 音量被打回 0.20 时房间底噪的窗内峰值是 0.004~0.005，
    /// 而当初真故障时（用户在说话）只有 0.002~0.003，两者是交叉的。**音量本身没有
    /// 这个问题**：0.2 就是 0.2。所以让确定性量当主判据，电平只负责"什么时候去看一眼"。
    ///
    /// **它只在录音期间存在**，而且第一个 tick 就会自查 `phase`：不在录了就把自己停掉。
    /// 今天刚把那张"从启动响到退出"的权限表拆掉，不能再留一张会忘记停的表。
    ///
    /// 5 秒这个间隔是"够快到用户还在说第一句、够慢到不打扰"的折中：读两个 CoreAudio
    /// 属性是微秒级，但坏掉的状态最多只影响开头那几秒。
    private func startInputGainWatch() {
        inputGainWatchTimer?.invalidate()
        inputGainWatchTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.phase == .recording else {
                    self.inputGainWatchTimer?.invalidate()
                    self.inputGainWatchTimer = nil
                    return
                }
                self.checkInputGainDuringRecording()
            }
        }
    }

    /// 例行复查那一下：读绑定设备的音量/静音，能修就修。
    ///
    /// **只在真的改动了什么的时候才说话** —— 每 5 秒一条"一切正常"是噪声，而且会把
    /// 「异常安静」那条真正重要的告警淹掉。
    private func checkInputGainDuringRecording() {
        let deviceID = boundInputDeviceID
        guard deviceID != kAudioObjectUnknown else { return }
        Task.detached(priority: .utility) { [weak self] in
            let result = LongFormRecorderController.healInputGainIfNeeded(
                onDeviceID: deviceID,
                reason: "录制中例行复查")
            guard result.userMessage != nil else { return }
            await MainActor.run { self?.reportQuietInputHeal(result) }
        }
    }

    /// 「现在开着麦克风的是谁」，翻译成用户看得懂的名字。
    /// bundle id 是 `cn.shandianshuo.desktop` 这种，对用户没有意义；能查到 App 就拿
    /// 它的显示名（`闪电说`），查不到才退回 bundle id 或 pid。
    private func microphoneHolderDisplayNames() -> [String] {
        AudioInputDeviceCatalog.processesCurrentlyCapturingInput().map { holder in
            if !holder.bundleIdentifier.isEmpty,
               let applicationURL = NSWorkspace.shared.urlForApplication(
                   withBundleIdentifier: holder.bundleIdentifier) {
                return FileManager.default.displayName(atPath: applicationURL.path)
            }
            if !holder.bundleIdentifier.isEmpty { return holder.bundleIdentifier }
            return "pid \(holder.processID)"
        }
    }

    func stopRecording() {
        guard phase == .recording || phase == .starting else { return }
        // 先撤声明再收尾：收尾里会碰音频设备，而声明还在的话引擎那边不敢起来。
        phase = .stopping
        stopTimers()

        // 记下**此刻**编辑窗开没开 —— 停止之后去往哪条分支全看它。
        isEditorOpenAtStopTime = isTranscriptExpanded

        // **抓屏必须在「停止」这一秒**，不能等收尾完再抓 —— 用户的原话是
        // 「每一次录音结束、也就是停止录音的那一刻，用户按下按钮或快捷键的那一秒，
        // 自动抓取当前屏幕的截图」。晚几百毫秒，屏幕上可能已经换了个样。
        let stopMomentSettings = AppSettingsStore.snapshot()
        polishScreenshotJPEG = stopMomentSettings.recordingPolishCapturesScreenshot
            ? Self.captureMainDisplayJPEG() : nil
        // 摄像头抓帧是**异步**的（要等一帧到），所以在停止这一秒启动、稍后再 await。
        // 同步等会把点击冻住最多 1.5 秒 —— 而用户按下停止时最不该有的就是卡顿。
        // 抓帧**已经在这一轮里一帧一帧攒好了**（转写里一出现「摄像头」就开始，
        // 一秒一帧）—— 这里是收尾，不是起点。见 `considerStartingCameraCapture`。
        cameraSession.stop()
        isCameraCapturing = false

        // 停止的音效。
        //
        // **要润色时不在这里响** —— 那一声让给「润色完成」。用户 2026-09-25 的规则：
        // 「如果用户勾选了润色（默认是勾选的），那么在转写完成的时候就不要发出这个
        // 声效了，要不然就重了。因为润色成功之后是有音效的……如果没有润色的话，
        // 转写完成是有一个音效的」。
        //
        // 实测（诊断日志）：这一声和末尾那一声只隔 **1 秒** —— 因为整条链现在很快
        // （关掉模型思考之后润色只要 1 秒）。1 秒内两声听起来就是「一个动作响了两次」，
        // 而不是两个独立事件。所以开了润色时这里保持安静，一次录音从头到尾只响一声。
        if !shouldRunPolishStep() {
            SoundEffectPlayer.shared.play(.sessionHungUp)
        }

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

        inputGainWatchTimer?.invalidate()
        inputGainWatchTimer = nil
        publishDiagnostic("录音结束：\(text.count) 字，\(String(format: "%.1f", session?.recordedSeconds ?? 0)) 秒")

        // **一个字都没有的时候要说一声。**
        //
        // 「录了几秒、返回 0 字」和「录成功、内容恰好很短」在界面上长得一模一样 ——
        // 用户唯一的线索是粘贴出来的东西是空的，而那要等他自己发现。
        // 判据取「一个字都没有」：真在说话的人不可能一个字都不出（识别器连「嗯」
        // 都会出），所以这一条几乎不会误报，却把静默的失败变成一句能读到的话。
        if text.isEmpty {
            let recordedSeconds = String(format: "%.1f", session?.recordedSeconds ?? 0)
            publishDiagnostic("⚠️ 录音结束但一个字都没有（\(recordedSeconds) 秒）"
                              + " —— 若是静音，原因见上面的「起录体检」与采集自检那几行。")
            lastSilentInputWarning = "这一场（\(recordedSeconds) 秒）没有识别到任何文字。"
                + "如果是静音，多半是麦克风被压低、被静音、或被别的程序占着 —— "
                + "录音诊断日志里有这一刻的设备和音量。"
        }

        // **这里一声都不响。**
        //
        // 原来这上面还有一行 `.sessionHungUp` —— 而它上一行就是我写的「音效已经在
        // `stopRecording` 里响过了，这里不再响一次」。注释和代码互相打脸，结果一次
        // 停止响了三声（点下去一声、收尾又一声、完成再一声），用户听到的就是「重了」。
        //
        // 「好了」那一声挪到**整条链的最末尾**（`completeStop` 的出口），只响一次：
        // 没开润色时它就是「转写完成」，开了润色时它是「润色完成」—— 两种情况下都
        // 只在真正结束的那一刻响，绝不会和别的声叠在一起。

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
        // 帧只可能来自「转写里出现过摄像头」那一条路 —— 没提就一帧都没有，
        // 所以这里不需要再判一次。
        let cameraFramesForPolish = cameraFrames
        if !cameraFramesForPolish.isEmpty {
            publishDiagnostic("附上 \(cameraFramesForPolish.count) 帧摄像头画面")
        }
        let polished = await polishIfConfigured(rawText: text, cameraFrames: cameraFramesForPolish)
        isPolishingTranscript = false
        // 用户在润色期间按了取消 → 这条路到此为止。录音文件和已转写的文本**照常保留**
        // （它们早就落盘了），只是不再往下走：不粘贴、不进剪贴板、不收尾。
        guard generationBeforePolish == cancellationGeneration else {
            publishDiagnostic("润色期间被取消，已保留录音与已转写内容")
            return
        }
        if polished != text {
            transcriptPlainText = polished
            // **写进「润色文本」那个文件，不动 `.txt`。**
            // 用户的要求：「润色文本与原文（撰写文本）要保存两份，分别是不同的文本文件，
            // 因为用户很有可能去看原文、原文档」。`.txt` 是识别器逐句落盘的原文，
            // 录制过程中就在写，润色不碰它。
            writePolishedTextFile(polished)
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

        // **录音 → Notion 笔记**（2026-09-27）。三条判据缺一不可：功能开着、检测到过关键词、
        // 用户没有取消 ——「若用户未点击，默认保存」就是第三条的反面。
        stopNotionKeywordWatch()
        let shouldSaveNotionNote = settings.notionNoteEnabled
            && showsNotionNoteButtons
            && !notionNoteCancelled

        if shouldSaveNotionNote {
            // 用户第 8 条：**原文**进剪贴板、**不粘贴**（他要的是能直接去别处粘贴）。
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            // **第三态**：带子收掉、只留那颗按钮显示「保存中…」（见 `isSavingNotionNote`）。
            isSavingNotionNote = true
            await saveNotionNote(rawText: text)
            isSavingNotionNote = false
            // 「已保存笔记」在原「取消」的位置显示 5 秒 —— 这 5 秒里那块带子不能收，
            // 否则用户根本看不到保存的结果（用户第 5 + 7 条合起来就是这个意思）。
            if notionNoteSaved {
                try? await Task.sleep(for: .seconds(Self.notionNoteSavedLingerSeconds))
            }
        } else if settings.recordingCopiesToClipboard || settings.recordingPastesAfterStop {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(finalText, forType: .string)
        }

        let shouldKeepPanel = isEditorOpenAtStopTime
        if !shouldKeepPanel {
            if settings.recordingPastesAfterStop && !shouldSaveNotionNote {
                pasteIntoFrontmostApplication(finalText)
            }
            finishCurrentSession()
        }
        // 带子收掉之后，那两个按钮的状态也跟着清掉（下一场重新检测）。
        showsNotionNoteButtons = false

        teardownStorage()
        audioLevel = 0
        isSpeechDetected = false
        elapsedSeconds = 0
        connectionState = .idle

        // **整条链的最后一声，也是唯一的一声「好了」。**
        // 没开润色时它代表「转写完成」，开了润色时代表「润色完成」—— 用户的要求是
        // 这两种情况各响一声、且不重叠。
        SoundEffectPlayer.shared.play(.answerFinished)
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
            // 每来一段都看一眼 —— 用户可能说到一半才提到摄像头。
            self.considerStartingCameraCapture()
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

/// 这个系统此刻**真正的**默认输入设备（不是那个动态聚合体）。
private nonisolated func realDefaultInputDeviceID() -> AudioDeviceID {
    var deviceID = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                            &address, 0, nil, &size, &deviceID)
    return status == noErr ? deviceID : 0
}

/// 把输入节点钉在一个**具体的设备**上，并返回它的名字。
///
/// ## 为什么必须钉
///
/// `AVAudioEngine` 默认跟的是 CoreAudio 的**默认设备聚合体**
///（`CADefaultDeviceAggregate-<pid>-0`）—— 那是按「此刻有哪些设备」**现组**的，
/// 声道数会变。实测 2026-09-26：内置麦克风 1 声道 + 录屏软件的虚拟驱动 2 声道
/// = **聚合体 3 声道，而它交出的是纯静音**（117 秒 0 字，服务端一直超时重连）。
///
/// ## 钉哪一个
///
/// 用户在「录音」设置页选了就钉那个（`recordingInputDeviceUID`），没选就钉
/// 系统的默认输入设备。**两种情况都绕开了聚合体** —— 那才是问题所在，
/// 「选谁」只是让用户能纠正「默认本身指错了」这种情形。
///
/// 选的那个设备**被拔掉了**就落回默认，并且**在日志里说出来**：
/// 静默换设备会让用户以为自己在用外置麦。
extension LongFormAudioCapture {
    /// 从绑定函数返回的 `名字 [id=N]` 里把 id 抠出来，问 CoreAudio 它几个输入声道。
    ///
    /// 解析字符串看着笨，但它用的是**绑定函数自己报的那个 id** —— 拿目录再查一遍名字
    /// 有可能查到另一个同名设备，而那样比出来的结论是错的。
    nonisolated static func channelCountOfPinnedDevice(named boundDescription: String) -> Int {
        guard let range = boundDescription.range(of: "[id="),
              let end = boundDescription[range.upperBound...].firstIndex(of: "]"),
              let deviceID = AudioDeviceID(boundDescription[range.upperBound..<end])
        else { return 0 }
        return AudioInputDeviceCatalog.inputChannelCount(of: deviceID)
    }

    nonisolated static func pinInputNodeToChosenInputDevice(_ node: AVAudioInputNode) -> String {
        guard let unit = node.audioUnit else { return "（拿不到 audioUnit）" }

        let chosenUID = AppSettingsStore.snapshot().recordingInputDeviceUID
        var target: AudioInputDevice?
        if !chosenUID.isEmpty {
            target = AudioInputDeviceCatalog.device(withUID: chosenUID)
            if target == nil {
                SoundEffectPlayer.appendToDiagnosticLog(
                    "录音：你选的输入设备（UID \(chosenUID)）现在不在了，这一场改用系统默认。")
            }
        }
        if target == nil, let defaultID = AudioInputDeviceCatalog.allInputDevices().first(where: \.isSystemDefault) {
            target = defaultID
        }
        guard let device = target else { return "（系统里没有任何输入设备）" }

        var deviceID = device.id
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                             kAudioUnitScope_Global, 0, &deviceID,
                             UInt32(MemoryLayout<AudioDeviceID>.size))
        return "\(device.name) [id=\(device.id)]"
    }
}

/// 输入节点现在挂在哪个设备上。
///
/// `AVAudioEngine.inputNode` 用的是**系统默认输入** —— 而「默认」是会变的，
/// 而且可能被虚拟设备影响（这台机器上就装着一个 `iShotAudioPlugin`，
/// Transport: Virtual）。所以出问题时第一个要知道的就是它到底绑到了谁。
private nonisolated func describeCurrentInputDevice(_ node: AVAudioInputNode) -> String {
    guard let unit = node.audioUnit else { return "（拿不到 audioUnit）" }
    var deviceID = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    guard AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                               kAudioUnitScope_Global, 0, &deviceID, &size) == noErr,
          deviceID != 0 else {
        return "（读不到当前设备）"
    }
    var name: CFString = "" as CFString
    var nameSize = UInt32(MemoryLayout<CFString>.size)
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioObjectPropertyName,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    let status = withUnsafeMutablePointer(to: &name) {
        AudioObjectGetPropertyData(deviceID, &address, 0, nil, &nameSize, $0)
    }
    return "\(status == noErr ? (name as String) : "（读不到名字）") [id=\(deviceID)]"
}

/// AUHAL 的输入回调。C 函数指针挂不上实例方法，所以在这里转一层。
///
/// `passUnretained`：这个回调的生命周期由 `AudioComponentInstanceDispose` 结束，
/// 而那时 `halUnit` 已置空、回调不会再进来。强引用会让采集类永远不释放。
private let longFormHALInputCallback: AURenderCallback = {
    refCon, actionFlags, timeStamp, busNumber, frameCount, _ in
    let capture = Unmanaged<LongFormAudioCapture>.fromOpaque(refCon).takeUnretainedValue()
    return capture.halInputCallbackFired(actionFlags: actionFlags,
                                         timeStamp: timeStamp,
                                         busNumber: busNumber,
                                         frameCount: frameCount)
}

extension LongFormAudioCapture {
    /// 这一场用哪个输入设备：设置里挑的那个；没挑、或挑的那个不在了，用系统默认。
    ///
    /// **一定要落到一个具体的 `AudioDeviceID`。** 把「系统默认」原样交给引擎，
    /// 正是它去组聚合体的原因（TN2091 与 quicktalk-app 那份记录的同一个结论）。
    nonisolated static func chosenInputDevice() -> AudioInputDevice? {
        let chosenUID = AppSettingsStore.snapshot().recordingInputDeviceUID
        if !chosenUID.isEmpty {
            if let device = AudioInputDeviceCatalog.device(withUID: chosenUID) { return device }
            SoundEffectPlayer.appendToDiagnosticLog(
                "录音：你选的输入设备（UID \(chosenUID)）现在不在了，这一场改用系统默认。")
        }
        return AudioInputDeviceCatalog.allInputDevices().first(where: \.isSystemDefault)
    }
}
