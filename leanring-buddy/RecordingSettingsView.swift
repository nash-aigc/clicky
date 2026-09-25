import AppKit
import SwiftUI

/// 设置页「录音」。
///
/// 放在 `GeneralSettingsView` 的扩展里而不是它自己的一个 View，是因为这一页
/// 读写的就是 `AppSettings`、用的也是同一套 `SettingsRow` / `SettingsCard` ——
/// 和「操作」「看与截图」那几页没有任何结构差别，另起一个 View 只会多一层
/// 用不上的间接。
///
/// 这一页里唯一不是偏好的两块：
/// - **历史录音**是浏览已有数据（和「归档」页同类），
/// - **录音状态**是一行实时读数。
///
/// ## API Key 存在哪（用户明确要求过）
///
/// 直接写进 App 自己的设置文件：`~/Library/Application Support/Clicky/AppSettings.json`
/// （`0600`，**在仓库之外**）。不建 env 文件、不建仓库内配置文件 —— 所以它不可能
/// 被推到 GitHub。这一页是它唯一的入口。
extension GeneralSettingsView {

    var recordingPage: some View {
        Group {
            SettingsPageHeader(
                title: "录音",
                subtitle: "按住快捷键开始录，再按一次结束。音频和文字都是边录边落盘的，中途断电也能在本地看到已经录到的部分。"
            )

            // **录音历史放在最顶上**（用户 2026-09-25：「最顶部是录音历史」），
            // 其余设置参数依次排在它下面。
            recordingHistorySection
            recordingShortcutSection
            recordingServiceSection
            recordingStorageSection
            recordingPolishSection
        }
    }

    // MARK: - 触发

    @ViewBuilder
    private var recordingShortcutSection: some View {
        SettingsGroupLabel("触发")
        SettingsCard {
            SettingsRow(
                label: "录音快捷键",
                description: recorderIsConfigured
                    ? "按下开始录，再按一次结束。录完之后音频、文字都落在下面的文件夹里。"
                    : "这一项**没有出厂预设** —— ⌃⌥1–3 给了语音聊天、⌃⌥4 给了释放引擎，再塞一个进去就会互相抢。所以请你点右边录一条自己的组合。"
            ) {
                ShortcutRecorderButton(
                    fallbackBinding: nil,
                    recordedShortcut: generalSettingsViewModel.binding(\.recordingShortcut)
                )
            }

            SettingsCardRowDivider()

            SettingsRow(
                label: "停止后放进剪贴板",
                description: "录完把全文写进系统剪贴板，并且**不会被还原** —— 你可以随时再去粘一次。"
            ) {
                SettingsSwitch(isOn: generalSettingsViewModel.binding(\.recordingCopiesToClipboard))
            }

            SettingsCardRowDivider()

            SettingsRow(
                label: "停止后自动粘贴",
                description: "录完自动切回你当时用的那个 App，在光标处按一次 ⌘V。需要辅助功能权限（和「操作」页要的是同一个）。"
            ) {
                SettingsSwitch(isOn: generalSettingsViewModel.binding(\.recordingPastesAfterStop))
            }
        }
    }

    /// 有没有录过快捷键。没录的话功能根本不会启动，所以上面那行要把话说清楚 ——
    /// 一个「设置好了但按了没反应」的功能比没有这个功能更糟。
    private var recorderIsConfigured: Bool {
        generalSettingsViewModel.draftSettings.recordingShortcut != nil
    }

    // MARK: - 识别服务

