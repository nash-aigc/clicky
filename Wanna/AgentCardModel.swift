//
//  AgentCardModel.swift
//  Wanna
//
//  侧栏卡片区的数据：**卡片 = 一个 Agent 主体**（自研主循环 / Claude Code 兜底），
//  卡片下面按状态四栏挂着它的任务。
//
//  ## 为什么要有这一层（而不是让视图直接读三个 store）
//
//  这张树要把**三份**数据合起来，而合并规则只能有一处：
//
//    1. 卡片本身 —— 主循环卡片来自 `ConversationSessionsStore`（= `ConversationSession`），
//       Claude Code 卡片来自 `AgentSessionStore`（= `AgentSession`）。**卡片不新建表**，
//       卡片 id 就是它们现成的 UUID 字符串。
//    2. 还活着的任务 —— `AgentActivityBoard.shared.agents`（内存，刘海那条带子也读它）。
//    3. 结束/已交接的任务 —— `FinishedTaskStore`（落盘，归档页也读它）。
//
//  第 2、3 份会**同时**包含同一条任务（做完的任务在看板上还会留十分钟）。合并规则：
//  **以落盘的那份为准**（它带着归因：谁发起的、有没有兜底、失败原因），看板只补
//  「还没落盘的」（正在跑的那些）。视图里再各算一份，就一定会漂。
//
//  用户为什么在意这张树（2026-09-26 的原话）：「这样就能保证用户知道哪些任务是我自己
//  设计的 Agent 完成的、哪些是 Claude Code 完成的。然后我再复盘，我就能知道我应该有
//  哪些方向去升级我自己的 Agent。」
//

import Foundation
import Combine

@MainActor
final class AgentCardModel: ObservableObject {

    /// 一行任务 —— 视图要的那些字段都在这儿，来源是落盘记录或看板上的活任务。
    struct CardTask: Identifiable, Equatable {
        let id: String
        let title: String
        let request: String
        let status: EphemeralAgent.Status
        let startedAt: Date
        let finishedAt: Date?
        /// 谁在执行（nil = 自研）。
        let externalAgentKind: String?
        /// 被兜底过没有 —— 卡片上那枚标记、复盘要看的就是它。
        let wasHandedOff: Bool
        let handoffReason: String?
        /// 试过几次（`attempts` 的条数；活任务用它的 attempts）。
        let attemptCount: Int

        var relativeTimeText: String {
            let reference = finishedAt ?? startedAt
            let seconds = max(0, Date().timeIntervalSince(reference))
            if seconds < 60 { return "刚刚" }
            if seconds < 3600 { return "\(Int(seconds / 60))m" }
            if seconds < 86_400 { return "\(Int(seconds / 3600))h" }
            return "\(Int(seconds / 86_400))d"
        }
    }

    /// 一张卡片。
    struct Card: Identifiable, Equatable {
        /// `"mainLoop:<uuid>"` / `"claudeCode:<uuid>"`。
        let id: String
        let kind: CardKind
        /// 背后那条 `ConversationSession` / `AgentSession` 的 id。
        let entityID: String
        let title: String
        /// 只有主循环卡片可能为 true —— 用户明确要求 Claude Code 卡片不参与「设为默认」。
        let isDefault: Bool
        /// 四栏。只放非空的栏由视图决定，这里保证四栏都在（顺序由 `TaskColumn.allCases` 定）。
        let tasksByColumn: [TaskColumn: [CardTask]]

        func tasks(in column: TaskColumn) -> [CardTask] { tasksByColumn[column] ?? [] }
        var totalTaskCount: Int { tasksByColumn.values.reduce(0) { $0 + $1.count } }
    }

    /// **卡片之间的顺序**：主循环在前、Claude Code 在后。
    ///
    /// 用户只说了「按状态排」（栏内），卡片之间的顺序他没有指定；这个顺序是「我先做的
    /// 是自研那条线」的直接读法，也与「Claude Code 是兜底」的定位一致。要改就改这一处。
    @Published private(set) var cards: [Card] = []

    /// 侧栏搜索框的内容（卡片标题或它的任务命中）。
    @Published var searchQuery: String = ""

    private var observers: [NSObjectProtocol] = []

