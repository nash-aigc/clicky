//
//  VoiceWebSessionController.swift
//  leanring-buddy
//
//  The orchestrator behind the three VoiceWeb mode shortcuts (三段式 /
//  全双工语音 / 全双工全模态) AND the notch sheet's 语音聊天 sidebar section.
//  Pressing a shortcut ≈ the user walking over to the VoiceWeb page and
//  clicking 「连接」; clicking a role preset in the sidebar does the same
//  after first making that role the active one. This controller detects the
//  VoiceWeb server, launches it when it is down, opens or reuses its Chrome
//  window, posts one connect command, and watches the session — but the
//  voice, video and playback themselves stay entirely in VoiceWeb's own
//  pipeline. Nothing here ports any of that; this file is only HTTP, one
//  subprocess launch and one AppleScript.
//
//  The path the commands travel is the external bridge built into VoiceWeb
//  for exactly this purpose (server.py 2026-09-23):
//
//      Clicky --POST /external/command--> server.py --page polls--> window.client
//      Clicky <--GET /external/state-----  page reports   <-- window.client
//
//  The browser is where `window.client` and the WebRTC mic live (AEC
//  constraint), so the page, not this controller, executes connect, device
//  toggles and text sends; this controller only reads the reported state.
//
//  Deliberately out of scope: streaming the reply word by word (the reply
//  appears whole, when VoiceWeb's history writes it), running two external
//  sessions at once (one at a time), and killing the VoiceWeb server on
//  teardown — the service is a resident the user may be using outside Clicky.
//

import AppKit
import Combine
import Foundation

@MainActor
final class VoiceWebSessionController: ObservableObject {

    enum VoiceWebMode: Int, CaseIterable {
        /// 三段式: pipeline (Bailian ASR → LLM → TTS).
        case threeStage = 0
        /// 全双工语音: duplex realtime audio.
        case duplexVoice = 1
        /// 全双工全模态: omni realtime audio + optional camera + screen.
        case omni = 2

        /// The `chat_engine` value VoiceWeb's config stores for this mode.
        var engineName: String {
            switch self {
            case .threeStage: return "pipeline"
            case .duplexVoice: return "duplex"
            case .omni: return "omni"
            }
        }

        var displayName: String {
            switch self {
            case .threeStage: return "三段式"
            case .duplexVoice: return "全双工语音"
            case .omni: return "全双工全模态"
            }
        }
    }

    /// Where the currently watched VoiceWeb session is, from the UI's point
    /// of view. `.connecting` covers the whole launch-connect flow (server
    /// probe, page, command); `.connected` is the page's own `ready` report.
    enum VoiceWebConnectionPhase: Equatable {
        case idle
        case connecting
        case connected
    }

    /// One VoiceWeb role preset — the roles already configured in VoiceWeb
    /// (config.json `roles`), surfaced as the 语音聊天 sidebar's list. Only
    /// the fields the list renders are carried; VoiceWeb owns the rest.
    struct VoiceWebRolePreset: Identifiable, Equatable {
        let id: String
        let name: String
    }

    /// One line of the voice chat's live transcript, mirrored from VoiceWeb's
    /// per-role history file. `isUser` picks the bubble side in the view.
    struct VoiceWebTranscriptEntry: Identifiable, Equatable {
        let id = UUID()
        let isUser: Bool
        let text: String
    }

    // MARK: - Published state (the 语音聊天 view reads these)

    /// The mode the active session was started with — nil when the session
    /// was started from the sidebar's role presets instead of a shortcut.
    @Published private(set) var activeMode: VoiceWebMode?

    /// The session lifecycle the 挂断/连接 button and the status capsule show.
    @Published private(set) var connectionPhase: VoiceWebConnectionPhase = .idle

    /// VoiceWeb's own role presets, refreshed when the 语音聊天 sidebar opens.
    @Published private(set) var rolePresets: [VoiceWebRolePreset] = []

    /// Why the preset list is empty, when it is — usually the server being
    /// down (the connect flow will start it, so the message is a hint, not a
    /// refusal).
    @Published private(set) var rolesErrorMessage: String?

    /// The role preset the sidebar has highlighted. Selecting is separate
    /// from connecting: the connect only happens on click-through of a row,
    /// which also sets this.
    @Published var selectedRoleID: String?

    /// The engine the 语音聊天 header's 模式 menu has picked, and the one a
    /// role-preset connect hands the page. Deliberately NOT `activeMode`:
    /// that one answers a different question — "was this session started by a
    /// mode shortcut?" — which `handleShortcutPress` reads to decide whether a
    /// second press hangs up or switches over. A role-preset session carries
    /// an engine without being a shortcut session.
    ///
    /// Not persisted: it describes the session the user is about to start, not
    /// the app. `activeMode`'s own doc says the same thing from the other side.
    @Published var selectedMode: VoiceWebMode = .threeStage {
        didSet {
            guard selectedMode != oldValue else { return }
            // 屏幕 / 摄像头两个开关读的键是跟着模式走的（三段式一个屏幕键、
            // 全模态另一对），换模式必须重读，否则按钮会显示上一种模式的值。
            reloadDeviceSwitches()
        }
    }

    /// 语音聊天页头部的「屏幕」开关，和 快捷键 页「VoiceWeb 语音模式」组里的
    /// 是**同一个设置** —— 两个入口读写的都是 `AppSettingsStore`，所以一处改
    /// 另一处立刻一致，不会出现"两个地方显示不同的值"。读哪一对键由
    /// `selectedMode` 决定：三段式只有 `voiceWebThreeStageSendsScreen`，全模态
    /// 才有 `voiceWebOmniScreenEnabled`。
    @Published private(set) var isScreenSharingEnabled = false

    /// 同上，「摄像头」开关 —— 只有全模态有摄像头。
    @Published private(set) var isCameraEnabled = false

