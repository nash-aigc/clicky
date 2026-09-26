//
//  ActionTagParser.swift
//  leanring-buddy
//
//  Parses the "action tags" a model is allowed to put at the end of its reply —
//  [POINT:…], [CLICK:…], [SCROLL:…], [TYPE:…], [SELECT:…], [PRESS:…], [OPEN:…],
//  [WAIT:…], [AX_TREE].
//
//  Pointing lives in this file too, but it is deliberately kept out of the
//  returned `actions` list. Pointing only moves the blue cursor; everything in
//  `actions` changes the user's actual machine. Keeping the two apart means the
//  code that executes actions can never accidentally run a point, and the
//  setting that turns pointing off cannot turn acting off along with it.
//
//  This is the single place either tag family is parsed. `CompanionManager`'s
//  older point-only parser is now a thin adapter over `parse(from:)` rather than
//  a second regex, because two regexes for one tag would eventually disagree.
//

import CoreGraphics
import Foundation

/// A coordinate the model reported, together with the optional element name and
/// the screen it belongs to.
///
/// `normalizedCoordinate` is on the model's **0–1000 grid**, not in screenshot
/// pixels and not in screen points. The name says so on purpose: a normalized
/// value and a plausible pixel value look identical, so mixing them up fails
/// silently rather than crashing — the cursor simply lands somewhere else. See
/// `CompanionManager.screenshotPixelCoordinate(fromNormalizedPoint:...)` for the
/// documented conversion and why it exists.
nonisolated struct ModelReportedCoordinate: Sendable {
    let normalizedCoordinate: CGPoint
    let elementLabel: String?
    /// Which screen the coordinate refers to, 1-based as the model numbers them,
    /// or nil to mean "whichever screen the mouse is on".
    let screenNumber: Int?
}

nonisolated enum ScrollDirection: String, Sendable {
    case up
    case down
}

/// A green mark the model wants drawn over the user's screen with a
/// `[SHAPE:…]` tag — a ring around the thing it means, an arrow showing where
/// something goes, a curve tracing a flow. Purely visual: unlike
/// `CompanionAction`, none of these touch the machine, which is why they ride
/// in `ActionParseResult` beside `pointingRequest` rather than in `actions`.
nonisolated enum AnnotationShapeKind: String, Sendable {
    /// A ring around something: the first point is its centre, the second a
    /// point just past its edge — the distance between the two is the radius.
    case circle
    /// From the first point to the second, with an arrowhead at the second.
    case arrow
    /// A plain segment between two points.
    case line
    /// A smooth curve through three or more points.
    case curve
    /// A closed outline through three or more points.
    case polygon

    /// How many points each kind needs to be drawable. Fewer is a malformed
    /// tag rather than a draw request — a ring around nothing has no meaning.
    var minimumPointCount: Int {
        switch self {
        case .circle, .arrow, .line:
            return 2
        case .curve, .polygon:
            return 3
        }
    }
}

nonisolated struct AnnotationShapeRequest: Sendable {
    let kind: AnnotationShapeKind
    /// The shape's points on the model's **0–1000 normalized grid**, in the
    /// order the model wrote them. Same grid as `[POINT:…]`, same conversion
    /// machinery — never screenshot pixels, which is what a raw value looks
    /// like and fails silently as.
    let points: [CGPoint]
    /// Short text the drawing is about ("export", "付款流程"), drawn in a small
    /// capsule beside the shape, or nil. Also the **anchor**: enclosing shapes
    /// look an element up by it in the AX tree. The two jobs are separable —
    /// `label` stays the element's own on-screen words while `displayLabel`
    /// carries whatever caption the user asked for (`锚定词|显示文字`).
    let label: String?
    /// The caption to actually draw, when the tag wrote `anchor|display` and
    /// the user asked for a label different from the element's own name. nil
    /// means draw `label` unchanged.
    let displayLabel: String?
    /// Which screen the shape belongs to, 1-based as the model numbers them,
    /// or nil to mean "whichever screen the mouse is on" — same rule as
    /// `[POINT:…]`.
    let screenNumber: Int?
}

/// Something the companion can do to the user's machine.
nonisolated enum CompanionAction: Sendable {
    case click(at: ModelReportedCoordinate)
    case rightClick(at: ModelReportedCoordinate)
    case doubleClick(at: ModelReportedCoordinate)
    case scroll(at: ModelReportedCoordinate, direction: ScrollDirection, amountInSteps: Int)
    case typeText(String)
    case pressKey(keyName: String, modifierNames: [String])
    /// Select a stretch of text in the focused text area **by content**: from the
    /// first occurrence of `startMarker` to the end of `endMarker` (or just the
    /// `startMarker` occurrence when there is no end). Resolved against the text
    /// area's real value through Accessibility, so it needs no coordinates at all —
    /// which is the point: a model anchoring a range deletion on a clicked
    /// position deletes one line too much whenever the click lands one line off.
    case selectText(startMarker: String, endMarker: String?)
    case openApplication(named: String)
    /// Do nothing for `seconds` — the pause the agent loop needs when the screen
    /// is visibly mid-change (a page loading, a window animating in) and acting
    /// on the next step now would act on a screen that has not settled yet.
    /// Without it the model's only way to "wait" is to report the job finished.
    case wait(seconds: Int)
    /// Ask for a fresh read of the frontmost app's accessibility tree. The result
    /// arrives on the *next* turn, which is what makes a multi-step action
    /// possible: look at the interface, then act on what is really there.
    case readAccessibilityTree
    /// Hand a task to the fourth exit — the desktop file agent, a Python
    /// subprocess whose whole world is `~/Desktop` (view / read / write /
    /// edit files there). The task text is the only free part: the executor
    /// is one fixed script, so this stays a "model picks from a menu" action,
    /// never arbitrary command generation. Its result rides back as a data
    /// block on the next turn, which is what lets the model answer questions
    /// about the files ("这个文件夹里有什么") through the agent too.
    case runDesktopFileAgent(task: String)
    /// Hand a task to the fifth exit — the figure agent, a Python subprocess
    /// that turns a figure description into a precise geometry SVG via the
    /// local geometry-dsl compiler (the model writes a `.geom` description,
    /// the compiler computes every coordinate). One fixed script, task text
    /// the only free part; the rendered figure lands in `~/Desktop/Clicky图形/`
    /// and opens in front of the user. Same shape as `runDesktopFileAgent`.
    case runFigureAgent(task: String)
}

