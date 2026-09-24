import Foundation
import AppKit

/// 三段式的「一个回合」执行器。
///
/// 它只做一件事：**拿到一句用户说的话，产出一段被念出来的回答**。会话的生命周期
/// （连接/挂断、转写、记忆、音频设备）不在这里，在 `VoiceChatController` —— 这样
/// 回合逻辑可以单独读、单独改，也便于将来把全双工那两个引擎并排放在同一层。
///
/// 三个环节全部复用 Clicky 既有的客户端，不新写任何 API 调用：
///
/// | 环节 | 复用 | 为什么 |
/// |---|---|---|
/// | 想 | `BailianVisionChatAPI.analyzeImageStreaming` | 已是 SSE 流式、已支持多图、已带推理抑制（首字 817ms vs 4298ms） |
/// | 说 | `BailianTTSClient.beginStreamingSpeech`（逐句快答） | 按句合成边播；`speakText` 是整段合成，90 字要等约 2 秒，对话场景不能用 |
/// | 看 | `CompanionScreenCaptureUtility` | 每回合拍一张，与按住说话那条路用的是同一个实现 |
///
/// **它绝不碰 `voiceState` / `currentResponseTask`** —— 与 Agent 子系统同一条红线。
/// 语音聊天有自己的说话状态，靠回调把它报给控制器。
@MainActor
final class CascadeVoiceEngine {

    // MARK: - 依赖（由控制器注入，与 `AgentSessionManager` 的闭包注入同款）

    /// 把一段回答文字交给「读出来」的通道。控制器接的是共享的 `BailianTTSClient`。
    private let speechSynthesizer: VoiceChatSpeechSynthesizing
    /// 失败往哪里报（控制器接 `lastErrorMessage`）。
    private let reportFailure: (String) -> Void

    // MARK: - 一个回合的可取消状态

    /// 当前回合。打断时取消它 —— 与 Clicky 的 `currentResponseTask` 同一个协作式
    /// 取消约定：`Task.sleep` 与 URLSession 流都会在取消时抛出，所以「停下」意味着
    /// 「在下一个 await 停下」，不会出现点了半截的动作。
    private var currentTurnTask: Task<Void, Never>?

    /// 供打断判断使用：现在有没有在念回答。
    private var isSpeakingProvider: () -> Bool = { false }
    /// 取一帧摄像头画面（JPEG）。没有画面时返回 nil，这一轮就只有屏幕图。
    private var cameraFrameProvider: () -> Data? = { nil }

    init(speechSynthesizer: VoiceChatSpeechSynthesizing,
         reportFailure: @escaping (String) -> Void,
         isSpeakingProvider: @escaping () -> Bool,
         cameraFrameProvider: @escaping () -> Data? = { nil }) {
        self.speechSynthesizer = speechSynthesizer
        self.reportFailure = reportFailure
        self.isSpeakingProvider = isSpeakingProvider
        self.cameraFrameProvider = cameraFrameProvider
    }

    /// 跑一个回合。
    ///
    /// - Parameters:
    ///   - utterance: 用户这一轮说的话（`onUtteranceFinalized` 给的最终转写）。
    ///   - role: 当前角色 —— 提示词、要不要送画面都从它读。
    ///   - preset: 当前选中的**预设** —— 三个位置用哪个模型、哪个音色，都由它决定。
    ///   - channel: 视频聊天 / 语音聊天 —— 画面那条硬闸在能力层里。
    ///   - callbacks: 把「回答开始 / 回答更新 / 回答结束」报给控制器。
    ///
    /// **能力层在这里现算，而不是由调用方传一个音色字符串进来**：界面为了置灰也要
    /// 算同一份东西，两处共用 `VoiceCatalog.capability(...)` 这一个实现，
    /// 于是"看得见的"和"真的用的"结构上不可能分家。
    func runTurn(utterance: String,
                 role: VoiceChatRole,
                 preset: VoiceChatPreset,
                 channel: VoiceChatChannel,
                 callbacks: CascadeTurnCallbacks) {
        cancelCurrentTurn()

        let capability = VoiceCatalog.capability(for: preset, channel: channel, role: role)
        currentTurnTask = Task { [weak self] in
            guard let self else { return }
            await self.performTurn(
                utterance: utterance,
                role: role,
                preset: preset,
                capability: capability,
                callbacks: callbacks
            )
        }
    }

