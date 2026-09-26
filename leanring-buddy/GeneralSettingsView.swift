//
//  GeneralSettingsView.swift
//  leanring-buddy
//
//  The seven pages of the settings window that are not 模型 — 通用, 对话与记忆,
//  听, 说, 看与截图, 操作, 快捷键 — plus the shared row/card/control pieces they
//  are built from.
//
//  Layout follows the approved design: a page header, small uppercase group
//  labels, and cards whose rows put a label + explanation on the left and the
//  control on the right. The shared pieces exist so every row lines up the same
//  way and a new setting costs one row, not one layout.
//

import Combine
import SwiftUI

/// One page of the settings window. The sidebar renders these in order.
enum SettingsPage: String, CaseIterable, Identifiable {
    case general
    case interactionStyle
    case model
    case agent
    case memory
    case listen
    case speak
    case vision
    case action
    case recording
    case review
    case shortcuts
    case voiceChatRoles
    case voiceCatalog
    case voiceChatConnection
    case exportSettings
    case importSettings
    case archive

    var id: String { rawValue }

    /// 导出 / 导入这两页不读也不写 `AppSettings`：它们把整套设置写出去或读回来，
    /// 是**动作**而不是偏好。所以它们不走 `GeneralSettingsActionBar`（上面那三颗
    /// 「恢复默认 / 保存 / 关闭」在这里要么没有意义、要么危险），由
    /// `SettingsTransferPage` 自己画。
    var isSettingsTransferPage: Bool {
        self == .exportSettings || self == .importSettings
    }

    /// 这一页要不要画右上角那条「恢复默认 / 保存 / 关闭」。
    ///
    /// 导出/导入是**动作**（把设置写出去、读回来），归档是**浏览**已有数据 ——
    /// 三页都不读也不写 `AppSettings`，那条栏在这里要么没有意义、要么危险
    /// （「恢复默认」在归档页上会去重置一堆跟这一页毫无关系的设置）。
    var drawsSettingsActionBar: Bool {
        !isSettingsTransferPage && self != .archive
    }

    var sidebarTitle: String {
        switch self {
        case .general: return "通用"
        case .interactionStyle: return "交互"
        case .model: return "模型"
        case .agent: return "Agent"
        case .memory: return "对话与记忆"
        case .listen: return "听（识别）"
        case .speak: return "说（播报）"
        case .vision: return "看与截图"
        case .action: return "操作"
        case .recording: return "录音"
        case .review: return "复盘"
        case .shortcuts: return "快捷键"
        case .voiceChatRoles: return "角色"
        case .voiceCatalog: return "音色查看"
        case .voiceChatConnection: return "连接"
        case .exportSettings: return "导出设置"
        case .importSettings: return "导入设置"
        case .archive: return "归档"
        }
    }

    /// The SF Symbol shown beside each sidebar title. SF Symbols rather than
    /// emoji so the icons take the text colour and read as one family.
    var sidebarSymbol: String {
        switch self {
        case .general: return "gearshape.fill"
        case .interactionStyle: return "slider.horizontal.3"
        case .model: return "cpu"
        case .agent: return "hammer"
        case .memory: return "bubble.left.fill"
        case .listen: return "mic.fill"
        case .speak: return "speaker.wave.2.fill"
        case .vision: return "eye.fill"
        case .action: return "cursorarrow"
        case .recording: return "record.circle"
        case .review: return "chart.bar.doc.horizontal"
        case .shortcuts: return "keyboard"
        case .voiceChatRoles: return "person.2.fill"
        case .voiceCatalog: return "waveform.circle.fill"
        case .voiceChatConnection: return "link.circle.fill"
        case .exportSettings: return "square.and.arrow.up"
        case .importSettings: return "square.and.arrow.down"
        case .archive: return "archivebox.fill"
        }
    }
}

// MARK: - Page content

/// The settings that live in `AppSettings`, one page at a time.
struct GeneralSettingsView: View {
    @ObservedObject var generalSettingsViewModel: GeneralSettingsViewModel
    let page: SettingsPage

    /// Whether the 清空对话记忆 confirmation is up. Deleting the conversation
    /// cannot be undone, so it never happens on a single click.
    @State private var isConfirmingConversationMemoryClear = false

    /// Whether macOS currently lets Wanna post clicks and keystrokes for the
    /// user. Only 操作 reads it (see `accessibilityPermissionControl`), and it
    /// cannot be asked for in code — macOS requires a person to grant it in its
    /// own dialog — so this is read back on a timer instead.
    @State private var hasAccessibilityPermission = WindowPositionManager.hasAccessibilityPermission()

