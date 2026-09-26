//
//  TemporaryConversationModel.swift
//  Wanna
//
//  「临时对话」—— 用当前对话模型聊几句，**关掉就没了**。
//
//  用户 2026-09-26 定的三条：
//
//    * 「临时对话内容显示在临时弹窗中，覆盖在当前会话上方…当前右侧会话内容保持不变」
//      —— 所以它**一个字节都不写进 `ConversationSessionsStore`**，底下那条会话
//      原样不动；
//    * 「点击「临时对话」后，右侧出现两个选项：屏幕、语音，默认均不勾选。若全勾选，
//      则每次发送问题截屏并播放生成结果；若不勾选，则相当于与理解模型对话」；
//    * 用当前对话模型（🧠），不另配一个。
//
//  为什么单独一个模型对象而不是往 `CompanionManager` 里塞：那条管线是**主对话**的
//  状态机（会话归属、历史、agent 循环、连续监听），临时对话跟它一个字都不该共享 ——
//  共享就会变成「临时对话污染了主对话的历史」这种最难查的一类问题。
//

import Foundation
import Combine

@MainActor
final class TemporaryConversationModel: ObservableObject {

    /// 一轮：问题 + 答案。答案边收边长（`isStreaming`）。
    struct Turn: Identifiable {
        let id = UUID()
        let question: String
        var answer: String = ""
        var isStreaming = false
        var failureText: String?
    }

    @Published private(set) var turns: [Turn] = []
    @Published private(set) var isAwaitingReply = false

    /// 「屏幕」：勾了才每次发送带上截图。**默认不勾**（用户明确要求）。
    @Published var sendsScreenshot = false
    /// 「语音」：勾了才把回答念出来。**默认不勾**。
    @Published var speaksReply = false

    /// 自己的客户端实例。`BailianVisionChatAPI` 每次请求都重新解析配置
    /// （仓规：**per-request**），所以多一个实例不会与主对话抢任何状态。
    private let visionChatAPI = BailianVisionChatAPI()
    private var currentReplyTask: Task<Void, Never>?

    /// 「与理解模型对话」用的系统提示词。**短**：临时对话是快问快答，
    /// 不是主对话那套带工具、带屏幕理解的长提示词（那套会把它变成另一个东西）。
    private static let temporarySystemPrompt = """
    你是一个临时对话助手。用户在快速问你一件事，直接回答，不要寒暄、不要复述问题。
    回答尽量短。你看不到用户的屏幕，除非这条消息里带了截图。
    """

    /// 发送一句。截图与播报按那两个勾选走。
    func send(_ rawText: String, companionManager: CompanionManager) {
        let question = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }

        currentReplyTask?.cancel()
        turns.append(Turn(question: question, isStreaming: true))
        let turnIndex = turns.count - 1
        isAwaitingReply = true

        let shouldCaptureScreenshot = sendsScreenshot
        let shouldSpeak = speaksReply

        currentReplyTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isAwaitingReply = false }
            do {
                // 勾了「屏幕」才截：不勾就是纯文字对话（用户：「若不勾选，则相当于与理解模型对话」）。
                var images: [(data: Data, label: String)] = []
                if shouldCaptureScreenshot {
                    let captures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
                    images = captures.map { (data: $0.imageData, label: $0.label) }
                }

                let (answerText, _) = try await self.visionChatAPI.analyzeImageStreaming(
                    images: images,
                    systemPrompt: Self.temporarySystemPrompt,
                    userPrompt: question,
                    onTextChunk: { [weak self] accumulatedText in
                        // **赋值，不是追加。**
                        //
                        // 这个回调每帧给的是**整段累积文本**，不是"新到的这一小块" ——
                        // `BailianVisionChatAPI.analyzeImageStreaming` 的最后一行是
                        // `await onTextChunk(currentAccumulatedText)`，参数名也写着
                        // `accumulatedText`。追加就把它变成了"前缀之和"：第 k 帧之后
                        // 屏上那段文字的长度约等于 k²/2，一条 30 字的回答会肿到 465 字、
                        // 十几行 —— 然后这一轮结束、下面那行 `answer = answerText`
                        // 把文字换回正确的那一份，整块又塌回去。用户 2026-09-26 报的
                        // 「临时对话时……回复的气泡总是闪一下，突然变大一下，即便回复的
                        // 是两个字的也会突然变大」就是它。
                        //
                        // 主对话那条路（`CompanionManager.swift` 里同一个回调）一直
                        // 都是赋值，所以只有临时对话有这个现象。
                        //
                        // 赋值之后 `answer` 在最后一帧就已经等于 `answerText`，下面那一行
                        // 因此是逐字节的 no-op —— 回合结束时界面上不再有任何变化。
                        guard let self, turnIndex < self.turns.count else { return }
                        self.turns[turnIndex].answer = accumulatedText
                    })

                guard turnIndex < self.turns.count else { return }
                self.turns[turnIndex].answer = answerText
                self.turns[turnIndex].isStreaming = false

                if shouldSpeak, !answerText.isEmpty {
                    await companionManager.speakTemporaryReply(answerText)
                }
            } catch is CancellationError {
                guard turnIndex < self.turns.count else { return }
                self.turns[turnIndex].isStreaming = false
            } catch {
                guard turnIndex < self.turns.count else { return }
                self.turns[turnIndex].isStreaming = false
                self.turns[turnIndex].failureText = error.localizedDescription
            }
        }
    }

    /// 关掉浮层 / 换回连续对话：**内容直接扔掉**（用完即弃，不落盘、不进历史）。
    func discardEverything() {
        currentReplyTask?.cancel()
        currentReplyTask = nil
        isAwaitingReply = false
        turns = []
        sendsScreenshot = false
        speaksReply = false
    }
}
