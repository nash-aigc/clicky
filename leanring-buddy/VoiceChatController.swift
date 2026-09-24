import Foundation
import AppKit
import Combine
import SwiftUI

/// 语音聊天的原生控制器。
///
/// 它的对外表面（`@Published` 与公开方法）是照着**已有的界面**定下来的：
/// `VoiceChatSessionView` / `HomeSpaceSidebarView` 只读这些成员，所以从旧的
/// 桥接实现换成原生实现时，**界面一行没改**。
///
/// 与 Chrome 那条路的根本区别：**没有外部进程、没有桥接轮询、没有页面**。
/// 麦克风走 `BuddyDictationManager` 的连续监听（它已经实现了 VAD 开轮、
/// 一次性打断闩、静音自动发送、≥4 字门槛与宽限兜底），说话走共享的
/// `BailianTTSClient`，理解走 `BailianVisionChatAPI`，全都在本进程里。
///
/// 结构照 `AgentSessionManager` 的成例：
/// - 由 `CompanionManager` 懒持有，通过闭包单向解耦
/// - **绝不碰 `voiceState` / `currentResponseTask`**（那是按住说话的槽位）
/// - 刘海相位走 `setNotchOverride` 覆盖，不写语音状态
@MainActor
final class VoiceChatController: ObservableObject {

    // MARK: - 对外类型（界面读的就是这些）

    /// 会话生命周期，语义与 Chrome 版一致：
    /// `.connecting` 覆盖整个建连过程，`.connected` 是**真的可以说话了**。
    /// 原生这条路没有「页面握手」，所以 `.connecting` 只覆盖「起麦克风 + 应用设备开关」，
    /// 它比 Chrome 版短得多，但保留这个相位是因为界面要显示「连接中…」。
    enum VoiceChatConnectionPhase: Equatable {
        case idle
        case connecting
        case connected
    }

    /// 角色卡片（侧栏列表用）。字段与 Chrome 版一致，只是数据来自本地角色表，
    /// 而不是 VoiceWeb 的 config.json。
    struct VoiceChatRolePreset: Identifiable, Equatable {
        let id: String
        let name: String
    }

    /// 一行对话。`isUser` 决定气泡在哪一侧。
    struct VoiceChatTranscriptEntry: Identifiable, Equatable {
        let id: UUID
        let isUser: Bool
        var text: String

        init(id: UUID = UUID(), isUser: Bool, text: String) {
            self.id = id
            self.isUser = isUser
            self.text = text
        }
    }

    /// 两个预览框（用户 2026-09-24 重新定的交互）：
    ///
    /// - 它是**常驻**的：会话在跑，这条就一直在页头下面，所以永远找得到入口。
    ///   （前一版把「缩起来」做成整条消失，用户点一下之后就再也叫不回来了 ——
    ///   他把这个当作 bug 报上来，是对的。）
    /// - 每个框各自可以**折叠成一条**：点一下折叠、再点一下展开。
    /// - **设备关掉就自动折叠**，打开就自动展开 —— 关着的设备占着画面位置没有意义。
    enum PreviewPane { case camera, screen }

    // MARK: - Published（视图读的就是这些）

    @Published private(set) var connectionPhase: VoiceChatConnectionPhase = .idle
    @Published private(set) var rolePresets: [VoiceChatRolePreset] = []
    @Published private(set) var rolesErrorMessage: String?
    @Published var selectedRoleID: String?
    @Published var selectedMode: VoiceChatEngine = .threeStage {
        didSet {
            guard selectedMode != oldValue else { return }
            // 屏幕/摄像头两个开关是按模式决定可用性的（全双工语音不能送画面），
            // 换模式必须重读，否则按钮会停留在上一种模式的状态。
            reloadDeviceSwitches()
        }
    }
    @Published private(set) var isScreenSharingEnabled = false
    @Published private(set) var isCameraEnabled = false
    @Published private(set) var transcriptEntries: [VoiceChatTranscriptEntry] = []
    @Published private(set) var activeRoleID: String?

    /// 会话开始时用的是哪个模式 —— 与 Chrome 版同义（快捷键起会话时才有值）。
    @Published private(set) var activeMode: VoiceChatEngine?

    /// 两个预览框的采集服务。它们只在本会话期间跑，断开就关 ——
    /// 屏幕流和摄像头都是「一直在耗电/占灯」的东西，没有会话时不该留着。
    let cameraPreview = CameraPreviewService()
    let screenPreview = ScreenPreviewCaptureService()