    /// **用户开口**：丢掉正在念的音频，但这一轮继续。
    ///
    /// 这是与对话页面对齐的关键，也是「一次误触为什么不能是终结」的答案：
    /// 语音聊天是**在本进程里开麦克风**的，播放时麦克风能读到自己声音的残留，
    /// 所以能量 VAD 偶尔会被顶过阈值。对话页面走 `stopPlayback()`（终止式），
    /// 但它的回答通常已经播完，误触代价小；语音聊天一次误触如果也是终止式的，
    /// 用户听到的就是「它自己把自己打断了」。
    ///
    /// 所以这里走 `bargeIn()`：**只丢声音，会话继续**。用户真的开口时，
    /// 那句话会走到 `startTurn` → `runTurn`，而 `runTurn` 第一件事就是取消
    /// 上一轮 —— 真正的打断一点都没变弱，只是它发生在「确认有新话要说」之后。
    func bargeIn() {
        speechSynthesizer.bargeIn()
    }

    /// **收尾**：挂断时用。取消这一轮并停掉声音 —— 这里要的就是终止，
    /// 因为会话已经不在了，没有「继续」可言。
    func stopEverything() {
        cancelCurrentTurn()
        speechSynthesizer.stopSpeaking()
    }

    /// 真正作废当前一轮（有新的一轮要开始时用）。
    private func cancelCurrentTurn() {
        currentTurnTask?.cancel()
        currentTurnTask = nil
    }

    // MARK: - 回合主体

