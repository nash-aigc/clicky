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
    /// 跑马灯那一条的高度。**对外可见** —— 控制器算窗口高度时必须用同一个数，
    /// 两处各写一遍就是 42 vs 32 那个差的来源（见 `panelFrame`）。
    static let ribbonHeight: CGFloat = 32

    /// 每侧向刘海**里面**压进多少。
    ///
    /// 刘海自己的**底角是圆的**（约 10pt）。两翼如果正好从刘海边缘起画，那个圆弧
    /// 处就会露出桌面的背景 —— 用户实测截图里两处缝隙都能看到。所以每侧各压进
    /// 这么多把圆角盖掉，中间那段相应变窄，**整条带的总宽不变**。
    private static let notchCornerOverlap: CGFloat = 14

    /// 小窗标题栏的高度。控制器算它的命中矩形时要用 —— 画的和点的必须是同一个数。
    static let titleBarHeight: CGFloat = 26

    /// 字幕条（转写那一行）的圆角半径。小窗的宽度要把它两侧各减掉一个 —— 见挂载处。
    /// 22 是 `transcriptRibbon` 里 `RecordingRibbonShape(cornerRadius: 22)` 那个值。
    static let ribbonCornerRadius: CGFloat = 22

    var body: some View {
        VStack(spacing: 0) {
            band
            if recorder.isTranscriptExpanded {
                expandedTranscriptPanel
            } else {
                VStack(spacing: 0) {
                    transcriptRibbon
                        // 点这一行就展开（用户的要求：「点击下面这行文字，自动展开」）。
                        .contentShape(Rectangle())
                        .onTapGesture { recorder.toggleTranscriptEditor() }
                        .help("点一下展开，看之前的转写内容")

                    // **摄像头小窗不在这里了 —— 它有了自己的面板。**
                    //
                    // 它原先就挂在这个位置（字幕条下面）。用户 2026-09-26 要求把小窗
                    // 挪到屏幕左侧中间／底部中央／右侧中间，而这三个位置**都在这块面板
                    // 之外** —— 这块面板锚在屏幕顶部中央、只有 `刘海高 + 560` 那么高。
                    //
                    // 而这块面板的帧又不能改（见 `panelFrame` 上面那段「背景穿透」的
                    // 注释）。所以小窗搬去了 `CameraStripPanelView` 那块**全屏、永远
                    // 点击穿透、永不移动**的面板，位置变成纯 SwiftUI 的事。
                }
            }
        }
        // 外层不锁宽度：展开时下面那块比黑带宽一倍，锁定的话会被裁掉。
        .frame(maxWidth: .infinity)
        // **纵向必须显式顶对齐。** 宿主视图是 `CGRect(origin: .zero, size: frame.size)`
        // 铺满整块面板的，而这块内容只有 64pt 高（刘海 32 + 字幕条 32），面板却有
        // `刘海高 + 560` —— 不写这一行，带子就由 SwiftUI 的默认对齐说了算。
        //
        // 而 `collapsedWingHitRects` 和摄像头小窗的几何**都硬假定「带子贴着窗口顶边」**。
        // 小窗搬走之后这里少了 ~177pt 的内容，正是会让那个假定失效的改动 ——
        // 所以把不变量写下来，别让它继续靠巧合成立。
        // 展开态内容高度本来就等于窗口高度，这一行在那里是 no-op。
        .frame(maxHeight: .infinity, alignment: .top)
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
                if recorder.isPolishingTranscript {
                    // **AI 润色中** —— 一道光扫过文字。
                    //
                    // 用户 2026-09-25 改的要求：「改为蓝白或蓝绿色彩光效果，光波在文字上
                    // 移动，移动时文字略微凸起或变化，**字号保持不变**」（原来那版是
                    // 字号忽大忽小，已经不是他要的了）。
                    //
                    // 字距：`AI` 和 `润色` 之间用一个 **thin space**（U+2009），
                    // 比普通空格窄、又不至于挨在一起 —— 用户：「缩小"AI"与"润色"之间的
                    // 字间距，保留一点空隙，不要完全挨着」。
                    ShimmeringPolishText(text: "AI\u{2009}润色中")
                } else if recorder.isFinalizingTranscript {
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
                if recorder.isPolishingTranscript {
                    // **AI 润色中** —— 一道光扫过文字。
                    //
                    // 用户 2026-09-25 改的要求：「改为蓝白或蓝绿色彩光效果，光波在文字上
                    // 移动，移动时文字略微凸起或变化，**字号保持不变**」（原来那版是
                    // 字号忽大忽小，已经不是他要的了）。
                    //
                    // 字距：`AI` 和 `润色` 之间用一个 **thin space**（U+2009），
                    // 比普通空格窄、又不至于挨在一起 —— 用户：「缩小"AI"与"润色"之间的
                    // 字间距，保留一点空隙，不要完全挨着」。
                    ShimmeringPolishText(text: "AI\u{2009}润色中")
                } else if recorder.isFinalizingTranscript {
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
                        ? recorder.finalizeSecondsRemaining : nil,
                    isPolishing: recorder.isPolishingTranscript)
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
            // 顶行 = **原来那一行实时转写留在原位**，现在是**整整一行都给它**。
            //
            // 复制按钮从这一行删掉了（用户：「把整个第一行右侧的复制按钮删掉，让第一行
            // 全部显示转写的内容」）。复制还有两条路，不缺口：⌘+Enter 一键复制并结束；
            // 而关窗本身就会把内容送进剪贴板（那是「任何一次录音都不会丢」的收口）。
            //
            // 这一行是**黑的** —— 它和上面的黑带连成一片，是刘海的延伸；再往下的正文区
            // 才是浮雕色。
            SmoothRevealedTranscriptText(text: recorder.marqueeText,
                                         availableWidth: bandWidth * 2 - 32,
                                         textColor: DS.Colors.success)
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 46)
            .background(Color.black)

            // **一整个可编辑的文本**，不是一行行的列表。
            //
            // 用户的原话：「双击之后只能编辑某一行，我希望能够编辑所有的文本，
            // 而且文本之间不要换行，因为文字是连续的……现在只能显示、只能编辑
            // 某一行，体验太差了」。所以这里是一个 `TextEditor`：点哪改哪，
            // 全文连续，段落之间没有换行。
            TextEditor(text: Binding(
                get: { recorder.transcriptDisplayText },
                set: { recorder.applyEditedTranscript($0) }))
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

    /// 展开面板的高度。同样对外可见，理由同上。
    static let expandedPanelBodyHeight: CGFloat = 560

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
        SmoothRevealedTranscriptText(text: recorder.marqueeText,
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

/// 刘海下面的**摄像头小窗**。
///
/// 用户 2026-09-26 的设计：
/// - 上面一条**标题栏**，下面一块**实时画面**
/// - **左上角退出** —— 停止抓帧，本轮到此为止
/// - **右上角展开** —— 画面放大
/// - **点标题栏折叠** —— 收成一条，入口还在，随时能叫回来
/// - **抓一帧，标题栏那颗绿点就亮一下、大一下** —— 让用户知道此刻正在抓
///
/// 画面刻意**压低分辨率和刷新率**：用户要的是「让用户能够看到就可以了，不需要渲染
/// 太高的像素或清晰度」。所以这里直接显示抓帧时那张 JPEG（768 长边），一秒换一张 ——
/// 既不额外开一路预览流，也让「你看到的这一张，就是正在被看的那一张」这句话成立。
/// 小窗面板里那个命名坐标空间。几何都在它里面量，控制器再换算成 AppKit 全局坐标。
private let cameraStripCoordinateSpaceName = "clickyCameraStripPanel"

/// 小窗在它自己那块面板里的命中几何。
///
/// **由视图发布，不在 AppKit 里另算一份。** 这个仓库在「画的和点的是两处算的」上
/// 真被打过一次 —— `NotchSupport.trailingWingOriginX` 那次，画出来的红电话和它的
/// 点击目标差了 71pt，屏幕上完全看不出来。所以每个控件都用 `GeometryReader` 把自己
/// 的真实矩形发上来，AppKit 侧只做坐标换算，一个可以漂的常量都没有。
struct CameraStripLayoutSnapshot: Equatable {
    var titleBarFrame: CGRect?
    var controlFrames: [CameraStripControl: CGRect] = [:]
}

struct CameraStripLayoutKey: PreferenceKey {
    static var defaultValue = CameraStripLayoutSnapshot()
    static func reduce(value: inout CameraStripLayoutSnapshot,
                       nextValue: () -> CameraStripLayoutSnapshot) {
        let reported = nextValue()
        if let titleBarFrame = reported.titleBarFrame { value.titleBarFrame = titleBarFrame }
        value.controlFrames.merge(reported.controlFrames) { _, newest in newest }
    }
}

/// 标题栏上的一颗圆按钮。**画多大、点多大，都是这一个 `diameter`。**
///
/// 控件本身收不到点击（窗口永远点击穿透），所以它的 `action` 平时不会执行 ——
/// 真正干活的是全局监听按这里发上去的矩形派发。两边都指向
/// `LongFormRecorderController.handleCameraStripControl`，所以哪天窗口变成可交互的，
/// 两条路也不会分家。
private struct CameraStripControlButton: View {
    let control: CameraStripControl
    let systemImage: String
    let tint: Color
    let help: String
    let action: () -> Void

    static let diameter: CGFloat = 18

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(tint)
                .frame(width: Self.diameter, height: Self.diameter)
                .background(Circle().fill(Color.white.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .help(help)
        .background(
            GeometryReader { geometry in
                Color.clear.preference(
                    key: CameraStripLayoutKey.self,
                    value: CameraStripLayoutSnapshot(
                        controlFrames: [control: geometry.frame(in: .named(cameraStripCoordinateSpaceName))]))
            }
        )
    }
}

private struct NotchCameraPreviewStrip: View {
    @ObservedObject var recorder: LongFormRecorderController
    /// **单独观察预览模型** —— 12 帧/秒只重算这一块，不牵动刘海那条带。
    @ObservedObject var previewModel: CameraPreviewModel
    let width: CGFloat

    /// 预览高度**由宽度和画面的比例推出来**，不是一个写死的高度。
    ///
    /// 用户 2026-09-26：「高度应该再增加一点，因为现在左右两侧还有很大的空白。
    /// 既然已经测到宽度，也知道摄像头的比例了，就能让摄像头占满整个宽度空间，
    /// 并保持它的比例」。
    ///
    /// 之前是 `.fit` + 一个 86pt 的高度上限：16:9 的画面被高度卡住，只能画到
    /// 153pt 宽，**两侧各空 80pt**。现在反过来 —— 宽度是已知的，高度按比例算出来，
    /// 于是画面正好填满宽度，空白消失，高度也自然变高。
    private func previewHeight(for cgImage: CGImage) -> CGFloat {
        let ratio = CGFloat(cgImage.height) / max(CGFloat(cgImage.width), 1)
        // 上限只是防呆（竖屏画面会把小窗拉得极高），正常横向画面用不到它。
        return min(width * ratio, Self.maximumPreviewHeight)
    }

    /// 防呆上限。
    private static let maximumPreviewHeight: CGFloat = 320
    static let titleBarHeight: CGFloat = 26

    /// 标题栏里的排布常量。**画的是这几个数，量的也是这几个数** ——
    /// 命中矩形由每个控件自己发布，所以这里不存在第二份需要同步的算术。
    private static let controlSpacing: CGFloat = 8
    private static let titleBarHorizontalPadding: CGFloat = 10
    private static let pulseDotSlot: CGFloat = 13
    private static let frameCountSlot: CGFloat = 26

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            if !recorder.isCameraPreviewCollapsed {
                preview
            }
        }
        .frame(width: width)
        .background(Color.black)
        .clipShape(RecordingRibbonShape(cornerRadius: 18))
        // 收/开小窗的动画由视图自己拥有 —— 动作的入口在控制器上（全局监听那条路），
        // 让那边去 `import SwiftUI` 只为一个 `withAnimation` 不值得。
        .animation(.easeInOut(duration: 0.18), value: recorder.isCameraPreviewCollapsed)
    }

    private var titleBar: some View {
        HStack(spacing: Self.controlSpacing) {
            // 左端：**镜像开关**。默认开着（自拍视角），用户可以自己关掉。
            CameraStripControlButton(
                control: .mirror,
                systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right",
                tint: previewModel.isMirrored ? DS.Colors.success : .white.opacity(0.6),
                help: previewModel.isMirrored ? "取消镜像" : "左右镜像"
            ) { recorder.handleCameraStripControl(.mirror) }

            // 抓一帧、这颗点亮一下并变大。
            //
            // **它的占位必须固定。** 用户 2026-09-26：「绿色的点右侧这个数字总是在
            // 左右移动」。原因就是这颗点自己从 7pt 长到 11pt，而它在数字左边 ——
            // 每抓一帧就把数字往右推 4pt。所以缩放发生在**固定尺寸的容器内部**，
            // 容器本身不动。
            ZStack {
                Color.clear.frame(width: Self.pulseDotSlot, height: Self.pulseDotSlot)
                CameraCapturePulseDot(pulse: previewModel.capturedFrameCount)
            }

            // **只留绿点 + 数字，「摄像头」三个字删掉了。**
            // 用户 2026-09-26：「把"摄像头"这三个文字删掉，只保留一个绿色小灯加一个数字即可」。
            Text("\(previewModel.capturedFrameCount)")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundColor(DS.Colors.success.opacity(0.9))
                .frame(width: Self.frameCountSlot, alignment: .center)

            // **中间这四个：把小窗挪到屏幕的别处。**
            //
            // 用户 2026-09-26：「当用户的纸上文字很小、需要把纸拿得很近时，由于小窗
            // 位于上方附近，会导致用户看不到小窗里的内容。通过移动小窗位置，既能让
            // 用户看到小窗内容，也能让摄像头更清晰地拍摄文字。」
            //
            // **「还原」单独一颗，不是「向上」。** 用户的原话是「增加一个还原按钮。
            // 用户点击还原，摄像头真的放回原来的位置上」—— 三个方向键去得了回不来
            // 是不够用的，而「向上」在他心里是四个方向里的一个，不是「还原」。
            CameraStripControlButton(control: .restore,
                                     systemImage: "arrow.uturn.backward",
                                     tint: accent(for: .restore),
                                     help: "还原（回到刘海下面）") {
                recorder.handleCameraStripControl(.restore)
            }
            CameraStripControlButton(control: .moveLeft,
                                     systemImage: "arrow.left",
                                     tint: accent(for: .moveLeft),
                                     help: "移到屏幕左侧中间") {
                recorder.handleCameraStripControl(.moveLeft)
            }
            CameraStripControlButton(control: .moveDown,
                                     systemImage: "arrow.down",
                                     tint: accent(for: .moveDown),
                                     help: "移到屏幕底部中央") {
                recorder.handleCameraStripControl(.moveDown)
            }
            CameraStripControlButton(control: .moveRight,
                                     systemImage: "arrow.right",
                                     tint: accent(for: .moveRight),
                                     help: "移到屏幕右侧中间") {
                recorder.handleCameraStripControl(.moveRight)
            }

            Spacer(minLength: 0)

            // 右端：**关闭**（停止抓帧，本轮不再抓）。
            CameraStripControlButton(control: .close,
                                     systemImage: "xmark",
                                     tint: .white.opacity(0.75),
                                     help: "停止抓帧（本轮不再抓）") {
                recorder.handleCameraStripControl(.close)
            }
        }
        .padding(.horizontal, Self.titleBarHorizontalPadding)
        .frame(height: Self.titleBarHeight)
        // **点这一条折叠小窗** —— 连 `contentShape` 一起，整条都可点，
        // 而不是只有文字那几像素。空白处（没有被控件矩形盖住的部分）走的就是这条路。
        .contentShape(Rectangle())
        .onTapGesture { recorder.handleCameraStripControl(.toggleCollapse) }
        .help(recorder.isCameraPreviewCollapsed ? "点一下展开小窗" : "点一下收起小窗")
        .background(
            GeometryReader { geometry in
                Color.clear.preference(
                    key: CameraStripLayoutKey.self,
                    value: CameraStripLayoutSnapshot(
                        titleBarFrame: geometry.frame(in: .named(cameraStripCoordinateSpaceName))))
            }
        )
    }

    /// 当前所在位置对应的那颗按钮标绿，和镜像按钮同一个约定 ——
    /// 在一排长得一样的圆钮里，「现在在哪」必须一眼看得出来。
    private func accent(for control: CameraStripControl) -> Color {
        let isActive: Bool
        switch control {
        case .restore: isActive = recorder.cameraStripPlacement == .belowNotch
        case .moveLeft: isActive = recorder.cameraStripPlacement == .left
        case .moveDown: isActive = recorder.cameraStripPlacement == .bottom
        case .moveRight: isActive = recorder.cameraStripPlacement == .right
        default: isActive = false
        }
        return isActive ? DS.Colors.success : .white.opacity(0.75)
    }

    @ViewBuilder
    private var preview: some View {
        if let cgImage = previewModel.frame {
            // **等比缩放整张，不裁切。**
            //
            // 上一版用的是 `.fill` + `.clipped()` —— 那是「填满这个框、多出来的切掉」，
            // 于是画面被裁掉一部分。用户：「你只有正确的比例，我才能看到摄像头里面的
            // 内容」。`.fit` 才是「整张都看得见」。
            Image(decorative: cgImage, scale: 1)
                .resizable()
                // **只镜像预览。** 发出去的那一帧不镜像 —— 镜像过的图上文字是反的，
                // 而用户会举着纸让模型读。
                .scaleEffect(x: previewModel.isMirrored ? -1 : 1, y: 1)
                .aspectRatio(contentMode: .fit)
                // **填满宽度，高度按比例。** 这是「左右两侧的空白」的正面修复。
                .frame(width: width, height: previewHeight(for: cgImage))
        } else {
            // 还没抓到第一帧 —— 预热要 0.35 秒，这一小段是正常的，要说出来而不是留一块空白。
            Text("正在启动摄像头…")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.45))
                .frame(height: 90)
        }
    }
}

