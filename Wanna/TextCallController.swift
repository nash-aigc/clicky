//
//  TextCallController.swift
//  Wanna
//
//  **文本 / 图文模式下的「通话」**（用户 2026-09-26）。
//
//  用户的原话是：「文本模式和图文模式的通话按钮路线是使用语音识别的形式，跟用户通过快捷键
//  识别屏幕、然后提问、在鼠标右下角显示窗口回复内容是同一个方法……用户点击通话按钮之后，
//  识别用户的内容，然后自动发送出去……它的功能就是替用户发送文本，不用手动输入，识别到
//  用户的文本后自动发送过去就可以。」
//
//  所以它**一句话都不碰语音聊天那套引擎**：只是把「连续监听 + 自动发送」接到这张卡片原本
//  的文本管线上 —— 说一句话，等于在那张卡片的输入框里打一行字并按回车。回答走同一条路
//  （按模式决定截不截屏 → 视觉模型 / Claude Code → 光标旁的气泡 + 播报），所以观感与按
//  快捷键提问完全一致；刘海的样式借用语音 / 视频那条通话的状态
//  （`.externalChatting` + 右侧那颗挂断），这正是用户要的「整个样式、刘海的样式跟语音视频的
//  样式一样，就是一个通话的状态」。
//
//  ## 两条边界，都是结构性的
//
//  1. **它和语音聊天共用同一个连续监听窗口**（`BuddyDictationManager` 只有一份，见该文件的
//     注释）。所以两条通话不可能同时活着 —— 卡片上那颗通话按钮先按模式分流（语音 / 视频 →
//     语音聊天控制器，文本 / 图文 → 这里），就是这条边界的唯一入口。
//  2. **「通话活着」这件事由那个窗口定义**，不由这里的一个 Bool 定义：窗口一关（用户按了
//     快捷键去录音、权限掉了、语音聊天接管了），通话就结束。少了这条，屏幕上会出现一个
//     还在说「通话中」、实际已经听不见的刘海 —— 那种不一致比功能少更糟。
//
//  ## 打断
//
//  用户在回答播放 / 生成中说下一句 = 打断（与语音对话同一条规矩：**开口就是打断**）。
//  这里只做一件事：把当前那一轮收掉，然后**由那段话自己的最终转写**去开新的一轮 ——
//  不要在 `onSpeechDetected` 里自己发送，那会连开两轮（语音聊天那条路踩过同样的坑）。
//

import Foundation
import Combine

@MainActor
final class TextCallController: ObservableObject {

    /// 正在通话的那张卡片（nil = 没在通话）。卡片 id 与 `AppSettings` 里那套一致
    /// （主循环卡片 = 会话 uuid、Claude Code 卡片 = 代理记录 uuid）。
    @Published private(set) var activeCardID: String?
    private var activeCardKind: CardKind = .mainLoop

    private let dictationManager: BuddyDictationManager

    /// 把一句话交给那张卡片**原本**的文本框路径 —— 分派住在 `CompanionManager`
    /// （它同时认识主循环管线和 Claude Code 管线），这里不认识任何一条。
    private let sendQuestion: (String, String, CardKind) -> Void

    /// 打断当前这一轮（停播报 + 取消正在跑的那一次）。
    private let interruptActiveResponse: () -> Void
    /// 有没有一轮正在跑 / 正在念 —— 决定"用户开口了要不要先收掉"。
    private let isResponseRunning: () -> Bool
    private let setNotchOverride: (NotchActivityPhase?) -> Void
    private let noteVoiceActivity: () -> Void
    /// 起不来时说一句话给用户（权限被拒 / 窗口被占）。
    private let presentFailure: (String) -> Void

    private var listeningWindowCancellable: AnyCancellable?

    /// 文本 / 图文通话的门槛：**3**，与语音聊天同一个数、同一个理由（那一侧的注释里有
    /// 完整推导：3 字能放行「几点了」这类正经短问题，又能挡住识别器从我们自己的播报里
    /// 猜出来的 1~2 字残片 —— 残片一旦过闸就成了"新问题"，会切掉正在念的回答）。
    private static let minimumTranscriptCharacters = 3

    init(dictationManager: BuddyDictationManager,
         sendQuestion: @escaping (String, String, CardKind) -> Void,
         interruptActiveResponse: @escaping () -> Void,
         isResponseRunning: @escaping () -> Bool,
         setNotchOverride: @escaping (NotchActivityPhase?) -> Void,
         noteVoiceActivity: @escaping () -> Void,
         presentFailure: @escaping (String) -> Void) {
        self.dictationManager = dictationManager
        self.sendQuestion = sendQuestion
        self.interruptActiveResponse = interruptActiveResponse
        self.isResponseRunning = isResponseRunning
        self.setNotchOverride = setNotchOverride
        self.noteVoiceActivity = noteVoiceActivity
        self.presentFailure = presentFailure
        bindListeningWindow()
    }