    /// Re-reads the Accessibility grant while the 操作 page is on screen.
    ///
    /// The page is rebuilt whenever the sidebar selection changes, so this only
    /// ticks while someone is actually looking at the row it updates.
    private let accessibilityPermissionPollTimer = Timer
        .publish(every: 1.5, on: .main, in: .common)
        .autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                switch page {
                case .general: generalPage
                case .interactionStyle: interactionStylePage
                case .agent: agentPage
                case .memory: memoryPage
                case .listen: listenPage
                case .speak: speakPage
                case .vision: visionPage
                case .action: actionPage
                case .recording: recordingPage
                case .review: reviewPage
                case .shortcuts: shortcutsPage
                case .voiceChatRoles:
                    // 角色页由 `VoiceChatRoleSettingsView` 自己画（它有两栏、
                    // 还要读角色存储），这里只是一个占位，与 模型 / 导出导入 同款。
                    EmptyView()
                case .voiceCatalog:
                    // 同上：音色查看由 `VoiceCatalogSettingsView` 自己画。
                    EmptyView()
                case .voiceChatConnection:
                    voiceChatConnectionPage
                case .archive:
                    // 同上：归档由 `NotchArchiveArea` 自己画（它有两栏）。
                    EmptyView()
                case .model: EmptyView() // 模型 is rendered by ModelSettingsView.
                // 导出 / 导入 is rendered by SettingsTransferPage — it is an
                // action on the whole settings file, not a page of AppSettings.
                case .exportSettings, .importSettings: EmptyView()
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: 通用

    private var generalPage: some View {
        Group {
            SettingsPageHeader(
                title: "通用",
                subtitle: "启动行为、蓝色光标、回答怎么呈现给你。"
            )

            SettingsGroupLabel("启动")
            SettingsCard {
                SettingsRow(
                    label: "开机自启动",
                    description: "登录 Mac 时自动启动 Wanna。"
                ) {
                    SettingsSwitch(isOn: generalSettingsViewModel.binding(\.launchesAtLogin))
                }
                SettingsCardRowDivider()
                SettingsRow(
                    label: "启动时自动打开面板",
                    description: "打开这一项后，每次启动都会自动展开刘海屏的对话面板。"
                ) {
                    SettingsSwitch(isOn: generalSettingsViewModel.binding(\.opensPanelOnLaunch))
                }
            }

            SettingsGroupLabel("刘海屏")
            SettingsCard {
                SettingsRow(
                    label: "刘海屏入口",
                    description: "在带刘海的 Mac 上把入口放进屏幕顶部的刘海里，点开就是主面板。关掉后应用将没有任何可见入口。"
                ) {
                    SettingsSwitch(isOn: generalSettingsViewModel.binding(\.enablesNotchPresence))
                }
                SettingsCardRowDivider()
                SettingsRow(
                    label: "刘海屏音效",
                    description: "对话开始、发送、回答到达这些节点播一声短音效。"
                ) {
                    SettingsSwitch(isOn: generalSettingsViewModel.binding(\.playsNotchSoundEffects))
                }
            }

            SettingsGroupLabel("蓝色光标")
            SettingsCard {
                SettingsRow(
                    label: "显示方式",
                    description: "「一直显示」是它一直跟着鼠标；后两项只在用到它的时候出现，平时屏幕上什么都没有。"
                ) {
                    SettingsSegmentedPicker(
                        selection: generalSettingsViewModel.binding(\.cursorPresenceMode),
                        options: CursorPresenceMode.allCases.map {
                            SettingsPickerOption(label: $0.displayName, value: $0)
                        }
                    )
                }
                SettingsCardRowDivider()
                SettingsRow(
                    label: "形状",
                    description: "「标准指针」把蓝色三角换成 Mac 指针的样子；箭头尖端对准的正是鼠标所在的位置。"
                ) {
                    SettingsSegmentedPicker(
                        selection: generalSettingsViewModel.binding(\.cursorShapeStyle),
                        options: CursorShapeStyle.allCases.map {
                            SettingsPickerOption(label: $0.displayName, value: $0)
                        }
                    )
                }
                SettingsCardRowDivider()
                SettingsRow(
                    label: "跟随距离",
                    description: "它停在鼠标的什么位置。「重叠」是压在鼠标上，「紧贴」只让开一点点，两者都没有那条一直拖着的尾巴。"
                ) {
                    SettingsSegmentedPicker(
                        selection: generalSettingsViewModel.binding(\.cursorFollowDistance),
                        options: CursorFollowDistance.allCases.map {
                            SettingsPickerOption(label: $0.displayName, value: $0)
                        }
                    )
                }
                SettingsCardRowDivider()
                SettingsRow(
                    label: "闲置后自动隐藏",
                    description: "只在上面选了「只在对话时出现」或「只在指位置时出现」时有用：说完话之后光标还留多久才消失。",
                    isEnabled: generalSettingsViewModel.draftSettings.cursorPresenceMode.hidesWhenIdle
                ) {
                    SettingsSlider(
                        value: generalSettingsViewModel.binding(\.transientCursorHideDelaySeconds),
                        range: 0.5...5,
                        step: 0.5,
                        valueLabel: { String(format: "%.1f 秒", $0) }
                    )
                }
            }

            SettingsGroupLabel("回答的呈现")
            SettingsCard {
                SettingsRow(
                    label: "回答时显示文字",
                    description: "回答一边生成一边显示在蓝色光标旁的气泡里；关掉则只朗读。"
                ) {
                    SettingsSwitch(isOn: generalSettingsViewModel.binding(\.showsResponseText))
                }
                SettingsCardRowDivider()
                SettingsRow(
                    label: "光标旁显示 Agent 状态",
                    description: "派出去的活跑完时，在光标旁弹一个对号加一句话。关掉之后**刘海左侧那一排按钮照常**——那边是「你想看就去看」，这边是「推到你眼前」，后台任务跑很久时后者会一直占着鼠标旁那块地方。"
                ) {
                    SettingsSwitch(isOn: generalSettingsViewModel.binding(\.showsAgentStatusAtCursor))
                }
                SettingsCardRowDivider()
                SettingsRow(
                    label: "回答文字多留一会儿",
                    description: "文字会一直留到这句念完，这是念完之后再停多久。设成 0 秒就是念完立刻消失。"
                ) {
                    SettingsSlider(
                        value: generalSettingsViewModel.binding(\.answerBubbleLingerSeconds),
                        range: 0...15,
                        step: 1,
                        valueLabel: { $0 < 1 ? "念完就消失" : String(format: "%.0f 秒", $0) }
                    )
                }
                SettingsCardRowDivider()
                SettingsRow(
                    label: "说话时实时显示识别文字",
                    description: "按住快捷键说话时，边说边上屏你正在说的内容；关掉只显示波形。"
                ) {
                    SettingsSwitch(isOn: generalSettingsViewModel.binding(\.showsLiveTranscript))
                }
            }

            SettingsNote(
                text: "「显示方式」是这一页影响最直接的一项：嫌蓝色光标碍事就改成后两项，平时它就完全不出现了。回答文字和识别文字不受它影响，仍然会显示在鼠标旁边。"
            )
        }
    }

    // MARK: 对话与记忆

    // MARK: 交互

    /// The card's theme, the sheet's expansion animation, and the composer's
    /// send key, on one page.
    ///
    /// 卡片样式 lived here alone until 2026-09-23, when the user widened it:
    /// 「把设置页面的"卡片样式"页面调整为"交互样式"，里面包含两个选项：卡片样式 /
    /// 窗口样式」. Two things about what belongs on a page, and this page is where
    /// they meet: the panel opening and the reply card are both "what a Wanna
    /// interaction looks like", which is the axis the user organised it along.
    ///
    /// The page was called 交互样式 until later the same day, when the user
    /// shortened it and added a third group in one instruction: 「设置页面的
    /// "交互交互样式"改为"交互"，并增加一个选项，即输入方式，或叫发送方法」. The
    /// send key is the same axis — it is how the user talks to Wanna, not how
    /// Wanna looks — so it belongs here rather than on 快捷键 (which is about the
    /// voice shortcut) or 通用.
    ///
    /// The card picker keeps the live preview below it, and the window-style row
    /// deliberately has none — 「不需要提供预览，因为很难预览」. An expansion is a
    /// 0.34 s animation of the whole 810×940 sheet; rendering a still of it would
    /// show a scaled-down panel, which is not what picking 中心缩放 buys.
    ///
    /// The picker is the same binding as before (moved, not duplicated: one
    /// setting, one home), so nothing about the stored style changed.
    private var interactionStylePage: some View {
        Group {
            SettingsPageHeader(
                title: "交互",
                subtitle: "回复卡片长什么样、面板怎么弹出来，以及输入框按哪个键发送。改完点右下角「保存」生效。"
            )

            SettingsGroupLabel("卡片样式")
            SettingsCard {
                SettingsRow(
                    label: "卡片颜色",
                    description: "黑色是默认，跟面板底色一致；蓝色是卡片规格里的原色；宣纸是米黄底、墨色字、带横线。流式回答带逐字模糊聚焦动画（新字先模糊，再逐渐变清晰）。"
                ) {
                    SettingsSegmentedPicker(
                        selection: generalSettingsViewModel.binding(\.answerCardStyle),
                        options: AnswerCardStyle.allCases.map {
                            SettingsPickerOption(label: $0.displayName, value: $0)
                        }
                    )
                }
            }

            SettingsGroupLabel("卡片预览")
            SettingsCard {
                VStack(alignment: .leading, spacing: 8) {
                    Text("回复卡片预览 — 当前所选样式的真实渲染效果")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.4))
                    AnswerCardView(
                        text: "好的，已经帮你点开了设置页面。窗口右上角的关闭按钮可以把面板收起来。",
                        isStreaming: false,
                        style: generalSettingsViewModel.draftSettings.answerCardStyle
                    )
                    .frame(maxWidth: 300, alignment: .leading)
                    .shadow(color: Color.black.opacity(0.25), radius: 8, x: 0, y: 3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }

            SettingsGroupLabel("窗口样式")
            SettingsCard {
                SettingsRow(
                    label: "展开方式",
                    description: WindowExpansionStyle.notchBloom.explanation
                        + "（默认）\n"
                        + WindowExpansionStyle.edgeScale.explanation
                        + "\n"
                        + WindowExpansionStyle.curtain.explanation
                        + "\n三种都是窗口一次到位、内容层做动画，不会逐帧重排，所以都不会卡。"
                ) {
                    SettingsSegmentedPicker(
                        selection: generalSettingsViewModel.binding(\.windowExpansionStyle),
                        options: WindowExpansionStyle.allCases.map {
                            SettingsPickerOption(label: $0.displayName, value: $0)
                        }
                    )
                }
                SettingsCardRowDivider()
                SettingsRow(
                    label: "弹出速度",
                    description: "面板展开动画的快慢，倍数越大越快。1× 是参考设计的原始速度；默认 2×，因为原始速度偏慢。三种展开方式和收起都跟着这个倍率走。"
                ) {
                    SettingsSegmentedPicker(
                        selection: generalSettingsViewModel.binding(\.notchExpansionSpeedMultiplier),
                        options: [
                            SettingsPickerOption(label: "1×", value: 1.0),
                            SettingsPickerOption(label: "1.5×", value: 1.5),
                            SettingsPickerOption(label: "2×", value: 2.0),
                            SettingsPickerOption(label: "3×", value: 3.0),
                        ]
                    )
                }
            }

            SettingsGroupLabel("输入")
            SettingsCard {
                SettingsRow(
                    label: "发送方式",
                    description: ComposerSendShortcut.returnKey.explanation
                        + "\n"
                        + ComposerSendShortcut.commandReturn.explanation
                        + "\n两种都能写多行：没被指定发送的那个键就是换行用的。"
                ) {
                    SettingsSegmentedPicker(
                        selection: generalSettingsViewModel.binding(\.composerSendShortcut),
                        options: ComposerSendShortcut.allCases.map {
                            SettingsPickerOption(label: $0.displayName, value: $0)
                        }
                    )
                }
            }
        }
    }

    private var memoryPage: some View {
        Group {
            SettingsPageHeader(
                title: "对话与记忆",
                subtitle: "它能记住多少、记多久、记住的是什么。"
            )

            SettingsGroupLabel("记忆范围")
            SettingsCard {
                SettingsRow(
                    label: "记住最近 \(generalSettingsViewModel.draftSettings.rememberedConversationRounds) 轮对话",
                    description: "更早的问答直接丢弃。调大记得更久，但每次提问更慢、更费 token。"
                ) {
                    SettingsStepper(
                        value: generalSettingsViewModel.binding(\.rememberedConversationRounds),
                        range: 0...30
                    )
                }
                SettingsCardRowDivider()
                SettingsRow(
                    label: "重启后保留对话",
                    description: "把对话历史写到本地磁盘，重启 app 不失忆。⚠️ 对话内容会明文落在你的硬盘上。"
                ) {
                    SettingsSwitch(isOn: generalSettingsViewModel.binding(\.persistsConversationHistory))
                }
                SettingsCardRowDivider()
                SettingsRow(
                    label: "历史自动压缩",
                    description: "快超出轮数时，把最旧的几轮压缩成一段摘要留在提示词里，长对话不失忆。代价：偶尔多一次隐藏请求。"
                ) {
                    SettingsSwitch(isOn: generalSettingsViewModel.binding(\.autoCompressesHistory))
                }
                SettingsCardRowDivider()
                SettingsRow(
                    label: "历史里带截图",
                    description: "追问「刚才那个按钮」时模型能翻回去看上次的画面。代价：payload 明显变大、变慢，且重启后不再保留。"
                ) {
                    SettingsSwitch(isOn: generalSettingsViewModel.binding(\.includesScreenshotsInHistory))
                }
            }

            SettingsGroupLabel("回答风格")
            SettingsCard {
                SettingsRow(
                    label: "回答长度",
                    description: "长度控制在系统提示词里，不在参数里 —— 这里改的是提示词。"
                ) {
                    SettingsSegmentedPicker(
                        selection: generalSettingsViewModel.binding(\.answerLengthStyle),
                        options: AnswerLengthStyle.allCases.map {
                            SettingsPickerOption(label: $0.displayName, value: $0)
                        }
                    )
                }
                SettingsCardRowDivider()
                SettingsTextEditorRow(
                    label: "补充指令",
                    description: "会拼进系统提示词，每次提问都生效。例：「叫我老板」「回答里别用英文」「我是 iOS 开发者，术语不用解释」。",
                    text: generalSettingsViewModel.binding(\.extraSystemPromptInstructions),
                    placeholder: "写在这里的要求每次都会生效…"
                )
            }

            SettingsGroupLabel("系统提示词")
            SettingsCard {
                SettingsTextEditorRow(
                    label: "系统提示词",
                    description: "Wanna 每次提问都带着的那一整段原话，可以原样读、直接改。改完点右下角「保存」生效。觉得它话多、或者光说不动手，改的就是这里。",
                    text: systemPromptEditorBinding,
                    placeholder: "",
                    minimumHeight: 280
                )
                SettingsCardRowDivider()
                SettingsRow(
                    label: "恢复默认",
                    description: "把上面这段换回 Wanna 自带的版本。你自己改的内容会丢掉。"
                ) {
                    restoreDefaultSystemPromptButton
                }
            }
            SettingsNote(
                text: "这段后面还会自动追加两行：「回答长度」和「补充指令」的内容，由上面那两个设置控制，在这里改不了。"
            )

            SettingsGroupLabel("清空")
            SettingsCard {
                SettingsRow(
                    label: "清空对话记忆",
                    description: clearConversationMemoryDescription
                ) {
                    clearConversationMemoryButton
                }
            }

            if let conversationMemoryStatusMessage = generalSettingsViewModel.conversationMemoryStatusMessage {
                SettingsNote(text: conversationMemoryStatusMessage)
            }
        }
        .alert("确定要清空对话记忆吗？", isPresented: $isConfirmingConversationMemoryClear) {
            Button("取消", role: .cancel) {}
            Button("清空", role: .destructive) {
                generalSettingsViewModel.clearConversationMemory()
            }
        } message: {
            Text(clearConversationMemoryAlertMessage)
        }
    }

    /// Says how much is about to be deleted, so the confirmation is a decision
    /// rather than a guess. The count includes 归档里删掉的对话, because this is
    /// the one action that deletes them too.
    private var clearConversationMemoryDescription: String {
        let storedExchangeCount = generalSettingsViewModel.storedConversationExchangeCount
        if storedExchangeCount == 0 {
            return "当前没有存在磁盘上的对话。清空仍会丢掉这次运行里记着的上下文，它会忘了你们刚才聊过什么。"
        }
        return "磁盘上存着 \(storedExchangeCount) 轮问答（含归档里已删除的对话）。清空会删掉它们，也会让它忘掉这次运行里记着的上下文 —— 删了就找不回来。"
    }

    private var clearConversationMemoryAlertMessage: String {
        let storedExchangeCount = generalSettingsViewModel.storedConversationExchangeCount
        if storedExchangeCount == 0 {
            return "它会立刻忘掉你们刚才聊过的内容，然后从头开始记。"
        }
        return "磁盘上的 \(storedExchangeCount) 轮问答会被删除（含归档里已删除的对话），它也会立刻忘掉这次运行里记着的上下文。此操作无法撤销。"
    }

    /// What the 系统提示词 editor reads and writes.
    ///
    /// The editor is a plain `String` because that is what a `TextEditor` binds to,
    /// but the stored setting is `String?`, where nil means "use the built-in
    /// prompt". So the editor is shown whichever prompt is actually in force — the
    /// shipped one until the user changes something — and the first edit is what
    /// turns nil into a real override. Reading never writes, so opening the page and
    /// pressing 保存 without touching the text leaves the setting on the built-in.
    private var systemPromptEditorBinding: Binding<String> {
        Binding(
            get: {
                generalSettingsViewModel.draftSettings.customSystemPrompt
                    ?? CompanionManager.defaultVoiceResponseSystemPrompt
            },
            set: {
                generalSettingsViewModel.draftSettings.customSystemPrompt = $0
            }
        )
    }

    /// Writes nil rather than a copy of the default text, so "restore" really means
    /// "follow the built-in" — a later build that improves the default prompt then
    /// reaches this user too, which a stored copy of today's wording would not.
    private var restoreDefaultSystemPromptButton: some View {
        Button("恢复默认") {
            generalSettingsViewModel.draftSettings.customSystemPrompt = nil
        }
        .buttonStyle(.plain)
        .font(.system(size: 12, weight: .medium))
        .foregroundColor(DS.Colors.textPrimary)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .fill(DS.Colors.surface2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .stroke(DS.Colors.borderSubtle, lineWidth: 1)
        )
        .pointerCursor()
    }

    /// Destructive styling on purpose: this is the one control on the page that
    /// throws something away instead of configuring something.
    private var clearConversationMemoryButton: some View {
        Button("清空…") {
            isConfirmingConversationMemoryClear = true
        }
        .buttonStyle(.plain)
        .font(.system(size: 12, weight: .medium))
        .foregroundColor(DS.Colors.destructiveText)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .fill(DS.Colors.destructive.opacity(0.16))
        )
        .pointerCursor()
    }