    /// The live transcript of the session's conversation — VoiceWeb writes
    /// each turn to a per-role history file, and the 1 s poll mirrors every
    /// message here (both sides, so the view shows the user's own words too).
    @Published private(set) var transcriptEntries: [VoiceWebTranscriptEntry] = []

    // MARK: - Injected bridges (the AgentSessionManager closure precedent)

    /// Shows a finished reply in the cursor-side answer bubble.
    private let presentAnswer: (String) -> Void
    /// Records a failure where the user can see it (`lastErrorMessage`).
    private let presentFailure: (String) -> Void
    /// Drives the notch pill's 「聊天中」 override.
    private let setNotchOverride: (NotchActivityPhase?) -> Void

    private let voiceWebBaseURL = URL(string: "http://localhost:8890")!

    // MARK: - Session state

    /// The whole connect-and-watch flow for the current session. Cancelled on
    /// disconnect and on a mode switch — every `Task.sleep` in it throws and
    /// the loop ends cooperatively, the same cancellation shape the voice
    /// pipeline's `currentResponseTask` relies on.
    private var sessionTask: Task<Void, Never>?

    /// The VoiceWeb server this controller launched (nil when the server was
    /// already running). Deliberately NOT terminated on teardown: the server
    /// is a resident service the user may use outside Clicky.
    private var launchedServerProcess: Process?

    /// The role preset the active session was started with — nil when it was
    /// started by a mode shortcut (those keep whatever role VoiceWeb itself
    /// has active; switching roles is the sidebar's job). Published so the
    /// sidebar can mark the row that is REALLY connected.
    @Published private(set) var activeRoleID: String?

    /// Which VoiceWeb history conversation the session's replies come from.
    /// Everything already in the conversation's history file loads into the
    /// transcript at first sight; only messages past that baseline reach the
    /// answer bubble.
    private var observedHistoryID: String?
    private var mirroredTranscriptMessageCount = 0
    /// A consecutive-disconnected tally so one transient page report cannot
    /// end the session.
    private var consecutiveDisconnectedPolls = 0

    /// The text this controller just sent into the session via the input box.
    /// VoiceWeb's history will eventually carry the same message as a user
    /// turn; the first history user message matching it is skipped so the
    /// transcript does not show the sent line twice.
    private var pendingOwnSentText: String?

    private static let serverProbeTimeoutSeconds: TimeInterval = 1
    private static let serverLaunchWaitSeconds: TimeInterval = 20
    private static let connectionWaitSeconds: TimeInterval = 30

    /// 外部大脑会话的闲置挂断时长：这么久没有听到用户开口（也没有任何最终
    /// 转写）就自动断开。监听不再占用本机麦克风，一个被忘记的会话会一直
    /// 开着浏览器的音频管道 —— 这是它的安全绳。
    private static let companionIdleDisconnectSeconds: TimeInterval = 180

    /// The external-brain companion poll interval. Deliberately faster than
    /// the transcript poll: the page's `user_speaking` report IS Clicky's
    /// barge-in signal, and every 300 ms of latency is a syllable of the user
    /// talking over the answer.
    private static let companionPollIntervalNanoseconds: UInt64 = 300_000_000

    // MARK: - External-brain companion session (VoiceWeb 方案, 2026-09-24)

    /// True while the running session is the **external-brain** one: VoiceWeb's
    /// pipeline owns listening (ASR + VAD + turn detection) and speaking
    /// (TTS through the browser, where the AEC's reference signal is), and
    /// Clicky is the LLM — questions arrive as final user transcript lines,
    /// answers are pushed to `POST /external/speak`. Set by
    /// `startExternalBrainSession`, cleared in `endSession`.
    private(set) var isExternalBrainSession = false

    /// A companion session is "live" from the moment it starts connecting, not
    /// only when connected — a press during the handshake must not start a
    /// local recording on top of it.
    var isCompanionSessionActive: Bool {
        isExternalBrainSession && connectionPhase != .idle
    }

    /// How many final user lines the companion poll has already handed to
    /// `onCompanionUtterance` — each final line fires exactly once.
    private var routedCompanionUserLineCount = 0

    /// Last time the companion session saw the user speak (a `user_speaking`
    /// report or a final transcript). Drives the idle auto-disconnect.
    private var lastCompanionUserActivityAt = Date()

    /// Set right before a companion session ends for a reason other than the
    /// user's own hang-up, consumed by `endSession` so the callback can say why.
    private var companionEndReason: String?

    /// Callbacks CompanionManager installs after construction. Optional vars
    /// rather than init parameters so the existing three-closure init keeps
    /// its shape and the companion wiring reads as one block over there.
    /// A final user utterance → the question pipeline.
    var onCompanionUtterance: ((String) -> Void)?
    /// The user started/stopped speaking (the page's RTVI report). `true`
    /// while a reply is generating is Clicky's barge-in.
    var onCompanionUserSpeechState: ((Bool) -> Void)?
    /// The browser started/stopped reading Clicky's answer (drives the
    /// cursor-side Speaking state and the answer bubble's linger).
    var onCompanionBotSpeechState: ((Bool) -> Void)?
    /// The session ended. The parameter carries a human-readable reason when
    /// the end was not the user's own hang-up (idle timeout, page disconnect).
    var onCompanionSessionEnded: ((String?) -> Void)?

    /// Starts the external-brain companion session: VoiceWeb listens and
    /// speaks, Clicky thinks. Quietly refused when one is already live — the
    /// talk shortcut is the only entry, and it routes through the
    /// active-session branch before ever reaching here.
    func startExternalBrainSession() {
        guard !isExternalBrainSession, connectionPhase == .idle else { return }
        isExternalBrainSession = true
        routedCompanionUserLineCount = 0
        lastCompanionUserActivityAt = Date()
        companionEndReason = nil
        // 三段式（pipeline）是唯一带「听+说」帧管道的引擎，外部大脑就骑在
        // 它上面——服务端用 `external_brain: true` 把 LLM 槽位换成透传 tap，
        // 听（ASR+VAD+打断）和说（TTS）一帧不变。
        startSession(mode: .threeStage, roleID: nil, externalBrain: true)
    }

