import AppKit
import Combine
import SwiftUI

/// 录音时贴在刘海上的那条东西。
///
/// 形态是用户在十个方案里选定的 A 案：
/// - **左翼**：`Record` 加一颗红点，内容贴着刘海右对齐（沿用 `Listening` 的排法）
/// - **右翼**：只有一个红色停止按钮，靠右放
/// - **刘海下方**：一行跑马灯，宽度和整条带一致，上直下圆的长方形
///
/// 跑马灯的滑动不是「整行跑完再绕回」，而是**新字不断从右边推入**：文本右对齐、
/// 超出的部分向左溢出再被裁掉，所以最新说出来的字永远停在右端可见处，旧字向左
/// 滑出并被渐隐吃掉。这和整行循环相比没有周期性的跳回，长会话里更稳。
struct NotchRecordingBandView: View {

    @ObservedObject var recorder: LongFormRecorderController
    let notchWidth: CGFloat
    let notchHeight: CGFloat

    /// 停止按钮的尺寸跟着它走。**只在说话时更新，静音时保持上一次的值** ——
    /// 用户的要求原话是「随着说话声音变大而变化，用户不说话时不再变化」，
    /// 所以这里刻意不做「静音时缓缓缩回」：那不叫「不再变化」。
    @State private var heldLevel: Double = 0

    private static let restingButtonSize: CGFloat = 17
    private static let maximumButtonSize: CGFloat = 30
    private static let ribbonHeight: CGFloat = 32

    /// 每侧向刘海**里面**压进多少。
    ///
    /// 刘海自己的**底角是圆的**（约 10pt）。两翼如果正好从刘海边缘起画，那个圆弧
    /// 处就会露出桌面的背景 —— 用户实测截图里两处缝隙都能看到。所以每侧各压进
    /// 这么多把圆角盖掉，中间那段相应变窄，**整条带的总宽不变**。
    private static let notchCornerOverlap: CGFloat = 14

    var body: some View {
        VStack(spacing: 0) {
            band
            if recorder.isTranscriptExpanded {
                expandedTranscriptPanel
            } else {
                transcriptRibbon
                    // 点这一行就展开（用户的要求：「点击下面这行文字，自动展开」）。
                    .contentShape(Rectangle())
                    .onTapGesture { recorder.toggleTranscriptEditor() }
                    .help("点一下展开，看之前的转写内容")
            }
        }
        // 外层不锁宽度：展开时下面那块比黑带宽一倍，锁定的话会被裁掉。
        .frame(maxWidth: .infinity)
        .onChange(of: recorder.audioLevel) { _, newLevel in
            if recorder.isSpeechDetected { heldLevel = newLevel }
        }
    }

    private var band: some View {
        HStack(spacing: 0) {
            leadingWing
                .frame(width: NotchSupport.leadingWingWidth + Self.notchCornerOverlap,
                       height: notchHeight)
            // 中间这段必须**填黑**，不能留透明：刘海的静止 pill 自己画着圆角，
            // 留给它透出来的话，那对圆角在带的下沿就是两个豁口。
            Rectangle()
                .fill(Color.black)
                .frame(width: max(notchWidth - Self.notchCornerOverlap * 2, 1),
                       height: notchHeight)
            trailingWing
                .frame(width: NotchSupport.trailingWingWidth + Self.notchCornerOverlap,
                       height: notchHeight)
        }
    }

    // MARK: - 左翼

    /// 两翼用**同一个宽度**。
    ///
    /// `NotchSupport` 里两翼是 86 / 88（量自原版刘海），我直接拿来用了 —— 但两翼
    /// 不等宽会让**中间那段刘海偏离面板中心 1pt**。收起时面板 361 宽、展开时 722 宽，
    /// 两次取整的方向不同，看上去就是「点一下刘海，它往右挪了几个像素」
    /// （用户报的偏移）。取两者的大值让结构左右对称，刘海段就永远居中。
    private var symmetricWingWidth: CGFloat {
        // **取两者的平均值**，不是最大值。
        //
        // 两个约束必须同时满足，而它们各自指向不同的数：
        //   ① 整条带的宽度要和 App 自己那条刘海带**一样**（86 + 185 + 88 = 359）；
        //   ② 中间的刘海段要**居中**。
        // 两翼取 86/88 满足①但不满足②（刘海偏左 1pt）；取 88/88 满足②却不满足①
        // （整条变成 361，用户看到的「转写条比刘海两侧动画宽 2px」就是这个）。
        // 取平均 87 两个都满足。
        (NotchSupport.leadingWingWidth + NotchSupport.trailingWingWidth) / 2
    }

    /// 整条带的宽度，**由对称后的两翼推出来**，不再从外面传进来 ——
    /// 传进来就会和视图里画的宽度各算一遍，两处一旦不一致就是接缝。
    private var bandWidth: CGFloat {
        NotchSupport.leadingWingWidth + notchWidth + NotchSupport.trailingWingWidth
    }

    /// 左翼按下时只用来驱动**内容**的缩放状态。
    @State private var isLeftWingPressed = false