    init() {
        reload()
        let center = NotificationCenter.default
        // 四份数据各有各的变更通知 —— 任何一个变了这张树都要重算，否则侧栏会显示旧归属。
        for name in [Notification.Name.wannaSessionsDidChange,
                     .wannaAgentSessionsDidChange,
                     .wannaFinishedTasksDidChange,
                     .wannaAppSettingsChanged] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.reload() }
            })
        }
        // 看板是内存里的 @Published，用 Combine 订阅（它没有通知）。
        agentBoardCancellable = AgentActivityBoard.shared.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                // objectWillChange 在**改之前**发；推到下一拍再读，拿到的才是新值。
                Task { @MainActor in self?.reload() }
            }
    }

    private var agentBoardCancellable: AnyCancellable?

    /// 重建整张树。**合并规则写在 `mergeTasks(for:)`，只有一处。**
    func reload() {
        var built: [Card] = []

        // ① 主循环卡片：未归档的会话（正常情况下就一条 —— 用户点「新建」时上一条会自动归档）。
        let defaultSessionID = AppSettingsStore.snapshot().defaultSessionID
        for session in ConversationSessionsStore.allSessions() {
            let cardID = session.id.uuidString
            built.append(Card(id: "\(CardKind.mainLoop.rawValue):\(cardID)",
                              kind: .mainLoop,
                              entityID: cardID,
                              title: session.title,
                              isDefault: defaultSessionID == cardID,
                              tasksByColumn: columns(forCardKind: .mainLoop,
                                                     cardID: cardID,
                                                     sessionStartedAt: session.createdAt)))
        }

        // ② Claude Code 卡片：代理名册（兜底接手过的任务会出现在这里）。
        for agent in AgentSessionStore.allAgents() {
            let cardID = agent.id.uuidString
            built.append(Card(id: "\(CardKind.claudeCode.rawValue):\(cardID)",
                              kind: .claudeCode,
                              entityID: cardID,
                              title: agent.name,
                              isDefault: false,          // 兜底卡片永不参与「设为默认」
                              tasksByColumn: columns(forCardKind: .claudeCode,
                                                     cardID: cardID,
                                                     sessionStartedAt: nil)))
        }

        cards = filtered(built, query: searchQuery)
    }

    private func filtered(_ cards: [Card], query: String) -> [Card] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return cards }
        return cards.compactMap { card in
            if card.title.localizedCaseInsensitiveContains(trimmed) { return card }
            let matching = card.tasksByColumn.mapValues { tasks in
                tasks.filter {
                    $0.title.localizedCaseInsensitiveContains(trimmed)
                        || $0.request.localizedCaseInsensitiveContains(trimmed)
                }
            }
            guard matching.values.contains(where: { !$0.isEmpty }) else { return nil }
            return Card(id: card.id, kind: card.kind, entityID: card.entityID,
                        title: card.title, isDefault: card.isDefault, tasksByColumn: matching)
        }
    }

    /// 一张卡片的四栏。
    private func columns(forCardKind cardKind: CardKind,
                         cardID: String,
                         sessionStartedAt: Date?) -> [TaskColumn: [CardTask]] {
        var byColumn: [TaskColumn: [CardTask]] = [:]
        for column in TaskColumn.allCases { byColumn[column] = [] }
        for task in mergeTasks(forCardKind: cardKind,
                               cardID: cardID,
                               sessionStartedAt: sessionStartedAt) {
            byColumn[TaskColumn.column(forStatus: task.status,
                                       isArchived: isHistorical(task, sessionStartedAt: sessionStartedAt)),
                     default: []].append(task)
        }
        // 栏内排序：新的在前（用户没指定；时间是唯一能保证"最近发生的在最上面"的顺序）。
        for column in byColumn.keys {
            byColumn[column]?.sort { $0.startedAt > $1.startedAt }
        }
        return byColumn
    }

    /// **「历史任务」的判据**：这条任务属于这张卡片的**更早**一轮（早于当次会话的开始），
    /// 也就是「已经翻篇、但还留在这里给你复盘」的那些。
    ///
    /// 计划里标了这是我的读法、请你确认 —— 若你要的是「所有已结束的」，把这一行改成
    /// `true` 即可。
    private func isHistorical(_ task: CardTask, sessionStartedAt: Date?) -> Bool {
        guard let sessionStartedAt else { return false }   // Claude Code 卡片没有"当次会话"这个概念
        return task.startedAt < sessionStartedAt
    }

    /// **合并规则只有这一处。** 见文件头：落盘的那份优先（它带归因），看板只补还没落盘的。
    private func mergeTasks(forCardKind cardKind: CardKind,
                            cardID: String,
                            sessionStartedAt: Date?) -> [CardTask] {
        var merged: [String: CardTask] = [:]

        for finished in FinishedTaskStore.shared.allTasks() {
            // 老记录（2026-09-26 之前）没有 `cardKind` —— 那时任务都是自研派出去的，
            // 所以按主循环卡片归，id 用它的 `sessionID`。**不能丢**：归档里那 20 多条
            // 就是靠这一条落到卡片下的。
            let effectiveKind = finished.cardKind ?? .mainLoop
            let effectiveCardID = finished.cardID ?? finished.sessionID
            guard effectiveKind == cardKind, effectiveCardID == cardID else { continue }
            merged[finished.id] = CardTask(id: finished.id,
                                           title: finished.title,
                                           request: finished.request,
                                           status: finished.status,
                                           startedAt: finished.startedAt,
                                           finishedAt: finished.finishedAt,
                                           externalAgentKind: finished.externalAgentKind,
                                           wasHandedOff: finished.wasHandedOff,
                                           handoffReason: finished.handoffReason,
                                           attemptCount: finished.attempts?.count ?? 1)
        }

        for live in AgentActivityBoard.shared.agents {
            guard merged[live.id] == nil else { continue }   // 落盘的那份优先
            let effectiveKind = live.cardKind ?? .mainLoop
            let effectiveCardID = live.cardID ?? live.sessionID
            guard effectiveKind == cardKind, effectiveCardID == cardID else { continue }
            merged[live.id] = CardTask(id: live.id,
                                       title: live.title,
                                       request: live.request,
                                       status: live.status,
                                       startedAt: live.startedAt,
                                       finishedAt: live.finishedAt,
                                       externalAgentKind: live.externalAgentKind,
                                       wasHandedOff: live.handoffReason != nil,
                                       handoffReason: live.handoffReason,
                                       attemptCount: live.attempts.count)
        }

        return Array(merged.values)
    }

    // MARK: - 动作

    /// 「设为默认」：屏幕快捷键发出去的问题从此进这一条主循环会话。
    ///
    /// 只对主循环卡片成立 —— Claude Code 卡片上没有这颗按钮（用户明确要求
    /// 「新建的 Claude Code 类型卡片不可设为默认」）。
    func setDefault(cardID: String) {
        // `save` 抛的是「写不进磁盘」。默认会话是用户刚点下的选择，写不进去要说出来，
        // 但**不能让它把侧栏搞崩** —— 所以吞掉错误并留一行日志（写失败的清一色是
        // 磁盘权限/满盘，改天再点一次就是了）。
        do {
            try AppSettingsStore.save(AppSettingsStore.snapshot().withDefaultSessionID(cardID))
        } catch {
            print("⚠️ Wanna: 记不住默认会话（\(cardID)）—— \(error)")
        }
    }

    /// 点一张卡片：把右侧内容列切到它对应的那一页。
    func open(_ card: Card,
              sessionsModel: ConversationSessionsModel,
              agentSessionManager: AgentSessionManager) {
        switch card.kind {
        case .mainLoop:
            if let sessionID = UUID(uuidString: card.entityID) {
                sessionsModel.selectSession(sessionID)
            }
            agentSessionManager.selectedSidebarSection = .conversations
        case .claudeCode:
            if let agentID = UUID(uuidString: card.entityID) {
                agentSessionManager.selectAgent(agentID)
            }
            // 点 Claude Code 卡片要把右侧切到 Agent 那一页 —— `selectAgent` 只改
            // 「选中谁」，不给内容列换页（它原先由侧栏的切换器负责，现在那个
            // 切换器被卡片区取代了）。
            agentSessionManager.selectedSidebarSection = .agents
        }
    }
}