    /// Pushes one piece of Clicky's answer into the running external-brain
    /// session (server.py `POST /external/speak` → `TTSSpeakFrame`): spoken by
    /// the pipeline's TTS through the browser, where the AEC can hear the
    /// reference signal — the whole reason the answer must never go through
    /// Clicky's local audio engine in this mode.
    func postExternalSpeak(_ text: String) async -> Bool {
        do {
            try await postJSONObject(["text": text], path: "external/speak")
            return true
        } catch {
            return false
        }
    }

    init(presentAnswer: @escaping (String) -> Void,
         presentFailure: @escaping (String) -> Void,
         setNotchOverride: @escaping (NotchActivityPhase?) -> Void) {
        self.presentAnswer = presentAnswer
        self.presentFailure = presentFailure
        self.setNotchOverride = setNotchOverride
        // 页头那三个控件的初值 —— 不读一次的话第一帧会显示成"全关"，而
        // 用户在设置页里可能早把它们打开了。
        reloadDeviceSwitches()
    }

    // MARK: - Shortcut entry

    /// One press of a VoiceWeb mode shortcut. Toggle semantics: the mode's own
    /// shortcut disconnects while connected; another mode's switches over
    /// (disconnect the old, connect the new). A session started from the
    /// 语音聊天 sidebar has no mode — any of the three shortcuts hangs it up
    /// (the user's rule: 第二次触发 = 自动挂断).
    func handleShortcutPress(modeIndex: Int) {
        guard let mode = VoiceWebMode(rawValue: modeIndex) else { return }
        if activeMode == nil, connectionPhase != .idle {
            disconnectCurrentSession()
            return
        }
        if activeMode == mode {
            disconnectCurrentSession()
            return
        }
        startSession(mode: mode, roleID: nil)
    }

    /// The 语音聊天 sidebar role row's connect button: make the role active in
    /// VoiceWeb, then connect. Clicking the already-connected role again is a
    /// no-op; clicking a different one while a session runs hangs up the old
    /// session first (the single-bridge command slot cannot carry both).
    ///
    /// Not wired to a sidebar row any more — a row click only selects (see
    /// `selectRole`), and the connection is started from the row's own
    /// 连接 button. Kept because that button and the shortcuts call it.
    func connectToRole(_ roleID: String) {
        selectedRoleID = roleID
        // `.connecting` counts as busy: a second click while the handshake is
        // still running would otherwise tear the半-finished session down and
        // start it again, which reads as the row restarting itself.
        if connectionPhase != .idle, activeRoleID == roleID { return }
        // 引擎取页头的 模式 菜单 —— 用户在那里选的就是这一条连接要用的模式。
        startSession(mode: selectedMode, roleID: roleID)
    }

    /// The sidebar row's action: select the role, and nothing else. Selection
    /// is the user's choice of who to talk to; starting a session is a separate
    /// decision made once, by the 连接 button. Keeping them apart is what stops
    /// the connection state from appearing to move between rows as the user
    /// clicks through them.
    func selectRole(_ roleID: String) {
        selectedRoleID = roleID
    }

    /// Best-effort disconnect at app termination — the server keeps running.
    func disconnectOnTermination() {
        sessionTask?.cancel()
        sessionTask = nil
        if connectionPhase != .idle {
            sendBridgeCommand(["action": "disconnect"])
        }
        // endSession (not a manual reset): a companion session has to fire its
        // ended-callback so CompanionManager's own state unwinds with it.
        endSession()
    }

    // MARK: - Role presets (sidebar list)

    /// Refreshes the VoiceWeb role presets for the sidebar list. Runs on the
    /// section's every appearance — cheap (one GET), and it heals the list
    /// after the server comes up.
    func refreshRolePresets() {
        Task { [weak self] in
            guard let self else { return }
            do {
                let data = try await self.httpGET(path: "/config")
                guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let config = object["config"] as? [String: Any],
                      let rawRoles = config["roles"] as? [[String: Any]] else {
                    self.rolesErrorMessage = "VoiceWeb 返回的配置里没有角色列表"
                    return
                }
                let presets = rawRoles.compactMap { role -> VoiceWebRolePreset? in
                    guard let roleID = role["id"] as? String, !roleID.isEmpty else { return nil }
                    let roleName = (role["name"] as? String) ?? ""
                    return VoiceWebRolePreset(id: roleID, name: roleName.isEmpty ? "未命名角色" : roleName)
                }
                self.rolePresets = presets
                self.rolesErrorMessage = presets.isEmpty ? "VoiceWeb 还没有配置任何角色预设" : nil
                if self.selectedRoleID == nil {
                    self.selectedRoleID = presets.first?.id
                }
            } catch {
                // The server being down is the normal case — the connect flow
                // starts it. The message is a hint about why the list is empty.
                self.rolesErrorMessage = "VoiceWeb 服务没有响应，点击角色会自动启动它"
            }
        }
    }

    // MARK: - Header device switches (模式 / 屏幕 / 摄像头)

    /// 头部那两个开关的当前值，从设置里重读一遍。
    ///
    /// 调用点有三处，都不是随便放的：`init`（第一帧就是对的）、
    /// `selectedMode` 的 `didSet`（换模式 = 换键）、以及页头的 `onAppear`
    /// （用户在设置页改了同一个开关之后回到这一页）。**不需要通知观察者**：
    /// 设置页是整窗独占的，它和语音聊天的页头不可能同时在屏幕上，所以
    /// "改完再回到这一页"一定会重新走一次 `onAppear` —— 和
    /// `refreshRolePresets` 靠的是同一条。
    func reloadDeviceSwitches() {
        let settings = AppSettingsStore.snapshot()
        isScreenSharingEnabled = Self.screenSharingSetting(from: settings, mode: selectedMode)
        isCameraEnabled = settings.voiceWebOmniCameraEnabled
    }