    /// 两个预览框各自的折叠状态。**放在控制器而不是视图的 `@State`**：
    /// 刘海面板每次展开都会重新插入 `VoiceChatSessionView`，放 `@State` 的话
    /// 用户刚折叠/展开的状态会在收起面板时丢掉。
    @Published private(set) var isCameraPreviewCollapsed = false
    @Published private(set) var isScreenPreviewCollapsed = false

    /// 右侧内容列现在显示的是「角色编辑」而不是对话。
    ///
    /// 用户 2026-09-24：「右键卡片后有一个"编辑"按钮，点击编辑，右侧的对话页面就变成一个设置页面」。
    /// 所以它是**就地替换右列**，不是弹窗 —— 与设置页那种整窗接管不同。
    @Published var isShowingRoleEditor = false

    /// 进编辑器时要选中的角色（右键哪张卡片就编哪个）。
    @Published var roleEditorInitialRoleID: String?

    /// 哪个框正在全屏（nil = 都在常规形态）。全屏是**互斥**的：两个框同时全屏
    /// 谁也占不满，所以设一个时另一个自动回常规。
    @Published private(set) var fullScreenPreviewPane: PreviewPane?

    // MARK: - 注入的桥（照 AgentSessionManager 的闭包注入）

    private let presentAnswer: (String) -> Void
    private let presentFailure: (String) -> Void
    private let setNotchOverride: (NotchActivityPhase?) -> Void

    /// 告诉 `CompanionManager`「语音引擎正在被用」—— 它会重置引擎空闲释放的倒计时。
    ///
    /// **这个回调是必须的，不是优化**：`CompanionManager` 的引擎释放任务只在
    /// 「按住说话的按键」那条路上被重置。语音聊天是点鼠标连上的，从不经过那条路，
    /// 所以会话期间**从没有人重置过倒计时** —— 如果用户先前用过对话页面，那个
    /// 倒计时可能正好在语音聊天进行中被触发，`releaseAudioEngineNow()` 会把引擎
    /// 从会话脚下抽掉（引擎停、回声消除关、麦克风死）。用户听到的就是「说着说着
    /// 就哑了」。
    private let noteVoiceSessionActivity: () -> Void

    /// 把共享音频引擎热起来（首次的 VPIO 重配约 2 秒）。同样是注入的闭包，
    /// 因为这个控制器刻意不持有 `CompanionManager`。
    private let warmUpVoiceEngine: () -> Void

    /// **立刻**解开「录制期间自动静音系统扬声器」造成的静音。
    ///
    /// 这是挂断音听不见的真正原因（2026-09-24 查实）：语音聊天是**在本进程里开麦克风**的
    /// （这正是它比 Chrome 版好的地方），于是 `SystemSpeakerMuteCoordinator` 会在会话期间
    /// 把系统输出设备静音。结束录音只是改变了**输入**信号，真正解静音发生在它那条
    /// 500 毫秒轮询里 —— 而挂断音只有 0.35 秒，于是它从头到尾都响在一个**被静音的设备**上。
    ///
    /// 连接音能听见，恰恰因为它响在第一次静音之前；Chrome 时代两个音都能听见，
    /// 因为那时候麦克风在浏览器里，这个协调器根本不会启动。
    private let restoreSpeakerMuteNow: () -> Void

    /// 共享的语音客户端与听写管理器 —— 由 `CompanionManager` 注入。
    /// 它们是**同一份实例**：按住说话、连续监听、语音聊天共用一条音频链路，
    /// 这正是用户观察到的「毫秒级打断」的来源，也是参考项目那条铁律的落地。
    private let speechSynthesizer: BailianTTSClient
    private let dictationManager: BuddyDictationManager

    private lazy var cascadeEngine = CascadeVoiceEngine(
        speechSynthesizer: TTSClientSpeechAdapter(client: speechSynthesizer),
        reportFailure: { [weak self] failureText in
            self?.lastTurnErrorMessage = failureText
        },
        isSpeakingProvider: { [weak speechSynthesizer] in
            speechSynthesizer?.isPlaying ?? false
        },
        // 摄像头那一路：取采集服务保留的最新一帧（它已经按 1fps 节流、并压到 640）。
        // 用闭包而不是把服务直接塞进引擎，是因为引擎不该知道「画面从哪来」——
        // 将来全双工那条路会换成往 WebSocket 上推帧，引擎这一侧不用动。
        cameraFrameProvider: { [weak self] in
            self?.cameraPreview.latestFrameJPEG
        }
    )