    /// 左翼：**点击入口，但外观上一点反馈都没有。**
    ///
    /// **刻意不用 `Button`。** 用户连着两次报「点击时还是有动画、背景像被穿透」——
    /// `Button` 在 macOS 上就是会画东西的（悬停底、按下底、成为 key 窗口之后的重绘），
    /// `buttonStyle(.plain)` 治不掉，自写的空 ButtonStyle 也治不干净。
    /// `onTapGesture` 是纯手势，**一个像素的视觉反馈都没有**，正是用户要的
    /// 「不需要任何东西，只需要让它有一个功能，有一个音效就可以了」。
    private var leadingWing: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                if recorder.isFinalizingTranscript {
                    Circle()
                        .fill(Color(red: 1.0, green: 0.27, blue: 0.23))
                        .frame(width: 10, height: 10)
                        .modifier(BreathingIndicatorModifier(isActive: true))
                    Text("转写中")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundColor(.white)
                        .modifier(BreathingTextModifier())
                } else if recorder.isRecording {
                    Circle()
                        .fill(Color(red: 1.0, green: 0.27, blue: 0.23))
                        .frame(width: 10, height: 10)
                        .modifier(BreathingIndicatorModifier(isActive: true))
                    Text(recorder.formattedElapsedTime)
                        .font(.system(size: 17, weight: .bold))
                        .foregroundColor(.white)
                        .monospacedDigit()
                } else if recorder.isTranscriptExpanded {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(DS.Colors.success)
                    Text("已转写")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundColor(DS.Colors.success)
                } else {
                    Circle()
                        .fill(Color.white)
                        .frame(width: 10, height: 10)
                    Text("Record")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundColor(.white)
                }
            }
            .padding(.trailing, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        .background(Color.black)
        .contentShape(Rectangle())
        .onTapGesture {
            SoundEffectPlayer.shared.play(.recordingEditorOpened)
            recorder.toggleTranscriptEditor()
        }
        .help(recorder.isTranscriptExpanded ? "收起并保存" : "点这里编辑转写内容")
    }

    // MARK: - 右翼

    /// 右侧那颗「音符」：红色音波，**唯一可点的东西**。
    ///
    /// 用户的要求：「右侧这部分做成音符效果，也就是音波效果，红色的音波。用户
    /// 点击这个音波，自动停止录音，并有一个挂断的音效」。所以它同时是**状态指示**
    /// （红 = 在录）和**停止入口**。挂断音效由 `completeStop()` 里的
    /// `SoundEffectPlayer.shared.play(.sessionHungUp)` 负责，这里只管把点击送达。
    private var trailingWing: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            Button {
                // 倒计时期间点它 = **放弃这一场**（用户：「如果在显示数字的过程中，
                // 用户点击这个数字……就自动取消转写，包括弹窗等全都自动取消，
                // 也不需要粘贴到剪贴板，直接放弃这次任务」）。
                if recorder.isFinalizingTranscript {
                    LongFormRecorderController.shared.cancelCurrentRecording()
                    return
                }
                if recorder.isRecording {
                    LongFormRecorderController.shared.stopRecording()
                } else {
                    LongFormRecorderController.shared.startRecording(resumingCurrentSession: true)
                }
            } label: {
                RecordingWaveformLabel(
                    level: recorder.isSpeechDetected ? recorder.audioLevel : heldLevel,
                    isRecording: recorder.isRecording,
                    finalizeSecondsRemaining: recorder.isFinalizingTranscript
                        ? recorder.finalizeSecondsRemaining : nil)
            }
            // **双击 = 放弃。** 单击一次是「停止录音、进入转写」，所以「单击两次」
            // 正好等价于双击 —— 用户要的就是这个（「单击一次再单击一次，都是停止
            // 转写的效果」）。用 `simultaneousGesture` 而不是 `.onTapGesture(count: 2)`：
            // 后者会和 Button 自己的单击识别打架，两个都收不到。
            .simultaneousGesture(
                TapGesture(count: 2).onEnded {
                    LongFormRecorderController.shared.cancelCurrentRecording()
                }
            )
            .buttonStyle(.plain)
            .padding(.trailing, 16)
            .help(recorder.isRecording ? "停止录音" : "继续录音")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        .background(Color.black)
    }

    // MARK: - 跑马灯

    // MARK: - 展开面板

    /// 点开之后向下长出来的那一块：能翻看之前的文本，右上角有复制和结束。
    ///
    /// 新说的内容永远在最下面一行（`liveRow`），和展开前那一行的内容是同一份
    /// 数据，所以「实时转写」在展开状态下照样成立。
    private var expandedTranscriptPanel: some View {
        VStack(spacing: 0) {
            // 顶行 = **原来那一行实时转写留在原位**（顶部居中），左边加「转写内容」、
            // 右边加「复制」。用户的原话：「还是显示在原来的位置上，只是增加了一个
            // 弹出窗口……中间位置的左侧是撰写什么内容，右侧是复制按钮」。
            //
            // 这一行是**黑的** —— 它和上面的黑带连成一片，是刘海的延伸；
            // 再往下的正文区才是浮雕色。用户：「弹出窗口的背景颜色，最上面那行是
            // 黑色，下面按照我刚才说的那个颜色」。
            HStack(spacing: 8) {
                // 「转写内容」四个字删掉了 —— 用户：「转写的时候文字把左侧"转写内容"
                // 这几个字盖掉了。转写内容这几个字没有意义，直接删掉。复制按钮保留」。
                // 所以这一行现在只剩：中间那行实时转写 + 右边的复制。
                Spacer(minLength: 16)

                // 就是收起状态下那一行，一点没改 —— 位置、字号、左右渐隐都一样。
                // `alwaysTrails: true` —— 展开面板里这一行**始终右对齐**，
                // 右端顶到复制按钮的左边（用户：「它应该显示到复制按钮的左侧」）。
                // 刘海下那条跑马灯不传这个参数，短句仍然从左排起 —— 那里没有右边的
                // 按钮要顶，短句缩在右边才是上一轮报过的「只显示在右半部分」。
                SmoothRevealedTranscriptText(text: recorder.liveTranscriptLine,
                                             availableWidth: bandWidth * 2 - 160,
                                             textColor: DS.Colors.success,
                                             alwaysTrails: true)
                    .frame(maxWidth: .infinity)

                Spacer(minLength: 8)

                // 风格 01 的 `.btn`：面板色、10pt 圆角、3/3/7 那对影子。
                Button {
                    recorder.copyTranscriptToClipboard()
                } label: {
                    Text(recorder.didJustCopyTranscript ? "已复制" : "复制")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(recorder.didJustCopyTranscript
                                         ? EmbossMaterial.page : EmbossMaterial.textMuted)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 7)
                        .modifier(EmbossedSurface(cornerRadius: 10, depth: 3,
                                                  isPressed: recorder.didJustCopyTranscript))
                }
                .buttonStyle(.plain)
                .padding(.trailing, 16)
            }
            .frame(height: 46)
            .background(Color.black)

            // **一整个可编辑的文本**，不是一行行的列表。
            //
            // 用户的原话：「双击之后只能编辑某一行，我希望能够编辑所有的文本，
            // 而且文本之间不要换行，因为文字是连续的……现在只能显示、只能编辑
            // 某一行，体验太差了」。所以这里是一个 `TextEditor`：点哪改哪，
            // 全文连续，段落之间没有换行。
            TextEditor(text: Binding(
                get: { recorder.transcriptDraftText ?? recorder.transcriptPlainText },
                set: { recorder.transcriptDraftText = $0 }))
                .font(.system(size: 17))
                .foregroundColor(EmbossMaterial.textPrimary)
                // 用户要求「行间距稍微再增大一点」。
                .lineSpacing(9)
                .scrollContentBackground(.hidden)
                .background(Color.clear)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                // **左右两边的边框删掉** —— 用户：「展开后显示红色方框的内容，
                // 左右两边的边框删掉」。原来正文装在一张带影子的卡片里（四边都有边），
                // 现在去掉卡片，正文直接铺在窗口底上、占满整宽。
                // ⌘S 保存。不按也会在折叠时自动保存（用户要求），
                // 这个快捷键只是给一个「我确认过了」的显式动作。
                .background(
                    Button("") { recorder.saveTranscriptDraft() }
                        .keyboardShortcut("s", modifiers: .command)
                        .opacity(0)
                )
                // ESC 折叠（用户要求：「用户点击 ESC 自动折叠刚才展开的部分」）。
                .onExitCommand { recorder.collapseTranscriptEditor() }
                .padding(.bottom, 16)

            // ⌘+Enter：复制全部 + 关窗 + 结束转写，三件事一次做完。
            // 用户的要求：「按住 command 加 enter，就会复制当前所有简历内容，然后
            // 关闭弹窗，转写结束。这个按钮做三件事：复制到剪贴板、弹窗关闭、转写结束」。
            Button {
                recorder.copyTranscriptToClipboard()
                recorder.collapseTranscriptEditor()
                recorder.finishCurrentSession()
            } label: {
                EmptyView()
            }
            .keyboardShortcut(.return, modifiers: .command)
            .opacity(0)
            .frame(width: 0, height: 0)

            // **这里不再有 `transcriptRibbon`。** 那一行已经搬到顶行、和黑带连成
            // 一片了；留在底部的话，面板最下面会多出一条黑边 —— 用户报的
            // 「弹出窗口的最下面应该没有黑色，现在还有黑色」就是它。
        }
        // 展开时这块比黑带**宽一倍**（用户要求：「宽度再增加两倍，然后居中对齐」）。
        // 窗口本身在展开时也会跟着变宽 —— 见 `NotchRecordingOverlayController.panelFrame`。
        .frame(width: bandWidth * 2, height: Self.expandedPanelBodyHeight, alignment: .bottom)
        // 风格 01 · 软浮雕：窗口底 #26262b，比面板 #2e2e34 暗一档。
        // 黑带本身仍是纯黑 —— 它要和硬件刘海熔成一体，不参与材质。
        .background(EmbossMaterial.page)
        .clipShape(RecordingRibbonShape(cornerRadius: 22, roundsTopCorners: true))
    }

    private static let expandedPanelBodyHeight: CGFloat = 560

    /// 最下面那行：正在说的内容，实时更新。展开和收起时是同一条数据。
    private var liveRow: some View {
        Text(recorder.liveTranscriptLine.isEmpty ? "…" : recorder.liveTranscriptLine)
            .font(.system(size: 16, weight: .semibold))
            .foregroundColor(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 跑马灯那一条的宽度。展开时跟着面板一起变宽 —— 用户说「最下面这一行是正在
    /// 实时转写的内容，能不能让它显示得长一点，现在太窄了」。
    private var ribbonWidth: CGFloat {
        recorder.isTranscriptExpanded ? bandWidth * 2 : bandWidth
    }

    private var transcriptRibbon: some View {
        marquee
            // 内容区比整条带窄，左右各留 12pt，文字不会压到圆角上。
            .frame(width: ribbonWidth - 24, height: Self.ribbonHeight, alignment: .trailing)
            .clipped()
            .mask(
                // 左右渐出渐隐，两端各 13%。
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.0),
                        .init(color: .black, location: 0.13),
                        .init(color: .black, location: 0.87),
                        .init(color: .clear, location: 1.0),
                    ],
                    startPoint: .leading, endPoint: .trailing
                )
            )
            // 先撑回整条带的宽度，再铺黑底、按形状裁剪 —— 顺序不能换：
            // 反过来的话圆角会被外层内容盖掉。
            .frame(width: ribbonWidth, height: Self.ribbonHeight)
            .background(Color.black)
            // 展开时它是面板的最底一条，圆角由面板那一层裁；收起时才自己裁
            // （那时它的上边要和黑带无缝拼在一起，只有下圆角）。
            .clipShape(recorder.isTranscriptExpanded
                       ? AnyShape(Rectangle())
                       : AnyShape(RecordingRibbonShape(cornerRadius: 22)))
    }

    private var marquee: some View {
        // 服务端每 300–400ms 才吐一次、一次好几个字，直接铺上去就是一跳一跳。
        // 平滑揭示把「数据的粒度」和「显示的平滑度」拆开 —— 见那个视图的注释。
        SmoothRevealedTranscriptText(text: recorder.liveTranscriptLine,
                                     availableWidth: ribbonWidth - 24)
    }
}



