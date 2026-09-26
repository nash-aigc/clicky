//
//  AddCardFormView.swift
//  Wanna
//
//  「添加」按下去之后那张**两行的表单**（用户 2026-09-26）：
//
//  「用户在添加的时候，需要让用户选择创建哪一类的 agent。你现在是直接添加，这是不对的。
//   必须要让用户点击添加按钮之后，有一个下拉菜单，可以选择主 agent 或者 claude code，
//   然后让用户填写标题、备注，以及选择哪一个 AI、哪一个 Agent。点击下拉按钮之后，其实
//   应该是两行。让用户填写这些参数之后，再点击创建，这样的效果才对。」
//
//  两行 = **第一行选种类，第二行填参数**。他后来又把「备注」整个删掉了（「删除备注的功能」），
//  所以第二行是：标题 + 用哪个 AI（主 Agent 是视觉模型，Claude Code 是 CLI 的 `--model`）
//  + 项目文件夹（只有 Claude Code 有）。
//
//  ## 为什么是"内联清单"而不是下拉菜单
//
//  种类与模型都用**竖排的可点行**，不是 `Menu` 也不是弹出层：
//  这个仓库为此付过两次代价 —— 原生 `Menu` 渲染出来的 `NSMenu` 从 SwiftUI 里根本没法调样式
//  （语音页那个手绘下拉就是为此写的），而挂在窄条 `.overlay` 上的清单**画得出、收不到点击**
//  （`开发经验/10-踩过的坑.md` D14）。内联清单没有这两个问题，代价只是多占几行高度。
//
//  ## 创建出来的是什么
//
//  - **主 Agent** → 一条新的主对话（`createSession`），并把它自己那份「用哪个 AI」写进
//    `AppSettings.cardVisionModelOverrides`（那次请求会带着这份覆盖去调模型）。
//  - **Claude Code** → 一条新的 `AgentSession`（`createAgent`，cwd = 选的项目文件夹），
//    模型写进 `AgentSession.modelAlias`（下一次 spawn 会带上 `--model`），卡片的聊天模式
//    默认「文本」（`CardChatMode.defaultMode(for:)` 就是这么定的）。
//

import SwiftUI

@MainActor
struct AddCardFormView: View {

    /// 表单关掉（取消 / 创建完）。
    let dismissAction: () -> Void
    /// 主 Agent：建一条新主对话。参数是标题。
    let createMainAgent: (String, String?) -> Void
    /// Claude Code：建一条新的 agent 记录。参数是标题、项目文件夹、模型别名。
    let createClaudeCodeAgent: (String, String, String?) -> Void
    /// 选项目文件夹（关一次弹窗、开一次 `NSOpenPanel`、再把弹窗放回来）。
    let pickFolder: (@escaping (String?) -> Void) -> Void

    @State private var draftKind: CardKind = .mainLoop
    @State private var draftTitle: String = ""
    @State private var draftFolderPath: String = ""
    @State private var draftModelChoiceID: String?
    @State private var draftClaudeModelAlias: String?
    @State private var isPickingFolder = false

    /// Claude Code 的模型别名 —— **是 CLI 自己的 `--model` 认的那几个**（`claude --help`
    /// 里写着的例子：`fable` / `opus` / `sonnet`），不是百炼的模型名。
    /// 两边的"AI"不是同一个东西，混在一张清单里只会让用户选到一个必然报错的名字。
    private static let claudeModelChoices: [(alias: String, displayName: String)] = [
        ("fable", "fable（最新）"),
        ("opus", "opus"),
        ("sonnet", "sonnet"),
    ]

    private var visionModelChoices: [ModelConfiguration.VisionModelChoice] {
        ModelConfigurationStore.snapshot().visionModelChoices
    }