    /// 把两个采集服务的变更**转发**给本控制器的订阅者。
    ///
    /// 不转发的话界面不会重绘：预览条监听的是本控制器，而「摄像头起好没有」
    /// 「屏幕有没有新画面」住在 `cameraPreview` / `screenPreview` 这两个**嵌套**
    /// 的 `ObservableObject` 上，它们的 `@Published` 变化不会往外冒。
    /// 实测症状（2026-09-24）：采集 1.3 秒就绪（日志 `采集就绪 总耗时 1326ms`），
    /// 但那一格 30 秒还写着「正在打开摄像头…」—— 不是慢，是没重绘。
    private var captureObservationCancellables: Set<AnyCancellable> = []

    /// 当前会话的回合状态。
    private var isSessionLive = false

    /// 正在流式更新的那行转写（用户说话的实时识别 / 模型的实时回答）。
    /// 用 id 记住它，每次更新是**替换**而不是追加 —— 否则流式会长出几百行。
    private var liveUserTranscriptEntryID: UUID?

    /// 这一轮的错误，展示在页面上（与 Chrome 版 `rolesErrorMessage` 同一个出口）。
    @Published private(set) var lastTurnErrorMessage: String?

    init(presentAnswer: @escaping (String) -> Void,
         presentFailure: @escaping (String) -> Void,
         setNotchOverride: @escaping (NotchActivityPhase?) -> Void,
         noteVoiceSessionActivity: @escaping () -> Void,
         warmUpVoiceEngine: @escaping () -> Void,
         restoreSpeakerMuteNow: @escaping () -> Void,
         speechSynthesizer: BailianTTSClient,
         dictationManager: BuddyDictationManager) {
        self.presentAnswer = presentAnswer
        self.presentFailure = presentFailure
        self.setNotchOverride = setNotchOverride
        self.noteVoiceSessionActivity = noteVoiceSessionActivity
        self.warmUpVoiceEngine = warmUpVoiceEngine
        self.restoreSpeakerMuteNow = restoreSpeakerMuteNow
        self.speechSynthesizer = speechSynthesizer
        self.dictationManager = dictationManager

        reloadRolePresets()
        reloadDeviceSwitches()

        // 见 `captureObservationCancellables`。
        for captureService in [cameraPreview.objectWillChange, screenPreview.objectWillChange] {
            captureService
                .sink { [weak self] _ in self?.objectWillChange.send() }
                .store(in: &captureObservationCancellables)
        }

        NotificationCenter.default.addObserver(
            forName: .clickyVoiceChatRolesDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reloadRolePresets()
            }
        }
    }

    // MARK: - 角色列表（侧栏读这些）

    func refreshRolePresets() {
        reloadRolePresets()
    }

    private func reloadRolePresets() {
        let storedRoles = VoiceChatRoleStore.allRoles()
        rolePresets = storedRoles.map { VoiceChatRolePreset(id: $0.id, name: $0.displayName) }
        rolesErrorMessage = nil

        // 选中项失效（角色被删）时回落到激活角色，再回落到第一个 —— 留一个指向
        // 已删角色的 selectedRoleID 会让侧栏一行都不高亮。
        if let selectedRoleID, storedRoles.contains(where: { $0.id == selectedRoleID }) {
            // 仍然有效，不动。
        } else {
            selectedRoleID = VoiceChatRoleStore.snapshot().activeRoleID ?? storedRoles.first?.id
        }
    }

    /// 侧栏点一行 —— **只选中，不连接**（与 Chrome 版同一个交互模型：
    /// 连接由那一行右边的「连接」按钮发起）。
    func selectRole(_ roleID: String) {
        selectedRoleID = roleID
        reloadDeviceSwitches()
    }

    /// 进语音聊天分区时的预热。
    ///
    /// **这里是「第一次慢、第二次快」的正解所在**（用户 2026-09-24 报的，并且他自己
    /// 指出了方向：「在用户点击语音聊天这个界面的时候，就自动加载这个引擎，而不是
    /// 点击连接才加载」）。
    ///
    /// 之前这个函数被我掏空了，只剩重读角色表 —— 而它原来是整条链路的预热入口
    /// （Chrome 版在这里把服务器和页面提前拉起来，「把用户选角色、移鼠标的那两三秒
    /// 变成预热预算」）。原生版本的冷启动代价换了个地方，但**道理完全一样**：
    /// 第一次连接付的是共享音频引擎的 VPIO 首次重配（仓里实测约 2 秒），
    /// 第二次不用再付 —— 所以只要在**进分区**时把它热起来，用户按下连接时它就是热的。
    ///
    /// `warmUpVoiceEngine` 由 `CompanionManager` 注入（它同时会把引擎空闲释放的
    /// 倒计时重置掉，见 `noteVoiceSessionActivity`）。
    func prepareForConnect() {
        reloadRolePresets()
        warmUpVoiceEngine()
    }

    // MARK: - 设备开关

    /// 当前要用的角色（激活角色优先，其次是侧栏选中的）。
    private var currentRole: VoiceChatRole {
        let stored = VoiceChatRoleStore.snapshot()
        let roleID = activeRoleID ?? selectedRoleID ?? stored.activeRoleID
        if let roleID, let match = stored.roles.first(where: { $0.id == roleID }) {
            return match
        }
        return stored.roles.first ?? VoiceChatRole.makeDefaultRole()
    }

    func reloadDeviceSwitches() {
        // 会话进行中，开关反映的是**这个会话真正开着什么**，不要去读角色的默认值 ——
        // 否则用户手动关掉屏幕后，下一次重读又把它点亮。
        if isSessionLive {
            isCameraEnabled = isCameraEnabled && selectedModeSupportsCamera
            isScreenSharingEnabled = isScreenSharingEnabled && selectedModeSupportsScreenSharing
            return
        }
        let role = currentRole
        isCameraEnabled = role.autoCameraEnabled && selectedModeSupportsCamera
        isScreenSharingEnabled = role.autoScreenEnabled && selectedModeSupportsScreenSharing
    }

    /// 全双工语音是**纯音频**的，送画面过去会被服务端忽略（VoiceWeb 实测
    /// `video_in_enabled=False`）。所以那两个开关要置灰，而不是让用户打开了
    /// 却什么都不发生。
    var selectedModeSupportsScreenSharing: Bool {
        selectedMode.supportsVideoInput
    }

    var selectedModeSupportsCamera: Bool {
        selectedMode.supportsVideoInput
    }

    func setScreenSharingEnabled(_ isEnabled: Bool) {
        guard selectedModeSupportsScreenSharing else { return }
        isScreenSharingEnabled = isEnabled
        // 开关就是采集的真开关：打开才起流，关掉立刻停 —— 屏幕流是一直在编码的，
        // 只改一个布尔值而不停流，等于用户以为关了其实还在录。
        if isEnabled {
            // 打开就自动展开：用户刚开它，当然是想看见它。
            isScreenPreviewCollapsed = false
            Task { await screenPreview.start() }
        } else {
            screenPreview.stop()
            // 关掉就自动折叠（用户明确定的行为）。
            isScreenPreviewCollapsed = true
            if fullScreenPreviewPane == .screen { fullScreenPreviewPane = nil }
        }
        persistDeviceSwitchesIntoRole()
    }

    func setCameraEnabled(_ isEnabled: Bool) {
        guard selectedModeSupportsCamera else { return }
        isCameraEnabled = isEnabled
        if isEnabled {
            isCameraPreviewCollapsed = false
            Task { await cameraPreview.start() }
        } else {
            cameraPreview.stop()
            isCameraPreviewCollapsed = true
            if fullScreenPreviewPane == .camera { fullScreenPreviewPane = nil }
        }
        persistDeviceSwitchesIntoRole()
    }

    /// 点一下折叠 / 再点一下展开 —— 每个框各自独立。
    func togglePreviewCollapsed(_ pane: PreviewPane) {
        switch pane {
        case .camera: isCameraPreviewCollapsed.toggle()
        case .screen: isScreenPreviewCollapsed.toggle()
        }
        // 折叠一个正在全屏的框，先退出全屏（否则那个框既「全屏」又「折叠」，
        // 界面不知道听谁的）。
        if isCollapsed(pane), fullScreenPreviewPane == pane {
            fullScreenPreviewPane = nil
        }
    }

    func isCollapsed(_ pane: PreviewPane) -> Bool {
        switch pane {
        case .camera: return isCameraPreviewCollapsed
        case .screen: return isScreenPreviewCollapsed
        }
    }

    /// 全屏 / 退出全屏。全屏的那个框必然不折叠。
    func toggleFullScreen(_ pane: PreviewPane) {
        if fullScreenPreviewPane == pane {
            fullScreenPreviewPane = nil
        } else {
            fullScreenPreviewPane = pane
            switch pane {
            case .camera: isCameraPreviewCollapsed = false
            case .screen: isScreenPreviewCollapsed = false
            }
        }
    }

    /// 有没有哪个预览框正在全屏。视图据此决定**要不要渲染对话流** ——
    /// 用户对这个形态的原话是「全屏时占据右侧部分的全部窗口，只保留最下面的输入框」，
    /// 所以对话流不是被压扁，而是整个让位。
    var isAnyPreviewFullScreen: Bool { fullScreenPreviewPane != nil }

    /// 把用户在现场改的开关写回角色 —— 用户把它关掉，下次连这个角色就不该又亮起来。
    private func persistDeviceSwitchesIntoRole() {
        var role = currentRole
        role.autoScreenEnabled = isScreenSharingEnabled
        role.autoCameraEnabled = isCameraEnabled
        VoiceChatRoleStore.upsertRole(role)

        // 同时把引擎选择写回角色：用户在页头换了模式，下次连这个角色应当照旧。
        if role.resolvedChatEngine != selectedMode, activeRoleID == nil {
            role.chatEngine = selectedMode.rawValue
            VoiceChatRoleStore.upsertRole(role)
        }
    }

    // MARK: - 连接 / 挂断

    func connectToRole(_ roleID: String) {
        // 已经连在这个角色上就什么都不做（重复点击不该重启会话）。
        if connectionPhase != .idle, activeRoleID == roleID { return }
        if connectionPhase == .connecting { return }

        // 换角色 = 换会话。先把上一个干净地收掉。
        if connectionPhase != .idle {
            disconnectCurrentSession()
        }

        selectedRoleID = roleID
        VoiceChatRoleStore.setActiveRoleID(roleID)

        let role = currentRole
        selectedMode = role.resolvedChatEngine

        activeRoleID = roleID
        activeMode = nil
        connectionPhase = .connecting
        lastTurnErrorMessage = nil

        // 应用这个角色的「连接时自动开启什么」。
        isCameraEnabled = role.autoCameraEnabled && selectedModeSupportsCamera
        isScreenSharingEnabled = role.autoScreenEnabled && selectedModeSupportsScreenSharing

        Task { [weak self] in
            await self?.beginSession()
        }
    }

    /// 起会话：装麦克风、开相位。
    private func beginSession() async {
        let settings = AppSettingsStore.snapshot()
        let sessionStartedAt = Date()

        // **先点火两个采集，再去起音频链路**（2026-09-24 按实测调整）。
        //
        // 原来是反过来的：先 await 起麦克风（里面含 ASR websocket 握手 + 引擎 VPIO
        // 首次重配，实测约 1.8~2 秒），再去起屏幕和摄像头 —— 于是「预览慢」其实是
        // 「被音频链路拖住」。而实测屏幕只要 ~93ms、摄像头 0.2~1.3 秒（冷热双峰），
        // 两者本来与音频毫无关系，没有理由排在它后面。
        //
        // `async let` 在这里的作用是**与音频链路并发**：采集的重活不在主线程上
        // （SCK 走 await、startRunning 在采集队列），所以它们能在 ASR 握手与
        // VPIO 重配的同时进行。
        async let screenPreviewStarted: Void = isScreenSharingEnabled ? screenPreview.start() : ()
        async let cameraPreviewStarted: Void = isCameraEnabled ? cameraPreview.start() : ()

        await dictationManager.startContinuousListening(
            utteranceEndSilenceSeconds: settings.continuousListeningSilenceSendSeconds,
            // 语音聊天的门槛是 **1**，不是对话页面的 4。
            //
            // 「演过谁？」「还在吗？」「几点了？」在连续问答里都是正经问题，可它们
            // 只有 3 个内容字 —— 用 4 字门槛会把它们**静默丢掉**：识别完全正确、
            // 文字也上了屏，然后什么都不发生。用户看到的就是「我问了它没反应」，
            // 而日志里只有一行 print，他那一侧完全看不到（2026-09-24 实测）。
            // **3，不是 1。**
            //
            // 我上一版填 1 是为了救「演过谁？」这类短问题，但那把尺子同时放行了
            // 识别器从我们自己播放声里猜出来的 1~2 字残片（「嗯。」「呃。」）——
            // 残片一旦过了闸就成了「新问题」，而新问题会取消上一轮、切掉正在念的
            // 回答。于是从「偶尔第一次打断」变成「每次都打断」。
            //
            // 3 是两侧都成立的那个数（2026-09-24 实测 + 日志核对）：
            //   · 「演过谁？」「还在吗？」「几点了？」正好都是 3 个内容字 —— 能过；
            //   · 1~2 字的回声残片 —— 挡住。
            // 这不是语气词过滤（那个已按你的要求去掉了），只是**长度**闸门。
            minimumContentCharacters: 3,
            onSpeechDetected: { [weak self] in
                // 「说话就打断」。控制器只做一件事：让引擎停 —— 停播放 + 取消
                // 正在生成的那一轮。**不要在播放中自己开一轮**：用户这一句会走
                // 正常的最终转写，到那时才是新回合，否则会连开两轮。
                self?.cascadeEngine.bargeIn()
            },
            onTranscriptUpdate: { [weak self] interimText in
                self?.publishLiveUserTranscript(interimText)
            },
            onUtteranceFinalized: { [weak self] finalText in
                self?.handleUserUtterance(finalText)
            },
            onUtteranceDropped: { [weak self] _ in
                // 门槛是 1，正常情况下走不到这里；真走到了就把那行气泡撤掉，
                // 绝不让一句「问了没反应」留在屏幕上。
                self?.discardLiveUserTranscript()
            }
        )

        // 起监听失败（权限被拒）时不要把界面留成「连接中」——那会让人一直等。
        guard dictationManager.isContinuousListening else {
            connectionPhase = .idle
            activeRoleID = nil
            presentFailure("语音聊天：拿不到麦克风权限，无法开始对话。")
            return
        }

        isSessionLive = true
        connectionPhase = .connected
        setNotchOverride(.externalChatting)
        // 连接成功的确认音。原来这一声在 Chrome 版的控制器里响，换成原生之后
        // 我漏了这一处 —— 用户 2026-09-24 报「挂断没有声音了」，同一批漏掉的
        // 还有这一声。两个音是配对的反向双音（上行 / 下行），所以必须成对出现，
        // 只补一个会让「连上」和「挂断」听起来不对称。
        SoundEffectPlayer.shared.play(.sessionConnected)

        // 按角色的「连接时自动开启什么」把采集真的起起来。
        // 与 `setScreenSharingEnabled` 走同一条路，所以「角色默认开」和「用户手动开」
        // 之后的行为完全一致，不会出现两套逻辑。
        // 收采集（它们在上面已经点火，这里只是等它们完成）。
        _ = await (screenPreviewStarted, cameraPreviewStarted)
        print(String(format: "💬 [voicechat] 采集就绪 总耗时 %dms（屏幕=%d 摄像头=%d）",
                     Int(Date().timeIntervalSince(sessionStartedAt) * 1000),
                     isScreenSharingEnabled ? 1 : 0,
                     isCameraEnabled ? 1 : 0))

        // 会话说一句「我在用引擎」，见 `noteVoiceSessionActivity` 的注释。
        noteVoiceSessionActivity()

        print("💬 语音聊天：会话已开始（角色「\(currentRole.displayName)」，模式 \(selectedMode.displayName)）")
    }

    func disconnectCurrentSession() {
        guard connectionPhase != .idle || isSessionLive else { return }

        isSessionLive = false
        activeRoleID = nil
        activeMode = nil

        cascadeEngine.stopEverything()
        dictationManager.endContinuousListening()

        // 两个采集都停掉：摄像头会把系统的绿灯一直点着，屏幕流一直在编码 ——
        // 会话都没了还留着它们，用户只会觉得「关了还在录」。
        cameraPreview.stop()
        screenPreview.stop()

        connectionPhase = .idle
        liveUserTranscriptEntryID = nil
        setNotchOverride(nil)

        // 挂断音。它必须在这个**唯一漏斗**里响 —— 刘海右翼的红色挂断、角色行上的
        // 「挂断」、再按一次连接快捷键，三条路都走到这里，所以一处就够。
        // 页面自己掉线不走这里（那不是「你挂断了」），与 Chrome 版同一条规矩。
        // **先解静音，再响** —— 顺序不能反（见 `restoreSpeakerMuteNow`）。
        restoreSpeakerMuteNow()
        SoundEffectPlayer.shared.play(.sessionHungUp)
        print("💬 语音聊天：会话已结束")
    }

    /// 退出 App 时收尾（`CompanionManager` 在 willTerminate 里调）。
    func disconnectOnTermination() {
        guard isSessionLive else { return }
        disconnectCurrentSession()
    }

    // MARK: - 快捷键

    /// 三个 VoiceWeb 模式快捷键中的一次按下。
    ///
    /// 与 Chrome 版同样的开关语义：**同一个模式的快捷键在会话中就是挂断**；
    /// 不同模式则切换过去。原生版本里「模式」是角色的属性，所以切换模式 =
    /// 用同一个角色、换 `chatEngine` 重连。
    func handleShortcutPress(modeIndex: Int) {
        // 按**下标**取模式，而不是按 rawValue 匹配：快捷键的序号（⌃⌥1/2/3）对应的
        // 就是 `allCases` 的第 0/1/2 项，两者的对应关系由 `allCases` 的顺序保证。
        guard VoiceChatEngine.allCases.indices.contains(modeIndex) else { return }
        let pressedMode = VoiceChatEngine.allCases[modeIndex]

        if connectionPhase != .idle {
            // 已在会话中：同一个模式 = 挂断；不同模式 = 换过去。
            if selectedMode == pressedMode, activeMode == pressedMode || activeMode == nil {
                disconnectCurrentSession()
                return
            }
            disconnectCurrentSession()
        }

        // 快捷键起会话 = **用被标为默认的那个角色**（用户 2026-09-24：
        // 「用户使用快捷键触发语音对话时，会自动触发这个默认选项」）。
        // 之前用的是「当前选中的角色」，那是鼠标点出来的状态，与快捷键无关。
        var role = VoiceChatRoleStore.defaultRole()
        role.chatEngine = pressedMode.rawValue
        VoiceChatRoleStore.upsertRole(role)

        selectedMode = pressedMode
        connectToRole(role.id)
        activeMode = pressedMode
    }

    // MARK: - 回合

    /// 用户说完一句（最终转写到了）。
    private func handleUserUtterance(_ finalUtteranceText: String) {
        guard isSessionLive else { return }

        let trimmed = finalUtteranceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // 把实时那行定稿成真正的用户气泡。
        finishLiveUserTranscript(with: trimmed)

        startTurn(utterance: trimmed)
    }

    /// 输入框发出去的一句话 —— 与说话走同一个回合，只是没有转写这一步。
    func sendText(_ rawText: String) {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard connectionPhase == .connected else {
            presentFailure("语音聊天：还没连接，连上之后才能打字发送。")
            return
        }

        // 打字也算一轮新对话：先把正在念的打断。
        cascadeEngine.bargeIn()
        appendTranscriptEntry(isUser: true, text: trimmed)
        startTurn(utterance: trimmed)
    }

    /// 开一轮新对话。**说话与打字共用它** —— 之前两条路各写一遍，导致
    /// 「新回合要新开气泡」这件事只在一条路上做了，那正是气泡顺序错乱的一半原因。
    private func startTurn(utterance: String) {
        // 每一轮都续一次倒计时，长会话才不会中途被释放。
        noteVoiceSessionActivity()

        // **这一轮的回答气泡在回合开始时就建好，并且把它的 id 绑给这一轮的闭包。**
        // 两件事一起解决（2026-09-24 收敛后的结论，两条机制都指向「共用槽」）：
        //
        //  · 气泡在**用户那句话之后**立刻占位。否则从用户说完到第一个字到达
        //    （截图 + 视觉请求要 0.6~4 秒）之间用户再说一句，就会排到它前面，
        //    看起来就是「我说的那句跑到了 AI 上一次回复的上面」。
        //  · id **按轮绑定**，而不是放在控制器上一个共享槽。否则上一轮迟到的分片
        //    认领不到气泡，会被追加到列表末尾 —— 同一个顺序错乱。
        let answerEntryID = UUID()
        transcriptEntries.append(VoiceChatTranscriptEntry(id: answerEntryID, isUser: false, text: ""))

        cascadeEngine.runTurn(
            utterance: utterance,
            role: currentRole,
            callbacks: CascadeTurnCallbacks(
                onAnswerTextChanged: { [weak self] answerSoFar in
                    self?.updateAnswerEntry(answerEntryID, text: answerSoFar)
                },
                onTurnFinished: { [weak self] finalReplyText, spokenText in
                    self?.finishTurn(answerEntryID,
                                     finalReplyText: finalReplyText,
                                     spokenText: spokenText)
                }
            )
        )
    }

    // MARK: - 转写

    private func publishLiveUserTranscript(_ interimText: String) {
        let trimmed = interimText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // 语气词**不再由代码拦**（用户 2026-09-24 改主意：
        // 「我觉得你就不要去拦语气词了，语气词我自己控制就好，如果代码很难实现的话」）。
        // 他说得对——这是他的说话习惯，交给代码判断只会误伤真话。

        if let liveUserTranscriptEntryID,
           let index = transcriptEntries.firstIndex(where: { $0.id == liveUserTranscriptEntryID }) {
            transcriptEntries[index].text = trimmed
        } else {
            let entry = VoiceChatTranscriptEntry(isUser: true, text: trimmed)
            liveUserTranscriptEntryID = entry.id
            transcriptEntries.append(entry)
        }
    }

    /// 把那行还没定稿的实时转写撤掉（用户那句没被采纳时用）。
    private func discardLiveUserTranscript() {
        guard let liveUserTranscriptEntryID else { return }
        transcriptEntries.removeAll { $0.id == liveUserTranscriptEntryID }
        self.liveUserTranscriptEntryID = nil
    }

    private func finishLiveUserTranscript(with finalText: String) {
        if let liveUserTranscriptEntryID,
           let index = transcriptEntries.firstIndex(where: { $0.id == liveUserTranscriptEntryID }) {
            transcriptEntries[index].text = finalText
        } else {
            appendTranscriptEntry(isUser: true, text: finalText)
        }
        liveUserTranscriptEntryID = nil
    }

    /// 把这一轮的回答写进**它自己的**气泡。
    private func updateAnswerEntry(_ answerEntryID: UUID, text: String) {
        guard let index = transcriptEntries.firstIndex(where: { $0.id == answerEntryID }) else { return }
        transcriptEntries[index].text = text
    }

    /// 一轮结束：定稿那一行，并把回答交给光标旁的气泡。
    private func finishTurn(_ answerEntryID: UUID, finalReplyText: String, spokenText: String) {
        let displayText = spokenText.isEmpty
            ? ActionTagParser.speakableTextFromStreamedReply(finalReplyText)
            : spokenText

        updateAnswerEntry(answerEntryID, text: displayText)

        // 与按住说话那条路共用一个出口：`CompanionManager` 注入的 `presentAnswer`
        // 会检查「回答时显示文字」并安排淡化，所以气泡行为两边一致。
        if !displayText.isEmpty {
            presentAnswer(displayText)
        }
    }

    private func appendTranscriptEntry(isUser: Bool, text: String) {
        transcriptEntries.append(VoiceChatTranscriptEntry(isUser: isUser, text: text))
    }
}

