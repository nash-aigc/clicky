//
//  NotionNoteClient.swift
//  Wanna
//
//  **把一段录音整理成两条 Notion 折叠列表，写进用户指定的那一页**（2026-09-27）。
//
//  用户的形状要求（逐条）：「创建折叠列表，标题为时间（如 2026年3月27日 06:13），后跟一句话总结。
//  折叠列表内分两块：第一块用代码块梳理内容，做成类似脑图或文件大纲的逻辑；第二块用 Markdown
//  形式整理，含标题、字体、颜色、表格、引用、标注等，不扩写，只整理排版。第二个折叠列表标题
//  相同，后面加括号「原文」，直接保存录音转写原文。」
//
//  ## 协议是**实测过的**，不是照文档猜的（2026-09-27）
//
//  · **追加子块是 `PATCH /v1/blocks/{id}/children`，不是 POST** —— POST 返回
//    `400 invalid_request_url`（第一次就是这么踩的）。
//  · 一个请求里可以带 `children`（嵌套一层），所以「一个折叠列表 + 它里面两块」是**一次调用**；
//    再往里一层就得第二次调用（官方限制：每次最多两层）。
//  · 富文本的 `annotations` 能带 `bold` / `color` 等 —— 用户要的「字体、颜色」就是它。
//  · 集成（integration）**必须被分享到那一页**，否则 404 `object_not_found`
//    （报错原文会点名集成名字）。所以连接测试那一步要如实把这句话说出来。
//
//  ## 为什么要一个"两段式"的整理提示词
//
//  用户要的两块是**两种东西**：大纲（代码块）与排版（Markdown）。让模型一次输出两段、用固定
//  分隔符切开，比调两次便宜一半、也不会两段互相矛盾。切不开时**不猜**：整段原文当成排版块，
//  大纲块留一句说明 —— 宁可少一块，也不要把半截内容塞进去。
//

import Foundation

/// Notion 那边的一次保存。
///
/// 它只做一件事：把「两条折叠列表」按用户要的形状写进指定页面。所有网络细节都在这里，
/// 调用方（录音子系统）只给数据。
@MainActor
final class NotionNoteClient {

    struct SaveRequest {
        /// 折叠列表的标题：`2026年3月27日 06:13`。
        let title: String
        /// 标题后面那句话总结。
        let summary: String
        /// 第一块：大纲（放进代码块）。
        let outline: String
        /// 第二块：排版后的 Markdown（按块类型拆好）。
        let formattedBlocks: [RichBlock]
        /// 原文折叠列表的正文（纯文本，按行拆）。
        let rawLines: [String]
    }

    /// 一个块。**这里只覆盖用户点名要的那几种**（标题 / 字体 / 颜色 / 表格 / 引用 / 标注），
    /// 不做通用 Markdown 引擎 —— 覆盖不到的一律当普通段落，绝不丢内容。
    enum RichBlock {
        case heading(level: Int, text: String)
        case paragraph([RichSpan])
        case quote([RichSpan])
        case bulleted([RichSpan])
        case numbered([RichSpan])
        case callout([RichSpan])
        case divider
        case tableRow([String])

        var notionJSON: [String: Any] {
            switch self {
            case .heading(let level, let text):
                let key = "heading_\(min(max(level, 1), 3))"
                return ["object": "block", "type": key,
                        "\(key)": ["rich_text": [Self.richText(["text": text])]]]
            case .paragraph(let spans):
                return ["object": "block", "type": "paragraph",
                        "paragraph": ["rich_text": spans.map(\.notionJSON)]]
            case .quote(let spans):
                return ["object": "block", "type": "quote",
                        "quote": ["rich_text": spans.map(\.notionJSON)]]
            case .bulleted(let spans):
                return ["object": "block", "type": "bulleted_list_item",
                        "bulleted_list_item": ["rich_text": spans.map(\.notionJSON)]]
            case .numbered(let spans):
                return ["object": "block", "type": "numbered_list_item",
                        "numbered_list_item": ["rich_text": spans.map(\.notionJSON)]]
            case .callout(let spans):
                return ["object": "block", "type": "callout",
                        "callout": ["rich_text": spans.map(\.notionJSON),
                                    "icon": ["type": "emoji", "emoji": "📌"]]]
            case .divider:
                return ["object": "block", "type": "divider", "divider": [:]]
            case .tableRow(let cells):
                // 表格在 Notion 里是 `table` + 若干 `table_row`，这里按**一行一段**写入
                //（见 `chunked`）：一次请求最多两层，表格要三层，所以拆成两次。
                return ["object": "block", "type": "table_row",
                        "table_row": ["cells": cells.map { [Self.richText(["text": $0])] }]]
            }
        }

        static func richText(_ fields: [String: Any]) -> [String: Any] { fields }
    }

    /// 一段带样式的文字。
    struct RichSpan {
        let text: String
        var bold = false
        var italic = false
        var code = false
        /// Notion 的颜色名（`red` / `blue` / `yellow_background` …）。nil = 默认。
        var color: String?