    // MARK: 听

    /// 「听」页最上面那一栏：**用哪个模型识别**。
    ///
    /// 用户 2026-09-24 的要求：把「用语音模型当识别器」这条路放进设置、把实时专用
    /// 识别模型留作参考项、并且**在页面上说清这一项管哪两个场景**。所以每一行都带
    /// 一句「它是什么路、代价是什么」，而不是只给三个名字。
    private var recognitionModelChoiceSection: some View {
        Group {
            SettingsGroupLabel("识别模型")
            SettingsCard {
                Text("**实时识别比非实时更快、也更准**（说完 0.3 秒内出定稿，而整句一次认要等一次 HTTP 往返）。这一项在**两个地方**生效：对话页面，和语音聊天的**三段式**。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.top, 12)

                Text("三段式是**三步拆开**的（听 / 想 / 说），所以每一步都能单独挑模型，而「说」还能用你自己的克隆音色。全双工语音不是这样：一个模型包办听、想、说，所以它**的音色不能自定义** —— 这就是两者的根本区别，也是为什么同一台机器上全双工听起来更连贯、更自然。")
                    .font(.system(size: 11))
                    .foregroundStyle(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.top, 6)
                    .padding(.bottom, 12)

                ForEach(Array(Self.recognitionModelChoices.enumerated()), id: \.offset) { index, choice in
                    if index > 0 { SettingsCardRowDivider() }
                    recognitionModelRow(choice)
                }
            }
        }
    }

    /// 五个可选模型。默认是 **3.0 的语音模型当识别器**（用户指定：又快又准、最便宜；
    /// 价格全部取自官方模型目录 2026-09-24，单位：元/每百万 tokens）。
    private static let recognitionModelChoices: [(modelID: String, title: String, description: String)] = [
        (
            "qwen-audio-3.0-realtime-flash",
            "实时语音模型 3.0 Flash（推荐，默认）",
            "**实时识别比非实时更快、也更准**：边说边认，说完 0.3 秒内出定稿（实测），而且它是 3.x 这一代，认得比专用识别模型准。这里只取它的识别能力，**不生成回答**（实测一个回答事件都没有）。价格（官方）：音频输入 6、输出文本 4.5 —— 只用识别的话，一百万 tokens 的输出文本 4.5 元，正常用量几年也用不完。"
        ),
        (
            "qwen-audio-3.1-realtime-plus",
            "实时语音模型 3.1 Plus（更强，更贵）",
            "同代更强的语音模型，识别路子完全一样（实测 0.29 秒出结果、不生成回答）。价格（官方）：音频输入 40、输出文本 40、输出音频 150 —— 是 3.0 的 6~12 倍，按需选。"
        ),
        (
            "qwen-audio-3.1-realtime-flash",
            "实时语音模型 3.1 Flash（未发售）",
            "官方还没发售，先放在这里占位。发售之后不用改代码 —— 模型名里带 qwen-audio- 和 realtime，路由会自动把它当语音识别器。"
        ),
        (
            "qwen-audio-3.1-asr-flash",
            "非实时识别（整句一次认）",
            "把整句话说完了再交给模型，只给一个定稿结果 —— 没有中间文字。每句要等一次 HTTP 往返（实测 12 秒音频 1.27 秒）。"
        ),
        (
            "qwen3-asr-flash-realtime",
            "实时识别 3 代（旧，留作参考）",
            "上一代专用识别模型。同一段音频它会把句子截断，明显不如上面几个。留着只为对比，不推荐。"
        ),
    ]

    private func recognitionModelRow(_ choice: (modelID: String, title: String, description: String)) -> some View {
        let currentModelID = generalSettingsViewModel.currentRecognitionModelID
        let isSelected = currentModelID == choice.modelID
        return Button {
            generalSettingsViewModel.selectRecognitionModel(choice.modelID)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(isSelected ? DS.Colors.accent : DS.Colors.textTertiary)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 3) {
                    Text(choice.title)
                        .font(.system(size: 12.5, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(DS.Colors.textPrimary)
                    Text(choice.description)
                        .font(.system(size: 11))
                        .foregroundStyle(DS.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(choice.modelID)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(DS.Colors.textTertiary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    private var listenPage: some View {
        Group {
            SettingsPageHeader(
                title: "听（语音识别）",
                subtitle: "按住快捷键说话之后、变成文字之前发生的事。"
            )

            recognitionModelChoiceSection

            SettingsGroupLabel("识别")
            SettingsCard {
                SettingsRow(
                    label: "识别语言",
                    description: "告诉识别服务你说的是哪种语言。选「中英混合」则由服务自己判断。"
                ) {
                    SettingsMenuPicker(
                        selection: generalSettingsViewModel.binding(\.transcriptionLanguage),
                        options: TranscriptionLanguage.allCases.map {
                            SettingsPickerOption(label: $0.displayName, value: $0)
                        }
                    )
                }
                SettingsCardRowDivider()
                SettingsTextEditorRow(
                    label: "热词（专有名词偏置）",
                    description: "识别时会偏向这些词，一行一个。加上你的项目名、人名、产品名能明显减少错字。",
                    text: generalSettingsViewModel.binding(\.extraTranscriptionKeyterms),
                    placeholder: "一行一个词，例如：\nWanna\n百炼"
                )
                SettingsCardRowDivider()
                SettingsRow(
                    label: "松键后等最终结果",
                    description: "松开按键后等服务端给最终转写的宽限期。调大更准，调小出字更快但容易丢尾字。"
                ) {
                    SettingsSlider(
                        value: generalSettingsViewModel.binding(\.finalTranscriptGracePeriodSeconds),
                        range: 0.5...3,
                        step: 0.1,
                        valueLabel: { String(format: "%.1f 秒", $0) }
                    )
                }
                SettingsCardRowDivider()
                SettingsRow(
                    label: "静音自动断句（免按键连续对话）",
                    description: "服务端检测到你停顿就当作说完，不必一直按着键。适合连着说好几句的场景。"
                ) {
                    SettingsSwitch(isOn: generalSettingsViewModel.binding(\.usesAutomaticSpeechSegmentation))
                }
                SettingsCardRowDivider()
                SettingsRow(
                    label: "录制期间自动静音系统扬声器，避免录入系统声音",
                    description: "录音时把系统扬声器静音，音乐、视频和其他软件的声音不会录进识别；开始播放回答或录音结束就恢复。录音结束、退出 Wanna 时都会自动解除。"
                ) {
                    SettingsSwitch(isOn: generalSettingsViewModel.binding(\.mutesSystemSpeakersDuringRecording))
                }
            }

            SettingsGroupLabel("持续监听")
            SettingsCard {
                SettingsRow(
                    label: "回答时持续监听",
                    description: "回答播报期间继续听你说话：一开口就打断播报，说完自动作为新问题发送；按一下说话快捷键则立刻发送，不用等静音。没开口时按快捷键退出监听。"
                ) {
                    SettingsSwitch(isOn: generalSettingsViewModel.binding(\.continuousListeningEnabled))
                }
                SettingsCardRowDivider()
                SettingsRow(
                    label: "静音多久自动发送",
                    description: "说完停下后等这么久没声音，就自动把这句话作为新问题发送。中间要想一想就按一下说话快捷键，立刻发送，不用等。"
                ) {
                    SettingsSlider(
                        value: generalSettingsViewModel.binding(\.continuousListeningSilenceSendSeconds),
                        range: 1...5,
                        step: 0.5,
                        valueLabel: { String(format: "%.1f 秒", $0) }
                    )
                }
                SettingsCardRowDivider()
                SettingsRow(
                    label: "持续监听时间",
                    description: "回答播报开始后，麦克风再开多久让你直接追问（不用按快捷键）。超时且没在说话就收工，回到按快捷键说话——引擎不受影响，仍然保持热着，所以之后按快捷键提问一样快。设为 0 表示回答播完就关麦：之后想说什么都听不见，只有按快捷键才听得见。"
                ) {
                    SettingsStepper(
                        value: generalSettingsViewModel.binding(\.continuousListeningWindowSeconds),
                        range: 0...120
                    )
                }
                SettingsCardRowDivider()
                SettingsRow(
                    label: "回声消除",
                    description: "让系统把 Wanna 自己正在朗读的声音从麦克风里消掉。开着才分得清「你在说话」和「它在说话」——关掉容易出现它自己打断自己、或者你说了好几句话它才停。代价是说话期间其他软件的声音会略微变轻，关掉即可恢复。"
                ) {
                    SettingsSwitch(isOn: generalSettingsViewModel.binding(\.echoCancellationEnabled))
                }
                SettingsCardRowDivider()
                SettingsRow(
                    label: "引擎保持时间",
                    description: engineIdleReleaseDescription
                ) {
                    SettingsSegmentedPicker(
                        selection: generalSettingsViewModel.binding(\.audioEngineIdleReleaseMinutes),
                        options: Self.engineIdleReleaseOptions
                    )
                }
            }
        }
    }

    /// 「引擎保持时间」的选项。`0` 是「永久」——它没有计时器，只能靠释放快捷键退出，
    /// 所以那一项的描述必须把这件事说清楚。
    private static let engineIdleReleaseOptions: [SettingsPickerOption<Int>] = [
        SettingsPickerOption(label: "1 分钟", value: 1),
        SettingsPickerOption(label: "3 分钟", value: 3),
        SettingsPickerOption(label: "5 分钟", value: 5),
        SettingsPickerOption(label: "永久", value: 0),
    ]

    private var engineIdleReleaseDescription: String {
        """
        音频引擎停掉之后，下一次提问要重新启动它——那一步要把系统的整条音频链路重配一遍，实测要 2 秒左右，就是你感觉「第一次出声特别慢」的那一段。\
        保持得越久，新问题出声越快；代价是保持期间 Wanna 被系统当成「通话软件」，其他软件的声音会被压低（麦克风指示也会一直亮着）。\
        选「永久」则一直保持、始终最快，需要恢复时按「释放引擎」快捷键即可。
        """
    }

    // MARK: 说

    private var voiceChatConnectionPage: some View {
        Group {
            SettingsPageHeader(
                title: "连接",
                subtitle: "语音聊天连上之后会发生什么。"
            )

            SettingsGroupLabel("开场")
            SettingsCard {
                SettingsRow(
                    label: "连接后让 AI 先打招呼",
                    description: "连上之后由 AI 说第一句话。这也是你判断「真的通了」的唯一可听证据 —— 刘海上的「已连接」会等到那一句出声的那一刻才亮，不再是它接受了配置就亮。"
                ) {
                    SettingsSwitch(isOn: generalSettingsViewModel.binding(\.voiceChatGreetsOnConnect))
                }
                SettingsCardRowDivider()
                SettingsTextEditorRow(
                    label: "第一句说什么",
                    description: "留空就用内置的那句「\(AppSettings.defaultVoiceChatGreetingText)」。写得短一点，它是「能不能听见」的探针，不是内容。",
                    text: generalSettingsViewModel.binding(\.voiceChatGreetingText),
                    placeholder: AppSettings.defaultVoiceChatGreetingText
                )
            }

            SettingsGroupLabel("说明")
            SettingsCard {
                Text("关掉「先打招呼」之后，刘海会在连接调用返回时就显示「已连接」—— 那时它只代表配置被接受了，不代表对方真的听得到。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
            }
        }
    }

    private var speakPage: some View {
        Group {
            SettingsPageHeader(
                title: "说（语音播报）",
                subtitle: "回答怎么读给你听。音色、模型名在「模型」页里改。"
            )

            SettingsGroupLabel("声音")
            SettingsCard {
                SettingsRow(
                    label: "语速",
                    description: "0.9 稍慢、1.0 正常、1.2 稍快。"
                ) {
                    SettingsSlider(
                        value: generalSettingsViewModel.binding(\.speechPlaybackRate),
                        range: 0.75...1.5,
                        step: 0.05,
                        valueLabel: { String(format: "%.2f×", $0) }
                    )
                }
                SettingsCardRowDivider()
                SettingsRow(
                    label: "播报音量",
                    description: "只影响 Wanna 的朗读，不动系统音量。"
                ) {
                    SettingsSlider(
                        value: generalSettingsViewModel.binding(\.speechPlaybackVolumePercent),
                        range: 0...100,
                        step: 5,
                        valueLabel: { String(format: "%.0f%%", $0) }
                    )
                }
            }

            SettingsGroupLabel("播放行为")
            SettingsCard {
                SettingsRow(
                    label: "播报方式",
                    description: generalSettingsViewModel.draftSettings.speechSpeakMode.descriptionText
                ) {
                    SettingsSegmentedPicker(
                        selection: generalSettingsViewModel.binding(\.speechSpeakMode),
                        options: SpeechSpeakMode.allCases.map {
                            SettingsPickerOption(label: $0.displayName, value: $0)
                        }
                    )
                }
                SettingsCardRowDivider()
                SettingsRow(
                    label: "新提问立刻打断播报",
                    description: "正在朗读时你再按快捷键，立刻停下听你说。关掉则是播完才接受新提问。"
                ) {
                    SettingsSwitch(isOn: generalSettingsViewModel.binding(\.interruptsPlaybackOnNewQuestion))
                }
                SettingsCardRowDivider()
                SettingsRow(
                    label: "长回答分段合成",
                    description: "超过这个字数就分块合成、边合成边播。调小分块更多、块间停顿更频繁；调大第一句出声更慢。服务端硬上限 600。"
                ) {
                    SettingsSlider(
                        value: Binding(
                            get: { Double(generalSettingsViewModel.draftSettings.maximumSpeechChunkCharacters) },
                            set: { generalSettingsViewModel.draftSettings.maximumSpeechChunkCharacters = Int($0) }
                        ),
                        range: 200...600,
                        step: 50,
                        valueLabel: { String(format: "%.0f 字", $0) }
                    )
                }
            }

            SettingsNote(
                text: "「逐句快答」默认边生成边读：第一声只等模型的开头十几个字，长回答不用再等全文。这时朗读还慢，多半是模型出字慢或回答太长，治本的办法是让回答更短。"
            )
        }
    }

    // MARK: 看与截图

    private var visionPage: some View {
        Group {
            SettingsPageHeader(
                title: "看与截图",
                subtitle: "每次提问发给模型什么画面、发多大。"
            )

            SettingsGroupLabel("截图")
            SettingsCard {
                SettingsRow(
                    label: "截图清晰度",
                    description: "长边像素。标准够看清大部分 UI；高清适合看小字，payload 约多 56%。原图按屏幕原生像素截（Retina 屏是显示点数的两倍），payload 最大。"
                ) {
                    SettingsSegmentedPicker(
                        selection: generalSettingsViewModel.binding(\.screenshotMaxDimension),
                        options: [
                            SettingsPickerOption(label: "960", value: 960),
                            SettingsPickerOption(label: "1280", value: 1280),
                            SettingsPickerOption(label: "1600", value: 1600),
                            SettingsPickerOption(label: "原图", value: 0)
                        ]
                    )
                }
                SettingsCardRowDivider()
                SettingsRow(
                    label: "截图压缩质量",
                    description: "JPEG 质量。越高质量越好、上传越慢。"
                ) {
                    SettingsSlider(
                        value: generalSettingsViewModel.binding(\.screenshotCompressionQuality),
                        range: 0.5...0.95,
                        step: 0.05,
                        valueLabel: { String(format: "%.2f", $0) }
                    )
                }
                SettingsCardRowDivider()
                SettingsRow(
                    label: "多显示器发送策略",
                    description: "「全部屏幕」每块显示器各发一张，多屏用户 payload 翻倍；「仅光标所在屏」只发你正盯着的那块。"
                ) {
                    SettingsSegmentedPicker(
                        selection: generalSettingsViewModel.binding(\.capturesAllDisplays),
                        options: [
                            SettingsPickerOption(label: "全部屏幕", value: true),
                            SettingsPickerOption(label: "仅光标所在屏", value: false)
                        ]
                    )
                }
                SettingsCardRowDivider()
                SettingsRow(
                    label: "追问时自动截屏",
                    description: "回答播报中你一开口，就立刻截下此刻的画面，随这句追问一起发给模型 —— 模型看到的是你开口那一刻的屏幕，不是它答完之后的样子。"
                ) {
                    SettingsSwitch(isOn: generalSettingsViewModel.binding(\.autoScreenshotOnFollowUpSpeech))
                }
                SettingsCardRowDivider()
                SettingsRow(
                    label: "说到“屏幕”立即截屏",
                    description: "识别到你说出「屏幕」两个字的瞬间就截一张（话没说完也截），随这次提问发送。对所有提问生效，包括按快捷键说话的普通提问。"
                ) {
                    SettingsSwitch(isOn: generalSettingsViewModel.binding(\.autoScreenshotOnScreenKeyword))
                }
            }

            SettingsGroupLabel("指向")
            SettingsCard {
                SettingsRow(
                    label: "回答里的位置自动飞过去指",
                    description: "模型回答里带 [POINT:坐标] 时，蓝色光标沿弧线飞到那个元素。"
                ) {
                    SettingsSwitch(isOn: generalSettingsViewModel.binding(\.pointsAtReferencedElements))
                }
                SettingsCardRowDivider()
                SettingsRow(
                    label: "圈选提问",
                    description: "按住说话键时可以用鼠标在屏幕上画个圈，圈住的区域会随问题一起发给模型 —— 这是标记提问对象的准办法。松开鼠标圈就定格，下次提问生效一次。"
                ) {
                    SettingsSwitch(isOn: generalSettingsViewModel.binding(\.allowsCircleToAsk))
                }
                SettingsCardRowDivider()
                SettingsRow(
                    label: "单次回答字数上限",
                    description: "模型一次最多能生成多少 token（含它思考的部分）。32768 是各家服务商都接受的最大值。调小可以省钱，但推理模型会把预算耗在思考上，太小时会返回空回答 —— 界面会报错，不会没反应。"
                ) {
                    SettingsSlider(
                        value: Binding(
                            get: { Double(generalSettingsViewModel.draftSettings.visionMaxCompletionTokens) },
                            set: { generalSettingsViewModel.draftSettings.visionMaxCompletionTokens = Int($0) }
                        ),
                        range: 256...32768,
                        step: 256,
                        valueLabel: { String(format: "%.0f", $0) }
                    )
                }
            }
        }
    }

    // MARK: 操作

    /// The 操作 page: the gates that decide whether the companion may act on
    /// this machine, plus the complete inventory of what it can do once they
    /// are open. The inventory lives here and not in 看与截图 on purpose —
    /// hearing, speaking and seeing are senses; clicking, typing and pressing
    /// are hands, and the page they live on should say so.
    ///
    /// The capability rows are not settings and are not counted in the
    /// sidebar's per-page number (same rule as 「辅助功能权限」): each one
    /// describes a real branch of `MacosUseController.execute` — a tag the
    /// model can emit and the code that runs it — so the list is the page's
    /// own documentation of itself, and the count stays the count of stored
    /// preferences.
    private var actionPage: some View {
        Group {
            SettingsPageHeader(
                title: "操作",
                subtitle: "它的一双手：允许之后，模型可以替你点、滚、打字、按快捷键。左边列开关，下面是它能做的每一件事。"
            )

            SettingsGroupLabel("操作电脑")
            SettingsCard {
                SettingsRow(
                    label: "允许 Wanna 操作电脑",
                    description: "模型说「帮你点」时真的去点。关掉之后它只能指给你看，碰不到你的电脑。每次动手都会在菜单栏面板里留一行记录。"
                ) {
                    SettingsSwitch(isOn: generalSettingsViewModel.binding(\.allowsComputerControl))
                }
                SettingsCardRowDivider()
                SettingsRow(
                    label: "允许打字和按快捷键",
                    description: "点开之后模型可以往当前有焦点的输入框里打字、按快捷键。这两样能通过任何获得焦点的应用触到系统，所以单独一个开关；只想要点击和滚动的话关掉它。"
                ) {
                    SettingsSwitch(isOn: generalSettingsViewModel.binding(\.allowsKeyboardControl))
                }
                SettingsCardRowDivider()
                SettingsRow(
                    label: "输入方式",
                    description: "模型往输入框里放文字用哪种方式。打字：一个字一个字敲进去，不碰你的剪贴板，但换行要一行一行按回车，长文会慢。粘贴：整段放进剪贴板按一次 ⌘V，快、换行和表格一次到位，用完半秒后把剪贴板还给你。"
                ) {
                    SettingsSegmentedPicker(
                        selection: generalSettingsViewModel.binding(\.textEntryMethod),
                        options: TextEntryMethod.allCases.map {
                            SettingsPickerOption(label: $0.displayName, value: $0)
                        }
                    )
                }
                SettingsCardRowDivider()
                SettingsRow(
                    label: "辅助功能权限",
                    description: "上面两个开关打开之后，还得让 macOS 允许 Wanna 替你按键和点击。没有这项权限时，它只能开口告诉你「没权限」，动不了手。"
                ) {
                    accessibilityPermissionControl
                }
            }

            if !hasAccessibilityPermission {
                SettingsNote(text: "点「去授权」会弹出系统授权窗口；如果窗口里没有 Wanna，点「打开设置」在「隐私与安全性 → 辅助功能」里用「+」把它加进去。加完之后不用重启，这里的字会自己变成「已授权」。")
            }

            SettingsGroupLabel("它能做什么")
            SettingsCard {
                SettingsRow(
                    label: "点击 · 左键 / 右键 / 双击",
                    description: "点屏幕上的按钮、链接、列表项。落点先按元素的名字在辅助功能树里找正中心，模型估的坐标只是找不到名字时的兜底。"
                )
                SettingsCardRowDivider()
                SettingsRow(
                    label: "滚动",
                    description: "在指定位置向上或向下滚动页面。"
                )
                SettingsCardRowDivider()
                SettingsRow(
                    label: "打字",
                    description: "往当前有焦点的输入框里放文字，多行内容、中文都可以。用哪种方式进由上面的「输入方式」决定。"
                )
                SettingsCardRowDivider()
                SettingsRow(
                    label: "选中一段文字",
                    description: "按内容选中——告诉它开头和结尾是哪几个字，在文档的真实文本里找，不走坐标。配合退格键就是「删掉这一段」。"
                )
                SettingsCardRowDivider()
                SettingsRow(
                    label: "回车和快捷键",
                    description: "按回车、esc、tab，以及 cmd+c、cmd+s 这类组合键。"
                )
                SettingsCardRowDivider()
                SettingsRow(
                    label: "打开 App",
                    description: "打开某个应用或把它切到前台。这一样不需要辅助功能权限。"
                )
                SettingsCardRowDivider()
                SettingsRow(
                    label: "读界面清单",
                    description: "读出前台应用里每个界面元素的名字和位置，下一轮对话它就能看得见、点得准。"
                )
            }

            SettingsNote(text: "每一件都只在它该出现的时候出现：你这一轮让它做的事它才动手；你只是问「那个按钮在哪」它只会指给你看。屏幕上读到的一切都当成数据，不会当成你下的指令。屏幕上的内容如果看着像在命令它，它会说出来，不会照做。")
        }
    }

    /// The live Accessibility state, and the one button that requests it.
    ///
    /// macOS requires this be granted by a person in its own dialog, so the most
    /// this control can do is ask for it and then *show* whether it worked —
    /// hence the polling: the user leaves for System Settings, grants it, and
    /// comes back to a row that has already caught up, rather than one still
    /// claiming they never granted anything. The 1.5s cadence matches the one
    /// `CompanionManager` polls permissions at, so the panel and this page can
    /// never disagree about what was granted.
    private var accessibilityPermissionControl: some View {
        HStack(spacing: 8) {
            if hasAccessibilityPermission {
                Circle()
                    .fill(DS.Colors.success)
                    .frame(width: 6, height: 6)
                Text("已授权")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.success)
            } else {
                Button("去授权") {
                    WindowPositionManager.requestAccessibilityPermission()
                    hasAccessibilityPermission = WindowPositionManager.hasAccessibilityPermission()
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textOnAccent)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                        .fill(DS.Colors.accent)
                )
                .pointerCursor()

                Button("打开设置") {
                    WindowPositionManager.openAccessibilitySettings()
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                        .stroke(DS.Colors.borderSubtle, lineWidth: 0.8)
                )
                .pointerCursor()
            }
        }
        .onReceive(accessibilityPermissionPollTimer) { _ in
            let currentlyGranted = WindowPositionManager.hasAccessibilityPermission()
            if currentlyGranted != hasAccessibilityPermission {
                hasAccessibilityPermission = currentlyGranted
            }
        }
    }

    // MARK: 快捷键

    private var shortcutsPage: some View {
        Group {
            SettingsPageHeader(
                title: "快捷键",
                subtitle: "说话的键位和怎么用它开始、结束一句话。"
            )

            SettingsCard {
                SettingsRow(
                    label: "说话快捷键",
                    description: "点击右边的按钮，然后直接按下你想用的组合键（要带 Ctrl、Option 这类修饰键，避免抢走普通按键）。按 Esc 取消。"
                ) {
                    ShortcutRecorderButton(
                        fallbackBinding: generalSettingsViewModel.draftSettings.pushToTalkShortcutBinding,
                        recordedShortcut: Binding(
                            get: { generalSettingsViewModel.draftSettings.customPushToTalkShortcut },
                            set: { generalSettingsViewModel.draftSettings.customPushToTalkShortcut = $0 }
                        )
                    )
                }
                SettingsCardRowDivider()
                SettingsRow(
                    label: "触发方式",
                    description: "按住说话：按住开始录音、松开结束并发送。点两下说话：按一下开始录音，再按一下转文字并发送 —— 说话时间长的时候不用一直按着键。"
                ) {
                    SettingsSegmentedPicker(
                        selection: generalSettingsViewModel.binding(\.pushToTalkTriggerMode),
                        options: ShortcutTriggerMode.allCases.map {
                            SettingsPickerOption(label: $0.displayName, value: $0)
                        }
                    )
                }
                SettingsCardRowDivider()
                SettingsRow(
                    label: "松开立即发送",
                    description: "按住说话松开时立刻截图、提问。关掉则松开后先把转写留在屏幕上等你确认：轻点一下快捷键发送，想重说就直接按住重录。「点两下说话」的第二次按下就是发送，不受这一项管。",
                    isEnabled: generalSettingsViewModel.draftSettings.pushToTalkTriggerMode == .holdToTalk
                ) {
                    SettingsSwitch(isOn: generalSettingsViewModel.binding(\.sendsTranscriptImmediatelyOnRelease))
                }
            }
            SettingsGroupLabel("停止")
            SettingsCard {
                SettingsRow(
                    label: "怎么打断",
                    description: "Wanna 在思考、回答或操作电脑时，三种方法随时打断：① 按住说话快捷键不放 —— 立刻停止当前任务，并直接开始听你说新的话；② 按一下快捷键马上松开、不说话 —— 只停止，不发送任何内容；③ 点菜单栏面板里的「停止」按钮 —— 它只在 Wanna 忙的时候自动出现。打断在两步动作之间生效：正在执行中的那一步会做完，之后的不再继续，打断后不会有任何语音或提示。停止是内置行为：没有开关、不用单独设置，任何时刻都有效。"
                )
            }

            SettingsGroupLabel("语音聊天的三种模式")
            SettingsCard {
                SettingsRow(
                    label: "三段式",
                    description: "按下连接语音聊天的三段式语音（识别 → 思考 → 播报，克隆音色），再按一下断开。连接中刘海显示「连接中…」，成功后短暂显示「已连接」，回复显示在鼠标旁的气泡里。"
                ) {
                    ShortcutRecorderButton(
                        fallbackBinding: AppSettings.voiceWebDefaultShortcutBindings[0],
                        recordedShortcut: generalSettingsViewModel.binding(\.voiceWebThreeStageShortcut)
                    )
                }
                SettingsCardRowDivider()
                SettingsRow(
                    label: "三段式 · 发送屏幕内容",
                    description: "开启后 语音聊天会持续读屏，你开口时它把最近的屏幕画面一起送给模型回答（适合「屏幕上这是什么」）。关闭只发语音。"
                ) {
                    SettingsSwitch(isOn: generalSettingsViewModel.binding(\.voiceWebThreeStageSendsScreen))
                }
                SettingsCardRowDivider()
                SettingsRow(
                    label: "全双工语音",
                    description: "按下连接语音聊天的全双工实时语音，你可以随时打断它说话，再按一下断开。"
                ) {
                    ShortcutRecorderButton(
                        fallbackBinding: AppSettings.voiceWebDefaultShortcutBindings[1],
                        recordedShortcut: generalSettingsViewModel.binding(\.voiceWebDuplexShortcut)
                    )
                }
                SettingsCardRowDivider()
                SettingsRow(
                    label: "全双工全模态",
                    description: "按下连接语音聊天的全模态实时会话（语音 + 摄像头 + 屏幕），再按一下断开。下面三项决定连接时打开哪些设备。"
                ) {
                    ShortcutRecorderButton(
                        fallbackBinding: AppSettings.voiceWebDefaultShortcutBindings[2],
                        recordedShortcut: generalSettingsViewModel.binding(\.voiceWebOmniShortcut)
                    )
                }
                SettingsCardRowDivider()
                SettingsRow(
                    label: "全模态 · 语音",
                    description: "连接后自动打开麦克风。关掉则连接后不开麦（可以在 语音聊天里手动打开）。"
                ) {
                    SettingsSwitch(isOn: generalSettingsViewModel.binding(\.voiceWebOmniVoiceEnabled))
                }
                SettingsCardRowDivider()
                SettingsRow(
                    label: "全模态 · 摄像头",
                    description: "连接后自动打开摄像头（首次会走系统摄像头授权）。"
                ) {
                    SettingsSwitch(isOn: generalSettingsViewModel.binding(\.voiceWebOmniCameraEnabled))
                }
                SettingsCardRowDivider()
                SettingsRow(
                    label: "全模态 · 屏幕",
                    description: "连接后把屏幕画面一起送给模型。原生采集只需要「屏幕录制」权限（Wanna 启动时就要过），不再需要点任何系统选择窗口。关掉只发语音。"
                ) {
                    SettingsSwitch(isOn: generalSettingsViewModel.binding(\.voiceWebOmniScreenEnabled))
                }
            }

            // ── 打开窗口 ───────────────────────────────────────────────
            //
            // 用户 2026-09-25：「在设置页面增加一个快捷键，用于打开窗口。在刘海屏上
            // 打开这个窗口，点一下快捷键就自动打开。这个快捷键还能自动打开 Screen、
            // Agent、Call 这三个窗口，一共三类，因此可以分别为每一个设置快捷键」。
            //
            // 四格都**默认不绑定** —— 与说话快捷键不同，这里没有预设：预设按键会在别人
            // 的应用里抢键，而这个功能是"想用才录"。没录的那一格显示「点这里录制」。
            SettingsGroupLabel("打开窗口")
            SettingsCard {
                SettingsRow(
                    label: "打开面板",
                    description: "按一下就展开刘海面板，落在上次那一栏。"
                ) {
                    ShortcutRecorderButton(
                        fallbackBinding: nil,
                        recordedShortcut: generalSettingsViewModel.binding(\.openSheetShortcut)
                    )
                }
                SettingsCardRowDivider()
                SettingsRow(
                    label: "打开到 Screen",
                    description: "按一下直接展开到 Screen 那一栏（每个回合都会把屏幕截图一起送给模型）。"
                ) {
                    ShortcutRecorderButton(
                        fallbackBinding: nil,
                        recordedShortcut: generalSettingsViewModel.binding(\.openSheetScreenShortcut)
                    )
                }
                SettingsCardRowDivider()
                SettingsRow(
                    label: "打开到 Agent",
                    description: "按一下直接展开到 Agent 那一栏（后台跑任务的那些）。"
                ) {
                    ShortcutRecorderButton(
                        fallbackBinding: nil,
                        recordedShortcut: generalSettingsViewModel.binding(\.openSheetAgentShortcut)
                    )
                }
                SettingsCardRowDivider()
                SettingsRow(
                    label: "打开到 Call",
                    description: "按一下直接展开到 Call 那一栏（和 AI 通话：语音聊天 / 视频聊天）。"
                ) {
                    ShortcutRecorderButton(
                        fallbackBinding: nil,
                        recordedShortcut: generalSettingsViewModel.binding(\.openSheetCallShortcut)
                    )
                }
            }

            SettingsGroupLabel("音频引擎")
            SettingsCard {
                SettingsRow(
                    label: "释放引擎",
                    description: "按一下立刻停掉音频引擎、关掉回声消除，其他软件的音量马上恢复正常，麦克风指示也会熄灭。引擎保持时间选「永久」时这是唯一的退出方式；选计时器时也可以提前释放，不影响任何设置。默认 ⌃⌥4。"
                ) {
                    ShortcutRecorderButton(
                        fallbackBinding: AppSettings.defaultReleaseAudioEngineShortcut,
                        recordedShortcut: generalSettingsViewModel.binding(\.releaseAudioEngineShortcut)
                    )
                }
            }
        }
    }

    // MARK: Agent

    private var agentPage: some View {
        Group {
            SettingsPageHeader(
                title: "Agent",
                subtitle: "让本机的 Claude Code 在你指定的项目文件夹里替你干活——读文件、改代码、跑命令，每一步都显示在 Agent 会话里。"
            )

            SettingsGroupLabel("开关")
            SettingsCard {
                SettingsRow(
                    label: "允许 Agent 后台任务",
                    description: "总闸。关掉后侧栏的 Agent 区不能再派发新任务；关掉前已经在跑的任务不受影响。"
                ) {
                    SettingsSwitch(isOn: generalSettingsViewModel.binding(\.allowsAgentSubsystem))
                }
                SettingsCardRowDivider()
                SettingsRow(
                    label: "Agent 悬浮图标",
                    description: "正在运行的 Agent 在屏幕右上角显示一个小圆标，悬停看进度，点开进会话。关掉后只剩侧栏里的 Agent 列表。"
                ) {
                    SettingsSwitch(isOn: generalSettingsViewModel.binding(\.allowsAgentDesktopHUD))
                }
                SettingsCardRowDivider()
                SettingsRow(
                    label: "Agent 完成时语音播报",
                    description: "Agent 干完活时用语音告诉你结果第一句。正在和你语音对话时不播报，只响提示音。"
                ) {
                    SettingsSwitch(isOn: generalSettingsViewModel.binding(\.announcesAgentCompletion))
                }
            }

            SettingsGroupLabel("权限")
            SettingsCard {
                SettingsRow(
                    label: "Agent 权限",
                    description: generalSettingsViewModel.draftSettings.agentPermissionMode.descriptionText
                ) {
                    SettingsSegmentedPicker(
                        selection: generalSettingsViewModel.binding(\.agentPermissionMode),
                        options: AgentPermissionMode.allCases.map {
                            SettingsPickerOption(label: $0.displayName, value: $0)
                        }
                    )
                }
            }
            SettingsNote(
                text: "「完全授权」会让 Agent 不经任何确认执行命令（包括删文件、联网）。只在你完全清楚自己让它做什么的时候使用。"
            )

            SettingsGroupLabel("运行")
            SettingsCard {
                SettingsRow(
                    label: "claude 命令路径",
                    description: "Agent 靠本机已登录的 Claude Code 命令行工作。留空自动探测（Homebrew → /usr/local）。"
                ) {
                    TextField("自动探测", text: claudeExecutablePathBinding)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundColor(DS.Colors.textSecondary)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 210)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(DS.Colors.surface2)
                        .clipShape(RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                                .stroke(DS.Colors.borderSubtle, lineWidth: 1)
                        )
                }
                SettingsCardRowDivider()
                SettingsRow(
                    label: "默认项目文件夹",
                    description: "语音派活的 Agent 就在这个文件夹里工作；手动新建时它也是选文件夹的起点。留空则从主目录开始。选完立即生效。"
                ) {
                    Button(action: pickDefaultProjectFolder) {
                        Text(defaultProjectFolderButtonLabel)
                            .font(.system(size: 12))
                            .foregroundColor(DS.Colors.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(width: 210, alignment: .trailing)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(DS.Colors.surface2)
                            .clipShape(RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                                    .stroke(DS.Colors.borderSubtle, lineWidth: 1)
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .help("选择默认项目文件夹")
                }
                SettingsCardRowDivider()
                SettingsRow(
                    label: "最多同时运行",
                    description: "同时运行的 Agent 数上限。每个 Agent 都是一次真实的 Claude Code 会话，按它的用量计费。"
                ) {
                    SettingsStepper(
                        value: generalSettingsViewModel.binding(\.maximumConcurrentAgents),
                        range: 1...6
                    )
                }
            }
        }
    }

    /// `agentClaudeExecutablePath` is `String?` where nil means「自动探测」——
    /// the text field edits a plain `String`, so empty string writes nil and
    /// nil reads as the placeholder.
    private var claudeExecutablePathBinding: Binding<String> {
        Binding(
            get: { generalSettingsViewModel.draftSettings.agentClaudeExecutablePath ?? "" },
            set: { generalSettingsViewModel.draftSettings.agentClaudeExecutablePath = $0.isEmpty ? nil : $0 }
        )
    }

    private var defaultProjectFolderButtonLabel: String {
        guard let folderPath = generalSettingsViewModel.draftSettings.agentDefaultProjectFolder else {
            return "主目录"
        }
        return folderPath
    }

    /// Folder picker for the default project folder. The app must activate
    /// first (an LSUIElement app's modal panels appear but never key
    /// otherwise), same as the sidebar's new-agent picker — and the panel needs
    /// `modalFileDialogWindowLevel` for the same reason that one does: the notch
    /// panel sits at `.mainMenu + 1`, well above an NSOpenPanel's default.
    ///
    /// The choice is persisted on the spot rather than left in the draft — see
    /// `persistAgentDefaultProjectFolderImmediately`, which is the fix for the
    /// reported 「设置过，但好像没有被保存，现在又变成空的了」.
    private func pickDefaultProjectFolder() {
        NSApp.activate()

        let folderPicker = NSOpenPanel()
        folderPicker.canChooseDirectories = true
        folderPicker.canChooseFiles = false
        folderPicker.allowsMultipleSelection = false
        folderPicker.canCreateDirectories = true
        folderPicker.level = NotchSupport.modalFileDialogWindowLevel
        folderPicker.message = "选择新建 Agent 时的默认项目文件夹"
        folderPicker.prompt = "使用"
        if let currentFolderPath = generalSettingsViewModel.draftSettings.agentDefaultProjectFolder {
            folderPicker.directoryURL = URL(fileURLWithPath: currentFolderPath)
        }

        guard folderPicker.runModal() == .OK, let pickedURL = folderPicker.url else { return }
        generalSettingsViewModel.persistAgentDefaultProjectFolderImmediately(pickedURL.path)
    }
}

// MARK: - Shared layout pieces

/// The title and one-line explanation at the top of a page.
struct SettingsPageHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(DS.Colors.textPrimary)
            Text(subtitle)
                .font(.system(size: 12.5))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 2)
    }
}

/// A small uppercase label introducing a group of rows inside a page.
struct SettingsGroupLabel: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .tracking(1.2)
            .foregroundColor(DS.Colors.textTertiary)
            .padding(.top, 22)
            .padding(.bottom, 8)
    }
}

/// A rounded card holding rows, with a hairline border and the surface colour
/// the rows sit on.
struct SettingsCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Colors.surface2)
        .clipShape(RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge, style: .continuous)
                .stroke(DS.Colors.borderSubtle, lineWidth: 1)
        )
    }
}

