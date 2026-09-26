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
/// 直接写进 App 自己的设置文件：`~/Library/Application Support/Wanna/AppSettings.json`
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
            recordingInputSection
            recordingServiceSection
            recordingStorageSection
            recordingPolishSection
            // Notion 笔记排在最后：它是「录完之后还能去哪儿」这一族里最新的一个出口。
            notionNoteSection
            recordingCameraSection
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
                placeholder: "张三，Wanna，火山引擎"
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

    /// 摄像头抓帧的全部参数。
    ///
    /// 用户 2026-09-26：「把这些参数（……显示的帧率、发送的帧率、分辨率、触发的关键词）
    /// 放在录音页面里，作为一个参数让用户可以选择，包括这个功能需不需要开启。」
    ///
    /// **判据在代码里，不靠模型猜。** 这一段全是本地参数和本地判定 —— 转写里没说触发词，
    /// 摄像头一次都不会启动，也不会为它花掉任何 token。
    @ViewBuilder
    private var recordingCameraSection: some View {
        SettingsGroupLabel("摄像头抓帧")
        SettingsCard {
            SettingsRow(
                label: "启用",
                description: "总开关。打开后，转写里出现下面的触发词才会开始抓帧 —— 判定是代码做的，不是让模型猜；一句都没提到触发词时，摄像头根本不会启动。"
            ) {
                SettingsSwitch(isOn: generalSettingsViewModel.binding(\.recordingPolishCapturesCamera))
            }
            SettingsCardRowDivider()
            SettingsRow(
                label: "触发词",
                description: "说什么才抓帧。逗号分隔，中英文逗号、顿号、换行都算。判定是精确匹配这几个字，不是「摄像头」三个字 —— 光说「摄像头」不抓，日常对话里太容易带出来。"
            ) {
                TextField("123摄像头，打开摄像头",
                          text: generalSettingsViewModel.binding(\.recordingCameraTriggerKeywords))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
            }
            SettingsCardRowDivider()
            SettingsRow(
                label: "画面帧率",
                description: "小窗里显示的帧率。这是眼睛在看的东西，低了就知道卡。它同时也是摄像头的采集帧率 —— 这里要 30，硬件就得按 30 帧给，给不了的话这一项等于没设。"
            ) {
                SettingsSegmentedPicker(
                    selection: generalSettingsViewModel.binding(\.recordingCameraPreviewFramesPerSecond),
                    options: [10, 15, 24, 30].map {
                        SettingsPickerOption(label: "\($0)", value: Double($0))
                    }
                )
            }
            SettingsCardRowDivider()
            SettingsRow(
                label: "送模型帧率",
                description: "真正发给模型的帧率。比画面低一个数量级是故意的：模型要的是「这段时间镜头对着什么」，一秒一张就够，而每多一帧就多一份 token。"
            ) {
                SettingsSegmentedPicker(
                    selection: generalSettingsViewModel.binding(\.recordingCameraModelFramesPerSecond),
                    options: [1, 2, 3, 4].map {
                        SettingsPickerOption(label: "\($0)", value: Double($0))
                    }
                )
            }
            SettingsCardRowDivider()
            SettingsRow(
                label: "清晰度",
                description: "采集分辨率。1080p 更清楚、更费电；720p 够看清人，也够看清一张纸上的大字。"
            ) {
                SettingsSegmentedPicker(
                    selection: generalSettingsViewModel.binding(\.recordingCameraUsesHighResolution),
                    options: [
                        SettingsPickerOption(label: "720p", value: false),
                        SettingsPickerOption(label: "1080p", value: true),
                    ]
                )
            }
            SettingsCardRowDivider()
            SettingsRow(
                label: "最多送几帧",
                description: "一次最多带几帧去问模型，超过就丢最早的。说得久了，前面那些帧跟最后的提问已经没关系了。覆盖时长按送模型帧率算 —— 1 帧/秒 × 24 帧 = 最近 24 秒。"
            ) {
                SettingsStepper(value: generalSettingsViewModel.binding(\.recordingCameraMaximumFrameCount),
                                range: 1...120)
            }
        }
    }

    /// 用哪个麦克风。
    ///
    /// 用户 2026-09-26：「让用户可以自己设置一个默认驱动设备，让用户可以看到」——
    /// **「可以设置」和「可以看到」是两件事，这里都做。**
    ///
    /// 它存在的理由是实测出来的一次故障：录屏软件的虚拟驱动（2 声道）和内置麦克风
    /// （1 声道）被 CoreAudio 合成了一个 3 声道的「默认设备聚合体」，而那个形态
    /// **交出的是纯静音** —— 录了 117 秒、0 字、服务端一直超时重连，全程不报错。
    /// 录音已经改成绑**具体设备**而不是那个聚合体，但「系统默认」本身可以被切到任何
    /// 地方（包括那个虚拟声道），所以用户要能自己指定、并且看见现在到底用的是谁。
    @ViewBuilder
    private var recordingInputSection: some View {
        SettingsGroupLabel("麦克风")
        SettingsCard {
            SettingsRow(
                label: "输入设备",
                description: "「跟系统默认」= 用 macOS 当前默认的那个。"
                    + "选具体设备更稳：默认设备可以被别的软件改（录屏软件的虚拟声道就在下面这个列表里），"
                    + "而改到那种设备上录出来的会是静音。"
            ) {
                Menu(currentInputDeviceMenuTitle) {
                    Button("跟系统默认") {
                        generalSettingsViewModel.draftSettings.recordingInputDeviceUID = ""
                    }
                    ForEach(AudioInputDeviceCatalog.allInputDevices()) { device in
                        Button(device.displayName + (device.isSystemDefault ? "（系统默认）" : "")) {
                            generalSettingsViewModel.draftSettings.recordingInputDeviceUID = device.uid
                        }
                    }
                }
                .menuStyle(.borderlessButton)
                .frame(width: 240)
            }
            SettingsCardRowDivider()
            // **「现在实际绑的是谁」** —— 和上面那个选择器是两件事：选了不等于绑上了
            //（设备可能被拔掉、可能被别的进程占着），而用户要看的正是这个。
            SettingsRow(
                label: "这一场实际用的",
                description: "只有录音跑起来之后才有值。它和上面选的不是一回事 —— "
                    + "设备被拔掉时 Wanna 会落回系统默认并在诊断日志里说明，"
                    + "这里显示的就是那一刻真正用的那个。"
            ) {
                Text(reportedInputDeviceName)
                    .font(.system(size: 11.5))
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 240, alignment: .trailing)
            }
            if let warning = silentInputWarning {
                SettingsCardRowDivider()
                SettingsRow(label: "上一场没录到声音", description: warning)
            }
        }
    }

    /// 选择器上显示的文字。
    private var currentInputDeviceMenuTitle: String {
        let uid = generalSettingsViewModel.draftSettings.recordingInputDeviceUID
        guard !uid.isEmpty else { return "跟系统默认" }
        return AudioInputDeviceCatalog.device(withUID: uid)?.name ?? "（选的那个现在不在）"
    }

    /// 最近一场录音实际绑的设备。没录过就是「还没录过」。
    private var reportedInputDeviceName: String {
        LongFormRecorderController.shared.lastBoundInputDeviceName ?? "还没录过"
    }

    /// 最近一场连续静音的告警。没有就是 nil。
    private var silentInputWarning: String? {
        LongFormRecorderController.shared.lastSilentInputWarning
    }

    /// **录音 → Notion 笔记**（用户 2026-09-27 第 9 条：「该功能放在设置页面的录音功能里，
    /// 允许用户自定义 URL、API key、模型、保存到 Notion 的链接、Notion API 和个人令牌，
    /// 以及撰写的提示词」）。
    ///
    /// 三组：**开关与目的地**、**整理用哪套模型**、**触发关键词与提示词**。整理那套模型
    /// **故意与「自定义风格」分开** —— 用户明确要求「转写部分使用另一套提示词，独立使用
    /// DeepSeek Flash 设计的提示词整理，不使用录音润色提示词」。
    @ViewBuilder
    private var notionNoteSection: some View {
        SettingsGroupLabel("Notion 笔记")
        SettingsCard {
            SettingsRow(
                label: "存成 Notion 笔记",
                description: "开着时：录音的开头或末尾**前 20 字**里出现下面任一关键词，刘海的**左**侧就会出现一颗「取消」。不点它就默认存成一条笔记；点了这一场就按普通录音处理。"
            ) {
                SettingsSwitch(isOn: generalSettingsViewModel.binding(\.notionNoteEnabled))
            }
            SettingsCardRowDivider()
            SettingsRow(
                label: "写到哪一页",
                description: "把那一页的链接整条粘进来即可（也能只填页面 id）。**必须先在这一页里把集成添加进来**：打开那一页 → 右上 ••• → 连接 → 选中你的集成，否则服务端会回 404。"
            ) {
                TextField("https://www.notion.so/…", text: generalSettingsViewModel.binding(\.notionNotePageID))
                    .textFieldStyle(.roundedBorder).frame(width: 300)
            }
            SettingsCardRowDivider()
            SettingsRow(
                label: "打开用的链接",
                description: "保存成功后点「已保存笔记」跳转的地址。留空则用上面那一页拼一个。"
            ) {
                TextField("留空则用上面那一页", text: generalSettingsViewModel.binding(\.notionNoteOpenURL))
                    .textFieldStyle(.roundedBorder).frame(width: 300)
            }
            SettingsCardRowDivider()
            SettingsRow(
                label: "集成令牌",
                description: "Notion 集成令牌（`ntn_…`）。它只写进本机设置文件（0600、仓库之外），不会进仓库；导出设置时那一条会带着它，导出页有说明。"
            ) {
                SecureField("ntn_…", text: generalSettingsViewModel.binding(\.notionNoteToken))
                    .textFieldStyle(.roundedBorder).frame(width: 300)
            }
        }

        SettingsCard {
            SettingsRow(
                label: "整理用的模型 ID",
                description: "把录音整理成「大纲 + 排版」这一步用哪个模型。默认 deepseek-flash —— 它是**改写**任务，这一套与「自定义风格」那套完全分开。"
            ) {
                TextField("deepseek-flash", text: generalSettingsViewModel.binding(\.notionNoteModelID))
                    .textFieldStyle(.roundedBorder).frame(width: 200)
            }
            SettingsCardRowDivider()
            SettingsRow(label: "服务地址", description: "留空则用「自定义风格」那套（再没有就用「模型」页里 🧠 的）。") {
                TextField("留空则用自定义风格那套", text: generalSettingsViewModel.binding(\.notionNoteBaseURL))
                    .textFieldStyle(.roundedBorder).frame(width: 260)
            }
            SettingsCardRowDivider()
            SettingsRow(label: "API Key", description: "留空同上。只写进本机设置文件。") {
                SecureField("留空同上", text: generalSettingsViewModel.binding(\.notionNoteAPIKey))
                    .textFieldStyle(.roundedBorder).frame(width: 260)
            }
        }

        SettingsCard {
            SettingsTextEditorRow(
                label: "触发关键词",
                description: "一行一个。检测**只在开头前 20 字与末尾后 20 字**里做，中间出现不算；比较前会去掉空格与标点（转写是 AI 出来的，标点常常和嘴里说的不一致），所以「保存 notion」与「保存notion」都命中。",
                text: generalSettingsViewModel.binding(\.notionNoteKeywords),
                placeholder: "保存笔记",
                minimumHeight: 120
            )
            SettingsCardRowDivider()
            SettingsTextEditorRow(
                label: "整理提示词",
                description: "要求模型**只排版、不扩写**，并按三段输出（【总结】【大纲】【排版】）—— 客户端按这三个标记切开，分别放进折叠列表里的两块。",
                text: generalSettingsViewModel.binding(\.notionNotePrompt),
                placeholder: "…",
                minimumHeight: 180
            )
        }
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

    /// **订阅转写状态**：`retranscribingRecordingIDs` 是 `@Published`，不订阅的话
    /// 「转写中…」那颗按钮永远不变回「重新转写」（进度只有它自己知道）。
    @ObservedObject private var recorder = LongFormRecorderController.shared

    @State private var isExpanded = false

    /// 这一条正在重新转写吗 —— 设置页据此把按钮变成「转写中…」。
    /// 它读的是 `LongFormRecorderController` 的 `@Published`，所以进度会自己刷新。
    private var isRetranscribing: Bool {
        LongFormRecorderController.shared.retranscribingRecordingIDs.contains(session.id)
    }

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
                    // **重新转写**（用户 2026-09-26：「网络问题或者其他的问题，他可能是断开了，
                    // 然后用户可以通过这样的历史点击重新进行一个重新撰写」）。
                    //
                    // 只有音频还在的时候才有意义 —— 识别器的输入就是那个 `.wav`。音频被保留
                    // 天数清理掉之后，这一颗就不画了（画一颗点了没反应的按钮更糟）。
                    action(isRetranscribing ? "转写中…" : "重新转写",
                           systemImage: isRetranscribing ? "hourglass" : "arrow.clockwise") {
                        guard !isRetranscribing else { return }
                        Task { await LongFormRecorderController.shared.retranscribe(recordingID: session.id) }
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
