import SwiftUI
import Combine

/// 设置 → 语音聊天 → 音色查看。
///
/// 用户的要求原话：「在语音聊天这个位置上，三段式、全双工语音和全双工全模态
/// 都应该支持音色查看，包括系统音色和用户的自定义音色……点击音色之后，右侧分别
/// 显示三个按钮：全双工全模态、三段式和全双工语音」—— 也就是**先选模式，再看
/// 那个模式能用的音色**。
///
/// 为什么必须是「先选模式」而不是一个总列表：三个模式的音色是**互不相交的三套**，
/// 而且填错不是少一个选项，是**整条 `session.update` 被服务端拒掉**（voice、
/// instructions、tools 一起失效）。所以这一页的每一行都能保证「在当前模式下可用」，
/// 判断全部来自 `VoiceCatalog`，不在这里另写一遍。
///
/// 「使用」写进的是**当前活动角色**的那一条音色字段
/// （`ttsVoice` / `omniVoice` / `duplexVoice`）—— 和 VoiceWeb 一样，音色是
/// 「角色 × 模式」的属性，不是全局一个。
struct VoiceCatalogSettingsView: View {

    let companionManager: CompanionManager

    /// 三段式下面再分两类：系统音色 / 克隆音色。
    ///
    /// 只有三段式有这两类，这是**能力**决定的而不是排版选择：克隆音色是
    /// 声音复刻产出的，它是**绑定合成模型**的（官方：3.1 克隆的只能 3.1 用），
    /// 而全双工 / 全模态那两条路的声音由实时模型自己发，认的是它们各自那套内置
    /// 音色表，克隆音色用不了。所以那两页只有一个列表，这里才有分类。
    private enum VoiceSource: String, CaseIterable, Identifiable {
        case system
        case custom
        /// **克隆工作台**：选参考音频 → 试听 → 上传克隆 → 看结果。
        /// 和上面那一栏的区别是：`custom` 是「已经存在的克隆音色」，这一栏是
        /// 「造一个新的出来」（用户 2026-09-24 要求把两者分开）。
        case clone

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .system: return "系统音色"
            case .custom: return "克隆音色"
            case .clone: return "声音克隆"
            }
        }
    }

    @State private var selectedEngine: VoiceChatEngine = .threeStage
    @State private var voiceSource: VoiceSource = .system
    @State private var searchText = ""
    /// 正在合成/播放的那一行。**只影响这一行** —— 见 `preview`。
    @State private var previewingVoiceID: String?

    /// 试听的代次。每发起一次 +1，回调只在代次没变时才收尾 —— 这样「点 A 试听、
    /// 还没合成完就点了 B」不会让 A 的收尾把 B 的状态抹掉（仓库里动画那几处
    /// 用的同一个办法）。
    @State private var previewGeneration = 0

    /// 等着第二次确认的那一行删除。见 `customVoiceRow` 里的两步删除。
    @State private var pendingDeleteVoiceID: String?

    /// 正在改名的克隆音色 id，以及输入框里的草稿。
    @State private var editingNicknameVoiceID: String?
    @State private var nicknameDraft = ""

    @State private var statusMessage: String?
    @State private var errorMessage: String?
    @State private var activeRole: VoiceChatRole?

    /// 该账号下的克隆音色。**懒加载**：只有切到「克隆音色」那一栏才去问云端，
    /// 因为它是一次网络往返，而大多数人打开这一页只是想挑个系统音色。
    @State private var customVoices: [CustomVoice] = []
    @State private var isLoadingCustomVoices = false
    @State private var customVoicesErrorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            modeSelector
            Divider().overlay(DS.Colors.borderSubtle)
            searchRow
            Divider().overlay(DS.Colors.borderSubtle)
            voiceList
            statusBar
        }
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: .clickyVoiceChatRolesDidChange)) { _ in
            reload()
        }
        // 收藏存在 `VoiceLibraryStore` 里，它变了要重画 —— 收藏要立刻排到最前面。
        .onReceive(NotificationCenter.default.publisher(for: .clickyVoiceLibraryChanged)) { _ in
            reload()
        }
        .onDisappear {
            companionManager.stopVoicePreview()
        }
    }

    // MARK: - 状态

    private func reload() {
        activeRole = VoiceChatRoleStore.activeRole()
    }

    /// 当前模式下这个角色选的音色。
    private var roleVoiceID: String {
        guard let activeRole else { return "" }
        switch selectedEngine {
        case .threeStage: return activeRole.ttsVoice
        case .omni: return activeRole.omniVoice
        case .duplexVoice: return activeRole.duplexVoice
        }
    }

    /// 当前模式用哪个模型 —— 它**决定可用音色**，所以界面上要看得见。
    ///
    /// 三段式是用户配的合成模型；另外两个模式的实时模型在 Phase 2/3 才会成为
    /// 设置项，现在取 `VoiceCatalog` 里那份有出处的默认值。
    private var currentModel: String {
        switch selectedEngine {
        case .threeStage:
            return ModelConfigurationStore.snapshot().status(of: .speech).resolvedRole?.modelID
                ?? BailianConfiguration.Models.textToSpeech
        case .omni:
            return VoiceCatalog.defaultOmniModel
        case .duplexVoice:
            return VoiceCatalog.defaultDuplexModel
        }
    }

    /// 只有三段式分「系统音色 / 克隆音色」两类 —— 见 `VoiceSource` 的注释。
    private var showsVoiceSourceTabs: Bool {
        selectedEngine == .threeStage
    }

    /// 当前这一栏要不要走克隆音色列表。
    private var isShowingCustomVoices: Bool {
        showsVoiceSourceTabs && voiceSource == .custom
    }

    /// 当前这一栏是不是克隆工作台。
    private var isShowingCloneWorkflow: Bool {
        showsVoiceSourceTabs && voiceSource == .clone
    }

    /// 当前模式 + 模型下可选的系统音色，按收藏排过序。
    private var visibleVoices: [VoiceOption] {
        let voices = VoiceCatalog.systemVoices(for: selectedEngine, model: currentModel)
        let ordered = VoiceLibraryStore.orderedByFavourites(voices, engine: selectedEngine)
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return ordered }
        return ordered.filter { voice in
            voice.displayName.lowercased().contains(query)
                || voice.id.lowercased().contains(query)
                || voice.note.lowercased().contains(query)
        }
    }

    /// 这个音色不能试听的原因；nil = 可以试听。
    ///
    /// 目前只有一个特例，而且它是官方能力边界而不是我们的 bug：`Tina` 不在
    /// Qwen-TTS 的音色表里，全模态要用它试听就得让实时模型自己发声。VoiceWeb
    /// 的做法是把 ▶ 置灰并写明原因，这里照做 —— 置灰比"点了没反应"诚实。
    private func previewUnavailableReason(for voice: VoiceOption) -> String? {
        if selectedEngine == .omni, voice.id == "Tina" {
            return "Tina 不在 Qwen-TTS 音色表里，无法试听，可直接选用"
        }
        return nil
    }

    // MARK: - 模式选择

    private var modeSelector: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 三个模式按钮：**放大、左对齐、上下那两行说明都删掉**
            // （用户 2026-09-24：「把三段式/全双工语音/全双工全模态的按钮变大一点，
            // 并删掉上面和下面的说明文字。按钮要大一点，靠左对齐」）。
            HStack(spacing: 8) {
                ForEach(VoiceChatEngine.pickerCases) { engine in
                    modeButton(engine)
                }
                Spacer(minLength: 0)
            }

            // 第二层两个按钮 + 「当前模型」挤在**同一行**，模型用绿色
            // （用户：「把下边的「当前模型」放在「系统音色」和「个人音色」两个按钮的
            // 同一行，用绿色显示，让用户能关注到」）。
            //
            // 它值得被关注是因为它**决定可用音色**：全双工换成 3.1 Plus 会多出 8 个
            // 音色，全模态换模型族会让 Cherry/Kai 失效。以前它是一行灰色小字，
            // 没人会去看。
            HStack(spacing: 8) {
                if showsVoiceSourceTabs {
                    ForEach(VoiceSource.allCases) { source in
                        sourceButton(source)
                    }
                }
                Spacer(minLength: 8)
                Text("当前模型：\(currentModel)")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(DS.Colors.success)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    private func modeButton(_ engine: VoiceChatEngine) -> some View {
        let isSelected = engine == selectedEngine
        return Button {
            selectedEngine = engine
            // 切模式时回到系统音色那一栏：另外两个模式根本没有克隆音色，
            // 留着上一次的选择会让人以为这一页空了。
            voiceSource = .system
            statusMessage = nil
            errorMessage = nil
        } label: {
            Text(engine.displayName)
                .font(.system(size: 13.5, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? DS.Colors.textOnAccent : DS.Colors.textSecondary)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(isSelected ? DS.Colors.accent : DS.Colors.surface3)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(isSelected ? Color.clear : DS.Colors.borderStrong, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    /// 第二层的两个小按钮。样式比模式按钮轻一档：它们是在**已经选定的模式里**
    /// 再分栏，和上面那一排不是同一级。
    private func sourceButton(_ source: VoiceSource) -> some View {
        let isSelected = source == voiceSource
        return Button {
            voiceSource = source
            statusMessage = nil
            errorMessage = nil
            if source == .custom { loadCustomVoicesIfNeeded() }
        } label: {
            Text(source.displayName)
                .font(.system(size: 12.5, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? DS.Colors.textPrimary : DS.Colors.textSecondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isSelected ? DS.Colors.surface4 : DS.Colors.surface3)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(isSelected ? DS.Colors.borderStrong : DS.Colors.borderSubtle, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    private func loadCustomVoicesIfNeeded() {
        loadCustomVoices(forceReload: false)
    }

    private func loadCustomVoices(forceReload: Bool) {
        guard !isLoadingCustomVoices else { return }
        isLoadingCustomVoices = true
        customVoicesErrorMessage = nil
        Task { @MainActor in
            defer { isLoadingCustomVoices = false }
            do {
                customVoices = try await CustomVoiceLibraryClient.listCustomVoices()
            } catch {
                customVoicesErrorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - 搜索

    private var searchRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(DS.Colors.textTertiary)

            // 输入框必须看得见边框（用户 2026-09-24：「搜索框要弄得明显一点，加一个
            // 边框线，现在看不到搜索框到底在哪里」）。原来它只有一行图标 + 占位文字
            // 浮在面板底色上，而面板底色和这一带的底色是同一个值 —— 于是输入框在
            // 视觉上不存在。现在给一块比底色浅的底 + 一道边框。
            TextField("搜索音色名称 / 编号 / 说明…", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(DS.Colors.textPrimary)

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(DS.Colors.textTertiary)
                }
                .buttonStyle(.plain)
            }

            // 刷新：**从账号里重新拉一遍已存在的音色**（用户 2026-09-24：
            // 「用户会实时修改，所以要刷新到保证是最新的模型才可以」）。
            // 用户可能在手机/控制台/别处刚克隆完一个，本地列表不会自己知道。
            //
            // 刷新**不会动本地记的名字**：昵称是按 `voice_id` 存在本地文件里的
            // （`VoiceLibraryStore.customVoiceNicknames`），刷新只是把云端那份
            // 列表换掉，id 没变名字就还在 —— 用户感觉不到中间发生过刷新。
            Button {
                loadCustomVoices(forceReload: true)
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11))
                    .foregroundStyle(DS.Colors.textSecondary)
                    .frame(width: 22, height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(DS.Colors.surface4)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(DS.Colors.borderStrong, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .help(isShowingCustomVoices ? "从账号重新拉一遍克隆音色" : "从账号重新拉一遍克隆音色（先切到「克隆音色」）")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(DS.Colors.surface3)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(DS.Colors.borderStrong, lineWidth: 1)
        )
        .padding(.horizontal, 20)
        .padding(.vertical, 9)
    }

    // MARK: - 列表

    @ViewBuilder
    private var voiceList: some View {
        if isShowingCloneWorkflow {
            // 克隆工作台自己会滚、自己带页头（含右上角「完成克隆」），
            // 所以这里不套 ScrollView。
            VoiceCloneWorkflowView(
                companionManager: companionManager,
                onFinished: {
                    // 「完成克隆」= 跳回「克隆音色」并**重新拉一遍**，
                    // 用户立刻能看到刚建好的那批。
                    voiceSource = .custom
                    statusMessage = "已回到「克隆音色」，列表已刷新。"
                    loadCustomVoices(forceReload: true)
                }
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if isShowingCustomVoices {
                        customVoiceSection
                    } else {
                        systemVoiceSection
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var systemVoiceSection: some View {
        if let warning = invalidCurrentVoiceWarning {
            warningRow(warning)
        }
        ForEach(visibleVoices) { voice in
            voiceRow(voice)
            Divider().overlay(DS.Colors.borderSubtle)
        }
        if visibleVoices.isEmpty {
            emptyListHint("没有匹配的音色。")
        }
    }

    @ViewBuilder
    private var customVoiceSection: some View {
        if let customVoicesErrorMessage {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(DS.Colors.destructiveText)
                Text(customVoicesErrorMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(DS.Colors.destructiveText)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("重试") { loadCustomVoicesIfNeeded() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DS.Colors.accentText)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
        } else if isLoadingCustomVoices, customVoices.isEmpty {
            emptyListHint("正在读取克隆音色…")
        } else if customVoices.isEmpty {
            emptyListHint("这个账号下还没有克隆音色。克隆的入口会在下一步接进来（要先把参考音频传成云端地址）。")
        } else {
            ForEach(filteredCustomVoices) { customVoice in
                customVoiceRow(customVoice)
                Divider().overlay(DS.Colors.borderSubtle)
            }
            if filteredCustomVoices.isEmpty {
                emptyListHint("没有匹配的克隆音色。")
            }
        }
    }

    private func emptyListHint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(DS.Colors.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(20)
    }

    /// 角色身上那个音色**在当前模式下不合法**时的提示。
    ///
    /// 这一条是防「连不上」的：跨家族音色会让整条 `session.update` 被拒，而且
    /// 报错不指向音色。与其等连接失败了再查，不如在这里就说清楚并给出一个能用的。
    private var invalidCurrentVoiceWarning: String? {
        let voiceID = roleVoiceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !voiceID.isEmpty else { return nil }
        guard !VoiceCatalog.isSelectable(voiceID, for: selectedEngine, model: currentModel) else { return nil }
        let fallback = VoiceCatalog.fallbackVoice(for: selectedEngine, model: currentModel)
        return "当前角色在「\(selectedEngine.displayName)」下选的音色「\(voiceID)」不在这个模式的音色表里，"
            + "连接会被服务端拒绝。建议改用「\(fallback)」。"
    }

    private func warningRow(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(DS.Colors.warning)
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(DS.Colors.warning)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("改用") {
                applyVoice(VoiceCatalog.fallbackVoice(for: selectedEngine, model: currentModel))
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(DS.Colors.accentText)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(DS.Colors.warning.opacity(0.10))
    }

    /// 克隆音色那一栏的搜索：昵称 / 编号 / 目标模型。
    ///
    /// 和系统音色搜的不是同一组字段（克隆音色没有「语言」「描述」，系统音色没有
    /// 昵称），所以是两份过滤而不是共用一个 —— VoiceWeb 也是这么分的
    /// （切换栏时会把搜索词清掉）。
    private var filteredCustomVoices: [CustomVoice] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let ordered = VoiceLibraryStore.orderedByFavourites(customVoices, engine: .threeStage) { $0.id }
        guard !query.isEmpty else { return ordered }
        return ordered.filter { customVoice in
            let displayName = VoiceLibraryStore.displayName(
                forCustomVoiceID: customVoice.id,
                cloudProvidedName: ""
            )
            return displayName.lowercased().contains(query)
                || customVoice.id.lowercased().contains(query)
                || customVoice.targetModel.lowercased().contains(query)
        }
    }

    private func customVoiceRow(_ customVoice: CustomVoice) -> some View {
        let isCurrent = customVoice.id == roleVoiceID
        let favouriteKey = VoiceLibraryStore.favouriteKey(for: customVoice.id, engine: .threeStage)
        let isFavourite = VoiceLibraryStore.isFavourite(key: favouriteKey)
        // 用户起的昵称优先；没起过就显示 id —— 云端不保存备注，见 `VoiceLibraryStore`。
        let displayName = VoiceLibraryStore.displayName(
            forCustomVoiceID: customVoice.id,
            cloudProvidedName: ""
        )
        // 克隆音色**绑定合成模型**：和目标模型不一致的那条路一定失败，所以在行上
        // 就把话说清楚，而不是等用户点了「使用」再报一个 411。
        let isUsableWithCurrentModel = customVoice.targetModel.isEmpty
            || customVoice.targetModel == currentModel

        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                if editingNicknameVoiceID == customVoice.id {
                    // 行内改名：输入框 + 保存/取消，回车即保存，Esc 取消。
                    HStack(spacing: 6) {
                        TextField("给这个音色起个名字（留空 = 清掉）", text: $nicknameDraft)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12.5))
                            .foregroundStyle(DS.Colors.textPrimary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(DS.Colors.surface3)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .stroke(DS.Colors.accent.opacity(0.6), lineWidth: 1)
                            )
                            .frame(maxWidth: 320)
                            .onSubmit { commitNicknameEdit() }

                        rowActionButton("保存", isPrimary: true) { commitNicknameEdit() }
                        rowActionButton("取消") {
                            editingNicknameVoiceID = nil
                        }
                    }
                } else {
                HStack(spacing: 6) {
                    Text(displayName)
                        .font(.system(size: 12.5, weight: isCurrent ? .semibold : .regular))
                        .foregroundStyle(DS.Colors.textPrimary)
                        // 双击名字也能改名 —— 用户提的两种入口都做上，因为这一行
                        // 的主要问题就是「看不出哪个是哪个」，改名的路越短越好。
                        .onTapGesture(count: 2) { beginEditingNickname(customVoice) }
                        .help("双击可以给它起个名字")
                    if isCurrent {
                        Text("当前")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(DS.Colors.success)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(DS.Colors.success.opacity(0.14))
                            )
                    }
                    if !customVoice.isReady {
                        Text(customVoice.status)
                            .font(.system(size: 10))
                            .foregroundStyle(DS.Colors.warning)
                    }
                }
                Text(customVoice.id)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(DS.Colors.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(customVoice.targetModel.isEmpty
                     ? "（云端没给目标模型）"
                     : "合成模型：\(customVoice.targetModel)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(isUsableWithCurrentModel ? DS.Colors.textTertiary : DS.Colors.warning)
                if !isUsableWithCurrentModel {
                    Text("只能用在 \(customVoice.targetModel) 上，当前合成模型是 \(currentModel) —— 直接选用会失败。")
                        .font(.system(size: 10))
                        .foregroundStyle(DS.Colors.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                }
            }

            Spacer(minLength: 8)

            rowActionButton(
                previewingVoiceID == customVoice.id ? "试听中…" : "▶ 试听",
                isEnabled: customVoice.isReady && previewingVoiceID != customVoice.id
            ) { previewCustomVoice(customVoice) }

            rowActionButton("使用", isPrimary: true, isEnabled: !isCurrent) { applyCustomVoice(customVoice) }

            // 「删除」夹在「使用」和「收藏」中间（用户指定的位置）。
            //
            // **两步，不能一步**（用户 2026-09-24：「编辑按钮就应该变成一个删除
            // 按钮。而且必须是二次删除：点击按钮之后，出现一个红色背景的按钮变成
            // 一个确认，点击两次才能删除」）。所以第一次点只是把它变成红色确认态，
            // 再点一次才真的去云端删。改名不再靠这颗按钮 —— 双击标题即可。
            if pendingDeleteVoiceID == customVoice.id {
                Button {
                    deleteCustomVoice(customVoice)
                } label: {
                    Text("确认删除")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(DS.Colors.destructiveText)
                        )
                }
                .buttonStyle(.plain)
                .help("再点一次就真的删掉（云端也会删）")

                rowActionButton("取消") { pendingDeleteVoiceID = nil }
            } else {
                rowActionButton("删除") { pendingDeleteVoiceID = customVoice.id }
            }

            starButton(isFavourite: isFavourite) { toggleFavourite(key: favouriteKey, displayName: displayName) }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 9)
    }

    /// 克隆音色的试听：**用它的目标模型合成**，不是用当前配置的模型。
    ///
    /// 这一条是音色绑定的直接后果：克隆是为某个模型做的，拿别的模型去合成它，
    /// 服务端会用一句 `Engine error [411]` 拒绝 —— 既不提音色也不提模型。
    private func previewCustomVoice(_ customVoice: CustomVoice) {
        let displayName = VoiceLibraryStore.displayName(
            forCustomVoiceID: customVoice.id,
            cloudProvidedName: ""
        )
        startPreview(voiceID: customVoice.id, displayName: displayName) { _ in
            let appSettings = AppSettingsStore.snapshot()
            // 传的是这个克隆**自己的**目标模型，不是当前配置的模型 —— 见
            // `previewCustomVoice` 上面那条关于音色绑定的说明。
            return try await VoicePreviewService.previewAudioData(
                engine: .threeStage,
                voice: customVoice.id,
                model: customVoice.targetModel.isEmpty ? self.currentModel : customVoice.targetModel,
                speechRate: appSettings.speechPlaybackRate,
                speechVolumePercent: appSettings.speechPlaybackVolumePercent,
                styleInstruction: ""
            )
        }
    }

    private func voiceRow(_ voice: VoiceOption) -> some View {
        let isCurrent = voice.id == roleVoiceID
        let favouriteKey = VoiceLibraryStore.favouriteKey(for: voice.id, engine: selectedEngine)
        let isFavourite = VoiceLibraryStore.isFavourite(key: favouriteKey)
        let previewUnavailable = previewUnavailableReason(for: voice)

        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(voice.displayName)
                        .font(.system(size: 12.5, weight: isCurrent ? .semibold : .regular))
                        .foregroundStyle(DS.Colors.textPrimary)
                    if isCurrent {
                        Text("当前")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(DS.Colors.success)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(DS.Colors.success.opacity(0.14))
                            )
                    }
                    if !voice.gender.isEmpty {
                        Text(voice.gender)
                            .font(.system(size: 10))
                            .foregroundStyle(DS.Colors.textTertiary)
                    }
                }
                HStack(spacing: 6) {
                    Text(voice.id)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(DS.Colors.textTertiary)
                    if !voice.note.isEmpty {
                        Text(voice.note)
                            .font(.system(size: 10.5))
                            .foregroundStyle(DS.Colors.textTertiary)
                            .lineLimit(1)
                    }
                }
                if let previewUnavailable {
                    Text(previewUnavailable)
                        .font(.system(size: 10))
                        .foregroundStyle(DS.Colors.textTertiary)
                }
            }

            Spacer(minLength: 8)

            // **只有正在试听的那一行**变成「试听中…」并禁用 —— 别的行照常可点
            // （用户 2026-09-24：「用户点击哪一个按钮，哪一个按钮就是合成中的状态，
            // 其他按钮应该不受影响，现在其他按钮也受影响了」）。
            rowActionButton(
                previewingVoiceID == voice.id ? "试听中…" : "▶ 试听",
                isEnabled: previewUnavailable == nil && previewingVoiceID != voice.id
            ) { preview(voice, previewUnavailableReason: previewUnavailable) }

            rowActionButton("使用", isPrimary: true, isEnabled: !isCurrent) { applyVoice(voice.id) }

            starButton(isFavourite: isFavourite) { toggleFavourite(voice, key: favouriteKey) }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
    }

    // MARK: - 底部状态

    private var statusBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider().overlay(DS.Colors.borderSubtle)
            HStack(spacing: 6) {
                if let errorMessage {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(DS.Colors.destructiveText)
                    Text(errorMessage)
                        .font(.system(size: 11))
                        .foregroundStyle(DS.Colors.destructiveText)
                        .lineLimit(2)
                } else if let statusMessage {
                    Text(statusMessage)
                        .font(.system(size: 11))
                        .foregroundStyle(DS.Colors.textSecondary)
                        .lineLimit(2)
                } else {
                    Text(activeRoleSummary)
                        .font(.system(size: 11))
                        .foregroundStyle(DS.Colors.textTertiary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 9)
        }
    }

    private var activeRoleSummary: String {
        guard let activeRole else { return "还没有角色，先去「角色」页建一个。" }
        let voiceID = roleVoiceID.trimmingCharacters(in: .whitespacesAndNewlines)
        let voiceDescription = voiceID.isEmpty ? "（未设置）" : voiceID
        return "「使用」写入当前角色「\(activeRole.displayName)」的\(selectedEngine.displayName)音色。现在是：\(voiceDescription)"
    }

    // MARK: - 行内按钮

    /// 音色行右侧那颗小按钮的统一样子。
    ///
    /// 用户 2026-09-24：「下面的音色、系统音色、各种音色的按钮也要做得大一点，
    /// 加一些边框线，现在看不到边框线，而且按钮太小，有时点击点不到」。
    /// 所以这里有底、有边框、有内边距 —— 三样都是为了让**可点区域看得见**，
    /// 而不是装饰：之前它们只有 22×14 的文字，点起来靠运气。
    private func rowActionButton(
        _ title: String,
        isPrimary: Bool = false,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: isPrimary ? .semibold : .regular))
                .foregroundStyle(
                    isEnabled
                        ? (isPrimary ? DS.Colors.accentText : DS.Colors.textSecondary)
                        : DS.Colors.textTertiary
                )
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(DS.Colors.surface3)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(isPrimary && isEnabled ? DS.Colors.accent.opacity(0.6) : DS.Colors.borderStrong,
                                lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }

    private func starButton(isFavourite: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: isFavourite ? "star.fill" : "star")
                .font(.system(size: 12))
                .foregroundStyle(isFavourite ? DS.Colors.warning : DS.Colors.textTertiary)
                .frame(width: 30, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(DS.Colors.surface3)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(DS.Colors.borderStrong, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .help(isFavourite ? "取消收藏" : "收藏（收藏的音色排在前面）")
    }

    // MARK: - 克隆音色改名

    /// 开始给这个克隆音色改名。草稿预填当前显示名。
    ///
    /// 为什么必须有这个入口：克隆音色的 id 是
    /// `qwen-audio-3.1-tts-flash-lyf-c81770bd…` 这种东西，一排排全是代码，
    /// 用户**分不清哪个是哪个**（用户 2026-09-24：「每一个「使用」按钮和「收藏」
    /// 按钮中间添加一个「编辑」按钮，点击编辑按钮之后可以对名字进行备注」）。
    /// 云端不保存备注，所以名字只能存在本地 —— 见 `VoiceLibraryStore`。
    private func beginEditingNickname(_ customVoice: CustomVoice) {
        editingNicknameVoiceID = customVoice.id
        // 预填**昵称**，没有昵称就留空 —— 而不是预填那个 id。
        //
        // 预填 id 看着像是「方便」，实际是个坑（2026-09-24 实测踩到）：id 有
        // 60+ 字符，而昵称上限是 20，于是用户点开「编辑」直接按保存，就会把那个
        // id 的前 20 个字符**当成昵称写进存储** —— 界面上看不出任何变化，但文件
        // 里从此多了一条没有意义的记录。留空则「不改就按保存」等于没改。
        nicknameDraft = VoiceLibraryStore.nickname(forCustomVoiceID: customVoice.id) ?? ""
    }

    private func commitNicknameEdit() {
        guard let voiceID = editingNicknameVoiceID else { return }
        do {
            try VoiceLibraryStore.setNickname(nicknameDraft, forCustomVoiceID: voiceID)
            // 名字为空 = 清掉备注，回到显示 id。
            let trimmed = nicknameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            statusMessage = trimmed.isEmpty
                ? "已清掉这个名字，这一行回到显示编号。"
                : "已把这一行命名为「\(trimmed)」。"
            errorMessage = nil
        } catch {
            errorMessage = "名字没写进磁盘：\(error.localizedDescription)"
        }
        editingNicknameVoiceID = nil
    }

    // MARK: - 动作

    /// 「使用」—— 写进活动角色的对应音色字段。
    ///
    /// 只写音色、**不写模型**：VoiceWeb 在克隆音色上会连模型一起写，因为克隆音色
    /// 绑定 `target_model`。系统音色没有这个约束，而模型在这里也不是这一页的职责
    /// （三段式的合成模型在「说」那一页、实时模型在 Phase 2/3 的设置里）。
    private func applyVoice(_ voiceID: String) {
        var role = VoiceChatRoleStore.activeRole()
        switch selectedEngine {
        case .threeStage: role.ttsVoice = voiceID
        case .omni: role.omniVoice = voiceID
        case .duplexVoice: role.duplexVoice = voiceID
        }
        VoiceChatRoleStore.upsertRole(role)
        reload()
        errorMessage = nil
        statusMessage = "已把「\(voiceID)」设为「\(selectedEngine.displayName)」的音色（角色：\(role.displayName)）。"
    }

    /// 克隆音色的「使用」：**先校验音色与模型的绑定**。
    ///
    /// 克隆是为某个合成模型做的，拿它配另一个模型，服务端会用 `Engine error [411]`
    /// 拒绝 —— 那句话既不提音色也不提模型，用户只会看到「选了音色但不会说话」。
    /// 所以这里拦住并说清楚，而不是把不合法的值写进角色。
    private func applyCustomVoice(_ customVoice: CustomVoice) {
        if !customVoice.targetModel.isEmpty, customVoice.targetModel != currentModel {
            errorMessage = "「\(customVoice.id)」是为 \(customVoice.targetModel) 克隆的，"
                + "这个音色只能用在那个模型上；当前合成模型是 \(currentModel)。"
                + "要改合成模型请去设置 → 模型。"
            return
        }
        applyVoice(customVoice.id)
    }

    /// 删掉一个克隆音色 —— **本地列表和云端一起**。
    ///
    /// 用户的原话是「用户可以去删除这个音色，重新克隆一个全新的」，所以只从列表里
    /// 拿掉不算数：那个音色还占着账号里的一条记录、合成时还能被选到。
    /// 云端删成功之后才动本地，失败就把错误显示出来、**不假装删掉了**。
    private func deleteCustomVoice(_ customVoice: CustomVoice) {
        pendingDeleteVoiceID = nil
        statusMessage = "正在删除「\(customVoice.id)」…"
        errorMessage = nil

        Task { @MainActor in
            do {
                try await CustomVoiceLibraryClient.deleteVoice(voiceID: customVoice.id)
                // 名字是按 id 存的，音色没了它也就没用了，一起清掉，
                // 免得以后万一有同 id 的残留顶着别人的名字。
                try? VoiceLibraryStore.setNickname("", forCustomVoiceID: customVoice.id)
                customVoices.removeAll { $0.id == customVoice.id }
                statusMessage = "已删除「\(customVoice.id)」（云端也删了）。"
            } catch {
                errorMessage = error.localizedDescription
                statusMessage = nil
            }
        }
    }

    private func toggleFavourite(_ voice: VoiceOption, key: String) {
        toggleFavourite(key: key, displayName: voice.displayName)
    }

    /// 收藏。系统音色和克隆音色共用这一条 —— 两者的区别只在 key 的命名空间上，
    /// 而那件事由 `VoiceLibraryStore.favouriteKey` 管，不在这里再分一次。
    private func toggleFavourite(key: String, displayName: String) {
        do {
            let isNowFavourite = try VoiceLibraryStore.toggleFavourite(
                key: key,
                displayName: displayName
            )
            errorMessage = nil
            statusMessage = isNowFavourite
                ? "已收藏「\(displayName)」，它现在排在列表最前面。"
                : "已取消收藏「\(displayName)」。"
        } catch {
            errorMessage = "收藏没写进磁盘：\(error.localizedDescription)"
        }
    }

    private func preview(_ voice: VoiceOption, previewUnavailableReason: String?) {
        guard previewUnavailableReason == nil else {
            errorMessage = previewUnavailableReason
            return
        }
        startPreview(voiceID: voice.id, displayName: voice.displayName) { model in
            let appSettings = AppSettingsStore.snapshot()
            return try await VoicePreviewService.previewAudioData(
                engine: self.selectedEngine,
                voice: voice.id,
                model: model,
                speechRate: appSettings.speechPlaybackRate,
                speechVolumePercent: appSettings.speechPlaybackVolumePercent,
                styleInstruction: ""
            )
        }
    }

    /// 试听的公共部分：代次、状态、播放、收尾。
    ///
    /// 抽出来是因为系统音色和克隆音色的**合成参数不一样**（克隆要用它自己的
    /// 目标模型），但「谁能点、状态怎么走、失败怎么显示」必须一致 —— 两处各写
    /// 一遍就会漂。
    private func startPreview(
        voiceID: String,
        displayName: String,
        synthesize: @escaping (String) async throws -> Data
    ) {
        // 换一个音色试听 = 停掉上一段，而不是让两段叠在一起。
        companionManager.stopVoicePreview()
        previewGeneration += 1
        let generation = previewGeneration
        previewingVoiceID = voiceID
        errorMessage = nil
        statusMessage = "正在合成「\(displayName)」…"

        Task { @MainActor in
            defer {
                if previewGeneration == generation { previewingVoiceID = nil }
            }
            do {
                let audioData = try await synthesize(currentModel)
                try await companionManager.playVoicePreview(wavData: audioData)
                guard previewGeneration == generation else { return }
                statusMessage = "正在试听「\(displayName)」。"
            } catch {
                guard previewGeneration == generation else { return }
                errorMessage = error.localizedDescription
                statusMessage = nil
            }
        }
    }
}
