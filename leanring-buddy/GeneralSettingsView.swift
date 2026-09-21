//
//  GeneralSettingsView.swift
//  leanring-buddy
//
//  The six pages of the settings window that are not 模型 — 通用, 对话与记忆, 听,
//  说, 看与截图, 快捷键 — plus the shared row/card/control pieces they are built
//  from.
//
//  Layout follows the approved design: a page header, small uppercase group
//  labels, and cards whose rows put a label + explanation on the left and the
//  control on the right. The shared pieces exist so every row lines up the same
//  way and a new setting costs one row, not one layout.
//

import SwiftUI

/// One page of the settings window. The sidebar renders these in order.
enum SettingsPage: String, CaseIterable, Identifiable {
    case general
    case model
    case memory
    case listen
    case speak
    case vision
    case shortcuts

    var id: String { rawValue }

    var sidebarTitle: String {
        switch self {
        case .general: return "通用"
        case .model: return "模型"
        case .memory: return "对话与记忆"
        case .listen: return "听（识别）"
        case .speak: return "说（播报）"
        case .vision: return "看与截图"
        case .shortcuts: return "快捷键"
        }
    }

    var sidebarEmoji: String {
        switch self {
        case .general: return "⚙️"
        case .model: return "🧠"
        case .memory: return "💬"
        case .listen: return "👂"
        case .speak: return "👄"
        case .vision: return "👁️"
        case .shortcuts: return "⌨️"
        }
    }

    /// The count shown on the right of the sidebar row — how many settings that
    /// page holds. Read from the design so the sidebar stays honest when a
    /// setting is added; 模型 is not counted here because its fields live in the
    /// model configuration rather than in `AppSettings`.
    var settingCount: Int? {
        switch self {
        case .general: return 6
        case .model: return nil
        case .memory: return 6
        case .listen: return 4
        case .speak: return 4
        case .vision: return 5
        case .shortcuts: return 2
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                switch page {
                case .general: generalPage
                case .memory: memoryPage
                case .listen: listenPage
                case .speak: speakPage
                case .vision: visionPage
                case .shortcuts: shortcutsPage
                case .model: EmptyView() // 模型 is rendered by ModelSettingsView.
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
                subtitle: "启动行为、回答怎么呈现给你。"
            )

            SettingsGroupLabel("启动")
            SettingsCard {
                SettingsRow(
                    label: "开机自启动",
                    description: "登录 Mac 时自动在菜单栏待命。"
                ) {
                    SettingsSwitch(isOn: generalSettingsViewModel.binding(\.launchesAtLogin))
                }
                SettingsCardRowDivider()
                SettingsRow(
                    label: "启动时自动打开面板",
                    description: "首次运行弹权限引导；打开这一项后每次启动都会弹出面板。"
                ) {
                    SettingsSwitch(isOn: generalSettingsViewModel.binding(\.opensPanelOnLaunch))
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
                SettingsCardRowDivider()
                SettingsRow(
                    label: "光标闲置后自动隐藏",
                    description: "关闭「显示光标」时，临时唤出的光标在说完话后多久消失。"
                ) {
                    SettingsSlider(
                        value: generalSettingsViewModel.binding(\.transientCursorHideDelaySeconds),
                        range: 0.5...5,
                        step: 0.5,
                        valueLabel: { String(format: "%.1f 秒", $0) }
                    )
                }
            }

            SettingsNote(
                text: "「开机自启动」和「回答时显示文字」是这两页里影响最直接的两项：一个决定它在不在，一个决定你听得见之外还看不看得见。"
            )
        }
    }

    // MARK: 对话与记忆

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
    /// rather than a guess.
    private var clearConversationMemoryDescription: String {
        let storedExchangeCount = generalSettingsViewModel.storedConversationExchangeCount
        if storedExchangeCount == 0 {
            return "当前没有存在磁盘上的对话。清空仍会丢掉这次运行里记着的上下文，它会忘了你们刚才聊过什么。"
        }
        return "磁盘上存着 \(storedExchangeCount) 轮问答。清空会删掉它们，也会让它忘掉这次运行里记着的上下文 —— 删了就找不回来。"
    }

    private var clearConversationMemoryAlertMessage: String {
        let storedExchangeCount = generalSettingsViewModel.storedConversationExchangeCount
        if storedExchangeCount == 0 {
            return "它会立刻忘掉你们刚才聊过的内容，然后从头开始记。"
        }
        return "磁盘上的 \(storedExchangeCount) 轮问答会被删除，它也会立刻忘掉这次运行里记着的上下文。此操作无法撤销。"
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

    private var listenPage: some View {
        Group {
            SettingsPageHeader(
                title: "听（语音识别）",
                subtitle: "按住快捷键说话之后、变成文字之前发生的事。"
            )

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
                    placeholder: "一行一个词，例如：\nClicky\n百炼"
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
            }
        }
    }

    // MARK: 说

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
                    description: "只影响 Clicky 的朗读，不动系统音量。"
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
                text: "朗读慢的大头不是这些参数，是「等整段回答生成完 + 合成约 2 秒」。想再快，治本的办法是让回答更短。"
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
                    description: "长边像素。标准够看清大部分 UI；高清适合看小字，payload 约多 56%。"
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

    // MARK: 快捷键

    private var shortcutsPage: some View {
        Group {
            SettingsPageHeader(
                title: "快捷键",
                subtitle: "按住说话的键位。纯修饰键组合不会和打字冲突。"
            )

            SettingsCard {
                SettingsRow(
                    label: "按住说话快捷键",
                    description: "按住开始录音、松开结束。改成别的键之后，面板上的提示文字会跟着变。"
                ) {
                    SettingsMenuPicker(
                        selection: Binding(
                            get: { generalSettingsViewModel.draftSettings.pushToTalkShortcutOption },
                            set: { generalSettingsViewModel.draftSettings.pushToTalkShortcutRawValue = $0.rawValue }
                        ),
                        options: BuddyPushToTalkShortcut.ShortcutOption.allShortcutOptions.map {
                            SettingsPickerOption(label: $0.displayText, value: $0)
                        }
                    )
                }
                SettingsCardRowDivider()
                SettingsRow(
                    label: "松开立即发送",
                    description: "松开按键立刻截图、提问。关掉则松开后先把转写留在屏幕上等你确认：轻点一下快捷键发送，想重说就直接按住重录。"
                ) {
                    SettingsSwitch(isOn: generalSettingsViewModel.binding(\.sendsTranscriptImmediatelyOnRelease))
                }
            }
        }
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
            .tracking(0.8)
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
        .background(DS.Colors.surface1)
        .clipShape(RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                .stroke(DS.Colors.borderSubtle, lineWidth: 1)
        )
    }
}

/// The hairline between two rows of the same card. A row of its own rather than
/// a `Divider` inside the row, so the line spans the card's full width.
struct SettingsCardRowDivider: View {
    var body: some View {
        Rectangle()
            .fill(DS.Colors.borderSubtle)
            .frame(height: 1)
    }
}

/// One settings row: label and explanation on the left, control on the right.
struct SettingsRow<Control: View>: View {
    let label: String
    let description: String
    @ViewBuilder let control: () -> Control

    init(label: String, description: String, @ViewBuilder control: @escaping () -> Control) {
        self.label = label
        self.description = description
        self.control = control
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
                    .frame(minHeight: 62)
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
            .tint(DS.Colors.success)
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
                .tint(DS.Colors.success)

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