    /// 能不能按「创建」—— 每种卡片缺什么，判据就一条。
    private var canCreate: Bool {
        let hasTitle = !draftTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        switch draftKind {
        case .mainLoop:
            return hasTitle
        case .claudeCode, .review:
            return hasTitle && !draftFolderPath.isEmpty
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Color.white.opacity(0.08))

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    kindSection
                    titleSection
                    modelSection
                    if draftKind != .mainLoop {
                        folderSection
                    }
                }
                .padding(12)
            }
            .frame(maxHeight: 380)

            Divider().overlay(Color.white.opacity(0.08))
            footer
        }
        .frame(width: 360)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(DS.Colors.surface2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.45), radius: 16, y: 6)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("添加")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
            Spacer(minLength: 4)
            Button(action: dismissAction) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.white.opacity(0.55))
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(Color.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help("取消")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - 第一行：种类

    private var kindSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("创建哪一类")
            HStack(spacing: 6) {
                kindRow(.mainLoop, title: "主 Agent", subtitle: "自研主循环：看屏幕、答问题、执行操作")
                kindRow(.claudeCode, title: "Claude Code", subtitle: "在某个项目文件夹里干活")
            }
        }
    }

    private func kindRow(_ kind: CardKind, title: String, subtitle: String) -> some View {
        let isSelected = draftKind == kind
        return Button {
            SoundEffectPlayer.shared.play(.sidebarButton)
            draftKind = kind
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12.5, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(isSelected ? DS.Colors.success : .white.opacity(0.85))
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.45))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isSelected ? DS.Colors.success.opacity(0.16) : Color.white.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(isSelected ? DS.Colors.success.opacity(0.75)
                                             : Color.white.opacity(0.08),
                                  lineWidth: isSelected ? 1.5 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    // MARK: - 第二行：标题

    private var titleSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("标题")
            TextField(placeholderTitle, text: $draftTitle)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                )
        }
    }

    private var placeholderTitle: String {
        // 用户：「默认是 claude code」—— 那张卡片的默认标题就是它。
        draftKind == .mainLoop ? "新对话" : "Claude Code"
    }

    // MARK: - 用哪个 AI

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel(draftKind == .mainLoop ? "用哪个 AI" : "Claude Code 用哪个模型")
            if draftKind == .mainLoop {
                if visionModelChoices.isEmpty {
                    hintText("还没有配好任何能看图的模型 —— 去「设置 → 模型」配一个，或者先不选（跟全局走）。")
                } else {
                    choiceRow(title: "跟设置里全局那份", isSelected: draftModelChoiceID == nil) {
                        draftModelChoiceID = nil
                    }
                    ForEach(visionModelChoices) { choice in
                        choiceRow(title: choice.displayName,
                                  isSelected: draftModelChoiceID == choice.id) {
                            draftModelChoiceID = choice.id
                        }
                    }
                }
            } else {
                choiceRow(title: "跟 Claude Code 自己的默认", isSelected: draftClaudeModelAlias == nil) {
                    draftClaudeModelAlias = nil
                }
                ForEach(Self.claudeModelChoices, id: \.alias) { choice in
                    choiceRow(title: choice.displayName,
                              isSelected: draftClaudeModelAlias == choice.alias) {
                        draftClaudeModelAlias = choice.alias
                    }
                }
            }
        }
    }

    private func choiceRow(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            SoundEffectPlayer.shared.play(.sidebarButton)
            action()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 11))
                    .foregroundColor(isSelected ? DS.Colors.success : .white.opacity(0.25))
                Text(title)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.88))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected ? Color.white.opacity(0.08) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    // MARK: - 项目文件夹（只有 Claude Code）

    private var folderSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("项目文件夹")
            HStack(spacing: 8) {
                Text(draftFolderPath.isEmpty ? "还没选" : draftFolderPath)
                    .font(.system(size: 11.5))
                    .foregroundColor(draftFolderPath.isEmpty ? .white.opacity(0.35) : .white.opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    SoundEffectPlayer.shared.play(.sidebarButton)
                    isPickingFolder = true
                    pickFolder { pickedPath in
                        isPickingFolder = false
                        if let pickedPath { draftFolderPath = pickedPath }
                    }
                } label: {
                    Text(isPickingFolder ? "选择中…" : "选择…")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundColor(.white.opacity(0.85))
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Color.white.opacity(0.08))
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .disabled(isPickingFolder)
            }
            hintText("它就跑在这个文件夹里，读写都在这里面。")
        }
    }

    // MARK: - 创建

    private var footer: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            Button(action: dismissAction) {
                Text("取消")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.7))
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.white.opacity(0.06))
                    )
            }
            .buttonStyle(.plain)
            .pointerCursor()

            Button(action: commit) {
                Text("创建")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(canCreate ? .black.opacity(0.85) : .white.opacity(0.35))
                    .padding(.horizontal, 14)
                    .frame(height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(canCreate ? DS.Colors.success : Color.white.opacity(0.06))
                    )
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .disabled(!canCreate)
            .help(canCreate ? "按这些参数建出来" : missingRequirementHint)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var missingRequirementHint: String {
        if draftTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "先填个标题" }
        return "先选一个项目文件夹"
    }

    private func commit() {
        guard canCreate else { return }
        SoundEffectPlayer.shared.play(.notchRevealed)
        let trimmedTitle = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        switch draftKind {
        case .mainLoop:
            createMainAgent(trimmedTitle, draftModelChoiceID)
        case .claudeCode, .review:
            createClaudeCodeAgent(trimmedTitle, draftFolderPath, draftClaudeModelAlias)
        }
        dismissAction()
    }

    // MARK: - 小零件

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundColor(.white.opacity(0.45))
            .textCase(.uppercase)
            .kerning(0.6)
    }

    private func hintText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5))
            .foregroundColor(.white.opacity(0.38))
            .fixedSize(horizontal: false, vertical: true)
    }
}
