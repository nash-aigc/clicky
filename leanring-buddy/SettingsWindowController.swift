//
//  SettingsWindowController.swift
//  leanring-buddy
//
//  Hosts the settings window: a sidebar of seven pages on the left, the selected
//  page on the right.
//
//  A separate window rather than a section inside the menu bar panel: the forms
//  are wider than the panel, and the panel auto-dismisses on any outside click —
//  which would close the form every time the user clicked away to copy an API key
//  out of their browser.
//
//  The window has two independent drafts behind it, one per view model: the
//  general pages edit `AppSettings` (AppSettings.json) and the 模型 page edits the
//  provider configuration (ModelConfiguration.json). They are separate files with
//  separate save buttons, so each page keeps its own 保存 — merging them into one
//  button would write two files from one click and make "what did I just save"
//  unanswerable.
//

import AppKit
import Combine
import SwiftUI

/// Which page the window is showing.
///
/// Held by the controller rather than as `@State` inside the root view so the
/// window can be *opened at* a page: the panel's 「更换…」 button next to the
/// vision model has to land on 模型, and a `@State` the controller cannot reach
/// would instead reopen whatever page was last looked at.
@MainActor
final class SettingsWindowPageSelection: ObservableObject {
    @Published var selectedPage: SettingsPage = .general
}

@MainActor
final class SettingsWindowController: NSWindowController {
    private let modelSettingsViewModel = ModelSettingsViewModel()
    private let generalSettingsViewModel = GeneralSettingsViewModel()
    private let pageSelection = SettingsWindowPageSelection()

    init() {
        let settingsWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        settingsWindow.title = "Clicky 设置"
        settingsWindow.minSize = NSSize(width: 780, height: 520)

        // The design tokens are a dark palette. Following the system appearance
        // would render the form in light mode for anyone whose Mac is set that way,
        // where the token colours read as muddy grey on grey.
        settingsWindow.appearance = NSAppearance(named: .darkAqua)

        // Required: without this, closing the window releases it a second time and
        // the app crashes. The controller also keeps a strong reference (held by
        // `CompanionManager`), and both halves are needed — releasing on close would
        // take the window down while the controller still points at it.
        settingsWindow.isReleasedWhenClosed = false

        settingsWindow.contentViewController = NSHostingController(
            rootView: ClickySettingsRootView(
                modelSettingsViewModel: modelSettingsViewModel,
                generalSettingsViewModel: generalSettingsViewModel,
                pageSelection: pageSelection
            )
        )
        settingsWindow.center()

        super.init(window: settingsWindow)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SettingsWindowController is created in code, not from a nib.")
    }

    /// Shows the window and brings it to the front.
    ///
    /// - Parameter initialPage: The page to open on. `nil` leaves the window on
    ///   whichever page it was last showing, which is what the gear icon wants;
    ///   「更换…」 passes `.model` so it lands where that button's promise is.
    func presentWindow(initialPage: SettingsPage? = nil) {
        if let initialPage {
            pageSelection.selectedPage = initialPage
        }

        // Both drafts are re-read on every present: the controller is created once
        // and reused, so without this the window would come back showing whatever
        // was in the drafts when it was last closed. Each view model leaves a
        // draft with unsaved edits alone, so nobody loses their typing.
        modelSettingsViewModel.reloadDraftFromStoreIfUnchanged()
        generalSettingsViewModel.reloadFromStoreIfUnchanged()

        // Required, and not obvious: this app is a menu bar accessory
        // (`LSUIElement`), so it is never the active application on its own. Without
        // activating, the window appears but never becomes key — and a non-key
        // window's text fields silently swallow every keystroke, which looks exactly
        // like a broken form.
        NSApp.activate()

        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Root view

private struct ClickySettingsRootView: View {
    @ObservedObject var modelSettingsViewModel: ModelSettingsViewModel
    @ObservedObject var generalSettingsViewModel: GeneralSettingsViewModel
    @ObservedObject var pageSelection: SettingsWindowPageSelection

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 178)

            Rectangle()
                .fill(DS.Colors.borderSubtle)
                .frame(width: 1)

            pageContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 780, minHeight: 520)
        .background(DS.Colors.background)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // HeyClicky 式头部：应用身份卡在导航之上。
            HStack(spacing: 10) {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [DS.Colors.overlayCursorBlue.opacity(0.85), DS.Colors.overlayCursorBlue.opacity(0.45)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 34, height: 34)
                    .overlay(
                        Triangle()
                            .stroke(Color.white, lineWidth: 2)
                            .frame(width: 12, height: 10)
                    )

                VStack(alignment: .leading, spacing: 3) {
                    Text("Clicky")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                    Text("本地语音伴侣")
                        .font(.system(size: 10.5))
                        .foregroundColor(DS.Colors.textTertiary)
                }

                Spacer()
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .fill(DS.Colors.surface2)
            )
            .padding(.horizontal, 12)
            .padding(.top, 16)
            .padding(.bottom, 14)

