//
//  leanring_buddyApp.swift
//  leanring-buddy
//
//  Notch-only companion app. No dock icon, no main window, no menu bar
//  icon — the app's entire UI is the notch pill / expanded sheet (and the
//  blue cursor overlay).
//

import ServiceManagement
import SwiftUI
import Sparkle

@main
struct leanring_buddyApp: App {
    @NSApplicationDelegateAdaptor(CompanionAppDelegate.self) var appDelegate

    var body: some Scene {
        // The app lives entirely in the notch subsystem managed by the
        // AppDelegate. This empty Settings scene satisfies SwiftUI's
        // requirement for at least one scene but is never shown
        // (LSUIElement=true removes the app menu).
        Settings {
            EmptyView()
        }
    }
}

/// Manages the companion lifecycle: starts the companion voice pipeline on
/// launch, applies the login-item setting, and auto-expands the notch sheet
/// when 「启动时自动打开面板」 asks for it.
@MainActor
final class CompanionAppDelegate: NSObject, NSApplicationDelegate {
    private let companionManager = CompanionManager()
    private var sparkleUpdaterController: SPUStandardUpdaterController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("🎯 Wanna: Starting...")
        print("🎯 Wanna: Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown")")

        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 0])

        companionManager.start()

        // 通用 → 启动: whether the app registers itself as a login item is now a
        // user setting (it used to be forced on). Applied here and re-applied on
        // every settings save below, so toggling it in the settings window takes
        // effect without a relaunch.
        let appSettings = AppSettingsStore.snapshot()
        applyLoginItemSetting(launchesAtLogin: appSettings.launchesAtLogin)

        // 通用 → 「启动时自动打开面板」: expand the notch sheet on launch so the
        // conversation is already open. Only meaningful once the notch
        // subsystem exists — onboarding and the permissions have to be done
        // (a fresh launch is running its first-launch flow instead), and the
        // pills need a beat to build, hence the delay.
        if appSettings.opensPanelOnLaunch,
           companionManager.hasCompletedOnboarding,
           companionManager.allPermissionsGranted {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.companionManager.notchWindowController?.expandForLaunch()
            }
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
                print("🎯 Wanna: Registered as login item")
            } catch {
                print("⚠️ Wanna: Failed to register as login item: \(error)")
            }
        } else {
            guard loginItemService.status == .enabled else { return }
            do {
                try loginItemService.unregister()
                print("🎯 Wanna: Unregistered as login item (turned off in settings)")
            } catch {
                print("⚠️ Wanna: Failed to unregister as login item: \(error)")
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
            print("⚠️ Wanna: Sparkle updater failed to start: \(error)")
        }
    }
}