    private func performTurn(utterance: String,
                             role: VoiceChatRole,
                             preset: VoiceChatPreset,
                             capability: VoiceCatalog.VoiceChatCapability,
                             callbacks: CascadeTurnCallbacks) async {
        do {
            // ① 看：按角色设置取画面。
            //
            // 拍在**请求之前**、与按住说话那条路一致：图像送进同一个视觉请求，
            // 而不是先发文字再补一张图（后者会让模型先答一遍再改口）。
            //
            // **两张图的标签必须能分清谁是谁**（用户 2026-09-24：三段式同时采摄像头
            // 和屏幕是对的，因为本质上都是图像，但「一定要让 AI 知道哪一个是屏幕的内容、
            // 哪一个是摄像头的内容」）。标签会随图一起进请求，所以这里写的是给模型看的
            // 那句话，而不是给日志看的短名。
            //
            // 外面还套一道 `capability.isVideoInputAllowed`：界面按它置灰，引擎按它
            // 决定发不发图 —— 同一份判据，所以不会出现"按钮是灰的但画面照样发出去了"。
            var images: [(data: Data, label: String)] = []
            if capability.isVideoInputAllowed {
                if role.autoScreenEnabled {
                    images.append(contentsOf: await captureScreenFramesForTurn())
                }
                if role.autoCameraEnabled, let cameraFrame = cameraFrameProvider() {
                    images.append((
                        data: cameraFrame,
                        label: "用户摄像头拍到的画面（这是摄像头，不是屏幕）："
                    ))
                }
            }
            if Task.isCancelled { return }

            // ② 说：逐句快答会话。**先建会话再发请求** —— 第一段回答一到就能合成，
            // 不必等整段回复。
            //
            // 音色来自能力层：它是**校验过**的那个（跨族音色在这里已经被换成兜底值），
            // 所以引擎不可能把服务端不认的音色填进去。
            let speechSession = try speechSynthesizer.beginStreamingSpeech(
                voiceID: capability.effectiveVoiceID
            )

            var streamedReplyText = ""
            var spokenTextAccumulator = ""

            // ③ 想：**走哪条管线由预设决定**（用户 2026-09-24：「每一个预设背后都是
            // 不同的管线」）。
            //
            //   · 理解＝实时模型 → WebSocket 会话：喂文字、收文字
            //     （`RealtimeTextUnderstandingClient`，协议逐条照官方文档，实测首字 0.48 秒）
            //   · 其余 → HTTP 图文（截图/摄像头帧一起进请求）
            //
            // 两条路的**下游完全一样**：文字边收边喂给朗读会话、边更新气泡，
            // 所以"表达"那一侧（3.1 TTS + 任意音色）一个字都不用改。
            var finalReplyText = ""
            let understandingModelID = preset.understandingModelID
                ?? VoiceCatalog.defaultUnderstandingModel

            if VoiceCatalog.isRealtimeModel(understandingModelID) {
                finalReplyText = try await RealtimeTextUnderstandingClient().generateText(
                    modelID: understandingModelID,
                    systemPrompt: systemPrompt(for: role),
                    userPrompt: utterance,
                    onTextChunk: { @MainActor accumulatedText in
                        streamedReplyText = accumulatedText
                        // 与 HTTP 那条路同一个 helper：念的是剥掉标签的那份。
                        let speakableText = ActionTagParser.speakableTextFromStreamedReply(accumulatedText)
                        if speakableText != spokenTextAccumulator {
                            spokenTextAccumulator = speakableText
                            speechSession.feed(cumulativeSpeakableText: speakableText)
                        }
                        callbacks.onAnswerTextChanged(speakableText)
                    }
                )
            } else {
                let (httpReplyText, _) = try await BailianVisionChatAPI().analyzeImageStreaming(
                    images: images,
                    systemPrompt: systemPrompt(for: role),
                    userPrompt: utterance,
                    modelIDOverride: understandingModelID,
                    onTextChunk: { @MainActor accumulatedText in
                        streamedReplyText = accumulatedText

                        // 念的是**剥掉标签**的那份：回复里可能带 `[POINT:]` 这类标记，
                        // 原样念出来会变成「方括号 P O I N T」。与按住说话那条路用的是
                        // 同一个 helper，两处的朗读文本因此不会分叉。
                        let speakableText = ActionTagParser.speakableTextFromStreamedReply(accumulatedText)
                        if speakableText != spokenTextAccumulator {
                            spokenTextAccumulator = speakableText
                            speechSession.feed(cumulativeSpeakableText: speakableText)
                        }

                        callbacks.onAnswerTextChanged(speakableText)
                    }
                )
                finalReplyText = httpReplyText
            }

            if Task.isCancelled { return }

            // 收尾：告诉合成器「不会再有新句子了」，把最后一段放出去。
            speechSession.finishStreaming()

            // 等这一轮真正念完再报告回合结束 —— 否则控制器会立刻认为「闲着」，
            // 而用户还在听。
            await speechSynthesizer.waitUntilPlaybackFinishes()

            if Task.isCancelled { return }

            callbacks.onTurnFinished(finalReplyText, spokenTextAccumulator)
        } catch is CancellationError {
            // 打断走的就是这条路，不是错误。
        } catch let urlError as URLError where urlError.code == .cancelled {
            // 取消中的 URLSession 流是以 `URLError.cancelled` 结束的，不是
            // `CancellationError` —— Clicky 的语音管线在这里踩过坑（一次打断会
            // 被当成失败报错）。同一个陷阱，同一处绕开。
        } catch {
            if Task.isCancelled { return }
            reportFailure("语音聊天：这一轮失败了 — \(error.localizedDescription)")
        }
    }

    /// 这个角色这一轮用的系统提示词。
    ///
    /// 角色的提示词就是「系统提示词」，用户右键编辑的那段直接发出去；开了屏幕时
    /// 追加一句能力说明，否则模型不知道自己收到了图，会答「我看不到你的屏幕」——
    /// 这正是 VoiceWeb 当前那个失败现象。
    private func systemPrompt(for role: VoiceChatRole) -> String {
        var prompt = role.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if prompt.isEmpty {
            prompt = VoiceChatRole.defaultSystemPrompt
        }

        if role.autoScreenEnabled {
            prompt += """


            你同时会收到用户屏幕的截图，标签里写明「这是屏幕」。用户提到「屏幕」「这里」「这个」时
            指的就是它。**如果同时还有一张摄像头画面，两者是不同的东西**：屏幕是电脑上显示的内容，
            摄像头是镜头前的人或场景；回答前先看清标签，不要把它们搞混。
            基于画面内容回答，不要说你看不到屏幕。
            """
        }
        return prompt
    }