/// 抓帧指示点：每抓一帧亮一下、大一下。
///
/// 外面套着一个**固定 13pt 的容器**（见调用处）—— 这里长多大都不会推动右边的数字。
private struct CameraCapturePulseDot: View {
    let pulse: Int
    @State private var isBright = false

    var body: some View {
        Circle()
            .fill(DS.Colors.success)
            .frame(width: isBright ? 12 : 7, height: isBright ? 12 : 7)
            .opacity(isBright ? 1 : 0.55)
            .animation(.easeOut(duration: 0.3), value: isBright)
            .onChange(of: pulse) { _, _ in
                isBright = true
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 120_000_000)
                    isBright = false
                }
            }
    }
}

/// 润色那几个字：一道光从左边扫到右边，扫过的地方变白。
///
/// 做法是**两层文字叠在一起** —— 底下那层是蓝绿底色，上面那层是白色，只有一条
/// 46pt 宽的渐变带能透出来，那条带子左右扫。比「改 `foregroundStyle` 的渐变停靠点」
/// 稳：那一种要求停靠点严格递增，而扫动的相位一定会越过端点。
///
/// **字号不变**（用户明确要求），「凸起」由白光本身表达 —— 扫过的地方更亮，读起来
/// 就是那一段浮起来了。
private struct ShimmeringPolishText: View {
    let text: String