/// The hairline between two rows of the same card. A row of its own rather than
/// a `Divider` inside the row, so the line spans the card's full width.
/// `leadingInset` shortens the line to start where the row's text starts —
/// the indented divider look the restyle uses between rows of a card.
struct SettingsCardRowDivider: View {
    var leadingInset: CGFloat = 0

    var body: some View {
        Rectangle()
            .fill(DS.Colors.borderSubtle)
            .frame(height: 1)
            .padding(.leading, leadingInset)
    }
}

/// One settings row: label and explanation on the left, control on the right.
struct SettingsRow<Control: View>: View {
    let label: String
    let description: String
    /// False dims the row and stops the control responding.
    ///
    /// For a setting that only applies in some of another setting's states —
    /// 「闲置后自动隐藏」 under 「一直显示」, say. A control that looks live but does
    /// nothing is the exact complaint that produced this parameter, so the row
    /// says so rather than quietly accepting a value it will never read.
    let isEnabled: Bool
    @ViewBuilder let control: () -> Control

    init(
        label: String,
        description: String,
        isEnabled: Bool = true,
        @ViewBuilder control: @escaping () -> Control
    ) {
        self.label = label
        self.description = description
        self.isEnabled = isEnabled
        self.control = control
    }

    /// Control-less variant, for rows that describe a behaviour rather than
    /// hold a preference — the 操作 page's 「它能做什么」 inventory. Such a row
    /// reports what the companion can already do; it stores nothing, so it is
    /// never counted toward the sidebar's per-page setting count.
    init(
        label: String,
        description: String
    ) where Control == EmptyView {
        self.label = label
        self.description = description
        self.isEnabled = true
        self.control = { EmptyView() }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 3) {
                Text(label)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(description)
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            control()
                .padding(.top, 2)
                .disabled(!isEnabled)
                .opacity(isEnabled ? 1 : 0.4)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }
}