/// 风格 01 · 软浮雕（新拟态凹凸）。
///
/// 参数逐条照抄用户给的那份参考实现
/// （`~/Doubao/chats/2026-09-24/new-chat/5种材质风格方案/5种材质风格方案.html`
/// 里 `.style-01` 那一节）：
///
/// ```css
/// body.style-01 { background:#26262b }
/// --panel:#2e2e34; --hi:rgba(255,255,255,.065); --lo:rgba(0,0,0,.5)
/// .bubble { background:var(--panel); border-radius:16px;
///           box-shadow:5px 5px 12px var(--lo), -5px -5px 12px var(--hi) }
/// .btn    { border-radius:10px; box-shadow:3px 3px 7px var(--lo), -3px -3px 7px var(--hi) }
/// .btn:active { box-shadow: inset 3px 3px 7px var(--lo), inset -3px -3px 7px var(--hi) }
/// ```
///
/// **关键在「两个方向相反的影子」。** 只有暗影是普通投影、只有高光是描边，
/// 两个一起才是「凸起来的那一块」—— 这就是新拟态的全部机制，少一个就退化成
/// 一张普通的卡片。按下时两个都翻成 `inset`，那块就从凸变成凹。
private enum EmbossMaterial {
    /// 页面底：比面板**暗**一档。新拟态要求面板和底同色系、只差明度。
    static let page = Color(hex: "#26262B")
    static let panel = Color(hex: "#2E2E34")
    static let highlight = Color.white.opacity(0.065)
    static let shadow = Color.black.opacity(0.5)
    static let textPrimary = Color(hex: "#EEF0F3")
    static let textMuted = Color(hex: "#CFD3DA")
}

