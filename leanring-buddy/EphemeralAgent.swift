import Foundation
import Combine

/// 一个**临时 agent** —— 用户的一次任务，而不是一个长期存在的对话。
///
/// ## 为什么是「一个任务一个」
///
/// 用户 2026-09-26 定死的形状：「每一个 agent 都是临时的，所以你不能用一个对话来固定它」。
/// 理由是任务本身分两类，而只有一类需要 agent：
///
/// - **固定的** → 做成脚本或技能（复盘就是干这个的），不需要 agent
/// - **即兴的** → 一次任务一个 agent，做完即散
///
/// 所以它**不挂在侧栏的会话列表上**：那里面装的是长期对话（Agent 页那几个 Claude Code
/// 会话，有自己的历史和层级）。把一次「保存杨幂资料」塞进去，等于让一个用完就扔的东西
/// 占一格永久界面。
///
/// ## 它记什么
///
/// 只记**给人看的**：这件事是什么、做到哪一步、成没成。工具调用单独放一列 ——
/// 用户的原话是「工具调用的部分一定要折叠起来，因为它会占用很多的空间」。
nonisolated struct EphemeralAgent: Identifiable, Sendable, Equatable {

    /// 任务的状态。**三态，不是两态** —— 方案 §04 给执行 agent 定的三态结果协议
    /// （`done_verified` / `done_unverified` / `failed`）在界面上的落点。
    /// 「做完了但没验证」和「做完了并且回读确认过」对用户是两件事：
    /// 前者他可能需要自己看一眼，后者可以放心。
    enum Status: String, Sendable, Equatable {
        case running
        case doneVerified
        case doneUnverified
        case failed

        var displayName: String {
            switch self {
            case .running: return "执行中"
            case .doneVerified: return "完成"
            case .doneUnverified: return "完成（未核验）"
            case .failed: return "没做成"
            }
        }
        var isFinished: Bool { self != .running }
    }

    /// **给用户复制的那一个。** 用户原话：「把这个 ID 复制…或者这 agent 的名字复制，
    /// 然后让用户知道他是哪一个，然后方便跟 AI 交流」—— 所以它要短、要能念出来、
    /// 要一眼认出是哪次任务。
    ///
    /// 形如 `a3f2` 的四位短码：够短能念，够长不易撞（同一分钟内起两个任务的概率很低，
    /// 真撞了也只是显示上少区分一次）。
    let id: String
    /// 这件事是什么 —— 取用户那句话的开头。
    let title: String
    /// 完整的用户原话。面板里显示，因为标题是截断的。
    let request: String
    let startedAt: Date
    var finishedAt: Date?
    var status: Status

    /// **给人看的步骤**（「点开了控制台」「滚动到底部」）。面板里逐行显示。
    var steps: [String]
    /// **工具/动作调用**。面板里**折叠** —— 用户明确要求，它们太长。
    var toolCalls: [String]

    init(id: String = EphemeralAgent.makeID(),
         title: String,
         request: String,
         startedAt: Date = Date()) {
        self.id = id
        self.title = title
        self.request = request
        self.startedAt = startedAt
        self.status = .running
        self.steps = []
        self.toolCalls = []
    }

    static func makeID() -> String {
        let alphabet = "23456789abcdefghjkmnpqrstuvwxyz"   // 去掉 0/o/1/l/i，念和抄都不容易错
        return String((0..<4).map { _ in alphabet.randomElement()! })
    }

    var durationSeconds: Double {
        (finishedAt ?? Date()).timeIntervalSince(startedAt)
    }

    /// 按钮下面那张卡显示的两行。
    ///
    /// **最后一步 + 状态**，不是标题 —— 卡片的用处是「现在怎么样了」，
    /// 而标题在按钮上已经能看个大概了。
    var bannerLine: String {
        if let last = steps.last { return last }
        return status == .running ? "正在执行…" : status.displayName
    }
}

/// 桌面上那些临时 agent 的看板。
///
/// **它是界面唯一的真相。** 刘海左侧的按钮、按钮下面弹出的卡片、点击之后那块面板，
/// 三处全读这一个对象 —— 三个各自记一份「谁在跑」必然会漂，而漂了以后用户看到的
/// 是「按钮亮着但面板是空的」。
@MainActor
final class AgentActivityBoard: ObservableObject {

    static let shared = AgentActivityBoard()
    private init() {}

    /// 卡片自动收起的时间。用户说的是「显示两秒钟」。
    static let bannerHoldSeconds: Double = 2.0