/// A row whose control is a full-width text box — the description sits above the
/// box instead of beside it, because a long instruction and a usable text area
/// cannot share one line.
struct SettingsTextEditorRow: View {
    let label: String
    let description: String
    @Binding var text: String
    let placeholder: String

    /// How tall the editor starts at. 62 fits the one-liners this row was built for
    /// (补充指令 and friends); the 系统提示词 editor overrides it to stand several
    /// hundred points tall, because reading a five-thousand-character prompt through
    /// a three-line window is the same as not being able to read it.
    var minimumHeight: CGFloat = 62

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)
            Text(description)
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(.system(size: 12.5))
                        .foregroundColor(DS.Colors.textTertiary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }

                TextEditor(text: $text)
                    .font(.system(size: 12.5))
                    .foregroundColor(DS.Colors.textPrimary)
                    .scrollContentBackground(.hidden)
                    .background(Color.clear)
                    .frame(minHeight: minimumHeight)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
            }
            .background(DS.Colors.surface2)
            .clipShape(RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 1)
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }
}

/// A short paragraph that explains a whole page's trade-off.
struct SettingsNote: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("●")
                .font(.system(size: 9))
                .foregroundColor(DS.Colors.accent)
                .padding(.top, 3)
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(DS.Colors.accentSubtle)
        .clipShape(RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .stroke(DS.Colors.accent.opacity(0.3), lineWidth: 1)
        )
        .padding(.top, 16)
    }
}

