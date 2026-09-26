//
//  NotchArchiveView.swift
//  Wanna
//
//  The 归档 page — where every deleted conversation goes now that the
//  sidebar's delete is a soft one. It takes the whole sheet over exactly the
//  way 设置 does (`NotchSheetRootView`'s third branch), which is why it carries
//  its own 245pt left column with the 「‹ 返回」 pill instead of leaning on the
//  session sidebar: the sidebar is the conversation home's, and it has to be
//  gone while this page is up.
//
//  Two actions live here, and they are deliberately different:
//
//    · 恢复 — clears `archivedAt`, so the conversation is a sidebar row again;
//    · 彻底删除 — the only thing in the app that removes a conversation from
//      disk. It asks first (an irreversible delete should), and it is offered
//      from the row's context menu rather than as a button on the page, so it
//      is never one stray click away.
//
//  The right column is the archived conversation, read-only: the same bubbles
//  the conversation view draws, with no composer — you cannot talk into an
//  archived conversation, you restore it first.
//
//  A note on the history: archiving is only a marker, it does not lose
//  anything, but nothing before this page existed left a marker behind —
//  conversations deleted by an older build were removed outright and cannot be
//  listed here.
//

import SwiftUI

struct NotchArchiveArea: View {

    @ObservedObject var sessionsModel: ConversationSessionsModel

    /// **做完的任务的历史**（`FinishedTaskStore`）—— 用户 2026-09-26：「任务完成之后
    /// 自动消失，然后自动归档到：左侧边栏——某个卡片的自动化任务的归档」，
    /// 「叫归档，本质是历史记录」。
    @State private var finishedTasks: [FinishedTask] = []
    /// 展开了哪几个主会话（折叠卡片：一张卡片 = 一个主会话 + 它下面挂的任务）。
    @State private var expandedHistoryGroups: Set<String> = []

    /// 左下角那颗「‹ 返回」。**可为空** —— 这个视图现在有两个宿主：整窗接管的
    /// 旧入口（要它），以及设置里的「归档」页（不要，设置侧栏自己就是导航）。
    /// 为空时那一行整块不画，而不是画一颗点了没反应的按钮。
    var backAction: (() -> Void)?

    /// 「退出 Wanna」。整窗接管那一版已经不需要它了（设置页才有），保留成
    /// 可选是为了以后别处复用；为空就不画。
    var closeAction: (() -> Void)?

    /// Which archived conversation the right column shows. Kept as an id, not
    /// a copy of the record: a 恢复 made anywhere else in the app must not
    /// leave this page holding a stale snapshot.
    @State private var selectedSessionID: UUID?

    /// The conversation the 彻底删除 alert is about. The alert only asks; the
    /// actual removal happens in its confirm action.
    @State private var sessionPendingPurge: ConversationSession?

    /// 内容列的宽度，量出来的。**它唯一的用途是给回答卡片当身份证**
    ///（见 `archivedConversation` 里的 `.id(contentColumnWidth)`）。
    ///
    /// 回答卡片把断好的行按宽度缓存在自己的 `@State` 里，而实时区那两行是
    /// `.fixedSize(horizontal: true)` 的 —— 于是「卡片算出来的那几行有多宽」变成了
    /// 这一列的最小宽度，而它又是从这一列量出来的，两者互相锁死：这一列一旦变宽
    /// 再变窄（全屏来回切），卡片不肯跟着变窄，两列就会被一起撑出面板。
    @State private var contentColumnWidth: CGFloat = 0