/// 凸起的一块。`depth` 就是 CSS 里那对 `5px/5px/12px` 的 5。
private struct EmbossedSurface: ViewModifier {
    var cornerRadius: CGFloat = 16
    var depth: CGFloat = 5
    var isPressed = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(EmbossMaterial.panel)
            )
            .overlay(
                // 按下时用**内阴影**：这就是「凹凸」里的「凹」。
                Group {
                    if isPressed {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .stroke(EmbossMaterial.shadow, lineWidth: 4)
                            .blur(radius: 3)
                            .mask(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    }
                }
            )
            .shadow(color: isPressed ? .clear : EmbossMaterial.shadow,
                    radius: depth * 2, x: depth, y: depth)
            .shadow(color: isPressed ? .clear : EmbossMaterial.highlight,
                    radius: depth * 2, x: -depth, y: -depth)
    }
}

/// 一个**什么都不画**的按钮样式。
///
/// 用户的要求：「刘海左侧用户点击的时候不要有任何变化，颜色、背景都不要变化，
/// 但是要增加一个音效」。`buttonStyle(.plain)` **做不到**这件事 —— 它在 macOS 上
/// 仍然会画一层悬停/按下的灰底（用户截图里红框圈出来的那个灰方块就是它）。
/// 所以这里要一个真正只返回 label、不加任何装饰的样式。
private struct SilentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

/// 文字的呼吸：**只动透明度，不动缩放**（文字缩放会糊）。
/// 用户：「转写中时，'转写中'这三个字增加一个呼吸效果」。
private struct BreathingTextModifier: ViewModifier {
    @State private var isDim = false

    func body(content: Content) -> some View {
        content
            .opacity(isDim ? 0.35 : 1.0)
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: isDim)
            .onAppear { isDim = true }
    }
}

/// 红点的呼吸。用户的要求：「左侧 record 的红点也是变化的，是呼吸的状态」。
private struct BreathingIndicatorModifier: ViewModifier {
    let isActive: Bool
    @State private var isExpanded = false