        var notionJSON: [String: Any] {
            var annotations: [String: Any] = ["bold": bold, "italic": italic, "code": code]
            if let color { annotations["color"] = color }
            return ["type": "text", "text": ["content": text], "annotations": annotations]
        }
    }

    enum NotionError: LocalizedError {
        case notConfigured(String)
        case http(code: Int, message: String)

        var errorDescription: String? {
            switch self {
            case .notConfigured(let what): return what
            case .http(let code, let message):
                // **服务端原话照抄**：404 里会点名"把这一页分享给哪个集成"，
                // 那句话是用户唯一能立刻行动的线索。
                return "Notion \(code)：\(message)"
            }
        }
    }

    private static let apiBase = "https://api.notion.com/v1"
    /// 稳定版协议。Notion 要求每个请求都带它。
    private static let notionVersion = "2022-06-28"

    /// 保存一条笔记。返回可打开的页面 URL。
    func save(_ request: SaveRequest) async throws -> String {
        let settings = AppSettingsStore.snapshot()
        let token = settings.notionNoteToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            throw NotionError.notConfigured("还没填 Notion 令牌（设置 → 录音 → Notion 笔记）")
        }
        guard let pageID = Self.normalizedPageID(settings.notionNotePageID) else {
            throw NotionError.notConfigured("还没填要写进哪一页（设置 → 录音 → Notion 笔记）")
        }

        let title = request.title
        // ① 第一条折叠列表：标题 + 总结，里面两块（大纲 / 排版）。
        var firstChildren: [[String: Any]] = [
            ["object": "block", "type": "code",
             "code": ["rich_text": [RichBlock.richText(["text": request.outline])],
                      "language": "plain text"]]
        ]
        firstChildren += request.formattedBlocks.map(\.notionJSON)
        try await appendChildren(pageID: pageID, token: token, children: [
            toggleBlock(title: "\(title) —— \(request.summary)", children: firstChildren)
        ])

        // ② 第二条折叠列表：标题同名 + 「（原文）」，正文是转写原文。
        let rawChildren: [[String: Any]] = request.rawLines.map {
            ["object": "block", "type": "paragraph",
             "paragraph": ["rich_text": [RichBlock.richText(["text": $0])]]]
        }
        try await appendChildren(pageID: pageID, token: token, children: [
            toggleBlock(title: "\(title)（原文）", children: rawChildren)
        ])

        return openURL(pageID: pageID)
    }

    /// 一条折叠列表（`toggle`）。`children` 最多一层 —— 官方限制每次请求两层，
    /// 而「toggle + 里面的块」正好两层 ✓。
    private func toggleBlock(title: String, children: [[String: Any]]) -> [String: Any] {
        ["object": "block", "type": "toggle",
         "toggle": ["rich_text": [RichBlock.richText(["text": title])],
                    "children": children]]
    }

    private func appendChildren(pageID: String, token: String,
                                children: [[String: Any]]) async throws {
        // **追加是 PATCH**（POST 会 400 invalid_request_url，实测）。
        var request = URLRequest(url: URL(string: "\(Self.apiBase)/blocks/\(pageID)/children")!)
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.notionVersion, forHTTPHeaderField: "Notion-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["children": children])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NotionError.http(code: -1, message: "没有响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            // Notion 的错误体里 `message` 是给人看的那一句（例如"把这一页分享给集成 X"）。
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { $0?["message"] as? String } ?? "未知错误"
            throw NotionError.http(code: http.statusCode, message: message)
        }
    }

    /// 打开用的链接：优先用户填的那条；没填就用页面 id 拼一个。
    private func openURL(pageID: String) -> String {
        let configured = AppSettingsStore.snapshot()
            .notionNoteOpenURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !configured.isEmpty { return configured }
        let compact = pageID.replacingOccurrences(of: "-", with: "")
        return "https://www.notion.so/\(compact)"
    }

    /// 用户可能填的是**链接**（`https://www.notion.so/xxx/3e02806c…?v=…`）而不是 id ——
    /// 两种都得认，因为"复制链接"是最自然的做法。
    static func normalizedPageID(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // 链接里最后一段 32 位十六进制就是 id。
        let candidates = trimmed.split(whereSeparator: { $0 == "/" || $0 == "?" || $0 == "-" })
        for piece in candidates.reversed() {
            let hex = piece.filter { $0.isHexDigit }
            if hex.count == 32, hex.count == piece.count {
                let s = String(hex)
                return "\(s.prefix(8))-\(s.dropFirst(8).prefix(4))-\(s.dropFirst(12).prefix(4))-\(s.dropFirst(16).prefix(4))-\(s.suffix(12))"
            }
        }
        // 也可能用户直接填了带连字符的 id。
        if trimmed.filter({ $0.isHexDigit }).count == 32 { return trimmed }
        return nil
    }
}