            // 分组导航：组与组之间用大写小标签隔开——HeyClicky 的侧栏是
            // 「General / 对话 / 看与操作」三段，不是一列平铺。
            sidebarSection(title: nil, pages: [.general, .model])
            sidebarSection(title: "对话", pages: [.memory, .listen, .speak, .shortcuts])
            sidebarSection(title: "看与操作", pages: [.vision, .action])

            Spacer()

            Text(versionLine)
                .font(.system(size: 10.5))
                .foregroundColor(DS.Colors.textTertiary)
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(DS.Colors.surface1)
    }

    /// One titled (or untitled) block of sidebar rows.
    private func sidebarSection(title: String?, pages: [SettingsPage]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let title {
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1.2)
                    .foregroundColor(DS.Colors.textTertiary)
                    .padding(.horizontal, 18)
                    .padding(.top, 12)
                    .padding(.bottom, 5)
            }

            ForEach(pages, id: \.self) { page in
                SettingsSidebarItem(
                    page: page,
                    isSelected: page == pageSelection.selectedPage,
                    action: { pageSelection.selectedPage = page }
                )
            }
        }
    }

    /// "Clicky 1.2 (137)" — the same identification HeyClicky prints in the
    /// bottom-left of its settings sidebar.
    private var versionLine: String {
        let shortVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let buildVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "Clicky \(shortVersion) (\(buildVersion))"
    }

    @ViewBuilder
    private var pageContent: some View {
        switch pageSelection.selectedPage {
        case .model:
            // Rendered by the model view model's own view, unchanged — it brings
            // its own introduction and its own 保存 / 测试连接 bar.
            ModelSettingsView(modelSettingsViewModel: modelSettingsViewModel)

        default:
            VStack(spacing: 0) {
                GeneralSettingsView(
                    generalSettingsViewModel: generalSettingsViewModel,
                    page: pageSelection.selectedPage
                )
                GeneralSettingsActionBar(generalSettingsViewModel: generalSettingsViewModel)
            }
        }
    }
}

// MARK: - Sidebar

private struct SettingsSidebarItem: View {
    let page: SettingsPage
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: page.sidebarSymbol)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(isSelected ? DS.Colors.textPrimary : DS.Colors.textSecondary)
                    .frame(width: 16)

                Text(page.sidebarTitle)
                    .font(.system(size: 12.5, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(isSelected ? DS.Colors.textPrimary : DS.Colors.textSecondary)

                Spacer(minLength: 4)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                    .fill(rowBackgroundColor)
            )
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { isHovering in
            self.isHovering = isHovering
        }
    }

    /// Selection is a tinted fill rather than a solid accent bar: the sidebar is
    /// a list of peers, and a filled accent row would read as "this one is a
    /// button" rather than "you are here".
    private var rowBackgroundColor: Color {
        if isSelected { return DS.Colors.accentSubtle }
        if isHovering { return DS.Colors.surface2 }
        return Color.clear
    }
}

// MARK: - Action bar

/// The 恢复默认 / 保存 bar under the general pages.
///
/// Sits outside the page's `ScrollView` so 保存 is reachable without scrolling,
/// which matters most on the longest page (对话与记忆).
// Internal rather than private: the notch sheet's embedded settings area
// reuses the same save bar as the titled window (NotchSettingsArea).
struct GeneralSettingsActionBar: View {
    @ObservedObject var generalSettingsViewModel: GeneralSettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            Divider().overlay(DS.Colors.borderSubtle)

            HStack(alignment: .center, spacing: DS.Spacing.lg) {
                Button("恢复默认") {
                    generalSettingsViewModel.resetToDefaults()
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                        .fill(DS.Colors.surface2)
                )
                .pointerCursor()
                .help("把这一页的所有设置改回初始值。点「保存」之前不会写入。")

                Spacer()

                if let saveErrorMessage = generalSettingsViewModel.saveErrorMessage {
                    Text(saveErrorMessage)
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.destructiveText)
                        .lineLimit(2)
                        .textSelection(.enabled)
                } else if generalSettingsViewModel.lastSavedAt != nil
                    && !generalSettingsViewModel.isDirty {
                    Text("已保存，立即生效")
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.success)
                }

                Button("保存") {
                    generalSettingsViewModel.save()
                }
                .buttonStyle(DSPillButtonStyle(isEnabled: generalSettingsViewModel.isDirty))
                .disabled(!generalSettingsViewModel.isDirty)

                Button("关闭") {
                    NSApp.keyWindow?.close()
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                        .fill(DS.Colors.surface2)
                )
                .pointerCursor()
            }
            .padding(.horizontal, 24)
            .padding(.vertical, DS.Spacing.md)
        }
        .background(DS.Colors.background)
    }
}