    @ViewBuilder
    private var recordingServiceSection: some View {
        SettingsGroupLabel("识别服务（豆包流式语音识别）")
        SettingsCard {
            SettingsRow(
                label: "API Key",
                description: "火山引擎控制台里的 API Key。只写进本机的设置文件（仓库之外），不会同步、不会被提交。"
            ) {
                SecureField("粘贴到这里", text: generalSettingsViewModel.binding(\.recordingServiceAPIKey))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
            }

            SettingsCardRowDivider()

            SettingsRow(
                label: "档位",
                description: generalSettingsViewModel.draftSettings.recordingResourceID.explanation
            ) {
                SettingsMenuPicker(
                    selection: generalSettingsViewModel.binding(\.recordingResourceID),
                    options: VolcengineASRResource.allCases.map {
                        SettingsPickerOption(label: $0.displayName, value: $0)
                    }
                )
            }

            SettingsCardRowDivider()

            SettingsRow(
                label: "自定义资源 ID",
                description: "填了就覆盖上面的档位。控制台里自建模型的 ID 不在那四个档位里，就填这里。"
            ) {
                TextField("留空则用上面的档位", text: generalSettingsViewModel.binding(\.recordingCustomResourceID))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
            }

            SettingsCardRowDivider()

            SettingsRow(
                label: "识别语言",
                description: "直接作为 language 发给服务端。留空让服务自己判断。"
            ) {
                TextField("zh-CN", text: generalSettingsViewModel.binding(\.recordingLanguage))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 160)
            }
        }