    var body: some View {
        // 任务历史的数据在这里刷新：出现时读一次，任务结束时再读一次
        //（`FinishedTaskStore` 落盘后会发通知）。
        HStack(spacing: 0) {
            archiveSidebar

            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(width: 1)

            VStack(spacing: 0) {
                if let archivedSession = selectedSession {
                    conversationHeader(archivedSession)
                    archivedConversation(archivedSession)
                } else {
                    emptyState
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            // 量这一列的宽度 —— 只给回答卡片当 `.id` 用，见 `contentColumnWidth`。
            .background(
                GeometryReader { geometryProxy in
                    Color.clear
                        .onAppear { contentColumnWidth = geometryProxy.size.width }
                        .onChange(of: geometryProxy.size.width) { _, newWidth in
                            contentColumnWidth = newWidth
                        }
                }
            )
        }
        .onAppear {
            repairSelectionIfNeeded()
            finishedTasks = FinishedTaskStore.shared.allTasks()
        }
        // 任务一结束就刷新历史（`FinishedTaskStore.record` 会发这个通知）。
        .onReceive(NotificationCenter.default.publisher(for: .wannaFinishedTasksDidChange)) { _ in
            finishedTasks = FinishedTaskStore.shared.allTasks()
        }
        .onChange(of: sessionsModel.archivedSessions) { _, _ in
            repairSelectionIfNeeded()
        }
        .alert(
            "彻底删除这条对话？",
            isPresented: Binding(
                get: { sessionPendingPurge != nil },
                set: { isPresented in
                    if !isPresented { sessionPendingPurge = nil }
                }
            ),
            presenting: sessionPendingPurge
        ) { sessionToPurge in
            Button("彻底删除", role: .destructive) {
                sessionsModel.purgeSession(sessionToPurge.id)
                sessionPendingPurge = nil
            }
            Button("取消", role: .cancel) {
                sessionPendingPurge = nil
            }
        } message: { sessionToPurge in
            Text("「\(sessionToPurge.title)」会从磁盘上消失，之后无法恢复。")
        }
    }

    // MARK: - Selection

    /// What the right column shows: the selected archived conversation, or the
    /// most recent one when nothing is selected.
    private var selectedSession: ConversationSession? {
        if let selectedSessionID,
           let selected = sessionsModel.archivedSessions.first(where: { $0.id == selectedSessionID }) {
            return selected
        }
        return sessionsModel.archivedSessions.first
    }

    /// Keeps the selection honest after a restore or a 彻底删除 made here or
    /// anywhere else: an id that no longer exists falls back to whatever is
    /// left, and the first arrival selects the newest archived conversation so
    /// the page never opens on an empty right column while the list has rows.
    private func repairSelectionIfNeeded() {
        let archivedSessionIDs = Set(sessionsModel.archivedSessions.map(\.id))
        if let selectedSessionID, !archivedSessionIDs.contains(selectedSessionID) {
            self.selectedSessionID = nil
        }
        if selectedSessionID == nil {
            selectedSessionID = sessionsModel.archivedSessions.first?.id
        }
    }

    // MARK: - 任务历史（按主会话折叠）

    /// **一张折叠卡片 = 一个主会话 + 它下面挂的任务。**
    ///
    /// 用户 2026-09-26 的原话：「归档页面，应该是：某个卡片（折叠形式），然后点击后显示
    ///（卡片=主会话，和不同的其他分组或任务的卡片的会话）……（如果主会话没有归档，
    /// 也要显示出来，防止用户找不到具体是哪个主会话）」—— 所以分组用的是**任务创建时
    /// 记下的那个会话标题** ✓，而不是去会话表里查（会话可能已经改名或被删 ✗）。
    @ViewBuilder
    private var taskHistorySection: some View {
        if !finishedTasks.isEmpty {
            let grouped = Dictionary(grouping: finishedTasks) { $0.sessionID ?? "" }
            let order = grouped.keys.sorted { left, right in
                let leftDate = grouped[left]?.map(\.finishedAt).max() ?? .distantPast
                let rightDate = grouped[right]?.map(\.finishedAt).max() ?? .distantPast
                return leftDate > rightDate
            }
            VStack(alignment: .leading, spacing: 0) {
                Text("任务历史")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.7)
                    .foregroundColor(.white.opacity(0.35))
                    .padding(.horizontal, 18)
                    .padding(.bottom, 4)

                ForEach(order, id: \.self) { key in
                    if let tasks = grouped[key] {
                        taskHistoryGroup(key: key, tasks: tasks)
                    }
                }
            }
            .padding(.bottom, 10)
        }
    }

    private func taskHistoryGroup(key: String, tasks: [FinishedTask]) -> some View {
        let isOpen = expandedHistoryGroups.contains(key)
        let title = tasks.first?.sessionTitle ?? "（会话已不在）"
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                if isOpen { expandedHistoryGroups.remove(key) } else { expandedHistoryGroups.insert(key) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isOpen ? "folder.fill" : "folder")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.55))
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.85))
                        .lineLimit(1)
                    Text("· \(tasks.count)")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.35))
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.white.opacity(0.3))
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                }
                .padding(.horizontal, 18)
                .frame(height: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerCursor()

            if isOpen {
                ForEach(tasks) { task in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(archiveStatusColor(task.status))
                            .frame(width: 7, height: 7)
                        Text(Self.archiveTimeFormatter.string(from: task.finishedAt))
                            .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                            .foregroundColor(.white.opacity(0.4))
                        Text(task.request)
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.7))
                            .lineLimit(2)
                        Spacer(minLength: 0)
                    }
                    .padding(.leading, 34)
                    .padding(.trailing, 18)
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private func archiveStatusColor(_ status: EphemeralAgent.Status) -> Color {
        switch status {
        case .running: return DS.Colors.accent
        case .doneVerified: return DS.Colors.success
        case .doneUnverified: return DS.Colors.warning
        case .failed: return DS.Colors.destructive
        }
    }

    private static let archiveTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()

    // MARK: - Sidebar

    private var archiveSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("归档")
                .font(.system(size: 26, weight: .bold))
                .foregroundColor(.white)
                .padding(.horizontal, 18)
                .padding(.top, NotchSupport.sheetHeaderTopInset)
                .padding(.bottom, 4)

            Text("删掉的对话都在这里，右键可以恢复或彻底删除")
                .font(.system(size: 11.5))
                .foregroundColor(.white.opacity(0.35))
                .padding(.horizontal, 18)
                .padding(.bottom, 14)

            taskHistorySection

            if sessionsModel.archivedSessions.isEmpty {
                Text("还没有归档的对话")
                    .font(.system(size: 12.5))
                    .foregroundColor(.white.opacity(0.35))
                    .padding(.horizontal, 18)
                    .padding(.top, 8)

                Spacer(minLength: 0)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(sessionsModel.archivedSessions.enumerated()), id: \.element.id) { rowIndex, session in
                            archivedSessionRow(session)
                            if rowIndex < sessionsModel.archivedSessions.count - 1 {
                                Divider()
                                    .overlay(Color.white.opacity(0.08))
                                    .padding(.leading, 12)
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                }

                Spacer(minLength: 0)
            }

            // 「‹ 返回」 pin 在左下角，和设置页同一处（用户 2026-09-23 给设置页
            // 定的位置：「返回按钮放在设置页面的左下角」）。这个页面是同一套
            // 整窗接管的写法 —— 两个页面的返回键落在同一个地方，用户才不用
            // 每次重新找。归档页没有「退出 Wanna」，所以这里只有它一颗。
            if let backAction {
                Button(action: backAction) {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 10, weight: .semibold))
                        Text("返回")
                            .font(.system(size: 11.5, weight: .medium))
                    }
                    .foregroundColor(.white.opacity(0.7))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.white.opacity(0.08)))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .help("返回对话")
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
            }
        }
        .frame(width: 245)
        // 不透明（用户 2026-09-23：「整个弹出窗口调整为完全不透明」）——见
        // `HomeSpaceSidebarView` 同处的说明。
        .background(DS.Colors.surface3)
    }

    private func archivedSessionRow(_ session: ConversationSession) -> some View {
        let isSelected = session.id == selectedSession?.id

        return Button(action: { selectedSessionID = session.id }) {
            VStack(alignment: .leading, spacing: 3) {
                Text(session.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white.opacity(0.9))
                    .lineLimit(1)

                Text(HomeSpaceSidebarView.previewText(session))
                    .font(.system(size: 11.5))
                    .foregroundColor(.white.opacity(0.4))
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(HomeSpaceSidebarView.relativeTime(session.updatedAt))
                        .font(.system(size: 10.5))
                        .foregroundColor(.white.opacity(0.32))

                    // 归档时间比「最后更新」更能说明它为什么在这儿 —— 用户刚
                    // 删掉的那条应该一眼看得出来。
                    if let archivedAt = session.archivedAt {
                        Text("· 归档于 \(HomeSpaceSidebarView.relativeTime(archivedAt))")
                            .font(.system(size: 10.5))
                            .foregroundColor(.white.opacity(0.32))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? Color.white.opacity(0.06) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .contextMenu {
            Button("恢复") {
                sessionsModel.restoreSession(session.id)
            }
            Divider()
            Button("彻底删除", role: .destructive) {
                sessionPendingPurge = session
            }
        }
    }

    // MARK: - Content column

    private func conversationHeader(_ archivedSession: ConversationSession) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(archivedSession.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)

                Text("\(archivedSession.entries.count) 条对话 · 只读")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.4))
            }

            Spacer(minLength: 8)

            Button {
                sessionsModel.restoreSession(archivedSession.id)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 10, weight: .semibold))
                    Text("恢复")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(Color(red: 0.35, green: 0.85, blue: 0.55))
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.white.opacity(0.1)))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help("恢复到侧栏，继续聊")

            // 收起按钮同样可为空：在设置里那一版，页头的「关闭」是设置页自己
            // 的那一颗，这里再来一个就是两个收起键。
            if let closeAction {
                Button(action: closeAction) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white.opacity(0.55))
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Color.white.opacity(0.08)))
                        .pointerCursor()
                }
                .buttonStyle(.plain)
                .help("收起（Esc）")
            }
        }
        .padding(.horizontal, NotchSupport.contentColumnHorizontalMargin)
        .padding(.top, NotchSupport.sheetHeaderTopInset)
        .padding(.bottom, 10)
    }

    private func archivedConversation(_ archivedSession: ConversationSession) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if archivedSession.entries.isEmpty {
                    Text("这条对话没有留下内容")
                        .font(.system(size: 12.5))
                        .foregroundColor(.white.opacity(0.35))
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                } else {
                    // `ConversationHistoryEntry` is not `Identifiable` — the
                    // conversation view iterates the same array by index
                    // (`NotchHomeView` uses `enumerated` + `id: \.offset`),
                    // and a turn's position in the file is a stable identity
                    // for a read-only page.
                    ForEach(Array(archivedSession.entries.enumerated()), id: \.offset) { _, entry in
                        if !entry.userTranscript.isEmpty {
                            archivedUserBubble(entry.userTranscript)
                        }
                        if !entry.assistantResponse.isEmpty {
                            AnswerCardView(
                                text: Self.displayTextWithoutActionTags(entry.assistantResponse),
                                isStreaming: false,
                                style: answerCardStyle
                            )
                            // 列宽变了就重建这张卡：断行缓存按宽度存在它的 `@State`
                            // 里，而实时区那两行不许被压缩，两件事合起来会让这一列的
                            // 最小宽度永远停在旧列宽上。见 `contentColumnWidth`。
                            .id(contentColumnWidth)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, NotchSupport.contentColumnHorizontalMargin)
            .padding(.top, 4)
            .padding(.bottom, 16)
        }
        // Read-only, but still selectable — the whole point of opening an
        // archived conversation is often to copy something out of it.
        .textSelection(.enabled)
    }

    private func archivedUserBubble(_ text: String) -> some View {
        HStack(alignment: .bottom) {
            Spacer(minLength: 56)

            Text(text)
                .font(.system(size: 14))
                .foregroundColor(.white)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 13)
                .padding(.vertical, 9)
                .background(
                    UnevenRoundedRectangle(
                        topLeadingRadius: Self.bubbleCornerRadius,
                        bottomLeadingRadius: Self.bubbleCornerRadius,
                        bottomTrailingRadius: Self.bubbleTailCornerRadius,
                        topTrailingRadius: Self.bubbleCornerRadius,
                        style: .continuous
                    )
                    .fill(DS.Colors.userBubbleFill)
                )
        }
    }

    /// The same geometry the three content columns use (14 / 4).
    private static let bubbleCornerRadius: CGFloat = 14
    private static let bubbleTailCornerRadius: CGFloat = 4

    /// The card theme the user chose in 设置 → 交互样式, read fresh so a saved
    /// change reaches this page without a rebuild.
    private var answerCardStyle: AnswerCardStyle {
        AppSettingsStore.snapshot().answerCardStyle
    }

    /// Displayed text, not the stored text: `[POINT:…]` and friends are the
    /// executor's, and showing them would put machine syntax in an archived
    /// conversation. The conversation view strips them the same way for the
    /// same reason (see `NotchHomeView.stripActionTagsForDisplay`).
    private static func displayTextWithoutActionTags(_ text: String) -> String {
        return text.replacingOccurrences(
            of: "\\[[A-Z_]+:[^\\]]*\\]",
            with: "",
            options: .regularExpression
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "archivebox")
                .font(.system(size: 34))
                .foregroundColor(.white.opacity(0.25))
            Text("归档是空的")
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.45))
            Text("在左侧对话列表里删掉一条对话，它会出现在这里")
                .font(.system(size: 11.5))
                .foregroundColor(.white.opacity(0.3))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
