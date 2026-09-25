import Foundation

/// 一次识别里「当前这一段」的结果。
///
/// 服务端用 `result_type: "single"` 时只回当前这一段，所以这个结构体的大小由
/// **句长**决定，而不是由会话长度决定 —— 这是 3 小时录音能跑下去的前提。
nonisolated struct VolcengineASRSegment: Equatable {
    let text: String
    /// `true` 表示这一段不会再变了（服务端 `definite`）。落盘以它为准。
    let isDefinite: Bool
    /// 这一段在**整条音频流**里的起止毫秒。绝对时间轴，跨连接由调用方自己平移。
    let startMilliseconds: Int
    let endMilliseconds: Int
}

/// 豆包流式语音识别的 WebSocket 客户端。
///
/// 只负责一件事：把 PCM 喂上去，把回包翻译成 `VolcengineASRSegment`。
/// 它不管落盘、不管界面、不管重连策略 —— 那些是 `LongFormRecorderController`
/// 的事。这样切开之后，这个文件可以脱离 App 单独跑（探针就是这么验的）。
///
/// ## 四个实测出来的硬约束（2026-09-25，真服务）
///
/// 1. **`result_type` 必须是 `"single"`。** 默认的 `"full"` 每帧回**整场累积**
///    文本：实测 28.6 秒时每帧已经 ~150 字，且随会话线性增长。3 小时是它的 377
///    倍，也就是每帧 5 万多字、每秒重下上百 KB —— 必崩。`"single"` 只回当前
///    这一段，实测每帧稳定在 1.8–2.1 KB，与会话长度无关。
/// 2. **末包一发，服务端立刻关连接**（实测关闭码 1000，reason "finish last
///    sequence"）。所以长录音中途**绝不能**发末包，它只在用户按停止时发。
/// 3. **压缩用 `none`，服务端接受。** 省掉 gzip 外壳那一整块没法自证的代码。
/// 4. **`X-Api-Resource-Id` 决定用哪一代哪一档模型**，请求体里的 `model_name`
///    恒为 `"bigmodel"`。所谓「换模型」就是换这个头。
nonisolated final class VolcengineRealtimeASRClient {

    struct Configuration {
        var apiKey: String
        var resourceID: String
        var language: String
        var hotwords: [String]
        /// 静音多久判定一句话结束（毫秒，服务端允许 300–5000）。它同时是
        /// **每帧包大小的上限来源** —— 段越长，单帧越大。
        var endWindowSizeMilliseconds: Int = 800
        var sampleRate: Int = 16000
        var channelCount: Int = 1
        var bitsPerSample: Int = 16

        static let endpoint = URL(string: "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async")!
    }

    enum ConnectionState: Equatable {
        case idle
        case connecting
        case connected
        case failed(String)
        case disconnected(reason: String)
    }

    // MARK: - 对外回调（都在主线程上调用）

    /// 当前这一段的最新结果。同一段会回调多次（边说边改），直到 `isDefinite`。
    var onSegment: ((VolcengineASRSegment) -> Void)?
    var onStateChange: ((ConnectionState) -> Void)?
    /// 一行诊断，进日志用。协议层的异常必须看得见，否则「录了 3 小时没文字」
    /// 这种事只能靠猜。
    var onDiagnostic: ((String) -> Void)?

    // MARK: - 状态（只在 socketQueue 上碰）

    private let socketQueue = DispatchQueue(label: "clicky.longform.asr.socket")
    private var configuration: Configuration
    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var receiveLoopTask: Task<Void, Never>?
    private var watchdogTimer: DispatchSourceTimer?
    private var lastReceivedFrameAt: Date?
    private var hasFinished = false
    /// 代次。每次连接自增，让旧连接的收包循环认得出自己已经过期 ——
    /// 重连后旧 socket 的迟到回包绝不能写进新一轮的转录。
    private var generation = 0
    private(set) var sentAudioByteCount: Int64 = 0
    /// 上一次打过日志的段起点毫秒。只在它变化时打 —— 见 `publishSegment`。
    private var lastAnnouncedSegmentStartMilliseconds = -1
    /// 连接真正建立的时刻。`新段 @连接后 Ns` 里的 N 用它算。
    private var connectionEstablishedAt: Date?
    /// 末包已发、正等服务端把最后一段判成 `definite` 时挂着这个回调。
    ///
    /// **它的存在就是为了提前返回。** 原来 `finishAndAwaitFinalResult` 是
    /// `asyncAfter(timeoutSeconds)` 到点才回调 —— 也就是说**每一次停止都固定等满
    /// 那 4 秒**，和用户说了两个字还是两百个字毫无关系。而服务端的定稿通常几百毫秒
    /// 就回来了。用户报的「说两个字也要等很久」就是这个。
    private var finalResultCompletion: (() -> Void)?

    init(configuration: Configuration) {
        self.configuration = configuration
    }

    func updateConfiguration(_ configuration: Configuration) {
        socketQueue.async { self.configuration = configuration }
    }

    // MARK: - 连接

    func connect() {
        socketQueue.async { self.startConnectionOnQueue() }
    }

    private func startConnectionOnQueue() {
        teardownOnQueue(sendLastPacket: false, notify: false)
        generation += 1
        let myGeneration = generation
        hasFinished = false
        sentAudioByteCount = 0
        lastReceivedFrameAt = nil
        lastAnnouncedSegmentStartMilliseconds = -1
        connectionEstablishedAt = Date()

        publishState(.connecting)

        var request = URLRequest(url: Configuration.endpoint)
        request.setValue(configuration.apiKey, forHTTPHeaderField: "X-Api-Key")
        request.setValue(configuration.resourceID, forHTTPHeaderField: "X-Api-Resource-Id")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Api-Request-Id")
        // 便于服务端侧定位问题；官方推荐带。
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Api-Connect-Id")

        let sessionConfiguration = URLSessionConfiguration.default
        // 长会话不能有请求超时：这条连接要活几十分钟甚至几小时，中间可能长时间
        // 只有心跳。超时交给下面的看门狗按「多久没收到回包」判断，语义更准。
        sessionConfiguration.timeoutIntervalForRequest = .infinity
        sessionConfiguration.timeoutIntervalForResource = .infinity
        sessionConfiguration.waitsForConnectivity = true

        let session = URLSession(configuration: sessionConfiguration)
        let task = session.webSocketTask(with: request)
        self.session = session
        self.task = task
        task.resume()

        sendConfigurationFrameOnQueue(generation: myGeneration)
        startReceiveLoopOnQueue(generation: myGeneration)
        startWatchdogOnQueue(generation: myGeneration)

        // URLSessionWebSocketTask 没有「打开成功」的回调，第一条回包就是证据。
        // 但界面不能等那么久，所以这里乐观地报「已连接」，真出错时由收包循环报错。
        socketQueue.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, self.generation == myGeneration, !self.hasFinished else { return }
            self.publishState(.connected)
        }
    }

    private func sendConfigurationFrameOnQueue(generation myGeneration: Int) {
        let payload: [String: Any] = [
            "user": ["uid": "clicky-longform-recorder"],
            "audio": [
                "format": "pcm",
                "codec": "raw",
                "rate": configuration.sampleRate,
                "bits": configuration.bitsPerSample,
                "channel": configuration.channelCount,
            ],
            "request": [
                "model_name": "bigmodel",
                "enable_itn": true,
                "enable_punc": true,
                "show_utterances": true,
                // 见类注释第 1 条：这一行是长会话能不能跑下去的分水岭。
                "result_type": "single",
                "end_window_size": configuration.endWindowSizeMilliseconds,
                "language": configuration.language,
                // 热词：专有名词、人名、项目代号的偏置。空数组不能传，
                // 服务端会把它当成「有一个空热词」而不是「没有热词」。
                "corpus": configuration.hotwords.isEmpty
                    ? [:] : ["hotwords": configuration.hotwords.map { ["word": $0] }],
            ] as [String: Any],
        ]
        guard let json = try? JSONSerialization.data(withJSONObject: payload) else {
            publishState(.failed("配置帧无法编码"))
            return
        }
        sendOnQueue(VolcengineASRFrame.fullClientRequest(json: json),
                    label: "配置",
                    generation: myGeneration)
    }

    // MARK: - 音频

    /// 喂一块 PCM。**不会阻塞调用方** —— 音频 tap 在实时线程上，那里阻塞会丢音。
    func enqueue(audio: Data) {
        guard !audio.isEmpty else { return }
        socketQueue.async { [weak self] in
            guard let self, !self.hasFinished, self.task != nil else { return }
            self.sentAudioByteCount += Int64(audio.count)
            // 中途永远 isLastPacket: false —— 见类注释第 2 条。
            self.sendOnQueue(VolcengineASRFrame.audioRequest(pcm: audio, isLastPacket: false),
                             label: "音频",
                             generation: self.generation,
                             reportFailure: false)
        }
    }

    /// 停止：发末包，等服务端把最后一段判成 `definite`，然后关连接。
    ///
    /// 等待是有意义的 —— 末包之后服务端还会回一帧把最后那句定稿（实测如此）。
    /// 不等就关，用户说的最后几个字会永远停在「临」状态、进不了落盘的那一份。
    func finishAndAwaitFinalResult(timeoutSeconds: Double = 4.0,
                                   completion: @escaping () -> Void) {
        socketQueue.async { [weak self] in
            guard let self, !self.hasFinished else {
                DispatchQueue.main.async { completion() }
                return
            }
            self.hasFinished = true
            self.watchdogTimer?.cancel()
            self.watchdogTimer = nil
            // 定稿一到就由 `handleJSONPayloadOnQueue` 调它 —— 那是**正常出口**。
            self.finalResultCompletion = completion
            self.sendOnQueue(VolcengineASRFrame.audioRequest(pcm: Data(), isLastPacket: true),
                             label: "末包", generation: self.generation)
            // 超时只是**兜底**：连接死了、或者服务端根本不回定稿时才走到这里。
            self.socketQueue.asyncAfter(deadline: .now() + timeoutSeconds) { [weak self] in
                self?.finishFinalResultWaitOnQueue(reason: "超时兜底")
            }
        }
    }

    /// 立刻断开，不发末包。用在「中断 / 换连接」上 —— 那两种情况都不需要
    /// 服务端定稿，因为音频还会从新连接继续喂。
    func cancel() {
        socketQueue.async { [weak self] in
            self?.hasFinished = true
            self?.teardownOnQueue(sendLastPacket: false, notify: true)
        }
    }

    // MARK: - 收包

    private func startReceiveLoopOnQueue(generation myGeneration: Int) {
        guard let task else { return }
        receiveLoopTask = Task.detached { [weak self] in
            while !Task.isCancelled {
                do {
                    let message = try await task.receive()
                    guard let self else { return }
                    self.socketQueue.async {
                        guard self.generation == myGeneration else { return }
                        self.lastReceivedFrameAt = Date()
                        if case .data(let data) = message { self.handleFrameOnQueue(data) }
                    }
                } catch {
                    guard let self else { return }
                    self.socketQueue.async {
                        guard self.generation == myGeneration, !self.hasFinished else { return }
                        self.publishState(.disconnected(reason: Self.describe(error)))
                        self.publishDiagnostic("收包循环结束：\(Self.describe(error))")
                    }
                    return
                }
            }
        }
    }

    private func handleFrameOnQueue(_ frame: Data) {
        let parsed: VolcengineASRFrame.ParsedFrame
        do {
            parsed = try VolcengineASRFrame.parse(frame)
        } catch {
            publishDiagnostic("帧解析失败：\(error)")
            return
        }

        switch parsed.messageType {
        case .serverError:
            let body = String(data: parsed.payload, encoding: .utf8) ?? ""
            let code = parsed.serverErrorCode.map(String.init) ?? "?"
            publishDiagnostic("服务端错误帧 code=\(code) \(body.prefix(300))")
            publishState(.failed("服务端返回错误 \(code)：\(body.prefix(160))"))
        case .fullServerResponse:
            handleJSONPayloadOnQueue(parsed.payload)
        default:
            break
        }
    }

    private func handleJSONPayloadOnQueue(_ payload: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            publishDiagnostic("回包不是 JSON：\(String(data: payload, encoding: .utf8)?.prefix(200) ?? "")")
            return
        }
        if let code = object["code"] as? Int, code != 0 {
            let message = object["message"] as? String ?? ""
            publishDiagnostic("回包 code=\(code) \(message)")
            publishState(.failed("识别服务报错 \(code)：\(message)"))
            return
        }
        guard let result = object["result"] as? [String: Any] else { return }

        // `result_type: "single"` 下 utterances 通常只有当前这一段，但服务端也
        // 可能同时回一段刚定稿的和一段正在说的。全部转出去，由上层按
        // `isDefinite` 决定谁落盘、谁只用于显示。
        let utterances = result["utterances"] as? [[String: Any]] ?? []
        if utterances.isEmpty {
            // 没有 utterances 时（例如 `show_utterances` 被服务端忽略）退回到
            // 整段 text，把它当成一个不定的段，至少界面上有字。
            if let text = result["text"] as? String, !text.isEmpty {
                publishSegment(VolcengineASRSegment(text: text, isDefinite: false,
                                                    startMilliseconds: 0, endMilliseconds: 0))
            }
            return
        }
        for utterance in utterances {
            let text = utterance["text"] as? String ?? ""
            guard !text.isEmpty else { continue }
            // **定稿一到，「等定稿」这件事立刻结束。** 这是正常出口，超时那条只是
            // 兜底。没有这一句，每次停止都要白等满 `timeoutSeconds`。
            if (utterance["definite"] as? Bool) == true, finalResultCompletion != nil {
                publishSegment(VolcengineASRSegment(
                    text: text,
                    isDefinite: true,
                    startMilliseconds: utterance["start_time"] as? Int ?? 0,
                    endMilliseconds: utterance["end_time"] as? Int ?? 0))
                finishFinalResultWaitOnQueue(reason: "定稿已到")
                return
            }
            publishSegment(VolcengineASRSegment(
                text: text,
                isDefinite: (utterance["definite"] as? Bool) ?? false,
                startMilliseconds: utterance["start_time"] as? Int ?? 0,
                endMilliseconds: utterance["end_time"] as? Int ?? 0
            ))
        }
    }

    /// 看门狗：音频一直在喂，却迟迟没有任何回包 —— 这条连接已经死了。
    ///
    /// 必须有这一条。这个项目的另一个 websocket（百炼实时识别）实测过「连接
    /// 悄悄断掉，既不回最终结果也不报错」，只靠收包循环的 error 分支会永远等下去。
    /// 判据用「距上一帧多久」而不是「距连接建立多久」，因为正常工作时回包很密。
    private func startWatchdogOnQueue(generation myGeneration: Int) {
        watchdogTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: socketQueue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in
            guard let self, self.generation == myGeneration, !self.hasFinished else { return }
            // 还没开始喂音频时不算 —— 用户可能按下快捷键后停顿很久才开口。
            guard self.sentAudioByteCount > 0 else { return }
            guard let last = self.lastReceivedFrameAt else { return }
            let silence = Date().timeIntervalSince(last)
            // 15 秒没有任何回包，而音频一直在喂：判定为死连接。
            if silence > 15 {
                self.publishDiagnostic("看门狗：已 \(Int(silence)) 秒没有任何回包，判定连接已死")
                self.publishState(.disconnected(reason: "连接无响应 \(Int(silence)) 秒"))
                self.teardownOnQueue(sendLastPacket: false, notify: false)
            }
        }
        timer.resume()
        watchdogTimer = timer
    }

    /// 结束「等定稿」这件事，只走一次。
    private func finishFinalResultWaitOnQueue(reason: String) {
        guard let completion = finalResultCompletion else { return }
        finalResultCompletion = nil
        publishDiagnostic("末包定稿结束（\(reason)）")
        teardownOnQueue(sendLastPacket: false, notify: true)
        DispatchQueue.main.async { completion() }
    }

    // MARK: - 收尾

    private func sendOnQueue(_ frame: Data, label: String, generation myGeneration: Int,
                             reportFailure: Bool = true) {
        guard generation == myGeneration, let task else { return }
        task.send(.data(frame)) { [weak self] error in
            guard let self, let error else { return }
            self.socketQueue.async {
                guard self.generation == myGeneration else { return }
                self.publishDiagnostic("发\(label)帧失败：\(error.localizedDescription)")
                if reportFailure {
                    self.publishState(.disconnected(reason: "发送失败：\(error.localizedDescription)"))
                }
            }
        }
    }

    private func teardownOnQueue(sendLastPacket: Bool, notify: Bool) {
        watchdogTimer?.cancel(); watchdogTimer = nil
        receiveLoopTask?.cancel(); receiveLoopTask = nil
        let closing = task
        task = nil
        closing?.cancel(with: .normalClosure, reason: nil)
        session?.invalidateAndCancel()
        session = nil
        if notify {
            publishState(.disconnected(reason: "已断开"))
        }
    }

    // MARK: - 回调派发

    private func publishSegment(_ segment: VolcengineASRSegment) {
        // 「实时不实时」的唯一判据是**新段什么时候开始**：段内每 300–400ms 会有一次
        // 微更新，每次打一行会把日志淹掉，而新段从「用户开口」到「屏幕上出现字」
        // 之间的延迟才是用户感知到的东西。所以只在段号变化时打一行。
        if segment.startMilliseconds != lastAnnouncedSegmentStartMilliseconds {
            lastAnnouncedSegmentStartMilliseconds = segment.startMilliseconds
            let sinceConnect = connectionEstablishedAt.map { Date().timeIntervalSince($0) } ?? -1
            publishDiagnostic(String(format: "新段 @连接后%.1fs 音频位置%dms 上行%dKB 「%@」",
                                     sinceConnect,
                                     segment.startMilliseconds,
                                     Int(sentAudioByteCount / 1024),
                                     String(segment.text.prefix(20))))
        }
        DispatchQueue.main.async { self.onSegment?(segment) }
    }
    private func publishState(_ state: ConnectionState) {
        DispatchQueue.main.async { self.onStateChange?(state) }
    }
    private func publishDiagnostic(_ line: String) {
        DispatchQueue.main.async { self.onDiagnostic?(line) }
    }

    private static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        // 关闭连接时 URLSession 固定报这个，它不是故障，是收尾噪声。
        if nsError.domain == NSPOSIXErrorDomain && nsError.code == 57 {
            return "连接已关闭"
        }
        return error.localizedDescription
    }
}