nonisolated struct ActionParseResult: Sendable {
    /// The reply with every tag removed — this is what gets spoken aloud.
    let spokenText: String
    /// The first [POINT:…] tag, or nil when the model pointed at nothing (it
    /// wrote [POINT:none], or wrote no point tag at all).
    let pointingRequest: ModelReportedCoordinate?
    /// Every action tag, in the order the model wrote them.
    let actions: [CompanionAction]
    /// Every [SHAPE:…] tag, in the order the model wrote them — drawings for
    /// the user's eyes only, never executed and never fed back as actions.
    let shapeRequests: [AnnotationShapeRequest]
    /// Every [AGENT_SPAWN:…] / [AGENT_SEND:…] tag. Deliberately NOT in
    /// `actions`: dispatching a background agent touches no screen, so it must
    /// not enter the one-action-per-screenshot continuation loop — these are
    /// handed to `AgentSessionManager` directly, the way `shapeRequests` are
    /// handed to the annotation manager.
    let agentRequests: [AgentDispatchRequest]
    /// 主 agent 把这件事派给了哪个 sub agent（`[AGENT:图形]`）。
    ///
    /// **和 `agentRequests` 是两件不同的事**，别混：那个是把活交给 Clicky 常驻的
    /// Claude Code 会话（后台、跨轮次、有名单）；这个是主 agent 把**这一轮**的活交给
    /// 三个 sub agent 之一，它当场跑完、结果回到这一轮的循环里。
    ///
    /// 同样**不进 `actions`**：派活本身不碰屏幕，不该触发「截图 → 续写」那个循环。
    let subAgentRequest: SubAgentRole?
    /// `[AGENT:名字:要做什么]` 里那个「要做什么」。
    ///
    /// **它是子 agent 那一轮的用户消息。** 没有它，子 agent 拿到的是**同一句用户原话**，
    /// 得自己再猜一遍主 agent 想让它干什么 —— 而「主 agent 决定做什么」这件事实际上
    /// 就等于没有被决定。官方把任务放在调用里（`Agent(subagent_type, prompt)`），
    /// 并且明说子 agent 就靠这个 prompt 拿全部信息。
    ///
    /// nil = 模型没写任务，调用方回落。
    let subAgentTask: String?
    /// 每一个 `[MCP:服务器.工具:{json}]`。
    ///
    /// **不进 `actions`**：一次 MCP 调用不碰屏幕，不该触发「截图 → 续写」那个循环 ——
    /// 和派活、图形板同一个理由。它当场跑完，结果作为一个数据块回给模型。
    ///
    /// **归执行 agent。** MCP 是「跑脚本 / 调工具」那一类能力（方案 §06 §一），
    /// 图形和文本 agent 都没有。判定在调用处，不在这里 —— 解析器只该回答
    /// 「模型写了什么」，不该回答「它有没有资格」。
    let mcpRequests: [MCPToolRequest]
    /// Every [SVG_BOARD:…] tag, in the order the model wrote them — figures
    /// for the user's eyes, drawn on screen next to a named element. Deliberately NOT in
    /// `actions`: a board touches no screen state, so it must not enter the
    /// one-action-per-screenshot continuation loop — these are handed to the
    /// figure-board controller, the way `shapeRequests` are handed to the
    /// annotation manager.
    let figureBoardRequests: [FigureBoardRequest]

    init(
        spokenText: String,
        pointingRequest: ModelReportedCoordinate?,
        actions: [CompanionAction],
        shapeRequests: [AnnotationShapeRequest] = [],
        agentRequests: [AgentDispatchRequest] = [],
        subAgentRequest: SubAgentRole? = nil,
        subAgentTask: String? = nil,
        mcpRequests: [MCPToolRequest] = [],
        figureBoardRequests: [FigureBoardRequest] = []
    ) {
        self.spokenText = spokenText
        self.pointingRequest = pointingRequest
        self.actions = actions
        self.shapeRequests = shapeRequests
        self.agentRequests = agentRequests
        self.subAgentRequest = subAgentRequest
        self.subAgentTask = subAgentTask
        self.mcpRequests = mcpRequests
        self.figureBoardRequests = figureBoardRequests
    }
}

/// 一次 `[MCP:服务器.工具:{json}]` —— 模型要调一个 MCP 工具。
nonisolated struct MCPToolRequest: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        /// `[MCP:服务器.工具:{json}]` —— 调一个工具。
        case call
        /// `[MCP:服务器.*]` —— 先看这个服务器有什么工具。
        ///
        /// **这一步是必须的，不是便利。** 方案 §08 明写「工具 schema 不直接注入
        /// 提示词」，所以模型手上根本没有工具清单；不给它一条「先问有什么」的路，
        /// 它只能猜工具名 —— 而猜错的表现是「服务器报错」，不是「你该先列一下」。
        case listTools
    }

    let kind: Kind
    let serverName: String
    let toolName: String
    /// 参数，**原始 JSON 字符串**，由调用处解析成字典。
    ///
    /// 留成字符串而不是在这里就解析成字典，是因为解析器至今只依赖
    /// Foundation + CoreGraphics、能脱离 App 单独跑（见这个文件的头注释）。
    /// 引一个 `[String: Any]` 进来不会破坏那一点，但会把「参数对不对」这件事
    /// 混进「标签怎么写」里 —— 它们该分开报错。
    let argumentsJSON: String
}