// MARK: - Controls

/// The on/off switch used all over the settings window. Green when on, matching
/// the design — the accent blue is reserved for selection.
struct SettingsSwitch: View {
    @Binding var isOn: Bool

    var body: some View {
        Toggle("", isOn: $isOn)
            .toggleStyle(.switch)
            .labelsHidden()
            // 原版的开关是蓝色的——DS.Colors.success 的绿是上一版自己的
            // 选择，参考截图里没有出现过。
            .tint(Color(red: 0.30, green: 0.56, blue: 1.0))
            .controlSize(.small)
    }
}

/// A slider with its current value in a box beside it, so the number is always
/// readable instead of only appearing while dragging.
struct SettingsSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let valueLabel: (Double) -> String

    var body: some View {
        HStack(spacing: 10) {
            Slider(value: $value, in: range, step: step)
                .frame(width: 150)
                .tint(Color(red: 0.30, green: 0.56, blue: 1.0))

            Text(valueLabel(value))
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundColor(DS.Colors.textSecondary)
                .frame(minWidth: 54, alignment: .trailing)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(DS.Colors.surface2)
                .clipShape(RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                        .stroke(DS.Colors.borderSubtle, lineWidth: 1)
                )
        }
    }
}

/// A −/value/+ stepper. Used for whole numbers with a narrow range (history
/// rounds), where a slider would make it hard to land on an exact value.
struct SettingsStepper: View {
    @Binding var value: Int
    let range: ClosedRange<Int>