    // MARK: - 状态

    var isActive: Bool { activeCardID != nil }

    /// 这张卡片现在是不是正在通话（卡片上那颗按钮的绿色高亮读它）。
    func isCalling(cardID: String) -> Bool { activeCardID == cardID }

    // MARK: - 起 / 停

    /// 打这一通「文本电话」。
    ///
    /// 起不来（麦克风权限被拒、窗口已经被别的会话占着）就**如实说一句**并回到 idle ——
    /// 让它静静地什么都不发生，用户只会以为是坏了。
    func start(cardID: String, cardKind: CardKind) async {
        guard activeCardID == nil else { return }

        activeCardID = cardID
        activeCardKind = cardKind
        // 刘海立刻进入「通话中」：它与语音 / 视频那条路同一个相位，右侧那颗挂断因此
        // 自动出现在同一个位置（不需要第二套命中矩形）。
        setNotchOverride(.externalChatting)
        // 通话期间麦克风是开着的，共享音频引擎不能被空闲倒计时抽走。
        noteVoiceActivity()

        let settings = AppSettingsStore.snapshot()
        await dictationManager.startContinuousListening(
            utteranceEndSilenceSeconds: settings.continuousListeningSilenceSendSeconds,
            minimumContentCharacters: Self.minimumTranscriptCharacters,
            onSpeechDetected: { [weak self] in
                // 开口就是打断：正在念 / 正在跑的那一轮先收掉。**不在这里发送** ——
                // 用户这句话自己的最终转写才是新的一轮（否则会连开两轮）。
                guard let self, self.isResponseRunning() else { return }
                self.interruptActiveResponse()
            },
            // 不逐字显示：文字按最终转写一次性进对话（与语音聊天页同一条口径）。
            onTranscriptUpdate: { _ in },
            onUtteranceFinalized: { [weak self] finalText in
                self?.handleFinalUtterance(finalText)
            },
            onUtteranceDropped: { droppedText in
                print("📞 文本通话：这句话太短，没有发送（\(droppedText)）")
            }
        )

        // 起不来：界面不能停在「通话中」。这一条与语音聊天那条一模一样。
        guard dictationManager.isContinuousListening else {
            endCall()
            presentFailure("通话：拿不到麦克风权限，没法开始。")
            return
        }
        print("📞 文本通话开始：卡片 \(cardID.prefix(8)) · 门槛 \(Self.minimumTranscriptCharacters) 字")

    }

    /// **听到一整句之后要做的事**（唯一一处）。
    ///
    /// 独立成方法而不是写在闭包里：它是这一整条路唯一会产生副作用的地方，值得有个名字
    /// ——`start` 里那两处回调（打断与最终转写）读起来才是两件不同的事。
    private func handleFinalUtterance(_ finalText: String) {
        guard let cardID = activeCardID else { return }
        // 上一轮还没结束就先收掉 —— 一次只答一个问题，而用户已经开口了。
        if isResponseRunning() { interruptActiveResponse() }
        print("📞 文本通话：把这句发出去 ——「\(finalText)」")
        sendQuestion(finalText, cardID, activeCardKind)
    }

    /// 挂断（卡片上那颗按钮再按一次、或者刘海右侧那颗电话）。
    func stop() {
        guard activeCardID != nil else { return }
        print("📞 文本通话结束：卡片 \(activeCardID?.prefix(8) ?? "-")")
        // 关窗会经 `bindListeningWindow` 回到 `endCall()`，所以这里只负责关窗。
        dictationManager.endContinuousListening()
        endCall()
    }

    /// 收尾：只改自己的状态与刘海，**不碰麦克风** —— 这条路是"窗口已经没了"时走的。
    private func endCall() {
        guard activeCardID != nil else { return }
        activeCardID = nil
        setNotchOverride(nil)
    }

    /// **把"通话是否活着"绑到那个连续监听窗口上。**
    ///
    /// 这是这个类里最要紧的一条不变量：通话的一切能力都来自那个窗口，窗口没了它就是个
    /// 假的「通话中」。而窗口可以被别的东西关掉 —— 用户按快捷键去录音（录音会先结束打开
    /// 的监听窗口）、权限掉了、语音聊天接手。与其在每一处都补一句"顺手把通话也停掉"，
    /// 不如就认这一个事实来源。
    private func bindListeningWindow() {
        listeningWindowCancellable = dictationManager.$isContinuousListening
            .receive(on: RunLoop.main)
            .sink { [weak self] isListening in
                guard let self, !isListening else { return }
                // 打开的那一瞬不处理（`start` 里已经置好状态），只在关闭时收尾。
                Task { @MainActor in self.endCall() }
            }
    }
}