    /// 三段式的屏幕开关和全模态的屏幕开关是**两个**存储键（VoiceWeb 自己的
    /// 配置就是这么分的：三段式是 `screen_vision`，全模态是 `screen`），所以
    /// 读的时候也要按模式选键。全双工语音两者都没有。
    private static func screenSharingSetting(from settings: AppSettings, mode: VoiceWebMode) -> Bool {
        switch mode {
        case .threeStage: return settings.voiceWebThreeStageSendsScreen
        case .duplexVoice: return false
        case .omni: return settings.voiceWebOmniScreenEnabled
        }
    }

    /// 三段式没有摄像头，全双工语音既没有摄像头也没有屏幕。按钮**禁用而不是
    /// 隐藏** —— 隐藏的话换模式时页头会跳一下，而且用户看不出"这个模式没有
    /// 这个能力"和"这个功能没做"的区别。
    var selectedModeSupportsScreenSharing: Bool { selectedMode != .duplexVoice }
    var selectedModeSupportsCamera: Bool { selectedMode == .omni }

    /// 写回设置并刷新本对象的两个开关。`AppSettingsStore.save` 本来就会发
    /// `.clickyAppSettingsChanged`（设置页据此重读），这里只需要更新自己的
    /// `@Published` 值，让头部按钮立刻变色。
    ///
    /// 值只在**下一次连接**时才被送进 VoiceWeb（`sendConnectCommand` 读的是
    /// 当时的设置）—— 桥没有运行时切换设备的命令，页头的 `.help` 写明了这一点。
    func setScreenSharingEnabled(_ isEnabled: Bool) {
        guard selectedModeSupportsScreenSharing else { return }
        var settings = AppSettingsStore.snapshot()
        switch selectedMode {
        case .threeStage: settings.voiceWebThreeStageSendsScreen = isEnabled
        case .omni: settings.voiceWebOmniScreenEnabled = isEnabled
        case .duplexVoice: return
        }
        persistAppSettings(settings)
    }

    func setCameraEnabled(_ isEnabled: Bool) {
        guard selectedModeSupportsCamera else { return }
        var settings = AppSettingsStore.snapshot()
        settings.voiceWebOmniCameraEnabled = isEnabled
        persistAppSettings(settings)
    }

    private func persistAppSettings(_ settings: AppSettings) {
        do {
            try AppSettingsStore.save(settings)
            reloadDeviceSwitches()
        } catch {
            presentFailure("保存语音聊天设置失败：\(error.localizedDescription)")
        }
    }

    // MARK: - Text input (the composer)