    func body(content: Content) -> some View {
        content
            // 停止后**不呼吸、也不变灰** —— 就是一颗静止的白点。
            // 用户的要求：「所有动画全部停止，无论是转写、录音按钮还是音律按钮，
            // 全都停止并变成白色」。
            .opacity(isActive && isExpanded ? 0.4 : 1.0)
            .scaleEffect(isActive && isExpanded ? 0.78 : 1.0)
            .animation(
                isActive
                    ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
                    : .easeOut(duration: 0.25),
                value: isExpanded)
            .onAppear { isExpanded = isActive }
            .onChange(of: isActive) { _, newValue in isExpanded = newValue }
    }
}

/// 右侧那颗红色音波。
///
/// 用户的要求：「右侧这部分做成音符效果，也就是音波效果，红色的音波」「录音时
/// 音符按钮是红色，停止录音时是绿色」「音符也是呼吸的状态」。
///
/// 波形用 `TimelineView(.animation)` 逐帧驱动而不是 CSS 式的关键帧动画：柱子的
/// 相位要错开，而且要**同时**受时间（一直在动 = 呼吸）和电平（大声时振幅大）
/// 两个量影响，关键帧动画表达不了后者。
private struct RecordingWaveformLabel: View {
    let level: Double
    let isRecording: Bool
    /// 非 nil 时右侧不画音波，改画倒计时数字。
    var finalizeSecondsRemaining: Int? = nil

    private static let barCount = 5

    var body: some View {
        if let seconds = finalizeSecondsRemaining {
            // 收尾期间：右侧显示倒计时（用户要求「右侧显示倒计时多少秒」）。
            // **绿色** —— 用户：「点击停止之后，倒计时的数字换成绿色」。
            Text("\(max(seconds, 0))s")
                .font(.system(size: 16, weight: .bold).monospacedDigit())
                .foregroundColor(DS.Colors.success)
                .frame(width: 32, height: 26)
                .contentShape(Rectangle())
        } else {
            waveform
        }
    }

    private var waveform: some View {
        // 停止后**整个动画停掉**，画成一排静止的白柱。
        // 不再用 `TimelineView` —— 那个东西一旦在树上就每帧都在跑，
        // 哪怕数字看不出来；用户要的是「所有动画全部停止」。
        if !isRecording {
            return AnyView(
                HStack(alignment: .center, spacing: 3) {
                    ForEach(0..<Self.barCount, id: \.self) { index in
                        Capsule()
                            .fill(Color.white)
                            .frame(width: 3.5, height: Self.restingBarHeights[index % Self.restingBarHeights.count])
                    }
                }
                .frame(width: 32, height: 26)
                .contentShape(Rectangle())
            )
        }
        return AnyView(
            TimelineView(.animation) { context in
                let seconds = context.date.timeIntervalSinceReferenceDate
                HStack(alignment: .center, spacing: 3) {
                    ForEach(0..<Self.barCount, id: \.self) { index in
                        Capsule()
                            .fill(barColor)
                            .frame(width: 3.5, height: barHeight(index: index, seconds: seconds))
                    }
                }
                .frame(width: 32, height: 26)
                .contentShape(Rectangle())
            }
        )
    }

    /// 停止时那一排柱子的固定高度 —— 一条静止的、看得出是波形的形状，不是一条直线。
    private static let restingBarHeights: [CGFloat] = [7, 14, 20, 12, 8]

    private var barColor: Color {
        isRecording
            ? Color(red: 1.0, green: 0.27, blue: 0.23)      // 录音中：红
            : Color(red: 0.20, green: 0.85, blue: 0.50)     // 已停止：绿（点它继续录）
    }

    private func barHeight(index: Int, seconds: Double) -> CGFloat {
        // 相位按柱错开，看起来才像波在走而不是整排一起跳。
        let wave = 0.5 + 0.5 * sin(seconds * 5.5 + Double(index) * 0.9)
        // 静音时靠 0.35 的底幅继续动 —— 用户要的是「呼吸」，停了就死了。
        let amplitude = 0.35 + 0.65 * min(max(level, 0), 1)
        return 4 + 17 * wave * amplitude
    }
}

/// 把「每 300–400ms 才来一次、一次好几个字」的服务端结果，按固定速率逐字揭示。
///
/// 用户的原话是「文字显示特别卡，应该是非常丝滑、流畅的感觉」。卡有两个来源，
/// 这是第二个：数据本身的粒度就是几百毫秒一跳，直接铺到屏幕上就是一跳一跳。
/// 这里按 40 字/秒匀速推进，比服务端的吞吐略快，所以永远追得上、不积压 ——
/// 显示的平滑度和数据的粒度从此无关。
///
/// 只在「追加」时逐字推进。识别器会回头改写已经说过的字（实测过），那种情况下
/// 逐字追一个被改过的串只会得到一段乱码动画，所以直接对齐过去。
private struct SmoothRevealedTranscriptText: View {
    let text: String
    /// 这一行能用多少宽度。用来决定文字是**从左排起**还是**贴着右边滚**。
    let availableWidth: CGFloat
    /// 文字颜色。展开面板里那一行用**绿色**（用户：「实时转写的这个文字，在最上面
    /// 那一行，应该要绿色」），刘海下那一行仍然是白的。
    var textColor: Color = .white
    /// 短文本时是不是也要贴着右边。
    ///
    /// 展开面板里是 `true`：那一行右边有个复制按钮，文字要顶到它左边；
    /// 刘海下那条是 `false`：短句从左排起（否则短句会缩在右边，看着像「只显示了
    /// 后半句」）。
    var alwaysTrails: Bool = false