    /// 蓝绿。用户给的是「蓝白或蓝绿」，取蓝绿 —— 它和「转写中」那个绿是同一个色系，
    /// 但更偏青，所以两个相位一眼能分清。
    private static let baseColor = Color(hex: "#2DD4BF")

    var body: some View {
        TimelineView(.animation) { context in
            let seconds = context.date.timeIntervalSinceReferenceDate
            // 一趟约 1.6 秒，来回扫。
            let phase = (seconds / 1.6).truncatingRemainder(dividingBy: 1)
            let travel: CGFloat = 84

            ZStack {
                Text(text)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(Self.baseColor)
                Text(text)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(.white)
                    .mask(
                        LinearGradient(colors: [.clear, .white, .clear],
                                       startPoint: .leading, endPoint: .trailing)
                            .frame(width: 46)
                            .offset(x: -travel / 2 + travel * CGFloat(phase))
                    )
            }
            .fixedSize()
            // 扫过时那一段稍微发光 —— 「略微凸起」的观感来源。
            .shadow(color: Self.baseColor.opacity(0.55), radius: 5)
        }
    }
}

/// 润色期间右侧那个图标：外圈慢速转，中心不断向外发射圆环。
///
/// 用户的设计：「空心圆环，慢速持续旋转。圆环内部为中心圆点，通过向外扩散多个
/// 大小不一的圆环实现呼吸效果，圆环随机扩散、逐渐变亮，最内侧圆环不断向外发射
/// 圆环，最外侧圆环持续转圈」。
///
/// 三个相位错开的扩散环 + 一个带缺口的旋转外环。外环**留一个缺口**是必要的：
/// 一个完整圆环转起来和静止长得一样，看不出在动。
private struct PolishingRings: View {
    private static let ringColor = Color(hex: "#2DD4BF")