        SettingsCard {
            SettingsTextEditorRow(
                label: "热词",
                description: "人名、地名、项目代号 —— 逗号或换行分隔。识别时会被优先考虑，但不保证百分之百。",
                text: generalSettingsViewModel.binding(\.recordingHotwords),
                placeholder: "张三，Clicky，火山引擎"
            )
        }
    }

    // MARK: - 落盘与长会话

    @ViewBuilder
    private var recordingStorageSection: some View {
        SettingsGroupLabel("长会话")
        SettingsCard {
            SettingsRow(
                label: "保存位置",
                description: recordingFolderDescription
            ) {
                Button("选择…") { chooseRecordingFolder() }
                    .buttonStyle(.bordered)
            }

            SettingsCardRowDivider()

            SettingsRow(
                label: "断线自动重连",
                description: "连接掉了就自动接上继续录，音频从头到尾不受影响。关掉的话断了就停，已录的部分照常保住。"
            ) {
                SettingsSwitch(isOn: generalSettingsViewModel.binding(\.recordingAutoReconnects))
            }

            SettingsCardRowDivider()

            SettingsRow(
                label: "音频保留",
                description: "录音文件很占空间（3 小时一场约 345MB），所以默认只留最近一天。**到期的只是音频文件，历史记录和文字都还在** —— 列表里那一条依然能看到、能复制。"
            ) {
                SettingsMenuPicker(
                    selection: generalSettingsViewModel.binding(\.recordingAudioRetentionDays),
                    options: [
                        SettingsPickerOption(label: "保留 1 天", value: 1),
                        SettingsPickerOption(label: "保留 3 天", value: 3),
                        SettingsPickerOption(label: "保留 7 天", value: 7),
                        SettingsPickerOption(label: "保留 30 天", value: 30),
                        SettingsPickerOption(label: "永久保存", value: 0),
                    ]
                )
            }
            SettingsCardRowDivider()
            SettingsRow(
                label: "文字保留",
                description: "文字比音频小三个数量级（3 小时约 6 万字 = 180KB），所以留得久得多 —— 回头看的是文字，不是那段录音。到期后**整场记录连同音频一起删掉**。"
            ) {
                SettingsMenuPicker(
                    selection: generalSettingsViewModel.binding(\.recordingTextRetentionDays),
                    options: [
                        SettingsPickerOption(label: "保留 7 天", value: 7),
                        SettingsPickerOption(label: "保留 30 天", value: 30),
                        SettingsPickerOption(label: "保留 90 天", value: 90),
                        SettingsPickerOption(label: "保留 1 年", value: 365),
                        SettingsPickerOption(label: "永久保存", value: 0),
                    ]
                )
            }
            SettingsCardRowDivider()

            SettingsRow(
                label: "换连接的间隔",
                description: "单次连接能活多久，官方没有给明确上限 —— 所以这里不依赖它。每隔一段时间在**静音处**换一条新连接：静音处换，接缝上没有字可丢。小时版按音频时长计费，换连接不额外花钱。"
            ) {
                SettingsMenuPicker(
                    selection: generalSettingsViewModel.binding(\.recordingRotationMinutes),
                    options: [
                        SettingsPickerOption(label: "不主动换", value: 0),
                        SettingsPickerOption(label: "每 10 分钟", value: 10),
                        SettingsPickerOption(label: "每 20 分钟", value: 20),
                        SettingsPickerOption(label: "每 30 分钟", value: 30),
                        SettingsPickerOption(label: "每 60 分钟", value: 60),
                    ]
                )
            }
        }

        SettingsCard {
            SettingsRow(
                label: "录音状态",
                description: recordingStatusDescription
            ) {
                Text(recorderIsRunning ? "录音中" : "空闲")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(recorderIsRunning ? DS.Colors.destructive : DS.Colors.textTertiary)
            }
        }

        SettingsCard {
            SettingsNote(
                text: "录音文件是标准的 16kHz 单声道 WAV —— 它里面的字节就是发给识别服务的字节，所以任何一段都能原样重放给服务端复现一次识别。文字同时写两份：`.txt` 是给人和剪贴板用的，`.jsonl` 每行一句、带毫秒时间戳。"
            )
        }
    }

    private var recordingFolderDescription: String {
        let configured = generalSettingsViewModel.draftSettings.recordingSaveFolderPath
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let url = RecordingLibraryStore.resolvedFolderURL(fromSettingsPath: configured)
        return "音频和文字都放这里。默认在桌面，方便你直接打开看：\(url.path)"
    }

    private var recordingStatusDescription: String {
        let recorder = LongFormRecorderController.shared
        if recorder.isRecording {
            return String(format: "已录 %.1f 秒，电平 %.2f", recorder.elapsedSeconds, recorder.audioLevel)
        }
        if let error = recorder.lastErrorMessage {
            return "上次出错：\(error)"
        }
        return "没在录。按下上面那条快捷键就开始。"
    }

    private var recorderIsRunning: Bool { LongFormRecorderController.shared.isRecording }

    private func chooseRecordingFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "选这个文件夹"
        panel.directoryURL = RecordingLibraryStore.resolvedFolderURL(
            fromSettingsPath: generalSettingsViewModel.draftSettings.recordingSaveFolderPath)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        generalSettingsViewModel.draftSettings.recordingSaveFolderPath = url.path
    }

    // MARK: - 历史

    /// 导入菜单上显示什么。已经导过就显示当前地址的主机名，让用户看得出填的是哪一家。
    private var importMenuTitle: String {
        let base = generalSettingsViewModel.draftSettings.recordingPolishBaseURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty, let host = URL(string: base)?.host else { return "选择服务商" }
        return host
    }

    /// 历史卡片要用的保存目录。
    private var folderURLForHistory: URL {
        RecordingLibraryStore.resolvedFolderURL(
            fromSettingsPath: generalSettingsViewModel.draftSettings.recordingSaveFolderPath)
    }

    @ViewBuilder
    private var recordingPolishSection: some View {
        SettingsGroupLabel("自定义风格")
        SettingsCard {
            SettingsRow(
                label: "自定义转写",
                description: "开启后，转写完成时把下面的风格提示词和转写原文一起发给模型，让模型按你的要求重写一遍，重写结果才是最终进剪贴板的内容。关掉则和以前完全一样：原文直接就是最终内容。"
            ) {
                SettingsSwitch(isOn: generalSettingsViewModel.binding(\.recordingPolishEnabled))
            }
            SettingsCardRowDivider()
            SettingsRow(
                label: "屏幕截图",
                description: "每次停止录音的那一刻自动抓一张屏幕，和转写内容一起发给模型参考。适合「我刚才指着屏幕说的那段话」这类场景。"
            ) {
                SettingsSwitch(isOn: generalSettingsViewModel.binding(\.recordingPolishCapturesScreenshot))
            }
            SettingsCardRowDivider()
            SettingsRow(
                label: "模型 ID",
                description: "默认 deepseek-flash。留空则用「模型」页里 🧠 那个角色的配置。"
            ) {
                TextField("deepseek-flash", text: generalSettingsViewModel.binding(\.recordingPolishModelID))
                    .textFieldStyle(.roundedBorder).frame(width: 200)
            }
            SettingsCardRowDivider()
            SettingsRow(
                label: "从「模型」页导入",
                description: "列出「模型」页面里已经配好的所有服务商，选一个就把它的**地址、Key、模型 ID** 直接填进来 —— 那边配过的东西不用在这里手抄一遍。"
            ) {
                Menu(importMenuTitle) {
                    ForEach(ModelConfigurationStore.snapshot().providers) { provider in
                        Button(provider.displayName) {
                            generalSettingsViewModel.draftSettings.recordingPolishBaseURL = provider.baseURL
                            generalSettingsViewModel.draftSettings.recordingPolishAPIKey = provider.apiKey
                            // 模型 ID 也跟着走 —— 一个服务商 + 它自己的模型名才是一次
                            // 能用的组合，只填地址而留着别的服务商的模型名必然 404。
                            if let model = provider.visionModelID, !model.isEmpty {
                                generalSettingsViewModel.draftSettings.recordingPolishModelID = model
                            }
                        }
                    }
                }
                .menuStyle(.borderlessButton)
                .frame(width: 220)
            }
            SettingsCardRowDivider()
            SettingsRow(label: "服务地址", description: "留空则用「模型」页里 🧠 那个服务商。填根地址即可，会自动补 /chat/completions。") {
                TextField("留空则用 🧠 的配置", text: generalSettingsViewModel.binding(\.recordingPolishBaseURL))
                    .textFieldStyle(.roundedBorder).frame(width: 260)
            }
            SettingsCardRowDivider()
            SettingsRow(label: "API Key", description: "留空则用「模型」页里 🧠 那个服务商的 Key。只写进本机设置文件，仓库之外。") {
                SecureField("留空则用 🧠 的 Key", text: generalSettingsViewModel.binding(\.recordingPolishAPIKey))
                    .textFieldStyle(.roundedBorder).frame(width: 260)
            }
        }

        RecordingPolishStylesEditor()
    }

    @ViewBuilder
    private var recordingHistorySection: some View {
        SettingsGroupLabel("录音历史")
        SettingsCard {
            let sessions = Array(RecordingLibraryStore.shared.allSessions().prefix(50))
            if sessions.isEmpty {
                SettingsRow(
                    label: "还没有录音",
                    description: "录完第一场之后，这里会列出每一场的时间和字数，每一条都能复制全文、播放、在访达里打开。"
                ) { EmptyView() }
            } else {
                // **只露出最近五条的高度，其余靠滑动。** 用户：「只显示最近五条内容，
                // 剩余内容通过滑动显示更多」。外层的设置页本身也在滚，所以这里用一个
                // 定高的内层滚动区 —— 不这么做的话，历史一长就把下面所有设置推到很远。
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(spacing: 8) {
                        ForEach(sessions, id: \.id) { session in
                            RecordingHistoryCard(session: session, folder: folderURLForHistory)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(height: Self.historyViewportHeight)
            }
        }

        if !RecordingLibraryStore.shared.allSessions().isEmpty {
            SettingsCard {
                SettingsNote(
                    text: "这里只列已经录过的场次。**删文件请到访达里删** —— 这个界面不会替你删掉任何一段录音。"
                )
            }
        }
    }

    /// 五条卡片出头的高度。卡片两行、加上内边距，单条约 78pt。
    private static let historyViewportHeight: CGFloat = 400

    /// 展开区十行出头的高度。行高（12.5pt 字 + 4pt 行距）约 21pt。
    private static let expandedTranscriptHeight: CGFloat = 210

    /// 标题：「26 年 09 月 30 日 14 点 · 3:24 · 812 字」。
    private static func historyTitle(for session: RecordingSession) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yy 年 MM 月 dd 日 H 点"
        return "\(formatter.string(from: session.startedAt)) · \(session.formattedDuration) · \(session.characterCount) 字"
    }

    private static func transcriptText(of session: RecordingSession, inFolder folder: URL) -> String {
        (try? String(contentsOf: session.transcriptFileURL(inFolder: folder), encoding: .utf8))?
            .replacingOccurrences(of: "\n", with: "") ?? ""
    }

    private static func transcriptPreview(of session: RecordingSession, inFolder folder: URL) -> String {
        let text = transcriptText(of: session, inFolder: folder)
        return text.isEmpty ? "（没有识别到文字）" : text
    }

    private func historyActionButton(_ title: String, systemImage: String,
                                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(DS.Colors.textSecondary)
                .frame(width: 26, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(DS.Colors.surface4)
                )
        }
        .buttonStyle(.plain)
        .help(title)
    }
}