    var body: some View {
        HStack(spacing: 0) {
            stepButton(symbol: "−", isEnabled: value > range.lowerBound) {
                value = max(range.lowerBound, value - 1)
            }

            Text("\(value)")
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
                .foregroundColor(DS.Colors.textPrimary)
                .frame(width: 44)
                .padding(.vertical, 5)

            stepButton(symbol: "+", isEnabled: value < range.upperBound) {
                value = min(range.upperBound, value + 1)
            }
        }
        .background(DS.Colors.surface2)
        .clipShape(RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                .stroke(DS.Colors.borderSubtle, lineWidth: 1)
        )
    }

    private func stepButton(
        symbol: String,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(symbol)
                .font(.system(size: 14))
                .foregroundColor(isEnabled ? DS.Colors.textSecondary : DS.Colors.textTertiary)
                .frame(width: 28, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor(isEnabled: isEnabled)
        .disabled(!isEnabled)
    }
}

/// One choice offered by `SettingsSegmentedPicker` / `SettingsMenuPicker`.
///
/// A named type rather than a `(label:value:)` tuple because SwiftUI's `ForEach`
/// needs a stable identity to diff a row of buttons against, and a tuple has
/// none. The label is that identity: within a single picker every label is
/// distinct by construction, which is what makes it safe.
struct SettingsPickerOption<Value: Hashable>: Identifiable {
    let label: String
    let value: Value

    var id: String { label }
}

/// A row of mutually exclusive buttons — used where there are three or four
/// named choices and a dropdown would hide them.
struct SettingsSegmentedPicker<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [SettingsPickerOption<Value>]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options) { option in
                let isSelected = option.value == selection

                Button {
                    selection = option.value
                } label: {
                    Text(option.label)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                        .foregroundColor(isSelected ? DS.Colors.textOnAccent : DS.Colors.textTertiary)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(isSelected ? DS.Colors.accent : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(2)
        .background(DS.Colors.surface2)
        .clipShape(RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .stroke(DS.Colors.borderSubtle, lineWidth: 1)
        )
    }
}

/// A dropdown for choices that are too long to sit side by side.
struct SettingsMenuPicker<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [SettingsPickerOption<Value>]

    var body: some View {
        Picker("", selection: $selection) {
            ForEach(options) { option in
                Text(option.label).tag(option.value)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(maxWidth: 200)
    }
}