// MARK: - 让 BailianTTSClient 满足引擎的协议

/// 适配层：把共享的 `BailianTTSClient` 收窄成引擎需要的那三个动作。
///
/// 单独写一层而不是让 `BailianTTSClient` 直接实现协议，是因为那个类属于**按住说话**
/// 那条路（它有引擎释放、分块、逐句快答一整套状态），不该为了语音聊天多背一个协议
/// 一致性；适配层也让「引擎用了哪几个能力」这件事在文件里一眼看得见。
@MainActor
final class TTSClientSpeechAdapter: VoiceChatSpeechSynthesizing {
    private let client: BailianTTSClient

    init(client: BailianTTSClient) {
        self.client = client
    }

    func beginStreamingSpeech() throws -> VoiceChatStreamingSpeech {
        StreamingSpeechAdapter(session: try client.beginStreamingSpeech())
    }

    func stopSpeaking() {
        client.stopPlayback()
    }

    func bargeIn() {
        client.bargeInWithoutEndingSession()
    }

    func waitUntilPlaybackFinishes() async {
        await client.waitUntilPlaybackFinishes()
    }
}

@MainActor
private final class StreamingSpeechAdapter: VoiceChatStreamingSpeech {
    private let session: BailianTTSClient.StreamingSpeechSession

    init(session: BailianTTSClient.StreamingSpeechSession) {
        self.session = session
    }

    func feed(cumulativeSpeakableText: String) {
        session.feed(cumulativeSpeakableText: cumulativeSpeakableText)
    }

    func finishStreaming() {
        session.finishStreaming()
    }

    func stop() {
        session.stop()
    }
}

// MARK: - 小工具

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