    /// 拍这一回合要送的屏幕帧。
    ///
    /// 复用 `CompanionScreenCaptureUtility` —— 与按住说话那条路拍的是同一种图
    /// （自己 App 的窗口已被排除，所以不会拍到自己）。失败不阻断回合：一次截图
    /// 失败不该让用户说不出话，只是这一轮没有画面。
    private func captureScreenFramesForTurn() async -> [(data: Data, label: String)] {
        let settings = AppSettingsStore.snapshot()
        do {
            let captures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG(
                maximumDimension: settings.screenshotMaxDimension == 0
                    ? nil : settings.screenshotMaxDimension,
                compressionQuality: settings.screenshotCompressionQuality,
                capturesAllDisplays: settings.capturesAllDisplays
            )
            return captures.map {
                (data: $0.imageData,
                 label: "用户屏幕的截图（这是屏幕，不是摄像头）· \($0.label)")
            }
        } catch {
            print("💬 语音聊天：这一轮的截图失败 — \(error.localizedDescription)")
            return []
        }
    }
}

/// 一个回合向外的三个回调。用结构体而不是三个闭包参数，是因为控制器要按回合
/// 传不同的目标（例如打断后换一轮），结构体让「这是一组」这件事在类型上成立。
@MainActor
struct CascadeTurnCallbacks {
    /// 回答文字变了（流式，每次都是**到目前为止的全文**，不是增量）。
    let onAnswerTextChanged: (String) -> Void
    /// 这一轮结束了（念完或被打断）。
    let onTurnFinished: (_ finalReplyText: String, _ spokenText: String) -> Void
}

/// 「把一段文字读出来」的抽象。
///
/// 控制器接的是共享的 `BailianTTSClient`；这里留一个协议是为了让引擎**不直接依赖**
/// 那个具体类型 —— `BailianTTSClient` 是 `@MainActor final class` 且带着引擎释放、
/// 分块、逐句快答一整套状态，引擎只需要其中两个动作。将来全双工那两个引擎走的是
/// 另一条播放路径（裸 PCM 直接进 `VoicePlaybackEngine`），届时也实现这个协议。
@MainActor
protocol VoiceChatSpeechSynthesizing {
    /// 开始一次逐句快答的朗读会话。
    ///
    /// `voiceID` 是**当前预设选中的音色**（由 `VoiceCatalog.capability` 校验过）。
    /// 它必须从这里传下去：`BailianTTSClient` 原来只认全局配置里的音色，于是语音聊天
    /// 里换了音色却听不出变化 —— 用户报的正是这个（「我选择了使用这个音色，但实际连接
    /// 时播放的音色调用的并不是我点击使用的那个音色」）。传 nil = 跟随全局配置。
    func beginStreamingSpeech(voiceID: String?) throws -> VoiceChatStreamingSpeech
    /// 立刻停掉正在念的，**并结束这一轮**（挂断用）。
    func stopSpeaking()
    /// 打断：丢掉正在念的，但**这一轮继续**（用户开口用）。
    func bargeIn()
    /// 等播放队列排空。
    ///
    /// 这个动作在**客户端**上而不在会话上，是因为「还在不在念」是播放器的状态：
    /// `BailianTTSClient.isPlaying` 会一直为真到**最后一块**音频播完
    /// （`.dataPlayedBack` 回调），逐句快答的每个分段都记在它自己身上。
    func waitUntilPlaybackFinishes() async
}

/// 逐句快答会话的抽象面 —— 只暴露引擎真正用到的三个动作。
@MainActor
protocol VoiceChatStreamingSpeech {
    /// 把「到目前为止要念的全文」喂进来；内部分句、合成、排队播放。
    func feed(cumulativeSpeakableText: String)
    /// 不会再有新句子了。
    func finishStreaming()
    /// 丢掉还没播的（打断用）。
    func stop()
}