    /// 一条任务记录活多久。
    ///
    /// **不是永久留着。** 用户要的是「做完就变成正常按钮」—— 而一块永远排满按钮的
    /// 刘海左侧，比没有还糟。做完的任务还留在这里，是为了让用户点开看刚才发生了什么；
    /// 过了这个时间就整条拿走。
    static let retentionSeconds: Double = 10 * 60

    /// 新的在前 —— 左侧按钮从刘海往左排，最新的离刘海最近（最容易被看到）。
    @Published private(set) var agents: [EphemeralAgent] = []
    /// 哪些 agent 的卡片正在展开。用 id 而不是给 struct 加字段：展开是**界面的**状态，
    /// 不是任务的属性 —— 任务不该知道自己正被显示着。
    @Published private(set) var expandedIDs: Set<String> = []

    // MARK: - 生命周期

    /// 一次任务开始。返回它的 id，调用方后面用它来追加步骤。
    @discardableResult
    func beginTask(request: String) -> String {
        pruneExpired()
        let agent = EphemeralAgent(title: Self.shortTitle(from: request), request: request)
        agents.insert(agent, at: 0)
        SoundEffectPlayer.appendToDiagnosticLog(
            "临时 agent \(agent.id) 开始：\(agent.title)")
        return agent.id
    }

    func appendStep(_ text: String, to agentID: String) {
        guard let index = agents.firstIndex(where: { $0.id == agentID }) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        agents[index].steps.append(trimmed)
        // **展开两秒然后自己收起来。** 用户的原话：「显示两秒钟之后…它就直接显示，
        // 如果执行完成了…它就折叠、就隐藏了，那就变成一个完整的、正常的一个按钮」。
        //
        // 代次计数：一次还没收完又来了新的一步，旧的定时不许把新的收掉。
        expandedIDs.insert(agentID)
        scheduleCollapse(of: agentID)
    }

    func appendToolCall(_ text: String, to agentID: String) {
        guard let index = agents.firstIndex(where: { $0.id == agentID }) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        agents[index].toolCalls.append(trimmed)
    }

    func finishTask(_ agentID: String, status: EphemeralAgent.Status) {
        guard let index = agents.firstIndex(where: { $0.id == agentID }) else { return }
        agents[index].status = status
        agents[index].finishedAt = Date()
        SoundEffectPlayer.appendToDiagnosticLog(
            "临时 agent \(agentID) \(status.displayName)："
            + "\(agents[index].toolCalls.count) 次工具调用，\(agents[index].steps.count) 条步骤")
        expandedIDs.insert(agentID)
        scheduleCollapse(of: agentID)
    }

    /// 用户点了按钮：展开/收起那块面板。**和「卡片自动收」是两条路** ——
    /// 用户手动点开的不许被定时收掉。
    func togglePanel(_ agentID: String) {
        manualPanelID = (manualPanelID == agentID) ? nil : agentID
    }

    /// 面板开着的那一个。nil = 没开。
    @Published var manualPanelID: String?

    // MARK: - 内部

    private var collapseGenerations: [String: Int] = [:]

    private func scheduleCollapse(of agentID: String) {
        let generation = (collapseGenerations[agentID] ?? 0) + 1
        collapseGenerations[agentID] = generation
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(Self.bannerHoldSeconds * 1_000_000_000))
            guard self.collapseGenerations[agentID] == generation else { return }
            self.expandedIDs.remove(agentID)
        }
    }

    /// 过期的拿走。
    ///
    /// **面板正开着的那一个不拿** —— 用户正在看它，把它从底下抽走是最糟的一种。
    private func pruneExpired() {
        let cutoff = Date().addingTimeInterval(-Self.retentionSeconds)
        agents.removeAll { agent in
            guard let finishedAt = agent.finishedAt, finishedAt < cutoff else { return false }
            return agent.id != manualPanelID
        }
    }

    /// 从用户那句话里取一个短标题。
    ///
    /// 去掉语气词开头（「嗯」「那个」「帮我」），因为按钮上只有几个字的位置，
    /// 而「嗯，帮我…」占掉一半。取不到就退回原话的前几个字。
    private static func shortTitle(from request: String) -> String {
        var text = request.trimmingCharacters(in: .whitespacesAndNewlines)
        for filler in ["嗯，", "嗯 ", "那个，", "那个 ", "然后，", "然后 ", "帮我", "请", "麻烦"] {
            while text.hasPrefix(filler) { text.removeFirst(filler.count) }
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return String(request.prefix(8)) }
        return String(text.prefix(10))
    }
}