/// 一条录音历史。**两行**。
///
/// 第一行 = 标题（时间 · 时长 · 字数）+ 右侧四个动作（复制全文 / 播放 / 在访达中显示 / 展开）。
/// 第二行 = 内容预览；展开后显示全文，**最多十行**，再多在这个小区域里滑。
///
/// 做成独立的 `View` 而不是 `GeneralSettingsView` 扩展里的一个函数：展开状态需要
/// `@State`，而 **extension 里不能声明存储属性** —— 每张卡片自己持状态，顺带也让
/// 「展开哪一条」天然是每张卡各管各的。
private struct RecordingHistoryCard: View {
    let session: RecordingSession
    let folder: URL

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            // ── 第一行：标题 + 动作（**没有复制按钮** —— 复制按内容分两行，
            //    因为源文本和润色文本是两份不同的东西，一个按钮说不清复制的是哪份）。
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                action("在访达中显示", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([session.audioFileURL(inFolder: folder)])
                }
                if audioExists {
                    action("播放", systemImage: "play.circle") {
                        NSWorkspace.shared.open(session.audioFileURL(inFolder: folder))
                    }
                } else {
                    // 音频按保留天数删掉了，但记录还在。**要说出来**，而不是让播放
                    // 按钮点了没反应。
                    Text("音频已清理")
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textTertiary)
                }
                action(isExpanded ? "收起" : "展开",
                       systemImage: isExpanded ? "chevron.up" : "chevron.down") {
                    withAnimation(.easeInOut(duration: 0.18)) { isExpanded.toggle() }
                }
            }

            // ── 第二行：源文本
            textRow(label: "源文本", text: sourceText, isEmpty: "（没有识别到文字）")

            // ── 第三行：润色文本
            textRow(label: "润色文本", text: polishedText, isEmpty: "（未润色 / 这一场没开自定义风格）")
        }
        .padding(11)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(DS.Colors.surface2)
        )
    }

    /// 一行文本：**开头是标识，右侧是复制按钮**，中间是内容。
    ///
    /// 标识必须在，否则两行看起来是同一种东西 —— 而它们不是：一份是识别器听到的，
    /// 一份是模型改写的。用户要能一眼分清自己在复制哪一份。
    @ViewBuilder
    private func textRow(label: String, text: String, isEmpty emptyPlaceholder: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(DS.Colors.textTertiary)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 5).fill(DS.Colors.surface4))
                .fixedSize()

            Text(text.isEmpty ? emptyPlaceholder : text)
                .font(.system(size: 12.5))
                .foregroundColor(text.isEmpty ? DS.Colors.textTertiary : DS.Colors.textSecondary)
                .lineSpacing(4)
                .lineLimit(isExpanded ? 5 : 1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)

            action("复制\(label)", systemImage: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            .opacity(text.isEmpty ? 0.35 : 1)
            .disabled(text.isEmpty)
        }
    }

    private var audioExists: Bool {
        FileManager.default.fileExists(atPath: session.audioFileURL(inFolder: folder).path)
    }

    /// **源文本**：识别器逐句落盘的原文。润色不改它。
    private var sourceText: String {
        Self.flattenedText(at: session.transcriptFileURL(inFolder: folder))
    }
    /// **润色文本**：走「自定义风格」重写之后的结果。没开润色时文件不存在 → 空串。
    private var polishedText: String {
        Self.flattenedText(at: session.polishedTranscriptFileURL(inFolder: folder))
    }

    private static func flattenedText(at url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8))?
            .replacingOccurrences(of: "\n", with: "") ?? ""
    }

    /// 标题：「26 年 09 月 30 日 14 点 · 3:24 · 812 字」。
    private var title: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yy 年 MM 月 dd 日 H 点"
        return "\(formatter.string(from: session.startedAt)) · \(session.formattedDuration) · \(session.characterCount) 字"
    }

    private func action(_ title: String, systemImage: String,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(DS.Colors.textSecondary)
                .frame(width: 26, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(DS.Colors.surface4)
                )
        }
        .buttonStyle(.plain)
        .help(title)
    }
}