    /// 屏幕上本来就只看得到最后几十个字。用窗口而不是全文，是为了让每帧的
    /// 布局开销与会话长度无关 —— 否则录得越久越卡。
    private static let windowCharacterCount = 64
    private static let charactersPerSecond: Double = 40
    private static let framesPerSecond: Double = 30
    private static let fontSize: CGFloat = 15

    @State private var shownText = ""
    private let ticker = Timer.publish(every: 1.0 / framesPerSecond, on: .main, in: .common).autoconnect()

    var body: some View {
        Text(shownText.isEmpty ? " " : shownText)
            .font(.system(size: Self.fontSize, weight: .medium))
            .foregroundColor(textColor)
            .lineLimit(1)
            .fixedSize()
            // 短句**从左排起**（用户报的「只显示在右半部分」就是这个：之前一律
            // 右对齐，短句自然缩在右边）；一旦长过这一行，改成贴着右边 ——
            // 最新说的字必须留在可见处，左对齐会让新字从右边被裁掉。
            .frame(width: availableWidth,
                   alignment: (alwaysTrails || measuredWidth > availableWidth) ? .trailing : .leading)
            .onReceive(ticker) { _ in advance() }
            .onChange(of: text) { _, _ in advance() }
            // **首次出现直接对齐，不从空串逐字爬。**
            //
            // 平滑揭示是给「新字到达」用的（30 字/秒，跟得上服务端每秒 ~25 字的
            // 吞吐）。但视图第一次出现时**根本没有新字** —— 文本早就在那儿了，
            // 应该立刻完整显示。原来这里调的是 `advance()`，而它每次只推进一个字，
            // 于是几十秒的录音要从空白爬十几秒才能爬完，用户看到的就是
            // 「第一次展开只显示左侧一点点」。第二次展开时 SwiftUI 复用了这个视图、
            // `shownText` 还留着上一次爬完的结果，所以看起来「第二次就正常了」。
            .onAppear {
                shownText = String(text.suffix(Self.windowCharacterCount))
            }
    }

    /// 用同一个字体直接量文字宽度。
    ///
    /// 不用 `GeometryReader` + `PreferenceKey` 那一套：那一套读到的尺寸比布局慢
    /// 一帧，而这一行每 1/30 秒就要判一次对齐 —— 慢一帧就会在临界点上左右横跳。
    /// 字体是我们自己定的，同步量一次既准又即时。
    private var measuredWidth: CGFloat {
        guard !shownText.isEmpty else { return 0 }
        let font = NSFont.systemFont(ofSize: Self.fontSize, weight: .medium)
        return (shownText as NSString).size(withAttributes: [.font: font]).width
    }

    private func advance() {
        let target = String(text.suffix(Self.windowCharacterCount))
        guard !target.isEmpty else {
            shownText = ""
            return
        }
        guard target.hasPrefix(shownText) else {
            // 被改写，或者内容已滚出窗口：对齐到目标末尾同样长的一段，接着往下走。
            shownText = String(target.suffix(max(shownText.count, 1)))
            return
        }
        guard target.count > shownText.count else { return }
        let step = max(1, Int(Self.charactersPerSecond / Self.framesPerSecond))
        shownText = String(target.prefix(min(shownText.count + step, target.count)))
    }
}

/// 上直下圆的长方形：顶边和黑带平接，只有下面两个角是圆的。
/// 这是用户对转录团的明确要求（「左上角和右上角应该是直线，下边是圆角」）。
private struct RecordingRibbonShape: Shape {
    var cornerRadius: CGFloat = 15
    /// 上面两个角要不要圆。收起态**不能圆** —— 它的上边和黑带拼在一起，
    /// 圆了就在接缝处露出桌面；展开态**要圆** —— 它是一块独立的浮窗。
    var roundsTopCorners: Bool = false

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let radius = min(cornerRadius, rect.height, rect.width / 2)
        if roundsTopCorners {
            path.move(to: CGPoint(x: rect.minX + radius, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
            path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + radius),
                              control: CGPoint(x: rect.maxX, y: rect.minY))
        } else {
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        }
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - radius, y: rect.maxY),
                          control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - radius),
                          control: CGPoint(x: rect.minX, y: rect.maxY))
        if roundsTopCorners {
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
            path.addQuadCurve(to: CGPoint(x: rect.minX + radius, y: rect.minY),
                              control: CGPoint(x: rect.minX, y: rect.minY))
        } else {
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        }
        path.closeSubpath()
        return path
    }
}

/// 录音带的宿主：一块**独立**的面板，贴在屏幕顶部。
///
/// ## 为什么不是画进现有的刘海窗口
///
/// 因为那个窗口的高度只有「刘海高 + 一点动画余量」，而跑马灯在刘海**下方** ——
/// 窗口不够高，画了也看不见。要改就得让 `NotchWindowController` 在录音期间
/// 实时改变窗口高度，而那套代码里有一堆不变量（resting frame、命中测试、
/// 展开/收起的两套动画），为一个独立功能去动它不划算。
///
/// 所以这里单开一块面板：位置和尺寸自己算，**和刘海子系统唯一的交集是
/// `NotchSupport` 里那几个几何常量**（刘海矩形、两翼宽度）。不碰它的相位机、
/// 不碰它的面板、不碰它的点击逻辑。录完就整个消失。
///
/// 面板是**可交互**的（`ignoresMouseEvents = false`），因为右翼那颗停止按钮要真的
/// 能点。代价是录音期间刘海周围那一小块区域的点击不会穿到下面 —— 这时候用户要
/// 么在说话、要么在点停止，这个代价可以接受。
@MainActor
final class NotchRecordingOverlayController {