/// 主 agent 写了 `[AGENT:谁]` 但那个名字认不出来时，记一次。
///
/// **不能静默丢掉。** 丢掉的后果和「模型根本没派活」在日志里长得一模一样 ——
/// 而这两件事的修法完全不同（一个是提示词里名字写错了，一个是目录没讲清）。
/// 只记最后一个，因为这个类型是 `nonisolated`，而它服务的是一条诊断日志。
nonisolated enum UnknownSubAgentName {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var lastSeen: String?

    static func record(_ name: String) {
        lock.lock(); lastSeen = name; lock.unlock()
    }

    static func consume() -> String? {
        lock.lock(); defer { lock.unlock() }
        let value = lastSeen; lastSeen = nil; return value
    }
}

/// One [AGENT_SPAWN:…] or [AGENT_SEND:…] tag: the model asking the voice
/// companion to act as a dispatcher — start a background agent, or hand a
/// follow-up instruction to one that already exists.
nonisolated struct AgentDispatchRequest: Sendable {
    nonisolated enum Kind: Sendable {
        /// Start a new agent named `agentName` and give it `message` as its
        /// first task.
        case spawn
        /// Give `message` to the existing agent named `agentName`.
        case send
    }

    let kind: Kind
    /// The agent's name as the model wrote it — matched against the roster
    /// case-insensitively, by containment, because the model may abbreviate.
    let agentName: String
    /// The task text: a new agent's first instruction, or an existing agent's
    /// follow-up.
    let message: String
}

/// One [SVG_BOARD:元素名：任务] tag: the model asking for a figure drawn ON
/// SCREEN, on a small white board placed next to a named element — the
/// screen-anchored sibling of [SVG_AGENT], which instead opens the figure as
/// a file. Deliberately NOT in `actions`, exactly like shapeRequests and
/// agentRequests: a board is a drawing for the user's eyes, so it must not
/// enter the one-action-per-screenshot continuation loop.
nonisolated struct FigureBoardRequest: Sendable {
    /// The on-screen element's own wording the anchor resolves against — the
    /// same label vocabulary the click path's AX lookup ranks (exact name →
    /// control-sized → nearest).
    let anchorLabel: String
    /// The figure description, passed to the figure agent verbatim.
    let task: String
}

