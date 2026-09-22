//
//  HomeSpaceSidebarView.swift
//  leanring-buddy
//
//  The notch sheet's session sidebar, drawn to HeyClicky's reference
//  screenshot: a waveform logo at the top, a search field beside a round
//  new-session button, the session list (pastel avatar, title + relative
//  time, preview line, hairline separators, a blue dot marking the active
//  session), and the account section pinned at the bottom (initial avatar,
//  account name, status line, gear into the settings).
//

import SwiftUI

struct HomeSpaceSidebarView: View {

    @ObservedObject var sessionsModel: ConversationSessionsModel
    @Binding var showsSettings: Bool

    @State private var hoveringSessionID: UUID?
    @State private var renamingSessionID: UUID?
    @State private var renameDraft: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            logoHeader
            searchRow
            sessionList
            Spacer(minLength: 0)
            accountSection
        }
        .background(Color.black.opacity(0.35))
    }

    // MARK: - Pieces

    /// 原版顶部只有一颗波形 logo，没有应用名文字。
    private var logoHeader: some View {
        Image(systemName: "waveform")
            .font(.system(size: 20, weight: .semibold))
            .foregroundColor(.white)
            .padding(.leading, 20)
            // 顶部让开茎带（与刘海相接的那段黑带）。
            .padding(.top, NotchSupport.restingPillAnimationHeadroom + 10)
            .padding(.bottom, 16)
        // .frame(maxWidth: .infinity, alignment: .leading) 由外层 VStack 的
        // alignment 提供。
    }

    /// 搜索框占满剩余宽度，旁边是原版那颗独立的圆形「＋」。
    private var searchRow: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.4))

                TextField("搜索对话", text: $sessionsModel.searchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundColor(.white)
                    .disableAutocorrection(true)

                if sessionsModel.isSearching {
                    Button(action: { sessionsModel.searchQuery = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.4))
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.white.opacity(0.07))
            )

            Button(action: { sessionsModel.createSession() }) {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white.opacity(0.85))
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Color.white.opacity(0.07)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help("新建会话")
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    private var sessionList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(sessionsModel.sidebarRows.enumerated()), id: \.element.session.id) { rowIndex, row in
                    sessionRow(row)
                    // 原版每行之间有一条发丝分隔线，与文字对齐、不压头像。
                    if rowIndex < sessionsModel.sidebarRows.count - 1 {
                        Divider()
                            .overlay(Color.white.opacity(0.08))
                            .padding(.leading, 66)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 2)
        }
    }

    private func sessionRow(_ row: ConversationSessionsModel.SessionRow) -> some View {
        let isSelected = row.session.id == sessionsModel.activeSessionID && !showsSettings

        return Button(action: {
            sessionsModel.selectSession(row.session.id)
            showsSettings = false
        }) {
            HStack(alignment: .center, spacing: 10) {
                // 原版用贴着侧栏左缘的小蓝点标记当前会话，选中行不再加底色。
                Circle()
                    .fill(Color(red: 0.25, green: 0.52, blue: 1.0))
                    .frame(width: 5, height: 5)
                    .opacity(isSelected ? 1 : 0)

                // 每个会话一只固定的角色脸——HeyClicky 会话网格的彩点头像
                MascotAvatarDisc(identity: MascotRoster.identity(forSessionID: row.session.id), diameter: 38)

                if row.session.id == renamingSessionID {
                    TextField("会话名", text: $renameDraft, onCommit: commitRename)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundColor(.white)
                } else {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .center, spacing: 6) {
                            Text(row.session.title)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.white)
                                .lineLimit(1)

                            Spacer(minLength: 4)

                            if hoveringSessionID == row.session.id {
                                Button(action: { sessionsModel.deleteSession(row.session.id) }) {
                                    Image(systemName: "trash")
                                        .font(.system(size: 10))
                                        .foregroundColor(.white.opacity(0.55))
                                        .frame(width: 18, height: 18)
                                        .background(Circle().fill(Color.white.opacity(0.1)))
                                }
                                .buttonStyle(.plain)
                                .pointerCursor()
                                .help("删除这个会话")
                            } else if row.searchPreview == nil && !row.session.entries.isEmpty {
                                Text(Self.relativeTime(row.session.updatedAt))
                                    .font(.system(size: 11))
                                    .foregroundColor(.white.opacity(0.4))
                                    .lineLimit(1)
                            }
                        }

                        if let searchPreview = row.searchPreview {
                            Text(searchPreview)
                                .font(.system(size: 12))
                                .foregroundColor(.white.opacity(0.45))
                                .lineLimit(1)
                        } else {
                            Text(row.session.entries.isEmpty
                                ? "还没有对话"
                                : Self.previewText(row.session))
                                .font(.system(size: 12))
                                .foregroundColor(.white.opacity(0.45))
                                .lineLimit(1)
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(hoveringSessionID == row.session.id && row.session.id != renamingSessionID
                        ? Color.white.opacity(0.05)
                        : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { hovering in
            hoveringSessionID = hovering ? row.session.id : (hoveringSessionID == row.session.id ? nil : hoveringSessionID)
        }
        .contextMenu {
            Button("重命名") {
                renamingSessionID = row.session.id
                renameDraft = row.session.title
            }
            Button("删除", role: .destructive) {
                sessionsModel.deleteSession(row.session.id)
            }
        }
    }

    private func commitRename() {
        if let renamingSessionID {
            sessionsModel.renameSession(renamingSessionID, to: renameDraft)
        }
        renamingSessionID = nil
        renameDraft = ""
    }

    /// 底部账户区：首字母头像 + 账户名 + 状态行，右侧一颗进设置的齿轮。
    /// （原版这里还有配额环和 info 图标——配额是账号服务的概念，本地
    /// 应用没有对应的真实数据，空着不画，免得展示一个假数字。）
    private var accountSection: some View {
        VStack(spacing: 0) {
            Divider()
                .overlay(Color.white.opacity(0.08))

            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.12))
                    Text(Self.accountInitial)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white.opacity(0.9))
                }
                .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 1) {
                    Text(Self.accountDisplayName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    Text("本地模式")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.4))
                }

                Spacer(minLength: 4)

                Button(action: { showsSettings = true }) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.55))
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Color.white.opacity(0.07)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .help("设置")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    // MARK: - Formatting

    /// 会话的第二行预览：取最近一条对话的开头（用户的话优先，读起来才
    /// 像原版的「我会读完四家中国发射…」）。
    private static func previewText(_ session: ConversationSession) -> String {
        let lastEntry = session.entries.last
        let candidate = lastEntry?.userTranscript ?? lastEntry?.assistantResponse ?? ""
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 32 else { return trimmed.isEmpty ? "还没有对话" : trimmed }
        return String(trimmed.prefix(32)) + "…"
    }

    /// Relative time for a session's last update — the sidebar's second line.
    private static func relativeTime(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    /// 本机账户名，仿原版账户区的名字行。
    private static var accountDisplayName: String {
        let fullName = NSFullUserName()
        return fullName.isEmpty ? "用户" : fullName
    }

    private static var accountInitial: String {
        String(accountDisplayName.prefix(1)).uppercased()
    }
}