    /// Sends a typed line into the connected session. The page executes
    /// `client.sendText` (the official RTVI text-input path, already wired
    /// through VoiceWeb's silent-reply wrapper); VoiceWeb echoes the message
    /// into its history, and the transcript poll mirrors it — the pending
    /// marker below keeps that echo from doubling the line on screen.
    func sendText(_ rawText: String) {
        let trimmedText = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }
        guard connectionPhase == .connected else {
            presentFailure("还没有连接语音聊天，先连上再打字。")
            return
        }
        pendingOwnSentText = trimmedText
        sendBridgeCommand(["action": "text", "text": trimmedText])
    }

    // MARK: - Session flow

    private func startSession(mode: VoiceWebMode?, roleID: String?, externalBrain: Bool = false) {
        sessionTask?.cancel()
        sessionTask = nil
        if connectionPhase != .idle {
            // Switching modes/roles while connected: the page must actually
            // drop the old connection before the new engine connects (single
            // command slot — a disconnect sent right before the connect would
            // be overwritten unread), so it is sent now and the flow below
            // sleeps past the page's 500 ms poll before connecting.
            sendBridgeCommand(["action": "disconnect"])
        }
        activeMode = mode
        activeRoleID = roleID
        // A companion session carries no mode: any of the three VoiceWeb mode
        // shortcuts (or another talk-shortcut press) hangs it up, the same
        // rule a sidebar-started session lives under.
        if externalBrain { activeMode = nil }
        // 这一条连接真正要用的引擎。shortcut 会话用它自己的模式；sidebar 起的
        // 会话没有模式，用页头 模式 菜单选的那一个。
        //
        // 必须另存一份而不是直接把 `selectedMode` 写进 `activeMode`：那个属性
        // 回答的是"这条会话是不是 shortcut 起的"（`handleShortcutPress` 靠它
        // 判断第二次触发是挂断还是换模式），把角色会话也标上模式会让「⌃⌥2」
        // 从"挂断"变成"切换到全双工语音"。
        let sessionEngineMode = mode ?? selectedMode
        connectionPhase = .connecting
        // A new session watches a new conversation; the transcript poll
        // repopulates from the history baseline at its first tick.
        observedHistoryID = nil
        mirroredTranscriptMessageCount = 0
        pendingOwnSentText = nil
        liveMirroredLineCount = 0
        presentedLiveBotLineCount = 0
        transcriptEntries = []
        // 连接中先显示「Connecting + 连接动画」；页面回报 ready 之后（runSession
        // 里 waitForConnection 通过的那一步）才换成「Chatting + 挂断图标」——
        // 用户 2026-09-23：「连接中的时候不知道……右侧不要有挂断按钮，而应该是
        // 一个连接中的动画效果。只有连接成功之后，右侧才是挂断按钮」。
        setNotchOverride(.externalConnecting)
        sessionTask = Task { [weak self] in
            await self?.runSession(mode: sessionEngineMode, externalBrain: externalBrain)
        }
    }

    /// - Parameter mode: 这条连接要用的引擎，**一定不是 nil** —— shortcut 会话
    ///   在自己的模式下起，sidebar 起的会话用页头 模式 菜单选的那个
    ///   （`startSession` 里合成 `sessionEngineMode`，两种来源在那一步就并成
    ///   一个值）。以前这里是 Optional，因为角色会话刻意不指定引擎、让页面
    ///   沿用自己加载时的那个；现在页头有了显式的模式选择，那个"不指定"的
    ///   分支就没有来源了。
    private func runSession(mode: VoiceWebMode, externalBrain: Bool) async {
        do {
            try await ensureVoiceWebServerIsReachable()
            try await ensureVoiceWebPageIsAvailable()
            // The mode switch disconnect above needs one page poll (500 ms) to
            // have been consumed before the connect overwrites the slot.
            try await Task.sleep(nanoseconds: 700_000_000)
            if let roleID = activeRoleID {
                // The role row's promise: connect AS this role. `active_role`
                // is VoiceWeb's own editable key (the page's role picker
                // writes the same one); the running bot reads it at session
                // start, so writing it right before the connect is enough.
                try await postJSONObject(["active_role": roleID], path: "/config")
            }
            try await sendConnectCommand(mode: mode, externalBrain: externalBrain)
            try await waitForConnection()
            connectionPhase = .connected
            // 连接成功才把右翼换成挂断图标 + 「Chatting」。
            setNotchOverride(.externalChatting)
            // 页头的 模式 菜单自动对齐这条会话真正用的引擎（用户 2026-09-23：
            // 「快捷键连接的是全双工语音模式，点击面板展开后，右上角的模式没有被
            // 自动切换成全双工语音模式。我希望它能自动切换」）。didSet 会连带
            // 重读屏幕/摄像头开关——它们本来就是"下次连接生效"的草稿，对齐后
            // 显示的就是当前模式的设置，语义一致。角色会话的 mode 本来就来自
            // selectedMode，这一步是幂等的；shortcut 会话在这一步换过去。
            selectedMode = mode
            try await pollSessionUntilDisconnected(externalBrain: externalBrain)
        } catch is CancellationError {
            return
        } catch {
            presentFailure("VoiceWeb 连接失败：\(error.localizedDescription)")
            SoundEffectPlayer.shared.play(.errorSurprised)
            endSession()
        }
    }

    /// Hangs up and returns the notch to idle. The transcript stays on screen
    /// — the user may still be reading it; the next connect replaces it.
    func disconnectCurrentSession() {
        sessionTask?.cancel()
        sessionTask = nil
        sendBridgeCommand(["action": "disconnect"])
        endSession()
    }

    private func endSession() {
        // Captured before the reset: a companion session's observer learns why
        // (nil = the user's own hang-up) alongside the fact itself.
        let wasExternalBrainSession = isExternalBrainSession
        let externalEndReason = companionEndReason
        companionEndReason = nil

        activeMode = nil
        activeRoleID = nil
        connectionPhase = .idle
        observedHistoryID = nil
        mirroredTranscriptMessageCount = 0
        pendingOwnSentText = nil
        consecutiveDisconnectedPolls = 0
        setNotchOverride(nil)

        if wasExternalBrainSession {
            isExternalBrainSession = false
            routedCompanionUserLineCount = 0
            onCompanionUserSpeechState?(false)
            onCompanionBotSpeechState?(false)
            onCompanionSessionEnded?(externalEndReason)
        }
    }

    // MARK: - Server reachability

    private func ensureVoiceWebServerIsReachable() async throws {
        if await isServerReachable() { return }

        // Down → launch it. A resident the user started themselves would be
        // reachable here, so reaching this line means Clicky owns this process.
        try launchVoiceWebServer()
        let pollDeadline = Date().addingTimeInterval(Self.serverLaunchWaitSeconds)
        while Date() < pollDeadline {
            try Task.checkCancellation()
            if await isServerReachable() { return }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        throw VoiceWebSessionError.serverDidNotStart
    }

    private func isServerReachable() async -> Bool {
        do {
            var request = URLRequest(url: voiceWebBaseURL.appendingPathComponent("status"))
            request.timeoutInterval = Self.serverProbeTimeoutSeconds
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    private func launchVoiceWebServer() throws {
        let projectFolderPath = AppSettingsStore.snapshot().voiceWebProjectFolderPath
        let pythonExecutablePath = projectFolderPath + "/.venv/bin/python"
        guard FileManager.default.fileExists(atPath: pythonExecutablePath) else {
            throw VoiceWebSessionError.pythonEnvironmentNotFound(projectFolderPath)
        }

        let serverProcess = Process()
        serverProcess.executableURL = URL(fileURLWithPath: pythonExecutablePath)
        serverProcess.arguments = ["-u", "server.py"]
        serverProcess.currentDirectoryURL = URL(fileURLWithPath: projectFolderPath)

        // stdout/stderr append to one log next to the app's own files — pure
        // intermediate output, only wanted when something goes wrong.
        let logFilePath = VoiceWebSessionController.serverLogFilePath
        if !FileManager.default.fileExists(atPath: logFilePath) {
            FileManager.default.createFile(atPath: logFilePath, contents: nil)
        }
        if let logHandle = FileHandle(forWritingAtPath: logFilePath) {
            logHandle.seekToEndOfFile()
            serverProcess.standardOutput = logHandle
            serverProcess.standardError = logHandle
        }

        try serverProcess.run()
        launchedServerProcess = serverProcess
    }

    /// Where the launched server's output lands. Kept beside the app's own
    /// files so it survives and can be inspected after a failure.
    static var serverLogFilePath: String {
        let applicationSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return applicationSupportURL
            .appendingPathComponent("Clicky", isDirectory: true)
            .appendingPathComponent("voice-web-server.log")
            .path
    }

    // MARK: - Chrome window

    /// Makes sure a VoiceWeb page is loaded somewhere in Chrome.
    ///
    /// The live-report check IS the page check: any page that loaded reports
    /// to the bridge (state changes + a 10 s heartbeat), so a report within
    /// the server's 35 s expiry proves a page is open — no window/tab work at
    /// all. Opening used to be decided by an in-app AppleScript raise, but
    /// Clicky lacks the Chrome-automation TCC grant, so the script always
    /// failed and the `open -a` fallback fired on EVERY press, stacking up
    /// one duplicate VoiceWeb tab per press (three tabs from three presses —
    /// measured 2026-09-23). The AppleScript is kept only as the
    /// bring-to-front courtesy for a fresh open; a one-time "Clicky wants to
    /// control Chrome" prompt is its price.
    private func ensureVoiceWebPageIsAvailable() async {
        if let state = await fetchBridgeState(), state.phase != nil {
            return
        }
        let raiseScript = """
        tell application "Google Chrome"
            repeat with w in windows
                set tabIndex to 0
                repeat with t in tabs of w
                    set tabIndex to tabIndex + 1
                    -- ":8890" rather than "localhost:8890" — Chrome also
                    -- surfaces the page as http://127.0.0.1:8890
                    if URL of t contains ":8890" then
                        set index of w to 1
                        set active tab index of w to tabIndex
                        return
                    end if
                end repeat
            end repeat
        end tell
        """
        if let appleScript = NSAppleScript(source: raiseScript) {
            var scriptError: NSDictionary?
            appleScript.executeAndReturnError(&scriptError)
        }
        // No live page report means no VoiceWeb page is loaded anywhere, so
        // opening a tab here cannot duplicate an existing one.
        let openProcess = Process()
        openProcess.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        openProcess.arguments = ["-a", "Google Chrome", "http://localhost:8890/client/"]
        try? openProcess.run()
    }

    // MARK: - Bridge commands and polling

    /// 把这一条连接的四个选择一起交给页面：引擎、麦克风、屏幕、摄像头。
    ///
    /// 屏幕与摄像头读的是**当前设置**（页头那两个开关和 快捷键 页写的是同一
    /// 批键），所以改完开关要重新连一次才会生效 —— 桥没有运行时切换设备的
    /// 命令，页头的 `.help` 写明了这一点。
    ///
    /// 引擎一定会发：页头 模式 菜单选的就是它。页面自己处理"引擎和我加载时
    /// 的不一样"这种情况（重新 POST 一次命令再 `location.reload()`，见
    /// 开发经验里那条实测——服务端切 `chat_engine` 对已经挂载的页面是不可见
    /// 的，它的连接会静默什么都不做）。
    private func sendConnectCommand(mode: VoiceWebMode, externalBrain: Bool = false) async throws {
        let settings = AppSettingsStore.snapshot()
        var payload: [String: Any] = ["action": "connect"]
        payload["engine"] = mode.engineName
        payload["mic"] = true
        if mode == .threeStage {
            payload["screen_vision"] = settings.voiceWebThreeStageSendsScreen
        }
        if mode == .omni {
            payload["mic"] = settings.voiceWebOmniVoiceEnabled
            payload["cam"] = settings.voiceWebOmniCameraEnabled
            payload["screen"] = settings.voiceWebOmniScreenEnabled
        }
        if externalBrain {
            // server.py 认的就是这个键：把 LLM 槽位换成透传 tap，听（ASR+VAD+
            // 打断）和说（TTS）留在 pipeline 里一帧不变，问题走最终用户转写
            // 上来、回答经 /external/speak 送回去。
            payload["external_brain"] = true
        }
        try await postBridgeCommand(payload)
    }

    /// The page's `connState()`-derived phase: ready / connecting /
    /// disconnected / failed. nil when the page has never reported (patch not
    /// loaded, page never opened). The server's `server_phase`/`running_engine`
    /// fields in the merged payload are deliberately not carried — they say
    /// nothing about whether the page itself is connected.
    private struct BridgeState {
        var phase: String?
        var mic: Bool?
        var cam: Bool?
        var screen: Bool?
        /// The page's LIVE transcript of the running session (`live` in the
        /// page's report: `[{r:"u"|"b", t:text}]`) — VoiceWeb's history file
        /// is only written at disconnect, so this is the only source that
        /// shows turns while the session is still up.
        var liveLines: [(isUser: Bool, text: String, isInterim: Bool)] = []
        /// The page's own speaking-state hooks (patch.js hooks
        /// botStartedSpeaking / botStoppedSpeaking into `EXB.botSpeaking`).
        /// The companion session's interrupt and voice-state machine reads
        /// both — the interim transcript alone cannot distinguish "the user
        /// is talking" from "the page is echoing the answer".
        var botSpeaking: Bool = false
        var userSpeaking: Bool = false
    }

    private func fetchBridgeState() async -> BridgeState? {
        guard let data = try? await httpGET(path: "/external/state") else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var liveLines: [(isUser: Bool, text: String, isInterim: Bool)] = []
        if let live = object["live"] as? [[String: Any]] {
            for line in live {
                guard let text = (line["t"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !text.isEmpty else { continue }
                let isUser = (line["r"] as? String) == "u"
                // The in-flight interim utterance rides the report tail; only
                // a line the page itself tags `interim` may be dropped from
                // final-line routing (a stale interim would otherwise fire
                // the question twice).
                let isInterim = (line["interim"] as? Bool) == true
                liveLines.append((isUser: isUser, text: text, isInterim: isInterim))
            }
        }
        return BridgeState(
            phase: object["phase"] as? String,
            mic: object["mic"] as? Bool,
            cam: object["cam"] as? Bool,
            screen: object["screen"] as? Bool,
            liveLines: liveLines,
            botSpeaking: (object["bot_speaking"] as? Bool) == true,
            userSpeaking: (object["user_speaking"] as? Bool) == true
        )
    }

    /// Waits until the page itself reports ready. The server's own READY
    /// snapshot is deliberately NOT accepted here: it says "ready" the moment
    /// the server is merely up, so accepting it declared victory while the
    /// page was still connecting — and the fresh page's "disconnected" report
    /// then ended the session two polls later.
    private func waitForConnection() async throws {
        let deadline = Date().addingTimeInterval(Self.connectionWaitSeconds)
        while Date() < deadline {
            try Task.checkCancellation()
            if let state = await fetchBridgeState() {
                if state.phase == "failed" {
                    throw VoiceWebSessionError.connectionFailed
                }
                if state.phase == "ready" {
                    return
                }
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        throw VoiceWebSessionError.connectionTimedOut
    }

    /// The connected session's watch loop: the transcript mirror (which also
    /// feeds the bubble), the page's LIVE transcript lines, and the user
    /// disconnecting from the VoiceWeb page itself ends the session.
    private func pollSessionUntilDisconnected(externalBrain: Bool) async throws {
        // The companion session polls at 300 ms instead of 1 s: the
        // interrupt path (user starts speaking → Clicky stops generating)
        // and the barge-in feel ride this loop, so a second of latency here
        // is a second the user's first word costs. The non-companion session
        // keeps 1 s — its only consumers are the transcript mirror and the
        // bubble, both of which tolerate it.
        let pollIntervalNanoseconds = externalBrain
            ? Self.companionPollIntervalNanoseconds
            : 1_000_000_000
        let disconnectedPollThreshold = externalBrain ? 4 : 2

        while true {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: pollIntervalNanoseconds)

            let state = await fetchBridgeState()
            if let state {
                if state.phase == "disconnected" || state.phase == "failed" {
                    consecutiveDisconnectedPolls += 1
                    if consecutiveDisconnectedPolls >= disconnectedPollThreshold {
                        endSession()
                        return
                    }
                } else {
                    consecutiveDisconnectedPolls = 0
                }
            }

            if externalBrain {
                guard let state, state.phase == "ready" else { continue }
                processCompanionState(state)
            } else {
                // The history file only changes at disconnect, so the mirror
                // is a no-op while the session runs; the live lines are what
                // moves.
                await refreshTranscriptIfPossible()
                if let state, state.phase == "ready" {
                    mergeLiveTranscript(state.liveLines)
                }
            }
        }
    }

    // MARK: - External-brain companion session state

    /// Feeds one ready poll's page state into the companion machine: speech
    /// callbacks for Clicky's interrupt/voice-state half, the transcript
    /// mirror for the 语音聊天 view, final user lines up to
    /// `CompanionManager` (its `submitTypedQuestion` pipeline), and the
    /// 180 s idle watchdog.
    private func processCompanionState(_ state: BridgeState) {
        onCompanionUserSpeechState?(state.userSpeaking)
        if state.userSpeaking {
            lastCompanionUserActivityAt = Date()
        }
        onCompanionBotSpeechState?(state.botSpeaking)

        mergeLiveTranscript(state.liveLines)
        routeCompanionFinalUserLines(state.liveLines)

        // Idle watchdog: nobody has spoken (and nothing has been asked) for
        // the full window — hang up so a forgotten session does not hold the
        // mic and the browser tab forever.
        if Date().timeIntervalSince(lastCompanionUserActivityAt)
            >= Self.companionIdleDisconnectSeconds {
            companionEndReason = "闲置超时，语音会话已自动结束"
            disconnectCurrentSession()
        }
    }

    /// Fires `onCompanionUtterance` for each FINAL user line Clicky has not
    /// yet routed. Interim lines are skipped (they are still being spoken —
    /// the final replaces them), and a routed count rather than a content
    /// check decides newness, because a user genuinely repeating a sentence
    /// must still reach the model.
    private func routeCompanionFinalUserLines(_ liveLines: [(isUser: Bool, text: String, isInterim: Bool)]) {
        let finalUserLines = liveLines.filter { $0.isUser && !$0.isInterim }
        guard finalUserLines.count > routedCompanionUserLineCount else { return }
        for line in finalUserLines[routedCompanionUserLineCount...] {
            routedCompanionUserLineCount += 1
            guard !line.text.isEmpty else { continue }
            onCompanionUtterance?(line.text)
        }
    }

    // MARK: - Live transcript (the page's report while the session runs)

    /// How many entries at the tail of `transcriptEntries` came from the page's
    /// live report — they are replaced wholesale on every poll (the last bot
    /// line grows as it streams), unlike the history mirror which only appends.
    private var liveMirroredLineCount = 0
    /// How many bot lines the bubble has already presented this session — a
    /// new bot line reaches the bubble exactly once.
    private var presentedLiveBotLineCount = 0

    /// Replaces the live tail of `transcriptEntries` with the page's current
    /// live transcript. The lines STAY on screen after hang-up (endSession
    /// deliberately leaves `transcriptEntries` alone) — the next connect
    /// resets them, and the saved history covers the long term.
    private func mergeLiveTranscript(_ liveLines: [(isUser: Bool, text: String, isInterim: Bool)]) {
        if liveMirroredLineCount > 0, liveMirroredLineCount <= transcriptEntries.count {
            transcriptEntries.removeLast(liveMirroredLineCount)
        }
        liveMirroredLineCount = 0

        var botLineCount = 0
        var appendedEntries: [VoiceWebTranscriptEntry] = []
        for line in liveLines {
            if line.isUser {
                // NOTE: the echo of a typed line is NOT skipped here — the
                // live lines are the only place the typed line appears (the
                // optimistic append doesn't exist, and the history file is
                // written at disconnect when polling has already stopped).
            } else {
                botLineCount += 1
            }
            appendedEntries.append(VoiceWebTranscriptEntry(isUser: line.isUser, text: line.text))
        }
        transcriptEntries.append(contentsOf: appendedEntries)
        liveMirroredLineCount = appendedEntries.count

        // 2026-09-23 修复「AI 回复只显示最后一句」：VoiceWeb 的 botTranscript
        // 是按句末标点逐句上报的（pipecat observer.py 的 _handle_llm_text_frame
        // 每句发一条），气泡不能再只取最新一句 —— 把"最近一条用户消息之后"
        // 的所有 bot 行拼起来，作为**目前为止的整段回复**送进气泡。它随每句
        // 落地而变长，结束时就是完整回复。
        //
        // The external-brain companion session deliberately SKIPS this: its
        // answer travels through CompanionManager's reply pipeline (sentence
        // → /external/speak), which already presents it in the cursor bubble
        // — and there are no botTranscript lines to read anyway, because no
        // LLM text frames flow through the external-brain tap.
        if !isExternalBrainSession, botLineCount > presentedLiveBotLineCount {
            var replySoFar: [String] = []
            for line in appendedEntries {
                if line.isUser {
                    replySoFar.removeAll()
                } else {
                    replySoFar.append(line.text)
                }
            }
            // 句与句之间不加空格：中文句末自带标点，补空格反而把气泡撑出缝隙。
            let fullReplySoFar = replySoFar.joined()
            if !fullReplySoFar.isEmpty {
                presentAnswer(fullReplySoFar)
            }
        }
        presentedLiveBotLineCount = botLineCount
    }

    // MARK: - Transcript mirror (view + bubble)

    /// Mirrors the session's VoiceWeb history into `transcriptEntries`, and
    /// pushes every NEW assistant message into the answer bubble. The
    /// conversation is the active role's own history file (VoiceWeb keeps one
    /// per role); a mode-shortcut session follows the most recently modified
    /// conversation, since it does not name a role.
    private func refreshTranscriptIfPossible() async {
        let conversationID: String?
        if let activeRoleID {
            conversationID = activeRoleID
        } else {
            conversationID = await newestHistoryConversationID()
        }
        guard let conversationID else { return }

        guard let data = try? await httpGET(path: "/history/\(conversationID)"),
              let detail = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let messages = detail["messages"] as? [[String: Any]] else { return }

        if observedHistoryID != conversationID {
            // First sight of this conversation: everything already in the
            // history file is the record the user asked to see (load it
            // whole), but the bubble only presents messages from now on.
            observedHistoryID = conversationID
            transcriptEntries = messages.compactMap(Self.transcriptEntry(fromMessage:))
            mirroredTranscriptMessageCount = messages.count
            return
        }

        guard messages.count > mirroredTranscriptMessageCount else { return }

        var appendedEntries: [VoiceWebTranscriptEntry] = []
        for message in messages[mirroredTranscriptMessageCount...] {
            let isUserMessage = (message["role"] as? String) == "user"
            let messageText = Self.transcriptText(fromMessage: message)
            if isUserMessage, messageText == pendingOwnSentText {
                // The echo of a line this controller just sent — the
                // optimistic entry is already on screen; skip the duplicate.
                pendingOwnSentText = nil
                continue
            }
            if let entry = Self.transcriptEntry(fromMessage: message) {
                appendedEntries.append(entry)
            }
            // Every new assistant message reaches the bubble exactly once —
            // the loop only ever sees each history position one time, because
            // `mirroredTranscriptMessageCount` jumps past it right below.
            if !isUserMessage, !messageText.isEmpty {
                presentAnswer(messageText)
            }
        }
        mirroredTranscriptMessageCount = messages.count
        transcriptEntries.append(contentsOf: appendedEntries)
    }

    /// A mode-shortcut session does not name a role, so its conversation is
    /// the most recently modified one in VoiceWeb's history list.
    private func newestHistoryConversationID() async -> String? {
        guard let historyList = try? await httpGET(path: "/history"),
              let listObject = try? JSONSerialization.jsonObject(with: historyList) as? [String: Any],
              let conversations = listObject["history"] as? [[String: Any]] else { return nil }
        return conversations
            .max(by: { ($0["mtime"] as? Double ?? 0) < ($1["mtime"] as? Double ?? 0) })?["id"] as? String
    }

    /// One history message → one transcript entry, or nil for a message with
    /// nothing readable.
    private static func transcriptEntry(fromMessage message: [String: Any]) -> VoiceWebTranscriptEntry? {
        let text = transcriptText(fromMessage: message)
        guard !text.isEmpty else { return nil }
        return VoiceWebTranscriptEntry(isUser: (message["role"] as? String) == "user", text: text)
    }

    /// VoiceWeb's history detail route has already flattened multimodal
    /// content to text server-side, so a plain string is the normal shape;
    /// an array of content parts is tolerated anyway.
    private static func transcriptText(fromMessage message: [String: Any]) -> String {
        if let text = message["content"] as? String { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let parts = message["content"] as? [[String: Any]] {
            let joined = parts.compactMap { $0["text"] as? String }.joined(separator: " ")
            return joined.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ""
    }

    // MARK: - HTTP plumbing

    private func httpGET(path: String) async throws -> Data {
        var request = URLRequest(url: voiceWebBaseURL.appendingPathComponent(path))
        request.timeoutInterval = 3
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw VoiceWebSessionError.httpStatus
        }
        return data
    }

    private func sendBridgeCommand(_ payload: [String: Any]) {
        Task { [weak self] in
            try? await self?.postBridgeCommand(payload)
        }
    }

    private func postBridgeCommand(_ payload: [String: Any]) async throws {
        try await postJSONObject(payload, path: "external/command")
    }

    private func postJSONObject(_ payload: [String: Any], path: String) async throws {
        var request = URLRequest(url: voiceWebBaseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 3
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (_, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw VoiceWebSessionError.httpStatus
        }
    }
}

enum VoiceWebSessionError: LocalizedError {
    case serverDidNotStart
    case pythonEnvironmentNotFound(String)
    case connectionFailed
    case connectionTimedOut
    case httpStatus

    var errorDescription: String? {
        switch self {
        case .serverDidNotStart:
            return "服务启动超时（20 秒内没有就绪）"
        case .pythonEnvironmentNotFound(let projectFolderPath):
            return "在 \(projectFolderPath) 下没有找到 .venv/bin/python，请在设置的快捷键页核对 VoiceWeb 项目文件夹"
        case .connectionFailed:
            return "连接失败（页面回报 failed，详情见 VoiceWeb 窗口）"
        case .connectionTimedOut:
            return "连接超时（30 秒内没有就绪）"
        case .httpStatus:
            return "服务返回了非 200 状态"
        }
    }
}
