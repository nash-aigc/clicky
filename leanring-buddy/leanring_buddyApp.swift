//
//  leanring_buddyApp.swift
//  leanring-buddy
//
//  Menu bar-only companion app. No dock icon, no main window — just an
//  always-available status item in the macOS menu bar. Clicking the icon
//  opens a floating panel with companion voice controls.
//

import ServiceManagement
import SwiftUI
import Sparkle

@main
struct leanring_buddyApp: App {
    @NSApplicationDelegateAdaptor(CompanionAppDelegate.self) var appDelegate

    var body: some Scene {
        // The app lives entirely in the menu bar panel managed by the AppDelegate.
        // This empty Settings scene satisfies SwiftUI's requirement for at least
        // one scene but is never shown (LSUIElement=true removes the app menu).
        Settings {
            EmptyView()
        }
    }
}

/// Manages the companion lifecycle: creates the menu bar panel and starts
/// the companion voice pipeline on launch.
@MainActor
final class CompanionAppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarPanelManager: MenuBarPanelManager?
    private let companionManager = CompanionManager()
    private var sparkleUpdaterController: SPUStandardUpdaterController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("🎯 Clicky: Starting...")
        print("🎯 Clicky: Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown")")

        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 0])

        menuBarPanelManager = MenuBarPanelManager(companionManager: companionManager)
        companionManager.start()

        // 通用 → 启动: whether the app registers itself as a login item is now a
        // user setting (it used to be forced on). Applied here and re-applied on
        // every settings save below, so toggling it in the settings window takes
        // effect without a relaunch.
        let appSettings = AppSettingsStore.snapshot()
        applyLoginItemSetting(launchesAtLogin: appSettings.launchesAtLogin)

        // Auto-open the panel if the user still needs to do something: either
        // they haven't onboarded yet, permissions were revoked — or they turned
        // on 「启动时自动打开面板」.
        if !companionManager.hasCompletedOnboarding
            || !companionManager.allPermissionsGranted
            || appSettings.opensPanelOnLaunch {
            menuBarPanelManager?.showPanelOnLaunch()
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appSettingsChanged),
            name: .clickyAppSettingsChanged,
            object: nil
        )
    }

    @objc private func appSettingsChanged() {
        applyLoginItemSetting(launchesAtLogin: AppSettingsStore.snapshot().launchesAtLogin)
    }

    func applicationWillTerminate(_ notification: Notification) {
        companionManager.stop()
    }

    /// Makes the macOS login-item registration match `launchesAtLogin`.
    ///
    /// Uses SMAppService, which also shows the app in System Settings > General >
    /// Login Items — so the user can always see (and override) what this wrote.
    private func applyLoginItemSetting(launchesAtLogin: Bool) {
        let loginItemService = SMAppService.mainApp

        if launchesAtLogin {
            guard loginItemService.status != .enabled else { return }
            do {
                try loginItemService.register()
                print("🎯 Clicky: Registered as login item")
            } catch {
                print("⚠️ Clicky: Failed to register as login item: \(error)")
            }
        } else {
            guard loginItemService.status == .enabled else { return }
            do {
                try loginItemService.unregister()
                print("🎯 Clicky: Unregistered as login item (turned off in settings)")
            } catch {
                print("⚠️ Clicky: Failed to unregister as login item: \(error)")
            }
        }
    }

    private func startSparkleUpdater() {
        let updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        self.sparkleUpdaterController = updaterController

        do {
            try updaterController.updater.start()
        } catch {
            print("⚠️ Clicky: Sparkle updater failed to start: \(error)")
        }
    }
}