/// 「自定义风格」的列表：可以有很多条，每条自己一个开关，能改名、改提示词、删除。
///
/// 做成独立 `View` 的理由和 `RecordingHistoryCard` 一样：需要 `@State`，而
/// `extension` 里不能声明存储属性。
private struct RecordingPolishStylesEditor: View {
    @State private var styles: [RecordingPolishStyle] = RecordingPolishStyleStore.shared.allStyles()
    @State private var expandedStyleID: String?

    var body: some View {
        SettingsCard {
            SettingsRow(
                label: "风格清单",
                description: "勾上的才会生效（而且总开关也要开着）。可以有多条 —— 按场景各写一条，比如「会议纪要」和「随手笔记」。"
            ) {
                Button("新增一条") {
                    let new = RecordingPolishStyle(id: UUID().uuidString, name: "新风格",
                                                   prompt: "", isEnabled: true, isBuiltIn: false)
                    RecordingPolishStyleStore.shared.upsert(new)
                    reload()
                    expandedStyleID = new.id
                }
                .buttonStyle(.bordered)
            }

            ForEach(styles) { style in
                SettingsCardRowDivider()
                styleRow(style)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: RecordingPolishStyleStore.didChangeNotification)) { _ in
            reload()
        }
    }

    @ViewBuilder
    private func styleRow(_ style: RecordingPolishStyle) -> some View {
        let index = styles.firstIndex(where: { $0.id == style.id }) ?? 0
        let isExpanded = expandedStyleID == style.id

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                // 开关写回存储：`binding(for:)` 拿到的 index 是**每次渲染现算的**，
                // 不在闭包里捕获 `index` —— 删掉一条之后捕获的那个下标就会指错行。
                SettingsSwitch(isOn: Binding(
                    get: { styles[safe: index]?.isEnabled ?? false },
                    set: { newValue in update(id: style.id) { $0.isEnabled = newValue } }))

                TextField("风格名称", text: Binding(
                    get: { styles[safe: index]?.name ?? "" },
                    set: { newValue in update(id: style.id) { $0.name = newValue } }))
                    .textFieldStyle(.plain)
                    .font(.system(size: 13.5, weight: .semibold))
                    .frame(maxWidth: 200, alignment: .leading)

                if style.isBuiltIn {
                    Text("出厂").font(.system(size: 11))
                        .foregroundColor(DS.Colors.textTertiary)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(DS.Colors.surface4))
                }