    var body: some View {
        TimelineView(.animation) { context in
            let seconds = context.date.timeIntervalSinceReferenceDate
            ZStack {
                // 中心圆点。
                Circle()
                    .fill(Self.ringColor)
                    .frame(width: 5, height: 5)

                // 三个向外扩散的环，相位错开 —— 看起来像连续发射而不是同时跳。
                ForEach(0..<3, id: \.self) { index in
                    let phase = ((seconds / 2.1) + Double(index) / 3)
                        .truncatingRemainder(dividingBy: 1)
                    Circle()
                        .stroke(Self.ringColor.opacity(1 - phase), lineWidth: 1.1)
                        .frame(width: 5 + 20 * CGFloat(phase),
                               height: 5 + 20 * CGFloat(phase))
                }

                // 最外圈：带缺口的空心环，慢速转。约 4 秒一圈。
                Circle()
                    .trim(from: 0, to: 0.78)
                    .stroke(Self.ringColor.opacity(0.85),
                            style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
                    .frame(width: 24, height: 24)
                    .rotationEffect(.degrees(seconds * 90))
            }
            .frame(width: 32, height: 26)
            .contentShape(Rectangle())
        }
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
    /// 润色中：右侧改画转圈。
    var isPolishing: Bool = false

    private static let barCount = 5

    var body: some View {
        if isPolishing {
            // 润色期间右侧：外圈慢速旋转 + 中心圆点不断向外发射圆环。
            // 用户：「在刘海右侧添加一个旋转图标：空心圆环，慢速持续旋转。圆环内部为
            // 中心圆点，通过向外扩散多个大小不一的圆环实现呼吸效果，圆环随机扩散、
            // 逐渐变亮，最内侧圆环不断向外发射圆环，最外侧圆环持续转圈」。
            PolishingRings()
        } else if let seconds = finalizeSecondsRemaining {
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
    /// 这一行能用多少宽度。
    let availableWidth: CGFloat
    var textColor: Color = .white

    private static let fontSize: CGFloat = 15
    /// 一次位移用多久滑完。
    ///
    /// **必须大于服务端的到达间隔（实测 300–400ms）。** 这是实测结论：动画时长
    /// 0.35s 配 400ms 间隔时，每段动画都跑完了下一批还没到 —— 实测 **9.0% 的时间完全
    /// 静止**，单次停顿中位 38ms，表现成 2.5 次/秒的「走—停—走」方波，正是用户说的
    /// 「停住不动、然后突然向左移动一下」。
    ///
    /// 0.6s 让动画永远跑不完，被下一批**从当前呈现值**平滑接上（这一点也是实测的：
    /// 5 组配置 + 21 次真实重定目标，打断瞬间的位置跳变**全是 0.000pt**）—— 于是
    /// 连续说话时屏幕上的位移是连续的，没有静止段。
    private static let slideDuration: Double = 0.6
    /// 窗口的**基准**字数。
    private static let maximumWindowCharacters = 160
    /// 裁剪的迟滞：窗口再多长这么多字才裁一次。
    ///
    /// **没有这个迟滞，上限就等于把窗口变回了定长窗口 —— 而那正是最初的根因。**
    /// 原条件是「超过 160 就裁到 160」，于是文本一过 160 字，**每来一个字都裁一次**：
    /// `windowStart` 前进 1、窗口永远 160 字、**宽度恒定不变** → 位移不变 →
    /// `onChange` 不触发 → 动画再也不被调度。而窗口内容每来一个字就换一格，屏幕上
    /// 就是一个字一个字地瞬跳。160 字 ≈ 6–10 秒语音，正好是用户说的「过了几秒钟、
    /// 十几秒之后就不丝滑了」。
    ///
    /// 有了迟滞，窗口在 160↔220 之间**先长后裁**：长的那 60 个字宽度一直在增，动画
    /// 一直在跑；裁的那一下右边缘仍然钉着、可见内容逐字不变，所以看不出来。
    private static let trimHysteresisCharacters = 60

    /// 窗口左端在全文里的位置。
    ///
    /// **这是这一版的关键，也是前十次全错的根源。**
    ///
    /// 之前用的是 `text.suffix(64)` —— 一个**定长**窗口。窗口满了之后，「前面掉出一个
    /// 汉字、后面进来一个汉字」会让窗口的**宽度一个 bit 都不变**（实测：汉字 advance
    /// 恒为 14.883268pt，纯中文 64 字窗口恒为 952.53pt）。而位移是
    /// `availableWidth - 窗口宽度`，所以位移**再也不变**，`onChange` **一次都不触发**，
    /// `withAnimation` **从来没有被执行过**。
    ///
    /// 屏幕上之所以还有位移，是因为窗口的**内容**被整串换掉、瞬时生效 —— 那一跳和
    /// 位移量无关，所以不受任何动画保护。这就是「停住不动、然后突然向左跳一下」。
    /// 而唯一还能改变宽度的东西是**半宽的标点**（「，」「。」实测 7.587549pt，正好
    /// 半个汉字），于是屏幕上唯一还会动的步长就是半个字 —— 这就是「半个字半个字地蹦」。
    ///
    /// 换成「由这个游标控制的**变长**窗口」之后，每来一个字窗口就真的变宽 14.88pt，
    /// 位移随之变化，动画每一次都被调度。
    @State private var windowStart = 0
    @State private var slideOffset: CGFloat = 0

    var body: some View {
        let shown = String(text.dropFirst(windowStart))
        // **文字右边缘永远钉在这一行的右端**，随着字变多向左长 ——
        // 用户的要求：「无论是第一个字还是第二个字，永远都是从右向左移动」。
        let targetOffset = availableWidth - Self.width(of: shown)

        Text(shown.isEmpty ? " " : shown)
            .font(.system(size: Self.fontSize, weight: .medium))
            .foregroundColor(textColor)
            .lineLimit(1)
            .fixedSize()
            // **文字不进动画事务**（动画只挂在 `slideOffset` 上）。否则 SwiftUI 会把
            // 「旧文字→新文字」也当成可动画的变化，两个版本同时画 = 叠影。
            .offset(x: slideOffset)
            .frame(width: availableWidth, alignment: .leading)
            .clipped()
            .onAppear {
                windowStart = max(0, text.count - Self.maximumWindowCharacters)
                slideOffset = availableWidth - Self.width(of: String(text.dropFirst(windowStart)))
            }
            .onChange(of: text) { _, newText in
                let total = newText.count
                // 窗口太长时把左端推近。**裁掉的是屏幕外面那部分**，而右边缘仍然钉住，
                // 所以屏幕上**看不出任何变化** —— 这一步不带动画是安全的。
                let truncated = total - windowStart
                    > Self.maximumWindowCharacters + Self.trimHysteresisCharacters
                if truncated {
                    windowStart = total - Self.maximumWindowCharacters
                    slideOffset = availableWidth - Self.width(of: String(newText.dropFirst(windowStart)))
                    return
                }
                let shownNow = String(newText.dropFirst(windowStart))
                withAnimation(.linear(duration: Self.slideDuration)) {
                    slideOffset = availableWidth - Self.width(of: shownNow)
                }
            }
    }

    /// 用同一个字体直接量文字宽度。批判者实测过：SwiftUI 自己渲染的宽度 =
    /// `ceil(NSString 量出来的)` ±1pt，两者一致，所以拿它算位移是可靠的。
    private static func width(of string: String) -> CGFloat {
        guard !string.isEmpty else { return 0 }
        let font = NSFont.systemFont(ofSize: fontSize, weight: .medium)
        return (string as NSString).size(withAttributes: [.font: font]).width
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
/// 摄像头小窗那一块**全屏面板**的 SwiftUI 根。
///
/// **它的全部职责就是「把小窗摆到屏幕上的某个位置」。** 窗口本身永远是整块屏幕、
/// 永远点击穿透、**永远不动也不改尺寸** —— 位置只是对齐和边距，窗口几何一次都不碰。
///
/// 这不是洁癖，是这个仓库最贵的一条教训：录音那条带的面板当初每次展开/收起都改窗口
/// 尺寸，而窗口是透明的、黑色全靠 SwiftUI 画，几何却在 CA 提交**之前**就改了 ——
/// 新露出来的那一瞬是空的，桌面直接透出来（见 `panelFrame` 上面的注释）。
/// 窗口一动不动之后，那个「窗口期」在结构上就不存在了。
///
/// 对齐方式就是用户说的那三种：「左侧对齐 / 底部对齐 / 右侧居中」——
/// 左中（垂直居中）、底中（水平居中）、右中（垂直居中）。
///
/// **用对齐而不是绝对坐标**：小窗的高度是 `宽度 × 画面宽高比`（见 `previewHeight`），
/// 会随摄像头出来的画面变 —— 对齐让「垂直居中」自动跟着走，AppKit 侧根本算不出来。
struct CameraStripPanelView: View {
    @ObservedObject var recorder: LongFormRecorderController
    let geometry: NotchSupport.CameraStripPlacementGeometry
    let onLayoutChange: (CameraStripLayoutSnapshot) -> Void

    var body: some View {
        NotchCameraPreviewStrip(recorder: recorder,
                                previewModel: recorder.cameraPreviewModel,
                                width: geometry.stripWidth)
            // **`.padding` 必须在无限 frame 之内**（先 padding、后 frame）。
            // 反过来的话撑大的是 frame 本身，内容一点都不内缩。
            .padding(edgeInsets)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
            .coordinateSpace(name: cameraStripCoordinateSpaceName)
            .onPreferenceChange(CameraStripLayoutKey.self) { snapshot in
                // `onPreferenceChange` 自带 Equatable 去重 —— 预览是 30 帧/秒的，
                // 没有这层去重就会每秒写三十次几何。这个视图刚花掉几个提交去掉
                // 每帧重建，不能在窗口这条路上加回来。
                onLayoutChange(snapshot)
            }
    }

    private var alignment: Alignment {
        switch recorder.cameraStripPlacement {
        case .belowNotch: return .topLeading   // 水平位置由 notchCenteredLeadingInset 定
        case .left: return .leading            // 左 + 垂直居中 = 「左侧对齐」
        case .bottom: return .bottom           // 底 + 水平居中 = 「底部对齐」
        case .right: return .trailing          // 右 + 垂直居中 = 「右侧居中」
        }
    }

    private var edgeInsets: EdgeInsets {
        switch recorder.cameraStripPlacement {
        case .belowNotch:
            return EdgeInsets(top: geometry.topInset, leading: geometry.notchCenteredLeadingInset,
                              bottom: 0, trailing: 0)
        case .left:
            return EdgeInsets(top: 0, leading: geometry.leadingInset, bottom: 0, trailing: 0)
        case .bottom:
            return EdgeInsets(top: 0, leading: 0, bottom: geometry.bottomInset, trailing: 0)
        case .right:
            return EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: geometry.trailingInset)
        }
    }
}

final class NotchRecordingOverlayController {

    static let shared = NotchRecordingOverlayController()

    private var panels: [NSPanel] = []
    private var phaseCancellable: AnyCancellable?
    private var isPresented = false
    /// 收起状态下两翼的屏幕矩形。窗口不动，所以它是常量，建面板时算一次。
    private var collapsedWingHitRects: [CGRect] = []

    /// 摄像头小窗的面板。**单独一个数组，绝不能和 `panels` 混。**
    ///
    /// 两个理由，任何一个单独都足够：
    /// - `reframePanels()` 会翻转 `panels` 里每个窗口的 `ignoresMouseEvents`，
    ///   而这个面板必须**永远**点击穿透 —— 它是全屏的，一旦收点击，整块屏幕都点不动。
    /// - `installDismissMonitors()` 的「点外面」判定是
    ///   `panels.contains { $0.frame.contains(location) }` —— 一个全屏成员会让
    ///   **每一次**点击都算「点在面板里面」，转写编辑框就再也收不起来了。
    private var cameraStripPanels: [NSWindow] = []

    /// 每个小窗面板收到的命中几何，键是面板身份。面板重建时旧键一起清掉。
    ///
    /// **由视图发布，不在 AppKit 里另算一份。** 收起态的窗口是
    /// `ignoresMouseEvents = true`（点击穿透），所以小窗上的按钮**一个都收不到真实
    /// 点击** —— 用户实测「左上角跟右上角这按钮完全没有功能」就是这个。全部走全局
    /// 监听和两翼是同一条路（刘海面板的静止 pill 用的也是这套）。
    ///
    /// 它不能用「标题栏里的相对横向位置」那种比例判定：上一版三个按钮时是
    /// 左 1/4 / 中 / 右 1/4，加到七个控件之后比例会碎成一团。
    private var cameraStripLayouts: [ObjectIdentifier: CameraStripLayoutSnapshot] = [:]

    /// 建面板时用的屏幕集合。拔了显示器/改了分辨率就整批重建。
    private var cameraStripScreenFrames: [CGRect] = []

    /// ⌘Enter 的监听。**按 `isCameraCapturing` 装卸** —— 见 `updateCameraStripShortcutMonitor`。
    private var cameraStripShortcutMonitor: Any?
    /// 收起时接管两翼点击的全局监听（0 = 左翼，1 = 右翼）。
    private var collapsedWingMonitor: Any?
    private var outsideClickMonitor: Any?
    private var escapeKeyMonitor: Any?
    /// 录音/润色期间的 ESC 取消监听 —— 和展开态无关，见 `updateCancellationMonitor`。
    private var cancellationMonitor: Any?

    private init() {}



    /// 由 `CompanionManager.start()` 调用一次。
    func startObservingRecorder() {
        guard phaseCancellable == nil else { return }
        let recorder = LongFormRecorderController.shared
        // 三个输入都要看：相位（在录/停了）、展开态（窗口高度）、是否还有未结束的
        // 会话（挂断之后面板要留着，绿色音波点一下继续录）。少看任何一个都会出现
        // 「点了没反应」或者「面板该在的时候不在」。
        phaseCancellable = Publishers.CombineLatest4(
            recorder.$phase, recorder.$isTranscriptExpanded, recorder.$isSessionActive,
            recorder.$isCameraCapturing)
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
            .sink { [weak self] _, _, _, _ in
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
                // ESC 取消这条路和展开态**无关**：收起状态下录音时也要能按 ESC 叫停。
                self.updateCancellationMonitor()
                // 摄像头小窗自己那块全屏面板，和它的 ⌘Enter 监听。
                self.syncCameraStripPanels()
                self.updateCameraStripShortcutMonitor()
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
            // 53 = ESC。
            guard event.keyCode == 53 else { return }
            Task { @MainActor in Self.handleEscapeKey() }
        }
    }

    /// ESC 按下去之后干什么。
    ///
    /// **分两档，先取消后折叠**：录音 / 转写 / 润色还在跑的时候，ESC 是「别做了」——
    /// 用户的要求是「无论它现在处于正在撰写、还是发送给 AI 模型，直接打断整个过程」；
    /// 都停了的时候，ESC 才是「收起这个窗口」（用户之前要的那条）。
    ///
    /// 顺序不能反：运行中按 ESC 却只把窗口收起来，用户会以为没生效，然后再按一次 ——
    /// 而那时任务已经跑完了。
    @MainActor
    static func handleEscapeKey() {
        let recorder = LongFormRecorderController.shared
        if recorder.phase != .idle || recorder.isPolishingTranscript {
            recorder.cancelCurrentRecording()
        } else {
            recorder.collapseTranscriptEditor()
        }
    }

    /// 录音 / 转写 / 润色期间的 ESC 监听。**它和展开态无关** —— 收起状态下录音时
    /// 也要能按 ESC 取消，所以单独一条，跟着「有没有活在跑」装卸。
    private func updateCancellationMonitor() {
        let isBusy = LongFormRecorderController.shared.phase != .idle
            || LongFormRecorderController.shared.isPolishingTranscript
        if isBusy {
            guard cancellationMonitor == nil else { return }
            cancellationMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
                guard event.keyCode == 53 else { return }
                Task { @MainActor in Self.handleEscapeKey() }
            }
        } else if let monitor = cancellationMonitor {
            NSEvent.removeMonitor(monitor)
            cancellationMonitor = nil
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
    /// **不再改窗口尺寸。** 只切换命中测试。
    ///
    /// 收起时窗口仍是展开那么大，多出来的那块是透明的 —— 必须让它**不收点击**，
    /// 否则用户在桌面那一片点什么都没反应。展开时才打开，编辑框和复制按钮要用。
    /// 收起状态下两翼的点击由 `collapsedWingHitRects` + 全局监听接管。
    private func reframePanels() {
        guard isPresented else { return }
        let isExpanded = LongFormRecorderController.shared.isTranscriptExpanded
        for panel in panels { panel.ignoresMouseEvents = !isExpanded }
        if isExpanded { installDismissMonitors() } else { removeDismissMonitors() }
        updateCollapsedWingMonitor()
    }

    /// 收起状态下，两翼在**屏幕坐标**里的矩形。
    ///
    /// 窗口不动，所以这两个矩形建好之后就是常量，算一次存着。
    private func computeCollapsedWingRects(for panel: NSPanel, notch: CGRect) -> [CGRect] {
        let bandWidth = NotchSupport.leadingWingWidth + notch.width + NotchSupport.trailingWingWidth
        let bandLeft = panel.frame.midX - bandWidth / 2
        let bandTop = panel.frame.maxY
        let wingWidth = (NotchSupport.leadingWingWidth + NotchSupport.trailingWingWidth) / 2 + 14
        let leading = CGRect(x: bandLeft, y: bandTop - notch.height,
                             width: wingWidth, height: notch.height)
        let trailing = CGRect(x: bandLeft + bandWidth - wingWidth, y: bandTop - notch.height,
                              width: wingWidth, height: notch.height)
        return [leading, trailing]
    }

    /// 收起时接管两翼点击的全局监听。0 = 左翼（展开编辑），1 = 右翼（停止/继续）。
    private func updateCollapsedWingMonitor() {
        let isExpanded = LongFormRecorderController.shared.isTranscriptExpanded
        if isExpanded || collapsedWingHitRects.isEmpty {
            if let m = collapsedWingMonitor { NSEvent.removeMonitor(m); collapsedWingMonitor = nil }
            return
        }
        guard collapsedWingMonitor == nil else { return }
        collapsedWingMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
            guard let self else { return }
            let point = NSEvent.mouseLocation

            // 摄像头小窗：按**视图发布的真实矩形**派发。
            //
            // 标题栏里没被任何控件矩形盖住的部分（那颗 Spacer）落到 `.toggleCollapse`
            // —— 「点这一条折叠小窗」那条既有行为就这么保住的，不需要为它专门留一个矩形。
            if let hit = self.cameraStripHitGeometry(at: point) {
                let control = CameraStripControl.allCases.first {
                    hit.controls[$0]?.contains(point) == true
                }
                Task { @MainActor in
                    LongFormRecorderController.shared
                        .handleCameraStripControl(control ?? .toggleCollapse)
                }
                return
            }

            guard let index = self.collapsedWingHitRects.firstIndex(where: { $0.contains(point) }) else { return }
            Task { @MainActor in
                if index == 0 {
                    SoundEffectPlayer.shared.play(.recordingEditorOpened)
                    LongFormRecorderController.shared.toggleTranscriptEditor()
                } else {
                    let recorder = LongFormRecorderController.shared
                    if recorder.isPolishingTranscript {
                    // **AI 润色中** —— 一道光扫过文字。
                    //
                    // 用户 2026-09-25 改的要求：「改为蓝白或蓝绿色彩光效果，光波在文字上
                    // 移动，移动时文字略微凸起或变化，**字号保持不变**」（原来那版是
                    // 字号忽大忽小，已经不是他要的了）。
                    //
                    // 字距：`AI` 和 `润色` 之间用一个 **thin space**（U+2009），
                    // 比普通空格窄、又不至于挨在一起 —— 用户：「缩小"AI"与"润色"之间的
                    // 字间距，保留一点空隙，不要完全挨着」。
                    ShimmeringPolishText(text: "AI\u{2009}润色中")
                } else if recorder.isFinalizingTranscript { recorder.cancelCurrentRecording() }
                    else if recorder.isRecording { recorder.stopRecording() }
                    else { recorder.startRecording(resumingCurrentSession: true) }
                }
            }
        }
    }


    // MARK: - 摄像头小窗：一块全屏、永不移动的点击穿透面板

    /// 把小窗的面板同步成「该显示就显示、该收就收」。
    ///
    /// 显示条件 = **抓帧中** 且 **转写编辑框没展开** —— 和它当初挂在字幕条下面时的
    /// 条件完全一致（展开态那块面板占满窗口高度，小窗本来就没地方放，而且那时用户
    /// 在看文字，不需要这个窗）。
    private func syncCameraStripPanels() {
        let recorder = LongFormRecorderController.shared
        let shouldShow = isPresented && recorder.isCameraCapturing && !recorder.isTranscriptExpanded
        guard shouldShow else {
            teardownCameraStripPanels()
            return
        }
        // 屏幕集合没变就什么都不用做 —— 位置变化靠 SwiftUI 自己重画
        //（`CameraStripPanelView` 观察着 `recorder`，`cameraStripPlacement` 是 @Published）。
        let screenFrames = NSScreen.screens.map(\.frame)
        if !cameraStripPanels.isEmpty, screenFrames == cameraStripScreenFrames { return }
        // 屏幕变了（拔了显示器、改了分辨率）就整批重建。这些面板没有任何状态，
        // 重建比逐个迁移便宜也安全。
        teardownCameraStripPanels()
        buildCameraStripPanels()
        cameraStripScreenFrames = screenFrames
    }

    private func buildCameraStripPanels() {
        let recorder = LongFormRecorderController.shared
        for screen in NSScreen.screens {
            guard let stripWidth = NotchSupport.cameraStripWidth(
                      on: screen, ribbonCornerRadius: NotchRecordingBandView.ribbonCornerRadius),
                  let notch = NotchSupport.notchRect(on: screen),
                  let geometry = NotchSupport.cameraStripGeometry(
                      on: screen,
                      stripWidth: stripWidth,
                      topInset: notch.height + NotchRecordingBandView.ribbonHeight)
            else { continue }

            let window = OverlayWindow(screen: screen)
            // **必须改回这一层。** `OverlayWindow` 生来是 `.screenSaver`（1000），那是给
            // 光标伴随物准备的 —— 它要求自己盖在右键菜单之上；小窗没这个需求，而
            // 「左中 / 右中」两个位置正好落在菜单弹出的区域里，一个 315pt 宽的黑块压住
            // 用户的右键菜单是看得见的缺陷。忘了这一行是**静默的**，小窗只是浮在所有东西上面。
            window.level = NotchSupport.cameraStripWindowLevel

            let hostingView = NSHostingView(rootView: CameraStripPanelView(
                recorder: recorder,
                geometry: geometry,
                // `window` 弱捕获：宿主视图由窗口持有，闭包再由宿主视图持有 ——
                // 强捕获就是 window → hostingView → rootView → 闭包 → window 的环，
                // 而且它活得比 `teardownCameraStripPanels` 还久。
                onLayoutChange: { [weak window] snapshot in
                    guard let window else { return }
                    let key = ObjectIdentifier(window)
                    let previous = self.cameraStripLayouts[key]?.titleBarFrame
                    self.cameraStripLayouts[key] = snapshot
                    // 位置一变，标题栏矩形就变 —— 这一行是验证时唯一能核对
                    // 「按钮到底有没有生效」的数字依据，所以只在真变了的时候打。
                    if let bar = snapshot.titleBarFrame, bar != previous {
                        SoundEffectPlayer.appendToDiagnosticLog(String(
                            format: "摄像头小窗标题栏（面板内）x=%.0f y=%.0f w=%.0f h=%.0f",
                            bar.minX, bar.minY, bar.width, bar.height))
                    }
                }))
            // 和录音带那块面板同一条规矩：宿主视图不许自己动窗口几何。
            hostingView.sizingOptions = []
            hostingView.frame = CGRect(origin: .zero, size: screen.frame.size)
            window.contentView = hostingView
            window.orderFrontRegardless()
            cameraStripPanels.append(window)
        }
        if !cameraStripPanels.isEmpty {
            SoundEffectPlayer.appendToDiagnosticLog("摄像头小窗面板已建：\(cameraStripPanels.count) 块")
        }
    }

    private func teardownCameraStripPanels() {
        guard !cameraStripPanels.isEmpty else { return }
        for panel in cameraStripPanels {
            cameraStripLayouts.removeValue(forKey: ObjectIdentifier(panel))
            panel.orderOut(nil)
        }
        cameraStripPanels.removeAll()
        cameraStripScreenFrames.removeAll()
    }

    /// 点在哪块小窗面板的标题栏里，以及那一下落在哪个控件上。
    ///
    /// 返回的矩形**已经换算成 AppKit 全局坐标**（`NSEvent.mouseLocation` 那一套）。
    private func cameraStripHitGeometry(
        at point: CGPoint
    ) -> (titleBar: CGRect, controls: [CameraStripControl: CGRect])? {
        for panel in cameraStripPanels {
            guard let snapshot = cameraStripLayouts[ObjectIdentifier(panel)],
                  let titleBarFrame = snapshot.titleBarFrame else { continue }
            let titleBar = Self.appKitGlobalRect(titleBarFrame, in: panel)
            guard titleBar.contains(point) else { continue }
            var controls: [CameraStripControl: CGRect] = [:]
            for (control, rect) in snapshot.controlFrames {
                controls[control] = Self.appKitGlobalRect(rect, in: panel)
            }
            return (titleBar, controls)
        }
        return nil
    }

    /// 换算本身住在 `NotchSupport`（纯几何），这里只是把面板的 frame 递过去。
    private static func appKitGlobalRect(_ rect: CGRect, in panel: NSWindow) -> CGRect {
        NotchSupport.appKitGlobalRect(fromPanelLocal: rect, panelFrame: panel.frame)
    }

    /// ⌘Enter：把小窗在「刘海下面」和「屏幕底部」之间来回切。
    ///
    /// **按 `isCameraCapturing` 装卸监听，而不是在回调里 `if`** —— 这才是用户要求的
    /// 「若摄像头未打开，该快捷键不会被软件识别」的**结构性**保证：摄像头没开时这条
    /// 监听根本不在系统里。`updateCancellationMonitor` 用的是同一个形状。
    ///
    /// **它和 ESC 一样只读不吞**：这个仓库里没有任何能拦截全局按键的机制
    /// （ESC 的两个监听、按住说话那个 CGEvent tap，全是 listen-only）。所以 ⌘Enter
    /// 也会传给你当前前台那个 App —— 在 Slack / 微信里就是「发送」。这是全局监听固有
    /// 的性质。不要去接一个会吞按键的 tap：那会让摄像头开着的那几分钟里 ⌘Enter
    /// 在全系统失效，比这个副作用糟得多。
    private func updateCameraStripShortcutMonitor() {
        let isCapturing = LongFormRecorderController.shared.isCameraCapturing
        guard isCapturing else {
            if let monitor = cameraStripShortcutMonitor {
                NSEvent.removeMonitor(monitor)
                cameraStripShortcutMonitor = nil
            }
            return
        }
        guard cameraStripShortcutMonitor == nil else { return }
        cameraStripShortcutMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            // **`isARepeat` 必须挡住。** 按住不放会连发，而这个动作是「切换」——
            // 不去重的话它会以按键重复的速率疯狂翻转。ESC 那两个监听没管这个是
            // 因为它们幂等，这个不是。
            guard !event.isARepeat else { return }
            // 主键盘回车 36 + 小键盘回车 76，两个都收。
            guard event.keyCode == 36 || event.keyCode == 76 else { return }
            // **精确等于 ⌘**（不是 `contains(.command)`），并排除 CapsLock 和小键盘标志
            // —— 否则 ⇧⌘Enter、⌥⌘Enter 也会触发。
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                .subtracting([.capsLock, .numericPad])
            guard flags == .command else { return }
            Task { @MainActor in
                LongFormRecorderController.shared.toggleCameraStripPlacement()
            }
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

    /// 收起整块。
    ///
    /// **不是直接 `orderOut`，而是先淡出。** 面板是一块独立窗口，压在 App 自己的
    /// 刘海 pill 上面；直接 `orderOut` 的话，它盖着的那块（黑带）在同一帧里从「面板
    /// 画的」切换到「pill 画的」，两者的尺寸/圆角不完全一致，中间那一瞬就是用户报的
    /// 「退出的时候整个刘海会闪一下」。淡出把这一帧的硬切换摊成 0.15 秒，切换点就看不
    /// 见了。
    private func hide() {
        guard isPresented else { return }
        isPresented = false
        let hiding = panels
        for panel in hiding {
            NSAnimationContext.beginGrouping()
            NSAnimationContext.current.duration = 0.15
            panel.animator().alphaValue = 0
            NSAnimationContext.endGrouping()
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 180_000_000)
            for panel in hiding {
                panel.orderOut(nil)
                panel.alphaValue = 1
            }
        }
        panels.removeAll()
        collapsedWingHitRects.removeAll()
        if let m = collapsedWingMonitor { NSEvent.removeMonitor(m); collapsedWingMonitor = nil }
        // 小窗的面板和它的快捷键监听一起收掉 —— 留一块全屏面板在屏幕上，
        // 或者留一条快捷键监听在系统里，都是「录音停了但还在吃按键」。
        teardownCameraStripPanels()
        if let m = cameraStripShortcutMonitor { NSEvent.removeMonitor(m); cameraStripShortcutMonitor = nil }
    }

    /// 面板要多高：静止时是「刘海 + 跑马灯」，展开时再加上那一整块面板。
    /// 面板的矩形。**它只在建面板时算一次，之后永不改变。**
    ///
    /// 这是「背景穿透」和抖动的根治办法。之前每次展开/收起都改窗口尺寸
    /// （359×64 ⇄ 718×592），而窗口是**透明**的 —— 黑色全靠 SwiftUI 画，窗口几何却
    /// 在 CA 提交**之前**就改了，SwiftUI 要到提交时才按新尺寸重画。中间那一瞬新露出来
    /// 的区域是空的，桌面就透出来。
    ///
    /// 窗口一动不动之后，**没有「窗口期」这个东西，穿透和抖动在结构上都不可能发生**。
    /// 收起时多出来的那块透明区域靠 `ignoresMouseEvents` 让开（见 `reframePanels`），
    /// 两翼的点击改走全局监听（见 `collapsedWingHitRects`）—— 刘海面板的静止 pill
    /// 用的就是这同一套办法。
    private func panelFrame(for screen: NSScreen) -> CGRect? {
        guard let notch = NotchSupport.notchRect(on: screen) else { return nil }
        let bandWidth = NotchSupport.leadingWingWidth + notch.width + NotchSupport.trailingWingWidth
        let panelWidth = min(bandWidth * 2, screen.frame.width - 40)
        let panelHeight = notch.height + NotchRecordingBandView.expandedPanelBodyHeight
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
        // 窗口不动，两翼矩形一次性算好；并且一建好就进入「收起」的命中状态。
        collapsedWingHitRects.append(contentsOf: computeCollapsedWingRects(for: panel, notch: notch))
        panel.ignoresMouseEvents = !LongFormRecorderController.shared.isTranscriptExpanded
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
