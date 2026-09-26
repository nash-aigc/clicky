//
//  TemporaryConversationOverlay.swift
//  Wanna
//
//  「临时对话」的浮层：盖在当前会话之上，宽高跟着内容列走。
//
//  用户 2026-09-26：「临时对话内容显示在临时弹窗中，覆盖在当前会话上方，宽度高度与
//  当前窗口一致，当前右侧会话内容保持不变」。
//
//  做成**内容列上的一层 overlay**（而不是整个刘海的整窗接管）：右列被完全盖住、
//  左列（卡片区）照常可点 —— 「当前右侧会话内容保持不变」这句就是这个意思，底下的
//  会话没有被改写，只是被盖住了；关掉浮层它就原样回来。
//
//  输入框直接用 `MessageComposerField`（三个内容页共用的那一个）：临时对话的输入需求
//  和主对话一模一样（三行、展开、回车/⌘回车发送），再写一个必然漂。
//

import SwiftUI

struct TemporaryConversationOverlay: View {

    @ObservedObject var model: TemporaryConversationModel
    @ObservedObject var companionManager: CompanionManager
    /// 关掉它：调用方把模式切回「连续对话」，并清空内容。
    var onClose: () -> Void

    @State private var draft = ""
    @State private var isComposerExpanded = false
    @State private var contentColumnHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Color.white.opacity(0.08))
            transcript
            composerRow
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            // 不透明：它是「另一段对话」，透出底下的会话只会让人分不清自己在跟谁说话。
            DS.Colors.surface3
        )
        .background(
            GeometryReader { geometryProxy in
                Color.clear
                    .onAppear { contentColumnHeight = geometryProxy.size.height }
                    .onChange(of: geometryProxy.size.height) { _, newHeight in
                        contentColumnHeight = newHeight
                    }
            }
        )
    }

    /// 页头：名字 + 两个勾选 + 清空 + 关闭。
    ///
    /// **「屏幕」「语音」放在这里而不是输入框那行**：那两个勾选只对临时对话有意义
    /// （主对话的「屏幕」是另一套语义），跟着浮层走，关掉就复位 —— 状态在
    /// `TemporaryConversationModel` 里，默认都是不勾（用户明确要求）。
    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.75))
            Text("临时对话")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
            Text("不记进任何会话，关掉就没了")
                .font(.system(size: 10.5))
                .foregroundColor(.white.opacity(0.40))

            Spacer(minLength: 6)

            toggleChip(title: "屏幕", systemImage: "rectangle.on.rectangle",
                       isOn: model.sendsScreenshot,
                       helpOn: "每次发送都带上截图",
                       helpOff: "不截屏，纯文字对话") {
                model.sendsScreenshot.toggle()
            }
            toggleChip(title: "语音", systemImage: "speaker.wave.2",
                       isOn: model.speaksReply,
                       helpOn: "回答用语音念出来",
                       helpOff: "只显示文字，不念") {
                model.speaksReply.toggle()
            }

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.white.opacity(0.55))
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(Color.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help("关掉临时对话（内容不会保留）")
        }
        .padding(.horizontal, NotchSupport.contentColumnHorizontalMargin)
        .frame(height: NotchSupport.contentColumnHeaderBandHeight)
    }

    private func toggleChip(title: String,
                            systemImage: String,
                            isOn: Bool,
                            helpOn: String,
                            helpOff: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: isOn ? "checkmark" : systemImage)
                    .font(.system(size: 9.5, weight: .semibold))
                Text(title).font(.system(size: 11.5))
            }
            .foregroundColor(isOn ? DS.Colors.success : .white.opacity(0.55))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.white.opacity(isOn ? 0.10 : 0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(isOn ? DS.Colors.success.opacity(0.55) : Color.white.opacity(0.08),
                                  lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help(isOn ? helpOn : helpOff)
    }

    private var transcript: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if model.turns.isEmpty {
                    Text("这一页不记进任何会话。勾上「屏幕」它会看着你的屏幕回答，勾上「语音」它会念出来。")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.38))
                        .padding(.top, 12)
                }

                ForEach(model.turns) { turn in
                    outgoingBubble(turn.question)
                    if let failureText = turn.failureText {
                        Text(failureText)
                            .font(.system(size: 11.5))
                            .foregroundColor(.red.opacity(0.75))
                            .padding(.horizontal, 12)
                    } else if !turn.answer.isEmpty {
                        AnswerCardView(text: turn.answer,
                                       isStreaming: turn.isStreaming,
                                       style: AppSettingsStore.snapshot().answerCardStyle)
                    } else if turn.isStreaming {
                        Text("在想…")
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.40))
                    }
                }
            }
            .padding(.horizontal, NotchSupport.contentColumnHorizontalMargin)
            .padding(.vertical, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func outgoingBubble(_ text: String) -> some View {
        HStack {
            Spacer(minLength: 56)
            Text(text)
                .font(.system(size: 13.5))
                .foregroundColor(.white)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(DS.Colors.userBubbleFill)
                )
        }
    }

    private var composerRow: some View {
        MessageComposerField(
            placeholder: "临时问一句，回车发送…",
            draft: $draft,
            isFocused: .constant(false),
            height: composerHeight,
            isExpanded: isComposerExpanded,
            canToggleExpansion: contentColumnHeight > 0,
            onToggleExpansion: { isComposerExpanded.toggle() },
            onSubmit: {
                let text = draft
                draft = ""
                model.send(text, companionManager: companionManager)
            },
            isResponding: model.isAwaitingReply,
            onStop: { model.discardEverything() }
        )
        .padding(.horizontal, NotchSupport.contentColumnHorizontalMargin)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    private var composerHeight: CGFloat {
        guard isComposerExpanded, contentColumnHeight > 0 else {
            return MessageComposerField.threeLineHeight
        }
        return contentColumnHeight * 0.30
    }
}
