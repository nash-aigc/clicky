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
/// 三段式的三栏（听/想/说）里改的是哪一栏。顶层声明：设置页与聊天页都要用。
enum PipelineModelSlot {
    case recognition, understanding, expression
}

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

    /// 角色卡片（侧栏列表用）。只挑列表要显示的两样：id 和名字，
    /// 完整字段在 `VoiceChatRole` 里。
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
    /// 当前聊天类型（视频聊天 / 语音聊天）。改动时跟着重算设备开关的可用性 ——
    /// 语音聊天不开画面这条闸就是在这里落到界面上的。
    @Published var selectedChannel: VoiceChatChannel = .voice {
        didSet {
            guard selectedChannel != oldValue else { return }
            reloadDeviceSwitches()
        }
    }
    @Published var selectedMode: VoiceChatEngine = .duplexVoice {
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
    /// 这正是用户观察到的「毫秒级打断」的来源，也是「一条音频链路」那条规则的落地。
    /// 试听要走它（播放引擎只有这一份）。视图的音色面板用。
    let speechSynthesizer: BailianTTSClient
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
            forName: .wannaVoiceChatRolesDidChange,
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
        // 进这一页时就把模式对齐到角色的真实值，别让下拉显示一个连接后会被推翻的值。
        syncSelectedModeFromRole()
    }

    /// 用户在页头换了模式。**必须写回角色，不能只改本地那个字段。**
    ///
    /// 为什么：`connectToRole` 会做 `selectedMode = role.resolvedChatEngine`，
    /// 也就是**从角色里读回来**。改成只赋 `selectedMode`，用户的选择会在按下「连接」
    /// 的那一刻被角色里存的旧值覆盖掉 —— 而这个覆盖是**静默**的：界面上的模式标签
    /// 会变回去，会话照旧用另一种模式跑（2026-09-24 实测：选了「全双工语音」，
    /// 连接后日志里写的是「模式 三段式」）。
    ///
    /// 所以「改模式」只有这一条路：先写角色，再改本地。页头那颗下拉必须走它。
    func selectMode(_ mode: VoiceChatEngine) {
        var role = currentRole
        role.chatEngine = mode.rawValue
        // 预设是**按 (聊天类型, 模式) 分的**：换了模式，原来那条预设不属于这一组了，
        // 所以清掉选择，让 `currentPreset` 回落到新组的默认预设 —— 并立刻把它写进角色
        // （模型、音色、设备默认值都跟着换）。
        role.presetID = nil
        VoiceChatRoleStore.upsertRole(role)
        selectedMode = mode
        applyCurrentPresetToRole()
    }

    /// 切换**聊天类型**（视频聊天 / 语音聊天）。
    ///
    /// 这是用户 2026-09-24 说的那条「分流」：它决定全双工那一行给哪些预设，
    /// 也决定画面能不能开。**语速不受影响**（用户明确要求）。
    func selectChannel(_ channel: VoiceChatChannel) {
        var role = currentRole
        role.chatChannel = channel.rawValue
        // 预设按 (聊天类型, 模式) 分组，换了类型同样要重新落一条。
        role.presetID = nil
        VoiceChatRoleStore.upsertRole(role)
        selectedChannel = channel
        applyCurrentPresetToRole()
    }

    /// 选中一条预设：把它写进角色（模型组合 + 音色 + 设备默认值）。
    func selectPreset(_ preset: VoiceChatPreset) {
        var role = currentRole
        role.presetID = preset.id
        role.chatEngine = preset.engine.rawValue
        VoiceChatRoleStore.upsertRole(role)
        selectedMode = preset.engine
        apply(preset, to: &role)
        VoiceChatRoleStore.upsertRole(role)
        reloadDeviceSwitches()
    }

    /// 把「当前该用哪条预设」写进角色。
    ///
    /// 换聊天类型 / 换模式 / 第一次用都会走到这里：角色上只有 `presetID`，
    /// 而模型组合与音色是**从预设里推出来的** —— 这一步就是把推导结果落盘，
    /// 让引擎那一侧（它读角色）和界面那一侧（它读预设）永远一致。
    private func applyCurrentPresetToRole() {
        var role = currentRole
        if role.presetID == nil {
            role.presetID = currentPreset.id
        }
        apply(currentPreset, to: &role)
        VoiceChatRoleStore.upsertRole(role)
        reloadDeviceSwitches()
    }

    /// 一条预设 → 角色字段。**画面那两个开关只在视频聊天下才写** ——
    /// 语音聊天不允许开画面（`VoiceChatChannel.allowsVideoInputAtAll` 是硬闸），
    /// 写了也会被 `reloadDeviceSwitches` 抹掉，但那会让"角色里存着 true"这种状态
    /// 短暂存在，不如一开始就不写。
    /// 一条预设 → 角色字段。
    ///
    /// 实现是 `VoiceChatPreset.applied(to:channel:)`（**纯函数**）—— 设置页的角色编辑器
    /// 也要做同一件事，而且它改的是**草稿**、不能落盘，所以那件事必须是纯的。
    /// 这里只负责「取当前聊天类型 + 应用到角色」，由调用方决定什么时候落盘。
    private func apply(_ preset: VoiceChatPreset, to role: inout VoiceChatRole) {
        role = preset.applied(to: role, channel: currentChannel)
    }

    /// 侧栏点一行 —— **只选中，不连接**（与 Chrome 版同一个交互模型：
    /// 连接由那一行右边的「连接」按钮发起）。
    func selectRole(_ roleID: String) {
        selectedRoleID = roleID
        syncSelectedModeFromRole()
        syncSelectedChannelFromRole()
        reloadDeviceSwitches()
    }

    /// 让页头那个模式下拉**显示的就是连接时会用的那个**。
    ///
    /// 为什么必须有它：`connectToRole` 里有一句 `selectedMode = role.resolvedChatEngine`
    /// —— 模式是**从角色里读回来**的。而角色里存着上一次选的模式（数据，跨启动、
    /// 跨代码回退都在）。于是「界面显示三段式、实际跑全双工」是可能的：用户按连接，
    /// 引擎被换成角色里存的那个，而下拉框要等到那一刻才跟着变。
    /// 2026-09-24 实测到的「三段式里我说话它不回应」就是这么来的 —— 那时真正跑的
    /// 是全双工，而全双工没有三段式那些实时转写/静音倒计时的提示。
    ///
    /// 同步放在**选角色**时做，显示与将要执行的因此永远一致。
    private func syncSelectedModeFromRole() {
        let roleMode = currentRole.resolvedChatEngine
        if selectedMode != roleMode {
            selectedMode = roleMode
        }
    }

    /// 把聊天类型也从角色里读回来。与 `syncSelectedModeFromRole` 同一条理由：
    /// 分流是**数据**（跨启动、跨角色），界面显示的那个必须就是接下来会执行的那个。
    private func syncSelectedChannelFromRole() {
        let roleChannel = VoiceChatChannel(rawValue: currentRole.chatChannel ?? "") ?? .voice
        if selectedChannel != roleChannel {
            selectedChannel = roleChannel
        }
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

    /// 全双工语音是**纯音频**的，送画面过去会被服务端忽略（实测
    /// `video_in_enabled=False`）。所以那两个开关要置灰，而不是让用户打开了
    /// 却什么都不发生。
    ///
    /// 2026-09-24 起判据从「模式」升级成**能力层**（`capability`）—— 因为它还要管
    /// 两件模式管不了的事：**语音聊天永远不开画面**，以及**所选模型吃不吃图片**
    /// （理解选了全双工语音模型时，三段式也不能开）。界面与引擎读的是同一个
    /// `isVideoInputAllowed`，所以不会出现"按钮亮着但画面没发出去"。
    var selectedModeSupportsScreenSharing: Bool {
        capability.isVideoInputAllowed
    }

    var selectedModeSupportsCamera: Bool {
        capability.isVideoInputAllowed
    }

    /// 画面为什么不能开（给按钮的 `.help` 用）。能开时为 nil。
    var videoInputDisabledReason: String? {
        capability.videoDisabledReason
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
        // 聊天类型也要从角色里读回来（数据跨启动），再把**当前预设**写进角色的
        // 模型/音色/设备字段 —— 连接用的就是这三样，所以它们必须先被摆正。
        syncSelectedChannelFromRole()
        applyCurrentPresetToRole()

        activeRoleID = roleID
        activeMode = nil
        connectionPhase = .connecting
        lastTurnErrorMessage = nil

        // 接一次就把「这一场到底用什么」打全 —— 用户报的症状是「选了模型/音色但连接时
        // 不是那个」，而这是唯一能直接对照的判据。
        let connectingPreset = currentPreset
        let connectingCapability = capability
        print("""
        💬 语音聊天开始连接：聊天类型=\(currentChannel.displayName) 模式=\(selectedMode.displayName) \
        预设=\(connectingPreset.id)（\(connectingPreset.title)）
           识别=\(connectingPreset.recognitionModelID ?? connectingPreset.duplexModelID ?? "-") \
        理解=\(connectingPreset.understandingModelID ?? connectingPreset.duplexModelID ?? "-") \
        表达=\(connectingPreset.expressionModelID ?? connectingPreset.duplexModelID ?? "-")
           音色=\(connectingCapability.effectiveVoiceID)（族=\(connectingCapability.effectiveVoiceEngine.displayName)）\
        画面=\(connectingCapability.isVideoInputAllowed ? "允许" : "不允许")
           说明=\(connectingCapability.notes.isEmpty ? "无" : connectingCapability.notes.joined(separator: "；"))
        """)

        // 应用这个角色的「连接时自动开启什么」。
        isCameraEnabled = role.autoCameraEnabled && selectedModeSupportsCamera
        isScreenSharingEnabled = role.autoScreenEnabled && selectedModeSupportsScreenSharing

        Task { [weak self] in
            await self?.beginSession()
        }
    }

    /// 起会话：装麦克风、开相位。
    /// 全双工语音的引擎。**和三段式互斥**：同一个会话只会起其中一个。
    ///
    /// 做成 lazy 是因为它要拿 `speechSynthesizer.voicePlaybackEngine`（共享播放引擎，
    /// 全 app 唯一那台），而那台要等控制器建好之后才拿得到。
    private lazy var duplexVoiceEngine: DuplexVoiceEngine = {
        DuplexVoiceEngine(
            playbackEngine: speechSynthesizer.voicePlaybackEngine,
            callbacks: DuplexVoiceEngine.Callbacks(
                onUserUtterance: { [weak self] transcript in
                    // **权威最终稿**（`…transcription.completed`）。它到达时，
                    // `speech_stopped` 那条预览气泡通常已经在屏上了 —— 所以这里走
                    // "改写那一条"，**不是再建一条**。见 `finishDuplexUserEntry`。
                    self?.finishDuplexUserEntry(transcript)
                },
                // Chatting 页**不显示增量**：用户 2026-09-25 明确要求「用户的提示词
                // 要一次性展示，不要一个字一个字地显示」，所以逐字的这一个刻意留空。
                //
                // **但"一次性"不等于"等一整轮答完"** —— 那是这次改正的地方：原先
                // 用户气泡只能由下面的 `onUserUtterance`（`…transcription.completed`）
                // 建立，而它在服务端时序里排在回答文字流完之后，于是用户说的话要等
                // AI 答完才出现。改由 `onUserSpeechStopped` 在"你说完了"那一刻整段建立
                // （见官方时序图：`speech_stopped` 紧跟在增量之后、`response.created` 之前）。
                onUserTranscriptUpdate: { _ in },
                onUserSpeechStopped: { [weak self] preview in
                    self?.showDuplexUserEntryOnce(preview)
                },
                onFirstAudioScheduled: { [weak self] in
                    self?.markVoiceChatFullyConnected()
                },
                onBargeIn: { [weak self] in
                    // **这里不解绑气泡。** 两件完全不同的事被混在一起了：
                    //
                    //  · 「停声」—— 本地判定（轮询上行电平）就能做，判错了代价只是
                    //    声音停一下，下一个 delta 就接回去了；
                    //  · 「换一条气泡」—— **不可逆**。解绑之后下一个 delta 会用
                    //    **已累积的全文**新建一条气泡，屏幕上于是出现**两张逐字相同的卡**。
                    //
                    // 实测（2026-09-25，`wanna-尾巴可读性-154136.log`）：一次开场
                    // 问候，全场只有一条回答（`resp_Z5HnM`，47 字）、**没有任何
                    // `speech_started`**，却在第 70 行出现
                    // `🎙️ 全双工会话：本地判定用户开口 —— 就地停声` —— 那条本地判定
                    // 是**误判**（AI 自己的声音进了麦克风），而它把气泡切成了两张。
                    //
                    // 气泡边界交给下面那个**服务端确认**的信号。
                    self?.finalizeDuplexAssistantEntryText()
                    self?.streamingAnswerEntryID = nil
                },
                onUserSpeechStarted: { [weak self] in
                    // **气泡边界在这里，不在本地打断那一条。**
                    //
                    // 判据只有一条：**跟文字累加器对齐**。`DuplexVoiceEngine` 在
                    // `speech_started` 这一支里清 `currentAssistantText`（服务端确认
                    // 用户开口），所以"下一条回答从零开始"这件事**发生在这里**。
                    // 气泡边界跟着它走，卡片装的文字就永远和它自己那一条回答对应。
                    //
                    // 原先边界在 `onBargeIn`（本地电平判定），两者不是一个时刻：
                    // 本地判定会误触发（AI 自己的声音进麦克风），于是它切出一条
                    // **装着全文的重复卡**；而服务端那一条即使也误触发，至少和
                    // 清累加器是同一个动作、同一个时刻，卡片不会和文字分家。
                    self?.duplexAssistantEntryID = nil
                },
                onAssistantTurnStarted: {
                    // Chatting 那边靠 `updateDuplexAssistantEntry` 在第一个 delta 时建气泡，
                    // 顺序天然正确（它只有一个流），所以这里不需要额外动作。
                },
                onAssistantText: { [weak self] cumulativeText in
                    self?.updateDuplexAssistantEntry(cumulativeText)
                },
                onAssistantTurnFinished: { [weak self] in
                    // **不在这里解绑全双工的气泡。**
                    //
                    // 实测（2026-09-25）：服务端把**一条**回答拆成多次
                    // `response.done`（一次实测 3 段），在这里解绑会让每一段各开
                    // 一条新气泡、每段只装几个字 —— 屏幕上就是「一条回答被切成
                    // 好几张碎卡片」，即用户报的「乱码／只显示一部分」。
                    //
                    // 全双工的气泡边界是**用户开口**（新回合），见
                    // `insertDuplexUserEntry`。三段式那条路仍然在这里解绑。
                    //
                    // 解绑之前先把文字定稿写回数组 —— 数组里存的是第一个分片，
                    // 见 `finalizeDuplexAssistantEntryText`。
                    self?.finalizeDuplexAssistantEntryText()
                    self?.streamingAnswerEntryID = nil
                },
                onSessionConfigured: {
                    // Chatting 的「已连接」仍等第一段音频（那边连上就打招呼，
                    // 出声是必然的，用户要的就是"听到声音才算连上"）。
                },
                onFailure: { [weak self] message in
                    guard let self else { return }
                    // 引擎报错（socket 断了 / 服务端拒了）= 这场会话**已经死了**。
                    // 只报错不收尾的话，界面会永远挂在「通话中」，而实际那条
                    // websocket 早就没了 —— 2026-09-25 实测（Ask 语音电话报
                    // `Conversation has no active response` 后状态卡死）。
                    // 走挂断漏斗：麦克风 tap、刘海状态、页面芯片一起归位。
                    if self.isSessionLive {
                        self.disconnectCurrentSession()
                    }
                    self.presentFailure("语音聊天：\(message)")
                }
            )
        )
    }()

    /// **正在流式输出**的那条回答的条目 id（nil = 没有正在流式的回答）。
    /// Chatting 页据此给这条渲染卡片式渲染动画（blur 渐显），历史条目渲染为定稿。
    @Published private(set) var streamingAnswerEntryID: UUID?
    /// 正在流式输出的那条回答的**文字**，单独挂在一个小对象上，不写进
    /// `transcriptEntries`。
    ///
    /// **为什么必须拆出来**：`transcriptEntries` 是控制器上的 `@Published`，而这个
    /// 控制器被**四个**视图观察 —— Chatting 内容列（真正需要文字的）、左侧角色栏
    /// （`HomeSpaceSidebarView:29`）、预览条（`VoiceChatPreviewStrip:19`）、整个面板
    /// 根（`NotchSheetRootView:28`）。逐字去改那个数组，等于**每来一个字就把整个
    /// 展开面板重新求值一次**，其中三个视图根本不需要文字。
    ///
    /// `sample` 实测（2026-09-25，全双工会话、面板展开）：主线程约 **36%** 的工作量
    /// 落在 `NSHostingView.layout()` 里，而那条栈的形状是
    /// `update → updateInheritedView → update → …` **逐层走完整棵树**
    /// （926 → 924 → 918 → 916 → 898 → 796 → 577 → 339 个样本），
    /// 不是某个叶子函数热 —— 特征就是"整棵面板在重算"，不是"某个视图很贵"。
    /// 逐字字符串本身早被本仓库实测排除过（0.12ms/delta，量级不够）。
    ///
    /// 拆开之后，逐字变化的只有这一个对象，而观察它的只有真正要显示文字的那一列。
    /// 这和尾巴那两处是同一个思路：**别让一个粗粒度的东西成为"变化"的单位。**
    @MainActor
    final class VoiceChatStreamingTextStore: ObservableObject {
        @Published private(set) var textByEntryID: [UUID: String] = [:]
        /// 最近一次写入的文字长度 —— 滚动触发用。让视图不必为了"字数变了没有"去
        /// 对整段文字做一次 `String.count`（那是 O(正文长度)，而 body 每次都会跑）。
        @Published private(set) var latestTextCharacterCount = 0

        func setText(_ text: String, forEntryID entryID: UUID) {
            textByEntryID[entryID] = text
            latestTextCharacterCount = text.count
        }

        func text(forEntryID entryID: UUID) -> String? {
            textByEntryID[entryID]
        }

        /// 这一轮定稿了：文字已经写进 `transcriptEntries`，这里的那份可以扔掉。
        func clearText(forEntryID entryID: UUID) {
            textByEntryID[entryID] = nil
        }
    }

    /// 逐字变化的文字住在这里，**不住在 `transcriptEntries` 里** —— 见
    /// `VoiceChatStreamingTextStore` 的说明。视图拿它优先于条目自己那份文字。
    let streamingAnswerTextStore = VoiceChatStreamingTextStore()

    /// 全双工那一轮回答的气泡 id。服务端的回答是流式推来的、没有「回合开始」这个
    /// 明确信号（`response.created` 才是），所以气泡在第一个 delta 到达时建、
    /// 在 `response.done` 时解绑 —— 和打字那条路同一个「一个回合一个气泡」的形状。
    /// 全双工那一轮回答气泡的 id。
    ///
    /// `private(set)` 而不是 `private`：Chatting 页拿它判断"这张卡还在长"，
    /// 而**不能只靠 `streamingAnswerEntryID`** —— 那个槽是三段式与全双工共用的，
    /// 全双工回复播放期间用户往输入框打一句话并回车（`sendText` → `startTurn`）
    /// 会把槽暂时指到那个新条目上，于是正在长的那张卡会被当成"已定稿"折叠一次，
    /// 那一行随即被画两遍、后面的字丢掉。这一个 id 只属于全双工，抢不走。
    /// 见 `VoiceChatSessionView` 里那句 `isStreaming`。
    private(set) var duplexAssistantEntryID: UUID?

    /// 这一场会话是不是全双工起的。**只有它为真时才去碰全双工引擎** ——
    /// `duplexVoiceEngine` 是 lazy 的，而 `disconnectCurrentSession` 三种模式共用，
    /// 在那里无条件调 `stop()` 会在三段式里凭空构造出引擎、并拆掉三段式自己的
    /// 麦克风 tap（2026-09-24 实测：「三段式里我说话它不回应」）。
    private var isDuplexSessionLive = false

    /// 给 Chatting 页用：**当前这条会话是不是全双工起的** —— 它决定卡片要不要做
    /// 「刚到的字模糊半透明 → 清晰」那段进场动画。
    ///
    /// **不能用 `activeMode` 判**：那个属性只在用快捷键（⌃⌥2）起会话时才被赋值
    /// （见 `handleShortcutPress` 末尾），用户点「连接」起会话时它一直是 nil ——
    /// 于是 `activeMode != .duplexVoice` 恒为真、动画一直开着。实测（2026-09-25）：
    /// 改完之后用户点连接进全双工，尾巴**照旧是糊的**，报「没修复」。
    ///
    /// 也不能用 `selectedMode`：那是界面上"选中的那一行"，用户可以在会话进行中
    /// 把高亮切到另一行而不重连。`isDuplexSessionLive` 是**这条会话本身**的事实，
    /// 与谁点的、怎么起的都无关。
    var isDuplexSessionRunning: Bool { isDuplexSessionLive }

    /// 「等第一段音频」的兜底计时器，见 `scheduleConnectionFallbackIfNoAudio`。
    private var connectionFallbackTask: Task<Void, Never>?

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

        // **全双工语音走另一条路，而且不开持续监听。**
        //
        // 两个原因，缺一都不行：
        //  · 这一条会话的回合由**服务端的 VAD** 决定（`turn_detection: server_vad`），
        //    再叠一套客户端的电平 VAD + 识别门槛，等于两个人抢方向盘。
        //  · App 那套连续监听会把麦克风 tap 装到共享引擎上 —— 而全双工也要装。
        //    同一根输入总线只有一个 tap，后装的会把先装的顶掉。
        if selectedMode == .duplexVoice {
            await startDuplexSession(role: currentRole, settings: settings)
            _ = await (screenPreviewStarted, cameraPreviewStarted)
            return
        }

        await dictationManager.startContinuousListening(
            utteranceEndSilenceSeconds: settings.continuousListeningSilenceSendSeconds,
            transcriptionModelIDOverride: currentRole.recognitionModelID,
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
            // **不再逐字显示转写**（用户 2026-09-25：「希望用户的提示词是一次性展示
            // 出来的，不要一个字一个字地显示，而是在用户说完整句话后一次性显示」）。
            // 逐字的实时气泡正是「用户提示词重复两份」的第一份（interim 一份、
            // final 一份）；去掉 interim，用户气泡就只剩 final 一份。
            // 说话期间的反馈由既有的相位动画（Listening）承担。
            onTranscriptUpdate: { _ in },
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
        // 同一条规则：先「连接中」，第一段音频真的播出来才叫「已连接」。
        connectionPhase = .connecting
        setNotchOverride(.externalConnecting)
        // 连接**不**响音效（用户 2026-09-24：「连接时，用户点击连接按钮的声音要去掉，
        // 挂断时的声音保留」）。
        //
        // 这里原来响 `.sessionConnected`，理由是「两个音是配对的反向双音，只响一个
        // 会不对称」——那个理由在 2026-09-24 之前成立，因为它描述的是**旧版面**的
        // 交互：连接要走一遍 Chrome 页面自启动，用户等好几秒才连上，那一声是"好了"
        // 的确认。原生实现之后连接几乎是即时的，同一个音就从"确认"变成了"用户刚点
        // 完按钮就被自己的 App 喊了一声"，而且它响在用户**刚做过的那个动作**之后，
        // 不携带任何新信息。挂断保留：挂断是结束一段会话，那一声是收尾，且它必须
        // 响在 `restoreSpeakerMuteNow()` 之后（见下）。

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

        // 三段式也要「AI 先说第一句」：那一轮的回答播放就是可听的连通证据。
        let greetingSettings = AppSettingsStore.snapshot()
        if greetingSettings.voiceChatGreetsOnConnect {
            let greetingText = greetingSettings.voiceChatGreetingText
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let greeting = greetingText.isEmpty
                ? AppSettings.defaultVoiceChatGreetingText
                : greetingText
            // `announcesUserBubble: false` —— 这句是我们替系统说的，不是用户说的，
            // 在对话流里冒出一个用户气泡会把记录弄脏。
            startTurn(utterance: greeting, announcesUserBubble: false)
            watchForFirstAudioToConfirmConnection()
        } else {
            markVoiceChatFullyConnected()
        }

        print("💬 语音聊天：会话已开始（角色「\(currentRole.displayName)」，模式 \(selectedMode.displayName)）")
    }

    /// 连接真正完成的**唯一**时刻：第一段回答音频开始播。
    ///
    /// 用户 2026-09-24：「刘海屏状态栏的状态应该等同于 AI 发声的那一秒……
    /// 所谓的连接中、连接成功，根本就不是连接成功，它只是假的连接成功。」
    /// 所以刘海切到「Chatting」和 `connectionPhase` 变 `.connected` 都在这里，
    /// 而不在连接调用返回的地方。
    private func markVoiceChatFullyConnected() {
        guard connectionPhase == .connecting else { return }
        connectionPhase = .connected
        setNotchOverride(.externalChatting)
        connectionFallbackTask?.cancel()
        connectionFallbackTask = nil
        noteVoiceSessionActivity()
        print("💬 语音聊天：第一段音频已开始播 —— 状态切到「已连接」")
    }

    /// 兜底：等不到第一段音频也要有个说法，不能把界面永远吊在「连接中」。
    ///
    /// 15 秒是实测留的余量（全双工首轮实测 3.4 秒出声；三段式还要过截图+理解+TTS）。
    /// 到点了就如实算连上，但**把话说在界面上** —— 用户知道「它可能没出声」，
    /// 比一个永远转圈的「连接中」有用。
    private func scheduleConnectionFallbackIfNoAudio() {
        connectionFallbackTask?.cancel()
        connectionFallbackTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard let self, !Task.isCancelled, self.connectionPhase == .connecting else { return }
            self.presentFailure("语音聊天：连接了 15 秒还没听到第一句话，它可能没有真的在服务。可以挂断重连试试。")
            self.markVoiceChatFullyConnected()
        }
    }

    /// 起一条全双工语音会话。失败就如实说明并回到未连接 —— 不留一个「连上了但
    /// 其实没在听」的状态。
    private func startDuplexSession(role: VoiceChatRole, settings: AppSettings) async {
        // 引擎要热着：VPIO 的首次重配 ~2 秒，现在付掉，等用户开口时就没有这个延迟。
        warmUpVoiceEngine()

        // **先亮灯，再握手。**
        //
        // 原先 `setNotchOverride(.externalConnecting)` 在握手**返回之后**才执行，
        // 而握手要等 VPIO 重配（~2 秒）加上 `session.updated`（最长 8 秒）——
        // 也就是用户按下「连接」之后最初那几秒，**刘海左右两侧什么都没有**，
        // 看起来像没反应。用户 2026-09-25：「进入这个界面点击连接时，左右两侧应该
        // 有挂断按钮或连接按钮」。
        //
        // 相位放在这里就没有那个空窗：按下去立刻是「连接中」，接上了转「通话中」
        // （`onFirstAudioScheduled` → `markVoiceChatFullyConnected`），失败由下面的
        // catch 收掉 —— 三种结局都有可见的反馈。
        connectionPhase = .connecting
        setNotchOverride(.externalConnecting)

        // **全模态的图像上行。** 在这之前这条路只发音频 —— 界面把摄像头/屏幕画成可用，
        // 实际一帧都没发给模型，用户看到的是「视频模式下全双工，摄像头、屏幕无法识别」。
        //
        // 两个采集服务已经各自把帧压好了（640 / 512 长边、1fps 节流），这里只是按当前
        // 开着的那几路把取帧闭包交给引擎；关掉的那一路**根本不进列表**，所以引擎不会
        // 白白去取、更不会发一帧用户已经关掉的画面。
        var imageFrameProviders: [() -> Data?] = []
        if isCameraEnabled {
            imageFrameProviders.append { [weak self] in self?.cameraPreview.latestFrameJPEG }
        }
        if isScreenSharingEnabled {
            imageFrameProviders.append { [weak self] in self?.screenPreview.latestFrameJPEG }
        }
        duplexVoiceEngine.imageFrameProviders = imageFrameProviders

        do {
            try await duplexVoiceEngine.start(
                role: role,
                model: role.duplexModelID ?? VoiceCatalog.defaultDuplexModel,
                voiceID: capability.effectiveVoiceID,
                systemPrompt: role.systemPrompt
            )
            isSessionLive = true
            isDuplexSessionLive = true
            noteVoiceSessionActivity()

            // 「连接中」在上面已经亮了（握手前就亮）。这里只补一行日志 ——
            // 真正的「已连接」等第一段音频
            // （`onFirstAudioScheduled` → `markVoiceChatFullyConnected`）。
            //
            // **打印"真正发出去"的那一对，不是角色里存的原始值。**
            //
            // 原先这里打的是 `selectedDuplexModel(for:)`（一个返回默认常量的函数，
            // 忽略角色的 `duplexModelID`）和 `role.duplexVoice`（未经能力层校验的原始
            // 字段）—— 2026-09-25 排查「全双工连不上」时，这一行显示的模型和音色
            // **都跟实际握手用的不一样**，正好把问题盖住。能力层是唯一知道
            // "最终发什么"的地方，日志就该读它。
            print("💬 语音聊天：全双工语音会话已开始（角色「\(role.displayName)」，模型 \(role.duplexModelID ?? VoiceCatalog.defaultDuplexModel)，音色 \(effectiveDuplexVoiceID(for: role))）")

            let greetingSettings = AppSettingsStore.snapshot()
            if greetingSettings.voiceChatGreetsOnConnect {
                let greetingText = greetingSettings.voiceChatGreetingText
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let greeting = greetingText.isEmpty
                    ? AppSettings.defaultVoiceChatGreetingText
                    : greetingText
                try await duplexVoiceEngine.speakGreeting(greeting)
                scheduleConnectionFallbackIfNoAudio()
            } else {
                // 不打招呼就没有「第一段音频」可等 —— 那就不假装，直接算连上。
                markVoiceChatFullyConnected()
            }
        } catch {
            duplexVoiceEngine.stop()
            connectionPhase = .idle
            activeRoleID = nil
            // **失败也要把刘海收干净。**
            //
            // 原先这里什么都不写相位 —— 而 `setNotchOverride(.externalConnecting)`
            // 已经在握手前亮起来了（见上面那段），不清就会**留一个假的「连接中」
            // 挂在刘海上**，与实际状态（什么都没连）不符。收尾口径与
            // `disconnectCurrentSession` 一致：相位回 idle，override 清空。
            setNotchOverride(nil)
            presentFailure("语音聊天：全双工语音起不来 —— \(error.localizedDescription)")
        }
    }

    /// 全双工**最终会用**的音色（能力层校验过的那个，异代会被换成兜底）。
    /// 只给日志用 —— 引擎那一侧读的是同一个值（`capability.effectiveVoiceID`），
    /// 所以日志与实际握手不会分家。
    private func effectiveDuplexVoiceID(for role: VoiceChatRole) -> String {
        VoiceCatalog.capability(
            for: currentPreset,
            channel: currentChannel,
            role: role
        ).effectiveVoiceID
    }

    func disconnectCurrentSession() {
        guard connectionPhase != .idle || isSessionLive else { return }

        isSessionLive = false
        activeRoleID = nil
        activeMode = nil

        cascadeEngine.stopEverything()
        if isDuplexSessionLive {
            duplexVoiceEngine.stop()
            isDuplexSessionLive = false
        }
        duplexAssistantEntryID = nil
        duplexUserEntryID = nil
        streamingAnswerEntryID = nil
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

    /// 三个模式快捷键中的一次按下。
    ///
    /// 与 Chrome 版同样的开关语义：**同一个模式的快捷键在会话中就是挂断**；
    /// 不同模式则切换过去。原生版本里「模式」是角色的属性，所以切换模式 =
    /// 用同一个角色、换 `chatEngine` 重连。
    func handleShortcutPress(modeIndex: Int) {
        // 按**下标**取模式，而不是按 rawValue 匹配：快捷键的序号（⌃⌥1/2/3）对应的
        // 就是 `allCases` 的第 0/1/2 项，两者的对应关系由 `allCases` 的顺序保证。
        guard VoiceChatEngine.pickerCases.indices.contains(modeIndex) else { return }
        let pressedMode = VoiceChatEngine.pickerCases[modeIndex]

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

        // **用户气泡只出现一次**：interim 已不再显示（见上面的 onTranscriptUpdate），
        // 所以这里没有"实时条目"要定稿 —— 直接由 startTurn 追加唯一的用户气泡。
        // （原来先 finishLive 再 startTurn 会追加第二份同文气泡，用户截图里的
        // 「Can you speak some English to me?」×2 就是它。）

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
        // **用户气泡不在这里追加。** `startTurn` 自己会追加（`announcesUserBubble`
        // 默认为真），这里再来一次就是**同一条消息画两个气泡** —— 实测：往 Chatting
        // 打字发一句，屏幕上出现两条一模一样的用户气泡（2026-09-25）。
        // 说话那条路（`handleUserUtterance`）只调 `startTurn`，所以一直是对的；
        // 打字这条路两边都写了一遍。
        startTurn(utterance: trimmed)
    }

    /// 开一轮新对话。**说话与打字共用它** —— 之前两条路各写一遍，导致
    /// 「新回合要新开气泡」这件事只在一条路上做了，那正是气泡顺序错乱的一半原因。
    /// 全双工下用户这句话的气泡落点。
    ///
    /// **为什么不直接追加**：服务端的时序是「先听到用户 → 立刻开始回答 → 文字 delta
    /// 一路推完 → **最后**才补上用户的转写完成事件」（实测一轮 9 个 delta 全到完，
    /// 转写才 completed）。气泡是「谁先到谁先建」，所以回答的气泡先出现，用户的
    /// 转写后到、直接 append 就排到了回答**下面** —— 正是用户报的「AI 回复在我的
    /// 消息气泡之前」。
    ///
    /// 修法只动顺序：转写到达时，如果这一轮的回答气泡已经在屏上，就把用户气泡
    /// **插到它前面**，恢复成时间顺序（先说话，回答是回应）。
    ///
    /// **它只被全双工的回调调用**，三段式那条路一行都不经过这里 —— 上一轮那次
    /// 改动之所以让人以为「拖坏了三段式」，真凶是另外两处跨模式的副作用
    /// （lazy 引擎被凭空构造 + 拆掉三段式自己的麦克风 tap），已经单独修掉了。
    /// 全双工这一轮**用户气泡**的 id：`speech_stopped` 时建的那一条。
    ///
    /// 存在的唯一理由是**防止同一条消息出现两次**：用户说完话时先按预览建一条，
    /// 服务端的权威最终稿随后到达 —— 没有这个 id，后者会再建一条，屏幕上就是
    /// `[用户][用户][回答]`。这个缺陷本项目**修过一次**（见下面 `insertDuplexUserEntry`
    /// 上方那段注记：用户截图里的「Can you speak some English to me?」×2）。
    private var duplexUserEntryID: UUID?

    /// 用户说完话的那一刻建气泡（一次性，不逐字），并记住它。
    private func showDuplexUserEntryOnce(_ preview: String) {
        let entryID = UUID()
        if let assistantEntryID = duplexAssistantEntryID,
           let assistantIndex = transcriptEntries.firstIndex(where: { $0.id == assistantEntryID }) {
            transcriptEntries.insert(
                VoiceChatTranscriptEntry(id: entryID, isUser: true, text: preview),
                at: assistantIndex
            )
        } else {
            transcriptEntries.append(VoiceChatTranscriptEntry(id: entryID, isUser: true, text: preview))
        }
        duplexUserEntryID = entryID
    }

    /// 权威最终稿到达：**改写**预览那条，而不是另建一条；没有预览那条（增量没来）
    /// 时才按老路建。
    private func finishDuplexUserEntry(_ finalTranscript: String) {
        if let userEntryID = duplexUserEntryID,
           let entryIndex = transcriptEntries.firstIndex(where: { $0.id == userEntryID }) {
            transcriptEntries[entryIndex] = VoiceChatTranscriptEntry(
                id: userEntryID,
                isUser: true,
                text: finalTranscript
            )
            duplexUserEntryID = nil
            return
        }
        insertDuplexUserEntry(finalTranscript)
    }

    private func insertDuplexUserEntry(_ transcript: String) {
        if let assistantEntryID = duplexAssistantEntryID,
           let assistantIndex = transcriptEntries.firstIndex(where: { $0.id == assistantEntryID }) {
            transcriptEntries.insert(
                VoiceChatTranscriptEntry(id: UUID(), isUser: true, text: transcript),
                at: assistantIndex
            )
        } else {
            appendTranscriptEntry(isUser: true, text: transcript)
        }
        // **用户开口 = 一对问答的边界**：从这里起解绑，下一条回答会开新气泡。
        //
        // 解绑必须放在**插入之后** —— 上面那段要靠这个 id 找到"本轮回答的气泡"，
        // 把用户这句插到它前面，恢复时间顺序。
        //
        // 为什么边界在这里而不是 `response.done`：服务端会把**一条**回答拆成多次
        // `response.created`/`response.done`（实测 3 段），按 done 解绑就会把一条
        // 回答切成几张碎卡片（用户报的乱码）。见 `onAssistantTurnFinished` 的注释。
        duplexAssistantEntryID = nil
    }

    // MARK: - 页头四栏（识别 / 理解 / 表达 / 音色）

    /// 这三栏写的是**当前角色**的独立配置（用户 2026-09-24：「每一个角色都应该可以
    /// 独立设置屏幕、摄像头、识别、理解、表达、音色，还有模式……用户在最终的面板上
    /// 切换不同的角色，他的整个配置参数就自动切换」）。nil = 跟随默认。

    var currentRecognitionModelID: String {
        currentRole.recognitionModelID ?? VoiceCatalog.defaultDuplexModel
    }
    var currentUnderstandingModelID: String {
        // 默认是 deepseek 而不是清单第一行：理解真正在用的是 HTTP 图文那条路，
        // 全双工/多模态当理解还没接线 —— 这一栏显示的必须是引擎实际在用的模型。
        currentRole.understandingModelID ?? VoiceCatalog.defaultUnderstandingModel
    }
    var currentExpressionModelID: String {
        currentRole.expressionModelID ?? VoiceCatalog.defaultExpressionModel
    }
    /// 音色跟着模式走：三段式用合成音色，全模态用它自己的内置音色。
    var currentExpressionVoiceID: String {
        selectedMode == .omni ? currentRole.omniVoice : currentRole.ttsVoice
    }
    /// 全双工语音那一类的音色（实时模型的龙安系），单独记录在角色上。
    var currentDuplexVoiceID: String {
        currentRole.duplexVoice
    }
    /// 全双工语音那一类当前选的**模型**（决定音色表）。nil = 3.0 Flash。
    var currentDuplexModelID: String {
        currentRole.duplexModelID ?? VoiceCatalog.defaultDuplexModel
    }

    // MARK: - 聊天类型 / 预设 / 依赖真相

    /// 当前聊天类型。角色里没写过就按**语音聊天**读 —— 它是更保守的一侧
    /// （不允许开画面），不会一上来就把用户的摄像头打开。
    var currentChannel: VoiceChatChannel {
        VoiceChatChannel(rawValue: currentRole.chatChannel ?? "") ?? .voice
    }

    /// 当前生效的预设。
    ///
    /// 三步回落，每一步都要**属于当前的 (聊天类型, 模式)**：
    ///   1. 角色里存的那个 id —— 存在且属于这一组才用；
    ///   2. 否则用这一组的默认预设（`isDefaultPreset`，每组有且只有一个）；
    ///   3. 再取不到（这一组一条预设都没有）就取这一组的第一条。
    ///
    /// 回落的必要性：聊天类型或模式一换，原来那条预设就不属于新组了，
    /// 而角色里的 id 还在 —— 不回落就会显示一条别的组的预设。
    var currentPreset: VoiceChatPreset {
        let channel = currentChannel
        let engine = selectedMode
        let presets = VoiceChatPresetStore.resolvedPresets(for: channel, engine: engine)
        if let storedID = currentRole.presetID,
           let match = presets.first(where: { $0.id == storedID }) {
            return match
        }
        return presets.first(where: \.isDefaultPreset) ?? presets.first
            ?? VoiceChatPreset.builtIn[0]
    }

    /// 当前预设下的**依赖真相** —— 界面与引擎读的同一份。
    var capability: VoiceCatalog.VoiceChatCapability {
        VoiceCatalog.capability(for: currentPreset, channel: currentChannel, role: currentRole)
    }

    /// 某个模式的预设清单（界面按行取用）。
    func presets(for engine: VoiceChatEngine) -> [VoiceChatPreset] {
        VoiceChatPresetStore.resolvedPresets(for: currentChannel, engine: engine)
    }

    /// 某一行**当前会用的**预设：选中的那一行就是当前预设；未选中的行取该组的默认预设
    /// （界面据此显示那一行的模型，但用户一眼能看出它没被选中 —— 模式按钮上没有对勾）。
    func preset(for engine: VoiceChatEngine) -> VoiceChatPreset {
        if engine == selectedMode { return currentPreset }
        let presets = VoiceChatPresetStore.resolvedPresets(for: currentChannel, engine: engine)
        return presets.first(where: \.isDefaultPreset) ?? presets.first ?? currentPreset
    }

    /// 某一行当前的**依赖真相**。
    ///
    /// 界面用 `capability(for:)` 取每一行的音色族与画面可用性；引擎用 `capability`
    /// 取当前那一行 —— 同一个 `VoiceCatalog.capability(...)` 实现，两处不会分家。
    func capability(for engine: VoiceChatEngine) -> VoiceCatalog.VoiceChatCapability {
        VoiceCatalog.capability(for: preset(for: engine), channel: currentChannel, role: currentRole)
    }

    /// 某一行**真正会用的**音色（能力层算出来的，已校验）。
    ///
    /// 音色面板右上角那个绿色标题显示的就是它 —— 不是角色里存的那个值。这是
    /// 「选了没生效」最直接的照妖镜：显示的和引擎用的是同一个数。
    func effectiveVoiceID(for engine: VoiceChatEngine) -> String {
        capability(for: engine).effectiveVoiceID
    }

    /// 某一行音色表所依据的**模型 id**（决定用哪张表）。
    func voiceTableModelID(for engine: VoiceChatEngine) -> String {
        let preset = preset(for: engine)
        switch engine {
        case .duplexVoice, .omni:
            return preset.duplexModelID ?? VoiceCatalog.defaultDuplexModel
        case .threeStage:
            return preset.expressionModelID ?? VoiceCatalog.defaultExpressionModel
        }
    }

    /// 用某个音色替换**某一行**的音色（写进该族的角色字段）。
    func setVoice(_ voiceID: String, for engine: VoiceChatEngine) {
        var role = currentRole
        switch engine {
        case .threeStage: role.ttsVoice = voiceID
        case .omni: role.omniVoice = voiceID
        case .duplexVoice: role.duplexVoice = voiceID
        }
        VoiceChatRoleStore.upsertRole(role)
    }

    func setDuplexModel(_ modelID: String) {
        var role = currentRole
        role.duplexModelID = modelID
        VoiceChatRoleStore.upsertRole(role)
    }
    /// 全模态模式当前选的**模型**（一个模型包办识别/理解/表达）。nil = 3.8 Omni Flash。
    var currentOmniModelID: String {
        currentRole.omniModelID ?? VoiceCatalog.defaultOmniModel
    }
    func setOmniModel(_ modelID: String) {
        var role = currentRole
        role.omniModelID = modelID
        VoiceChatRoleStore.upsertRole(role)
    }

    func setPipelineModel(_ slot: PipelineModelSlot, modelID: String) {
        var role = currentRole
        switch slot {
        case .recognition: role.recognitionModelID = modelID
        case .understanding: role.understandingModelID = modelID
        case .expression: role.expressionModelID = modelID
        }
        VoiceChatRoleStore.upsertRole(role)
        // 识别模型变了立刻反映到「下一次连接」：把全局配置里那份也同步过去 ——
        // 对话页面读的是全局配置，两处不一致会让同一个模型名在两个页面表现不同。
        if slot == .recognition {
            var configuration = ModelConfigurationStore.snapshot()
            if let providerIndex = configuration.providers.firstIndex(
                where: { $0.id == configuration.transcriptionProviderID }
            ) {
                configuration.providers[providerIndex].transcriptionModelID = modelID
                try? ModelConfigurationStore.save(configuration)
            }
        }
    }

    func setExpressionVoice(_ voiceID: String) {
        var role = currentRole
        if selectedMode == .omni {
            role.omniVoice = voiceID
        } else {
            role.ttsVoice = voiceID
        }
        VoiceChatRoleStore.upsertRole(role)
    }

    /// 记录全双工语音那一类的音色。**只记录，不接合成** —— 三段式的实时合成
    /// 接线在下一批；现在动它只会让 TTS 拿到一个它不认的音色（411）。
    func setDuplexVoice(_ voiceID: String) {
        var role = currentRole
        role.duplexVoice = voiceID
        VoiceChatRoleStore.upsertRole(role)
    }

    /// 全双工那一轮的助手气泡：第一次 delta 建气泡，之后原地更新。
    ///
    /// ## 为什么这里必须同时设 `streamingAnswerEntryID`
    ///
    /// 卡片靠它判断"这段文字**还在长**"，而那一个判断决定了两件完全不同的事：
    ///
    /// ```swift
    /// paragraphs(liveLineCount:)          // AnswerCardView：实时区那几行不折叠
    /// if isStreaming { … .blur(2.6).opacity(0.2) … }
    /// ```
    ///
    /// `streamingAnswerEntryID` 原先**只在三段式那条路（`startTurn`）被赋值**，而全双工
    /// 根本走不到那里 —— 于是全双工的卡片拿到的是 `isStreaming == false`，走"已定稿"
    /// 分支：`settlingFinalLine: true` 会把**还在长的那一行也折叠一遍，就在它刚出生的
    /// 那一刻**，而 `foldedLineCount` 只增不减 —— 那一行后来长出来的字**永远不会再被
    /// 折叠、也没有任何地方画它**。
    ///
    /// 表现就是用户报的「全双工回复乱码」：一条 304 字的回答只显示出 23 个字，每行
    /// 只剩开头一两个 —— 实测（用他自己那次通话的 149 个 delta 重放卡片的算法）输出
    /// 与截图逐字符一致，碎片之间的间距正好是一行（33 字符），而且碎片可能是半个词
    /// （「动力」只剩下「力」），因为折叠抓到的是跨过行边界那个 delta 的尾巴。
    ///
    /// 修法只是**把这一页缺的那一个赋值补上** —— 文字、累积、换行全都是好的。
    /// 顺带也把模糊书写尾巴还给了这一页：`liveLineView` 原本同样被这个 false 关在门外。
    private func updateDuplexAssistantEntry(_ cumulativeText: String) {
        if let entryID = duplexAssistantEntryID {
            updateAnswerEntry(entryID, text: cumulativeText)
            streamingAnswerEntryID = entryID
        } else {
            let entryID = UUID()
            transcriptEntries.append(VoiceChatTranscriptEntry(id: entryID, isUser: false, text: cumulativeText))
            duplexAssistantEntryID = entryID
            streamingAnswerEntryID = entryID
        }
    }

    /// 全双工这一轮的**文字定稿**：把 store 里最新那份写回数组元素，再扔掉 store 那份。
    ///
    /// **全双工必须显式做这一步，不能像三段式那样交给 `finishTurn`**：全双工没有
    /// `onTurnFinished` 这个出口（它的气泡边界是"用户开口"，见 `onAssistantTurnFinished`），
    /// 而它建气泡那一帧写进数组的是**第一个 delta**，不是最新那份 —— 所以只扔不写回
    /// 的话，卡片会当场跳回第一个分片。
    ///
    /// 反过来不扔只是留下一条多余的文字，不会显示错任何东西（视图是"store 优先、
    /// 数组兜底"）。所以这里宁可漏调，不可写反顺序。
    private func finalizeDuplexAssistantEntryText() {
        guard let entryID = duplexAssistantEntryID ?? streamingAnswerEntryID,
              let latestText = streamingAnswerTextStore.text(forEntryID: entryID)
        else { return }
        if let index = transcriptEntries.firstIndex(where: { $0.id == entryID }) {
            transcriptEntries[index].text = latestText
        }
        streamingAnswerTextStore.clearText(forEntryID: entryID)
    }

    /// 三段式下「第一段音频」= 合成器真的开始播了。它是计算属性、不是 @Published，
    /// 所以这里轮询（100ms，最长 15 秒），而不是订阅。
    private func watchForFirstAudioToConfirmConnection() {
        scheduleConnectionFallbackIfNoAudio()
        Task { @MainActor [weak self] in
            guard let self else { return }
            let deadline = Date().addingTimeInterval(15)
            while Date() < deadline {
                if self.speechSynthesizer.isPlaying {
                    self.markVoiceChatFullyConnected()
                    return
                }
                if self.connectionPhase != .connecting { return }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func startTurn(utterance: String, announcesUserBubble: Bool = true) {
        // 每一轮都续一次倒计时，长会话才不会中途被释放。
        noteVoiceSessionActivity()

        // 用户气泡按需画：开场那句打招呼是我们**替系统**说的，不是用户说的 ——
        // 在对话流里放一个用户气泡会把记录弄脏（用户会以为自己在记录里说过那句话）。
        if announcesUserBubble {
            transcriptEntries.append(VoiceChatTranscriptEntry(isUser: true, text: utterance))
        }

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
        streamingAnswerEntryID = answerEntryID

        cascadeEngine.runTurn(
            utterance: utterance,
            role: currentRole,
            preset: currentPreset,
            channel: currentChannel,
            callbacks: CascadeTurnCallbacks(
                onAnswerTextChanged: { [weak self] answerSoFar in
                    self?.updateAnswerEntry(answerEntryID, text: answerSoFar)
                },
                onAnswerTextComplete: { [weak self] in
                    self?.finishAnswerTextStreaming(answerEntryID)
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
    ///
    /// **写的是 `streamingAnswerTextStore`，不是 `transcriptEntries` 里的那个元素** ——
    /// 后者是控制器上的 `@Published`，而四个视图在观察这个控制器，逐字去改它等于
    /// 每来一个字就把整个展开面板重算一次。详见 `VoiceChatStreamingTextStore`。
    ///
    /// 定稿由 `finishTurn` 负责：那时才把最终文字写进数组元素，并清掉这里那份。
    private func updateAnswerEntry(_ answerEntryID: UUID, text: String) {
        streamingAnswerTextStore.setText(text, forEntryID: answerEntryID)
    }

    /// 这一轮的文字到此为止了 —— 正常收完，或中途失败。
    ///
    /// **卡片的模糊尾巴只该在文字还在来的时候存在**，而 `streamingAnswerEntryID`
    /// 原先要到 `finishTurn` 才清，那要等「说」那条路把排队的音频全部放完：文字
    /// 早就完整地摆在屏幕上，最后 5 个字却还是模糊 + 20% 透明度，直到朗读走到
    /// 某个分段间隙才淡出来。
    ///
    /// 更糟的是**失败那一轮根本清不掉**（`CascadeVoiceEngine` 的 `catch` 不调
    /// `onTurnFinished`），于是最后 5 个字会一直糊在那里 —— 用户报的「最后那几个字
    /// 渲染不出来」永久化的那一档就是它。所以这个出口由引擎在**两个地方**都报：
    /// 流正常收完，以及出错。
    ///
    /// 只清「还指着这一轮」的那个槽：取消时 `startTurn` 已经把槽指到新的一轮上，
    /// 旧一轮迟到的这个回调不能把新一轮的尾巴一并收掉。
    private func finishAnswerTextStreaming(_ answerEntryID: UUID) {
        guard streamingAnswerEntryID == answerEntryID else { return }
        streamingAnswerEntryID = nil
    }

    /// 一轮结束：定稿那一行，并把回答交给光标旁的气泡。
    private func finishTurn(_ answerEntryID: UUID, finalReplyText: String, spokenText: String) {
        streamingAnswerEntryID = nil
        let displayText = spokenText.isEmpty
            ? ActionTagParser.speakableTextFromStreamedReply(finalReplyText)
            : spokenText

        // **定稿写进数组元素，并把流式那份扔掉。**
        //
        // 整轮只有这一次写 `transcriptEntries`（每字一次的那个在
        // `updateAnswerEntry` 里，写的是 `streamingAnswerTextStore`）。扔的顺序不能
        // 反：视图取文字是"store 优先、数组兜底"，先扔再写数组会有一帧读到空的。
        if let index = transcriptEntries.firstIndex(where: { $0.id == answerEntryID }) {
            transcriptEntries[index].text = displayText
        }
        streamingAnswerTextStore.clearText(forEntryID: answerEntryID)

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

    func beginStreamingSpeech(voiceID: String?) throws -> VoiceChatStreamingSpeech {
        StreamingSpeechAdapter(session: try client.beginStreamingSpeech(voiceOverride: voiceID))
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