    static let shared = NotchRecordingOverlayController()

    private var panels: [NSPanel] = []
    private var phaseCancellable: AnyCancellable?
    private var isPresented = false
    private var outsideClickMonitor: Any?
    private var escapeKeyMonitor: Any?

    private init() {}

    /// 由 `CompanionManager.start()` 调用一次。
    func startObservingRecorder() {
        guard phaseCancellable == nil else { return }
        let recorder = LongFormRecorderController.shared
        // 三个输入都要看：相位（在录/停了）、展开态（窗口高度）、是否还有未结束的
        // 会话（挂断之后面板要留着，绿色音波点一下继续录）。少看任何一个都会出现
        // 「点了没反应」或者「面板该在的时候不在」。
        phaseCancellable = Publishers.CombineLatest3(
            recorder.$phase, recorder.$isTranscriptExpanded, recorder.$isSessionActive)
            .receive(on: DispatchQueue.main)
            // **参数只用来看「有东西变了」，具体值一律现读 live 值。**
            //
            // 实测：`@Published` 在 willSet 里发值，`receive(on:)` 又把它推迟一个
            // 主队列轮次，于是闭包拿到的 `isExpanded` 和运行时的真实值是**两份不同的
            // 读取**（实测 4/4 次回调都对不上）。`@Published` 赋同值也会发，一次收起
            // 会触发 3 次 sink。
            //
            // 原来 `installDismissMonitors()` 和 `makeKey()` 读的是那个过期参数，
            // 所以会出现「面板已经收起、却给它 makeKey() 并装上全局 ESC 监听」。
            .sink { [weak self] _, _, _ in
                guard let self else { return }
                let isExpanded = recorder.isTranscriptExpanded
                if recorder.phase == .idle && !recorder.isSessionActive {
                    self.hide()
                } else {
                    self.show()
                    self.reframePanels()
                }
                // 折叠的两个入口只在**展开时**才装监听 —— 平时不该有全局鼠标/键盘
                // 监听在跑，那会白白吃掉用户的每一个 ESC。
                if isExpanded { self.installDismissMonitors() } else { self.removeDismissMonitors() }
                // 展开时立刻把面板变成 key，编辑框马上就能打字/粘贴。
                //
                // 用户的要求：「里面的内容可以用户输入，不一定非要转写之后才能输入，
                // 用户可以直接先粘贴一些提示词或文本」。不主动 makeKey 的话，用户得
                // 先点一下编辑区才能粘贴 —— 而他会以为「这里不能输入」。
                if isExpanded { self.panels.first?.makeKey() }
            }
    }

    /// 「点弹窗外面折叠」和「按 ESC 折叠」—— 用户明确要求的两条，之前一条都没生效。
    ///
    /// 两个都用**全局**监听，而不是视图里的手势 / `onExitCommand`：
    /// - 点外面这件事视图根本收不到（点在别的 App 上）；
    /// - `onExitCommand` 只在文本框拿到焦点时才触发，而用户经常是展开之后**没点
    ///   进去**就直接按 ESC，那时焦点还在别的 App 上，视图那一侧永远等不到。
    ///
    /// 全局监听**只读不吞**：监听器不拦截事件，所以点外面等于「既折叠了，又把这一下
    /// 正常给了下面那个 App」，不会因为折叠动作吃掉用户的一次点击。
    private func installDismissMonitors() {
        guard outsideClickMonitor == nil else { return }

        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self else { return }
            let location = NSEvent.mouseLocation
            // 点在面板自己的矩形里就不算「外面」。
            if self.panels.contains(where: { $0.frame.contains(location) }) { return }
            Task { @MainActor in
                LongFormRecorderController.shared.collapseTranscriptEditor()
            }
        }

        escapeKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            // 53 = ESC。用户的要求：「用户点击 ESC 也自动折叠」。
            guard event.keyCode == 53 else { return }
            Task { @MainActor in
                LongFormRecorderController.shared.collapseTranscriptEditor()
            }
        }
    }

    private func removeDismissMonitors() {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        if let escapeKeyMonitor { NSEvent.removeMonitor(escapeKeyMonitor) }
        outsideClickMonitor = nil
        escapeKeyMonitor = nil
    }

    /// 展开/收起时窗口要跟着长高变矮。**这是当初把这套做成独立面板而不是画进
    /// 刘海窗口的理由之一** —— 这块窗口的高度完全由我们自己说了算。
    private func reframePanels() {
        guard isPresented else { return }

        for panel in panels {
            guard let screen = panel.screen ?? NSScreen.main,
                  let frame = panelFrame(for: screen) else { continue }

            // **顺序不能换：先把内容排到新尺寸，再改窗口。**
            // 反过来的话，中间有一瞬窗口已经变宽、内容还按旧尺寸摆着 —— 那一瞬多出来
            // 的地方是透明的，用户看到的就是「闪了一下，背景像被穿透」。
            if let contentView = panel.contentView {
                contentView.frame = CGRect(origin: .zero, size: frame.size)
                contentView.needsLayout = true
                contentView.layoutSubtreeIfNeeded()
            }
            panel.setFrame(frame, display: true)
        }
    }

    private func show() {
        guard !isPresented else { return }
        isPresented = true
        for screen in NSScreen.screens {
            guard let panel = makePanel(for: screen) else { continue }
            panel.orderFrontRegardless()
            panels.append(panel)
        }
    }

    private func hide() {
        guard isPresented else { return }
        isPresented = false
        for panel in panels { panel.orderOut(nil) }
        panels.removeAll()
    }

    /// 面板要多高：静止时是「刘海 + 跑马灯」，展开时再加上那一整块面板。
    private func panelFrame(for screen: NSScreen) -> CGRect? {
        guard let notch = NotchSupport.notchRect(on: screen) else { return nil }
        let isExpanded = LongFormRecorderController.shared.isTranscriptExpanded
        // 和视图里 `bandWidth` 用**同一个公式**：两翼取对称宽度（大的那个），
        // 中间是刘海。写两遍必然漂，所以这里的注释就是那处的注释。
        let bandWidth = NotchSupport.leadingWingWidth + notch.width + NotchSupport.trailingWingWidth
        let ribbonHeight: CGFloat = 42
        // 展开时下面那块的宽度**加倍**（用户要求），整块窗口跟着变宽、仍然以刘海居中。
        let panelWidth = isExpanded
            ? min(bandWidth * 2, screen.frame.width - 40)
            : bandWidth
        let expandedHeight: CGFloat = 560
        let panelHeight = notch.height + ribbonHeight + (isExpanded ? expandedHeight : 0)
        // 刘海矩形是**左上角显示坐标**（`auxiliaryTopLeftArea` 那套），AppKit
        // 全局坐标是左下角 —— 顶边贴着屏幕顶边，所以 y = screen.maxY - 高度。
        // x 要加上这块屏幕自己的原点（多显示器时不为 0）。
        let notchCenterX = screen.frame.minX + notch.minX + notch.width / 2
        return CGRect(x: notchCenterX - panelWidth / 2,
                      y: screen.frame.maxY - panelHeight,
                      width: panelWidth,
                      height: panelHeight)
    }

    private func makePanel(for screen: NSScreen) -> NSPanel? {
        guard let notch = NotchSupport.notchRect(on: screen),
              let frame = panelFrame(for: screen) else { return nil }
        let bandWidth = frame.width

        // 必须是能成为 key 的面板：编辑那一行时文本框要收得到键盘。
        // 面板是 `.nonactivatingPanel`，所以成为 key 也**不会**把用户当时在用的
        // App 顶掉（不激活本 App），编辑完就还回去。
        let panel = KeyableRecordingPanel(contentRect: frame,
                                          styleMask: [.borderless, .nonactivatingPanel],
                                          backing: .buffered,
                                          defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        // 压在刘海面板之上：录音期间这条带要盖住原来的静止 pill。
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovable = false
        // **关掉 NSWindow 自带的 frame 动画。** 改 frame 时 AppKit 默认会插一段
        // 短动画，表现出来就是「展开时窗口先向右上甩一下再回到正位」。展开/收起
        // 每一次都要瞬间到位，不要这段系统动画。
        panel.animationBehavior = .none

        let hostingView = NSHostingView(rootView: NotchRecordingBandView(
            recorder: .shared,
            notchWidth: notch.width,
            notchHeight: notch.height))
        // **必须置空。** 这是「展开时向右上角甩一下」的根因，实测 + A/B 验证：
        //
        // `NSHostingView.sizingOptions` 默认是 `.standardBounds`（实测 rawValue=7）。
        // 当它被设为窗口的 `contentView` 时，会**绕开 Auto Layout 直接调
        // `setContentSize`** —— 抓到的调用栈：
        //     NSHostingView.updateConstraints
        //       → updateWindowContentSizeExtremaIfNecessary
        //         → setContentSize → setFrame
        // 而 `setContentSize` 是**钉住左上角**的语义（实测：顶边和左边不动，向下向右长）。
        //
        // 于是：`reframePanels()` 设好正确的帧之后约 82ms，NSHostingView 会按
        // **SwiftUI 内容的固有尺寸**再改一次窗口，把我们的值当场作废。内容从收起
        // 换到展开时，它搬的方向是错的 —— 实测 dx=+179pt（向右）、高度少 42pt
        // （底边上移），合起来正是用户说的「向右上角甩一下」，随后下一次
        // `reframePanels` 把它拽回正位，就是「然后再回到正位置」。
        //
        // 置空之后实测 dx=0 / dTop=0 / dH=0 —— 窗口再没被它碰过。
        // 这个面板的几何全部由 `panelFrame(for:)` 说了算，不需要宿主视图再插一手。
        hostingView.sizingOptions = []
        hostingView.frame = CGRect(origin: .zero, size: frame.size)
        panel.contentView = hostingView
        return panel
    }
}

/// 允许成为 key 的无边框面板。
///
/// 默认的无边框 `NSPanel` 不接受键盘焦点，展开面板里那一行的文本框就一个字都
/// 打不进去 —— 而且不报任何错，看起来只是「双击了没反应」。
private final class KeyableRecordingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