nonisolated enum ActionTagParser {

    // MARK: - Tag patterns

    /// `[POINT:x,y]`, `[POINT:x,y:label]`, `[POINT:x,y:label:screen2]`,
    /// `[POINT:none]` — and the same four shapes for the three click kinds.
    ///
    /// Capture groups: 1 = which tag, 2 = x, 3 = y, 4 = label, 5 = screen number.
    private static let pointingAndClickingPattern =
        #"\[(POINT|CLICK|RIGHT_CLICK|DOUBLE_CLICK):(?:none|(\d+)\s*,\s*(\d+)(?::([^\]:\s][^\]:]*?))?(?::screen(\d+))?)\]"#

    /// `[SCROLL:x,y:up:3]` with an optional `:label` and an optional `:screenN`.
    ///
    /// Capture groups: 1 = x, 2 = y, 3 = direction, 4 = steps, 5 = label, 6 = screen.
    private static let scrollingPattern =
        #"\[SCROLL:(\d+)\s*,\s*(\d+):(up|down):(\d+)(?::([^\]:\s][^\]:]*?))?(?::screen(\d+))?\]"#

    private static let typingPattern = #"\[TYPE:([^\]]*)\]"#
    private static let selectingPattern = #"\[SELECT:([^\]]+)\]"#
    private static let pressingPattern = #"\[PRESS:([^\]]+)\]"#
    private static let openingPattern = #"\[OPEN:([^\]]+)\]"#
    private static let accessibilityTreePattern = #"\[AX_TREE\]"#
    private static let waitingPattern = #"\[WAIT:([^\]]+)\]"#

    /// `[PY_AGENT:把 todo.txt 的内容改成……]` — hand a task to the desktop file
    /// agent (the fourth exit). The task is the whole rest of the tag.
    ///
    /// Capture group: 1 = task text.
    private static let desktopAgentPattern = #"\[PY_AGENT:([^\]]+)\]"#

    /// `[SVG_AGENT:画一个三角形和它的外接圆]` — hand a task to the figure agent
    /// (the fifth exit). The task is the whole rest of the tag.
    ///
    /// Capture group: 1 = task text.
    private static let figureAgentPattern = #"\[SVG_AGENT:([^\]]+)\]"#

    /// `[SVG_BOARD:三角形:画出两条边并标注勾股定理]` — the on-screen whiteboard
    /// variant of the figure agent: draw the figure next to a named element
    /// instead of opening it as a file. The anchor is split at the FIRST
    /// colon, so the element name cannot contain one but the task text may.
    ///
    /// Capture groups: 1 = anchor element name, 2 = task text.
    private static let figureBoardPattern = #"\[SVG_BOARD:([^:\]]+?):([^\]]+)\]"#

    /// `[SHAPE:circle:500,300;560,300:a label:screen2]` — kind, then two or more
    /// ";"-separated points, then an optional label and an optional screen.
    /// The label may carry an `anchor|display` split (`Manage|管理`): before
    /// the pipe is the element's own on-screen name the AX lookup anchors on,
    /// after it the caption the user asked to see drawn instead.
    ///
    /// Capture groups: 1 = kind, 2 = everything after the kind's colon (points,
    /// label, screen — split further below).
    private static let shapePattern = #"\[SHAPE:\s*([^\]]+)\]"#

    /// `[AGENT_SPAWN:调研员:整理沙箱文件夹里的文件清单]` — start a new background
    /// agent and hand it the task. The name may not contain a colon (it is the
    /// split point); the task text may contain anything but `]`.
    ///
    /// Capture groups: 1 = agent name, 2 = task text.
    private static let agentSpawnPattern = #"\[AGENT_SPAWN:\s*([^:\]]+?)\s*:\s*([^\]]*?)\s*\]"#

    /// `[AGENT_SEND:调研员:把清单写成 markdown]` — hand a follow-up instruction
    /// to an agent that already exists in the roster.
    ///
    /// Capture groups: same as `agentSpawnPattern`.
    private static let agentSendPattern = #"\[AGENT_SEND:\s*([^:\]]+?)\s*:\s*([^\]]*?)\s*\]"#

    /// `[AGENT:图形]` — 主 agent 说「这件事归它」。
    ///
    /// **和上面两条不会撞**：它们在 `AGENT` 后面跟的是 `_SPAWN` / `_SEND`，
    /// 而这一条要求紧跟一个冒号。
    ///
    /// Capture groups: 1 = sub agent 的名字（图形 / 执行 / 文本）。
    /// `[AGENT:名字]` 或 `[AGENT:名字:要做什么]`。
    ///
    /// **第二个参数是 2026-09-26 加的，而且它不是便利。** 加之前这个标签**只能装「谁」**，
    /// 而主 agent 想说的话里大部分是「做什么」。实测（`ConversationSessions.json`，
    /// 「帮我点一下计算器里的 7」那一轮）主 agent 的回复是：
    ///
    ///     我不能自己去点，得派执行 agent 去按。
    ///     我正在让执行 agent 在计算器里点那个 7。
    ///
    /// **两句话都在讲派活，一个标签都没有。** 日志排除了「写了没认出」：那条路径会打
    /// 「认不出的 agent 名字」，而它没有出现。所以模型是把整件事写进了散文 ——
    /// 一个只能写「执行」、写不下「在计算器里点 7」的标签，对它要表达的内容来说太窄了。
    ///
    /// 官方那一边是 `Agent(subagent_type, prompt)`：**名字和任务都是调用的参数**，所以
    /// 子 agent 不必回头猜。这里补上的是同一件事。
    private static let subAgentPattern = #"\[AGENT:\s*([^\]:]+?)\s*(?::([^\]]*))?\]"#

    // MARK: - MCP 标签的扫描

    /// 扫 `[MCP:服务器.工具:{json}]`。
    ///
    /// **不能用正则。** 参数是 JSON，而 JSON 的值里完全可能有 `]` ——
    /// `{"query": "a]b"}`。`[^\]]*` 会在那个 `]` 上提前收尾，把一个合法参数截成
    /// 半个对象；而模型那侧看到的是「参数不对」，不是「解析器错了」，**归因直接跑偏**。
    ///
    /// 所以这个标签自己走一遍字符：跟踪「在不在字符串里」和「花括号深度」，
    /// 只有**深度归零且不在字符串里**遇到的 `]` 才是它的结尾。
    ///
    /// 标签一定要 `claim` —— 没认领的话它会留在要朗读的那句话里，用户会听见
    /// 「firecrawl 点 firecrawl search」这种话。
    private static func scanMCPRequests(
        in text: String,
        claimTagRange: (Range<String.Index>) -> Bool
    ) -> [MCPToolRequest] {
        let opening = "[MCP:"
        var requests: [MCPToolRequest] = []
        var searchStart = text.startIndex

        while let openRange = text.range(of: opening, options: [.caseInsensitive],
                                         range: searchStart..<text.endIndex) {
            let bodyStart = openRange.upperBound
            var index = bodyStart
            var depth = 0
            var inString = false
            var isEscaped = false
            var closing: String.Index?

            while index < text.endIndex {
                let character = text[index]
                if isEscaped { isEscaped = false }
                else if inString, character == "\\" { isEscaped = true }
                else if character == "\"" { inString.toggle() }
                else if !inString {
                    if character == "{" { depth += 1 }
                    else if character == "}" { depth -= 1 }
                    else if character == "]", depth <= 0 { closing = index; break }
                }
                index = text.index(after: index)
            }
            // 没闭合就到此为止：剩下的半截不当标签，也不当正文。
            guard let closing else { break }

            let tagRange = openRange.lowerBound..<text.index(after: closing)
            if claimTagRange(tagRange),
               let request = parseMCPBody(String(text[bodyStart..<closing])) {
                requests.append(request)
            }
            searchStart = text.index(after: closing)
        }
        return requests
    }

    /// 拆 `服务器.工具:{"json"}`；冒号后面那一段可以没有（= 无参数）。
    private static func parseMCPBody(_ body: String) -> MCPToolRequest? {
        let head: String
        let argumentsJSON: String
        if let colon = body.firstIndex(of: ":") {
            head = String(body[body.startIndex..<colon])
            let raw = String(body[body.index(after: colon)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            argumentsJSON = raw.isEmpty ? "{}" : raw
        } else {
            head = body
            argumentsJSON = "{}"
        }
        // 只按**第一个**点切：工具名里再有点（`a.b.c`）也归工具名。
        let parts = head.split(separator: ".", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        let server = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let tool = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !server.isEmpty, !tool.isEmpty else { return nil }
        // `*` 是「列出这个服务器的工具」，不是一个叫 `*` 的工具。
        return MCPToolRequest(kind: tool == "*" ? .listTools : .call,
                              serverName: server, toolName: tool,
                              argumentsJSON: argumentsJSON)
    }

    // MARK: - Parsing

    /// Pulls every action tag out of a model reply, and returns what is left to
    /// say out loud alongside the actions to perform.
    static func parse(from responseText: String) -> ActionParseResult {
        var claimedRanges: [Range<String.Index>] = []
        var pointingRequest: ModelReportedCoordinate?
        var actions: [CompanionAction] = []
        var shapeRequests: [AnnotationShapeRequest] = []
        var agentRequests: [AgentDispatchRequest] = []
        var subAgentRequest: SubAgentRole?
        var subAgentTask: String?
        var mcpRequests: [MCPToolRequest] = []
        var figureBoardRequests: [FigureBoardRequest] = []

        // Tags are removed from the spoken text afterwards, so a tag nested inside
        // another tag's text would corrupt the result once both were cut. Letting
        // the first tag to claim a stretch of the reply keep it can't happen with
        // the shapes the prompt asks for; the guard is here so that it degrades
        // into "one tag ignored" instead of mangled speech.
        func claimTagRange(_ tagRange: Range<String.Index>) -> Bool {
            guard !claimedRanges.contains(where: { $0.overlaps(tagRange) }) else { return false }
            claimedRanges.append(tagRange)
            return true
        }

        forEachMatch(in: responseText, pattern: pointingAndClickingPattern) { match, tagRange in
            guard claimTagRange(tagRange) else { return }

            let tagName = capture(1, of: match, in: responseText)?.uppercased() ?? ""

            // [POINT:none] / [CLICK:none] carry no coordinate. They are treated as
            // "no tag" rather than as an error, so a model that answers a question
            // without pointing still gets its whole sentence spoken.
            guard let x = capture(2, of: match, in: responseText).flatMap(Double.init),
                  let y = capture(3, of: match, in: responseText).flatMap(Double.init) else {
                return
            }

            let reportedCoordinate = ModelReportedCoordinate(
                normalizedCoordinate: CGPoint(x: x, y: y),
                elementLabel: capture(4, of: match, in: responseText)?
                    .trimmingCharacters(in: .whitespaces),
                screenNumber: capture(5, of: match, in: responseText).flatMap(Int.init)
            )

            switch tagName {
            case "POINT":
                // Only the first point wins. A second one would have nowhere to
                // fly to — the cursor can only be in one place.
                if pointingRequest == nil {
                    pointingRequest = reportedCoordinate
                }
            case "CLICK":
                actions.append(.click(at: reportedCoordinate))
            case "RIGHT_CLICK":
                actions.append(.rightClick(at: reportedCoordinate))
            case "DOUBLE_CLICK":
                actions.append(.doubleClick(at: reportedCoordinate))
            default:
                break
            }
        }

        forEachMatch(in: responseText, pattern: scrollingPattern) { match, tagRange in
            guard claimTagRange(tagRange) else { return }

            guard let x = capture(1, of: match, in: responseText).flatMap(Double.init),
                  let y = capture(2, of: match, in: responseText).flatMap(Double.init),
                  let directionName = capture(3, of: match, in: responseText)?.lowercased(),
                  let direction = ScrollDirection(rawValue: directionName),
                  let amountInSteps = capture(4, of: match, in: responseText).flatMap(Int.init) else {
                return
            }

            actions.append(
                .scroll(
                    at: ModelReportedCoordinate(
                        normalizedCoordinate: CGPoint(x: x, y: y),
                        elementLabel: capture(5, of: match, in: responseText)?
                            .trimmingCharacters(in: .whitespaces),
                        screenNumber: capture(6, of: match, in: responseText).flatMap(Int.init)
                    ),
                    direction: direction,
                    amountInSteps: amountInSteps
                )
            )
        }

        forEachMatch(in: responseText, pattern: typingPattern) { match, tagRange in
            guard claimTagRange(tagRange) else { return }
            guard let textToType = capture(1, of: match, in: responseText), !textToType.isEmpty else { return }
            actions.append(.typeText(textToType))
        }

        forEachMatch(in: responseText, pattern: selectingPattern) { match, tagRange in
            guard claimTagRange(tagRange) else { return }
            guard let selectionDescription = capture(1, of: match, in: responseText)?
                .trimmingCharacters(in: .whitespaces), !selectionDescription.isEmpty else { return }

            // The separator is split ONCE, at its first occurrence: the start
            // marker therefore cannot contain ">>>", but the end marker may.
            let parts: [String]
            if let separatorRange = selectionDescription.range(of: ">>>") {
                parts = [
                    String(selectionDescription[..<separatorRange.lowerBound]),
                    String(selectionDescription[separatorRange.upperBound...])
                ]
            } else {
                parts = [selectionDescription]
            }

            let startMarker = parts[0]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\\n", with: "\n")
            guard !startMarker.isEmpty else { return }
            let endMarker = parts.count > 1
                ? parts[1]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "\r\n", with: "\n")
                    .replacingOccurrences(of: "\\n", with: "\n")
                : nil

            actions.append(.selectText(
                startMarker: startMarker,
                endMarker: (endMarker?.isEmpty == false) ? endMarker : nil
            ))
        }

        forEachMatch(in: responseText, pattern: pressingPattern) { match, tagRange in
            guard claimTagRange(tagRange) else { return }
            guard let keyDescription = capture(1, of: match, in: responseText) else { return }
            let (keyName, modifierNames) = splitKeyDescription(keyDescription)
            guard !keyName.isEmpty else { return }
            actions.append(.pressKey(keyName: keyName, modifierNames: modifierNames))
        }

        forEachMatch(in: responseText, pattern: openingPattern) { match, tagRange in
            guard claimTagRange(tagRange) else { return }
            guard let applicationName = capture(1, of: match, in: responseText)?
                .trimmingCharacters(in: .whitespaces), !applicationName.isEmpty else { return }
            actions.append(.openApplication(named: applicationName))
        }

        forEachMatch(in: responseText, pattern: accessibilityTreePattern) { _, tagRange in
            guard claimTagRange(tagRange) else { return }
            actions.append(.readAccessibilityTree)
        }

        forEachMatch(in: responseText, pattern: waitingPattern) { match, tagRange in
            guard claimTagRange(tagRange) else { return }
            // The seconds are clamped rather than rejected: a model that writes
            // [WAIT:30] is asking for a pause, and refusing it silently would
            // leave the reply looking like it succeeded while nothing waited.
            // The text lands in a local first: chaining the conversion straight
            // onto the optional-capture call makes the overload resolution pick
            // the wrong flatMap, and this reads better anyway.
            let secondsText = capture(1, of: match, in: responseText)?
                .trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "s", with: "")
                .replacingOccurrences(of: "秒", with: "")
            guard let requestedSeconds = secondsText.flatMap({ Double($0) }) else {
                return
            }
            let clampedSeconds = max(1, min(10, requestedSeconds.rounded()))
            actions.append(.wait(seconds: Int(clampedSeconds)))
        }

        forEachMatch(in: responseText, pattern: desktopAgentPattern) { match, tagRange in
            guard claimTagRange(tagRange) else { return }
            guard let taskText = capture(1, of: match, in: responseText)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !taskText.isEmpty else { return }
            actions.append(.runDesktopFileAgent(task: taskText))
        }

        forEachMatch(in: responseText, pattern: figureAgentPattern) { match, tagRange in
            guard claimTagRange(tagRange) else { return }
            guard let taskText = capture(1, of: match, in: responseText)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !taskText.isEmpty else { return }
            actions.append(.runFigureAgent(task: taskText))
        }

        forEachMatch(in: responseText, pattern: figureBoardPattern) { match, tagRange in
            guard claimTagRange(tagRange) else { return }
            guard let anchorLabel = capture(1, of: match, in: responseText)?
                .trimmingCharacters(in: .whitespaces), !anchorLabel.isEmpty else { return }
            guard let taskText = capture(2, of: match, in: responseText)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !taskText.isEmpty else { return }
            figureBoardRequests.append(FigureBoardRequest(anchorLabel: anchorLabel, task: taskText))
        }

        forEachMatch(in: responseText, pattern: shapePattern) { match, tagRange in
            guard claimTagRange(tagRange) else { return }
            // The pattern swallows *any* `[SHAPE:…]` tag — an unknown kind, a
            // malformed point list — and claims it above, so garbage never
            // reaches the spoken text. Only a fully valid request survives to
            // the drawing stage.
            guard let shapeBody = capture(1, of: match, in: responseText) else {
                return
            }
            let bodyParts = shapeBody.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard let kindName = bodyParts.first.map(String.init)?
                    .trimmingCharacters(in: .whitespaces)
                    .lowercased(),
                  let kind = AnnotationShapeKind(rawValue: kindName),
                  bodyParts.count > 1 else {
                return
            }
            guard let shapeRequest = parseShapeBody(String(bodyParts[1]), kind: kind) else {
                return
            }
            shapeRequests.append(shapeRequest)
        }

        mcpRequests = Self.scanMCPRequests(in: responseText, claimTagRange: claimTagRange)

        forEachMatch(in: responseText, pattern: subAgentPattern) { match, tagRange in
            guard claimTagRange(tagRange) else { return }
            guard let rawName = capture(1, of: match, in: responseText) else { return }
            // **认不出是谁就当没写过这个标签。** 猜一个最近的（比如把「图形大师」
            // 猜成图形）比不派更危险：派错会把「帮我点登录」交给只会画图的 agent，
            // 而它照样会回一句听起来合理的答复。方案 §02 那句「宁可自己答错，
            // 不可派错活」在代码里就落在这一行。
            guard let role = SubAgentRole(named: rawName) else {
                UnknownSubAgentName.record(rawName)
                return
            }
            // 只认第一个：一句话派两件事，第二件没人接，而屏幕上会显示一个
            // 「已派活」的错觉。
            if subAgentRequest == nil {
                subAgentRequest = role
                // 任务写在标签里就带过去；没写就是 nil，由调用方决定回落到什么
                // （今天是用户原话）。**不在这里编一个默认值** —— 解析器只该回答
                // 「模型写了什么」。
                let rawTask = capture(2, of: match, in: responseText)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                subAgentTask = (rawTask?.isEmpty == false) ? rawTask : nil
            }
        }

        forEachMatch(in: responseText, pattern: agentSpawnPattern) { match, tagRange in
            guard claimTagRange(tagRange) else { return }
            guard let agentName = capture(1, of: match, in: responseText)?
                .trimmingCharacters(in: .whitespaces), !agentName.isEmpty else { return }
            let taskText = capture(2, of: match, in: responseText)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            // An empty task would start an agent that does nothing; treating it
            // as no tag at all (it has already been claimed, so the garbage
            // never reaches the spoken text either).
            guard !taskText.isEmpty else { return }
            agentRequests.append(AgentDispatchRequest(kind: .spawn, agentName: agentName, message: taskText))
        }

        forEachMatch(in: responseText, pattern: agentSendPattern) { match, tagRange in
            guard claimTagRange(tagRange) else { return }
            guard let agentName = capture(1, of: match, in: responseText)?
                .trimmingCharacters(in: .whitespaces), !agentName.isEmpty else { return }
            let followUpText = capture(2, of: match, in: responseText)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !followUpText.isEmpty else { return }
            agentRequests.append(AgentDispatchRequest(kind: .send, agentName: agentName, message: followUpText))
        }

        return ActionParseResult(
            spokenText: spokenTextByRemoving(claimedRanges, from: responseText),
            pointingRequest: pointingRequest,
            actions: actions,
            shapeRequests: shapeRequests,
            agentRequests: agentRequests,
            subAgentRequest: subAgentRequest,
            subAgentTask: subAgentTask,
            mcpRequests: mcpRequests,
            figureBoardRequests: figureBoardRequests
        )
    }

    /// Splits a `[SHAPE:…]` tag's body — everything after the kind's colon —
    /// into its points, label and screen number.
    ///
    /// The body reads `"x1,y1;x2,y2[;…][:label][:screenN]"`. The points are
    /// split off at the body's first `":"` so a label containing a colon still
    /// parses, and a trailing `:screenN` is only treated as a screen number when
    /// it actually says "screen" — otherwise it is part of the label.
    private static func parseShapeBody(
        _ shapeBody: String,
        kind: AnnotationShapeKind
    ) -> AnnotationShapeRequest? {
        let bodyParts = shapeBody.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard let pointsPart = bodyParts.first else { return nil }
        let trailingPart = bodyParts.count > 1 ? String(bodyParts[1]) : nil

        var labelText: String?
        var displayText: String?
        var screenNumber: Int?
        if let trailingPart {
            if let screenMatch = trailingPart.range(of: #"(?:^|:)screen(\d+)\s*$"#, options: .regularExpression) {
                let screenText = trailingPart[screenMatch]
                    .replacingOccurrences(of: "screen", with: "")
                    .trimmingCharacters(in: CharacterSet(charactersIn: ":"))
                screenNumber = Int(screenText)
                let labelPart = String(trailingPart[..<screenMatch.lowerBound])
                let trimmedLabel = labelPart.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
                labelText = trimmedLabel.isEmpty ? nil : trimmedLabel
            } else {
                labelText = trailingPart.isEmpty ? nil : trailingPart
            }
        }

        // Optional `anchor|display` split: everything before the first `|`
        // stays the AX-lookup anchor, everything after is what the capsule
        // draws. A label the user asked to rename/translate must keep the
        // element's own words as the anchor — a translated-only label matches
        // no element, the lookup fails, and the shape falls back to the
        // model's estimated coordinates (the "renamed it and it went crazy"
        // failure).
        if let existingLabelText = labelText, let pipeIndex = existingLabelText.firstIndex(of: "|") {
            let anchor = String(existingLabelText[existingLabelText.startIndex..<pipeIndex])
                .trimmingCharacters(in: .whitespaces)
            let display = String(existingLabelText[existingLabelText.index(after: pipeIndex)...])
                .trimmingCharacters(in: .whitespaces)
            if anchor.isEmpty {
                // `|display` with no anchor: nothing to look up, so keep the
                // whole text as a plain display-only label.
                labelText = nil
                displayText = display.isEmpty ? nil : display
            } else {
                labelText = anchor
                displayText = display.isEmpty ? nil : display
            }
        }

        let parsedPoints: [CGPoint] = pointsPart
            .split(separator: ";")
            .compactMap { pointText in
                let coordinates = pointText.split(separator: ",")
                guard coordinates.count == 2,
                      let x = Double(coordinates[0].trimmingCharacters(in: .whitespaces)),
                      let y = Double(coordinates[1].trimmingCharacters(in: .whitespaces)) else {
                    return nil
                }
                return CGPoint(x: x, y: y)
            }

        guard parsedPoints.count >= kind.minimumPointCount else { return nil }

        return AnnotationShapeRequest(
            kind: kind,
            points: parsedPoints,
            label: labelText,
            displayLabel: displayText,
            screenNumber: screenNumber
        )
    }

    // MARK: - Helpers

    /// Splits `"cmd+a"` into the key to press and the modifiers held with it.
    ///
    /// Which component is the key is decided by **name, not by position**.
    /// Position is the obvious way to write this and it is wrong: the prompt
    /// teaching this tag spells the combination key-first (`[PRESS:a+cmd]`),
    /// while macOS convention spells it modifier-first, and a model asked for
    /// "全选" can reasonably emit either. Read positionally, one of those two
    /// comes out as "hold A down and strike Command" — which the executor
    /// refuses as an unknown modifier, so the shortcut simply never fires.
    /// Deciding by name makes both orders the same request, which is what a tag
    /// written by a language model needs.
    ///
    /// A description that is nothing but modifiers (`cmd`) names that modifier
    /// key itself; there is no other component left to be the one struck.
    private static func splitKeyDescription(_ keyDescription: String) -> (keyName: String, modifierNames: [String]) {
        let components = keyDescription
            .split(separator: "+")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        let modifierNames = components.filter { modifierFlag(named: $0) != nil }
        let otherNames = components.filter { modifierFlag(named: $0) == nil }

        guard let keyName = otherNames.last ?? modifierNames.last else { return ("", []) }
        return (keyName, modifierNames.filter { $0 != keyName })
    }

    /// Maps the words a model may write for a modifier key into the event flag
    /// they mean, or `nil` for anything that is not a modifier.
    ///
    /// This table lives with the tag parser rather than with the code that
    /// presses the keys, because "which of `cmd+a`'s two halves is the key" is
    /// a question about the *tag* — the parser has to answer it, and the answer
    /// has to be the same vocabulary the executor can turn into flags. Two
    /// tables would eventually disagree, and a disagreement here surfaces as a
    /// shortcut that quietly does nothing.
    ///
    /// Several spellings each, because these come from a language model and not
    /// from a keyboard: `cmd`, `command` and `⌘` all mean the same thing, and
    /// refusing one of them would look like the feature is broken.
    nonisolated static func modifierFlag(named modifierName: String) -> CGEventFlags? {
        switch modifierName.lowercased() {
        case "cmd", "command", "meta", "super", "⌘":
            return .maskCommand
        case "shift", "⇧":
            return .maskShift
        case "opt", "option", "alt", "⌥":
            return .maskAlternate
        case "ctrl", "control", "^":
            return .maskControl
        case "fn", "function":
            return .maskSecondaryFn
        default:
            return nil
        }
    }

    /// Removes the claimed tag ranges and tidies the sentence left behind.
    ///
    /// Built by splicing the text *between* the ranges rather than by deleting
    /// them in place: deleting in place means mutating a string while holding
    /// indices into a different copy of it, which is the kind of thing that works
    /// until it doesn't.
    private static func spokenTextByRemoving(
        _ tagRanges: [Range<String.Index>],
        from responseText: String
    ) -> String {
        let sortedRanges = tagRanges.sorted { $0.lowerBound < $1.lowerBound }

        var spokenText = ""
        var nextCharacterToCopy = responseText.startIndex
        for tagRange in sortedRanges {
            spokenText += responseText[nextCharacterToCopy..<tagRange.lowerBound]
            nextCharacterToCopy = tagRange.upperBound
        }
        spokenText += responseText[nextCharacterToCopy...]

        return spokenText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Streaming speech support (逐句快答)

    /// The tag keywords one combined pattern for the streaming speech path —
    /// a keyword added to the parser above must be added here too, or the
    /// streaming speech would read the tag aloud instead of removing it.
    private static let streamingTagKeywords =
        "POINT|CLICK|RIGHT_CLICK|DOUBLE_CLICK|SCROLL|TYPE|SELECT|PRESS|OPEN|WAIT|AX_TREE|SHAPE|AGENT_SPAWN|AGENT_SEND|PY_AGENT|SVG_AGENT|SVG_BOARD"

    /// A complete tag, however far the reply has streamed: `[TYPE:北京新闻]`.
    private static let streamingCompleteTagPattern =
        "\\[(?:\(streamingTagKeywords))[^\\]]*\\]"

    /// A tag that has started but not closed yet — the tail of text still
    /// streaming in: `[POINT:123,45` (keyword whole, arguments still arriving)
    /// or `[POIN` (the keyword itself only half-streamed). The second shape
    /// needs its own arm: `[POIN` matches no keyword yet, so a keyword-only
    /// pattern would let it through and the tag's first letters would be
    /// spoken aloud — and the next call would retract them, which breaks the
    /// prefix monotonicity the session's cumulative feed diffs on. The arm
    /// matches a trailing `[` followed by letters only, however many: a
    /// bracketed English word (`[documentation`) is held too, but holding is
    /// always safe — releasing the held text later only extends the output,
    /// while leaking it early and removing it later is the break.
    private static let streamingOpenTagPattern =
        "\\[(?:\(streamingTagKeywords))[^\\]]*$|\\[[A-Za-z_]*$"

    /// Strips action tags from reply text that may still be mid-tag, for the
    /// streaming speech path.
    ///
    /// Complete tags are removed; a trailing stretch that could still be the
    /// beginning of a tag is held back (`[POINT:123,45` has not closed yet —
    /// speaking it now would read the tag aloud, and finding out one character
    /// too late is what this hold-back prevents). Once the tag closes it is
    /// removed on a later call, so each call's result always extends the
    /// previous call's — the session diffs on that property.
    static func speakableTextFromStreamedReply(_ streamedReplyText: String) -> String {
        var speakableText = streamedReplyText

        // **两个正则提为静态缓存**（2026-09-25 性能修复）：这个函数在流式回答期间
        // **每个文字 delta 调用一次**（三段式喂朗读 + 更新卡片都要过它），原先每次
        // 都现场编译两个 `NSRegularExpression` —— 主线程上每 delta 两次正则编译，
        // 整轮 O(n²)。模式是常量，编译一次终身复用。
        if let completeTagRegex = Self.streamingCompleteTagRegex {
            let wholeTextRange = NSRange(streamedReplyText.startIndex..., in: streamedReplyText)
            speakableText = completeTagRegex.stringByReplacingMatches(
                in: streamedReplyText,
                options: [],
                range: wholeTextRange,
                withTemplate: ""
            )
        }

        if let openTagRegex = Self.streamingOpenTagRegex {
            let wholeTextRange = NSRange(speakableText.startIndex..., in: speakableText)
            if let openTagMatch = openTagRegex.firstMatch(in: speakableText, options: [], range: wholeTextRange),
               let openTagRange = Range(openTagMatch.range, in: speakableText) {
                speakableText = String(speakableText[..<openTagRange.lowerBound])
            }
        }

        return speakableText
    }

    /// 编译一次、终身复用的流式剥标签正则（见 `speakableTextFromStreamedReply`）。
    private static let streamingCompleteTagRegex = try? NSRegularExpression(
        pattern: streamingCompleteTagPattern,
        options: [.caseInsensitive]
    )
    private static let streamingOpenTagRegex = try? NSRegularExpression(
        pattern: streamingOpenTagPattern,
        options: [.caseInsensitive]
    )

    private static func forEachMatch(
        in text: String,
        pattern: String,
        _ body: (NSTextCheckingResult, Range<String.Index>) -> Void
    ) {
        // Case-insensitive on purpose: the tags are uppercase in the prompt, but a
        // model that writes [click:…] means exactly the same thing, and silently
        // speaking the tag aloud instead of clicking would be a confusing failure.
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return
        }

        let wholeTextRange = NSRange(text.startIndex..., in: text)
        for match in regex.matches(in: text, options: [], range: wholeTextRange) {
            guard let tagRange = Range(match.range, in: text) else { continue }
            body(match, tagRange)
        }
    }

    private static func capture(
        _ groupIndex: Int,
        of match: NSTextCheckingResult,
        in text: String
    ) -> String? {
        guard groupIndex < match.numberOfRanges,
              let groupRange = Range(match.range(at: groupIndex), in: text) else {
            return nil
        }
        return String(text[groupRange])
    }
}