                Spacer(minLength: 0)

                Button(isExpanded ? "收起提示词" : "编辑提示词") {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        expandedStyleID = isExpanded ? nil : style.id
                    }
                }
                .buttonStyle(.bordered)

                // 出厂那条**不给删** —— 恢复它意味着让用户重新贴一遍三千多字的提示词。
                if !style.isBuiltIn {
                    Button("删除") {
                        RecordingPolishStyleStore.shared.delete(id: style.id)
                        reload()
                    }
                    .buttonStyle(.bordered)
                }
            }

            if isExpanded {
                SettingsTextEditorRow(
                    label: "提示词",
                    description: "发给模型时拼在转写原文的前面。上面是要求，下面是内容。",
                    text: Binding(
                        get: { styles[safe: index]?.prompt ?? "" },
                        set: { newValue in update(id: style.id) { $0.prompt = newValue } }),
                    placeholder: "例如：把下面的语音转写整理成通顺的书面语，保留原意，去掉口头语。",
                    minimumHeight: 200)
            }
        }
        .padding(.vertical, 4)
    }

    private func update(id: String, _ change: (inout RecordingPolishStyle) -> Void) {
        guard var style = styles.first(where: { $0.id == id }) else { return }
        change(&style)
        RecordingPolishStyleStore.shared.upsert(style)
        reload()
    }

    private func reload() {
        styles = RecordingPolishStyleStore.shared.allStyles()
    }
}

private extension Array {
    /// 下标越界返回 nil。列表在编辑中被删掉一条时，正在渲染的那一帧仍可能拿着旧下标。
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
