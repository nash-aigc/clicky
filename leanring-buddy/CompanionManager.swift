//
//  CompanionManager.swift
//  leanring-buddy
//
//  Central state manager for the companion voice mode. Owns the push-to-talk
//  pipeline (dictation manager + global shortcut monitor + overlay) and
//  exposes observable voice state for the panel UI.
//

import AVFoundation
import Combine
import Foundation
import ScreenCaptureKit
import SwiftUI

enum CompanionVoiceState {
    case idle
    case listening
    case processing
    case responding
}

@MainActor
final class CompanionManager: ObservableObject {
    @Published private(set) var voiceState: CompanionVoiceState = .idle
    @Published private(set) var lastTranscript: String?
    @Published private(set) var currentAudioPowerLevel: CGFloat = 0
    @Published private(set) var hasAccessibilityPermission = false
    @Published private(set) var hasScreenRecordingPermission = false
    @Published private(set) var hasMicrophonePermission = false
    @Published private(set) var hasScreenContentPermission = false

    /// Screen location (global AppKit coords) of a detected UI element the
    /// buddy should fly to and point at. Parsed from the model's response;
    /// observed by BlueCursorView to trigger the flight animation.
    @Published var detectedElementScreenLocation: CGPoint?
    /// The display frame (global AppKit coords) of the screen the detected
    /// element is on, so BlueCursorView knows which screen overlay should animate.
    @Published var detectedElementDisplayFrame: CGRect?
    /// Custom speech bubble text for the pointing animation. When set,
    /// BlueCursorView uses this instead of a random pointer phrase.
    @Published var detectedElementBubbleText: String?

    // MARK: - Onboarding Video State (shared across all screen overlays)

    @Published var onboardingVideoPlayer: AVPlayer?
    @Published var showOnboardingVideo: Bool = false
    @Published var onboardingVideoOpacity: Double = 0.0
    private var onboardingVideoEndObserver: NSObjectProtocol?
    private var onboardingDemoTimeObserver: Any?

    // MARK: - Onboarding Prompt Bubble

    /// Text streamed character-by-character on the cursor after the onboarding video ends.
    @Published var onboardingPromptText: String = ""
    @Published var onboardingPromptOpacity: Double = 0.0
    @Published var showOnboardingPrompt: Bool = false

    // MARK: - Onboarding Music

    private var onboardingMusicPlayer: AVAudioPlayer?
    private var onboardingMusicFadeTimer: Timer?

    let buddyDictationManager = BuddyDictationManager()
    let globalPushToTalkShortcutMonitor = GlobalPushToTalkShortcutMonitor()
    let overlayWindowManager = OverlayWindowManager()
    // Response text is now displayed inline on the cursor overlay via
    // streamingResponseText, so no separate response overlay manager is needed.

    /// Clients for the configured models. Both are constructed without arguments
    /// and resolve the endpoint, key and model from the user's model
    /// configuration on every request, so a change saved in the settings window
    /// takes effect on the next question rather than on the next launch.
    private lazy var visionChatAPI = BailianVisionChatAPI()

    private lazy var bailianTTSClient = BailianTTSClient()

    /// Conversation history so the companion remembers prior exchanges. Each entry
    /// is the user's transcript, the assistant's response, and — when
    /// 「历史里带截图」 is on — the screenshots the answer was based on.
    ///
    /// Kept in memory always; written to disk only while 「重启后保留对话」 is on.
    private var conversationHistory: [ConversationHistoryEntry] = []

    /// What older turns have been compressed into.
    ///
    /// Non-empty only once 「历史自动压缩」 has folded an exchange that aged out of
    /// the window. Sent as its own system message, so the model keeps the gist of
    /// a conversation the user has scrolled past the limit of.
    private var compressedHistorySummary: String = ""

    /// The compression request that is in flight, if any.
    ///
    /// Held so `stop()` can cancel it, and so a second compression cannot start
    /// while one is running — two summaries folding the same exchange would
    /// produce a summary of a summary.
    private var historyCompressionTask: Task<Void, Never>?

    /// The currently running AI response task, if any. Cancelled when the user
    /// speaks again so a new response can begin immediately.
    private var currentResponseTask: Task<Void, Never>?

    private var shortcutTransitionCancellable: AnyCancellable?
    private var voiceStateCancellable: AnyCancellable?
    private var audioPowerCancellable: AnyCancellable?
    private var accessibilityCheckTimer: Timer?
    private var pendingKeyboardShortcutStartTask: Task<Void, Never>?
    /// Scheduled hide for transient cursor mode — cancelled if the user
    /// speaks again before the delay elapses.
    private var transientHideTask: Task<Void, Never>?

    /// A transcript waiting for the user to confirm it, when
    /// 快捷键 → 「松开立即发送」 is off.
    ///
    /// Nothing is sent while this holds a value; the text sits in the cursor
    /// bubble so it can be read before it becomes a question. A second tap of the
    /// shortcut sends it, and simply speaking again replaces it.
    private var pendingConfirmationTranscript: String?

    /// When the shortcut went down, so a release can tell a tap from a hold.
    private var shortcutPressBeganAt: Date?

    /// Set once a press has sent the pending transcript, so the tail end of that
    /// same press — the dictation session still delivering its final result —
    /// cannot send it twice.
    private var didSendPendingConfirmationThisPress = false

    /// True when all three required permissions (accessibility, screen recording,
    /// microphone) are granted. Used by the panel to show a single "all good" state.
    var allPermissionsGranted: Bool {
        hasAccessibilityPermission && hasScreenRecordingPermission && hasMicrophonePermission && hasScreenContentPermission
    }

    /// Whether the blue cursor overlay is currently visible on screen.
    /// Used by the panel to show accurate status text ("Active" vs "Ready").
    @Published private(set) var isOverlayVisible: Bool = false

    /// The vision role as currently configured, for the menu bar panel to display.
    ///
    /// Exposed as a status rather than as a model name so the panel can show the
    /// specific reason a role is unusable ("DeepSeek 的 URL 或 API Key 还没填")
    /// instead of a generic "not configured".
    ///
    /// The model choice used to live here as an `@Published var` validated against
    /// a fixed list of two Bailian model IDs. That list silently replaced any model
    /// name it did not recognise with the default — which is exactly what a custom
    /// model is — so ownership of the choice now sits in the settings window.
    var visionRoleStatus: RoleConfigurationStatus {
        ModelConfigurationStore.snapshot().status(of: .vision)
    }

    /// The most recent failure worth telling the user about, or nil.
    ///
    /// Shown as a line of text in the panel. The companion apologises out loud when
    /// a request fails, but a spoken apology is indistinguishable from the model
    /// failing to answer — it hid an exhausted-quota 403 behind "抱歉，我这边出了点
    /// 问题" for a long time. The panel shows the API's own words instead.
    @Published private(set) var lastErrorMessage: String?

    /// The answer as it streams in, shown in a bubble beside the cursor.
    ///
    /// Stays empty when 通用 → 「回答时显示文字」 is off, so the overlay renders the
    /// bubble purely on "is there text" and needs no knowledge of the setting —
    /// which is what keeps the setting to one gate, in the pipeline that fills this.
    @Published private(set) var streamingAnswerText: String = ""

    /// Clears the answer bubble once the voice has stopped and the user's linger
    /// has elapsed. Cancelled whenever a new answer takes the bubble over.
    private var answerBubbleClearTask: Task<Void, Never>?

    /// What the user is saying right now, shown in a bubble beside the cursor.
    ///
    /// Empty when 通用 → 「说话时实时显示识别文字」 is off, or when the transcript is
    /// hidden because the panel is in transient mode. Same one-gate reasoning as
    /// `streamingAnswerText`.
    @Published private(set) var liveTranscriptText: String = ""

    /// The settings window, held strongly.
    ///
    /// `MenuBarPanelManager` holds its panel the same way and for the same reason:
    /// a window controller released while its window is still on screen takes the
    /// window down with it.
    private var settingsWindowController: SettingsWindowController?
    private var modelConfigurationChangedObserver: NSObjectProtocol?
    private var conversationHistoryClearedObserver: NSObjectProtocol?
    private var appSettingsChangedObserver: NSObjectProtocol?

    /// Whether the blue cursor companion is currently drawn.
    ///
    /// This is what the panel's status row reads, and what the overlay multiplies
    /// into every part of the companion it draws. It is deliberately separate from
    /// `isOverlayVisible`: the overlay *windows* stay up for the life of the app
    /// (see `showOverlayIfPossible`), so `isOverlayVisible` is true even while the
    /// companion is hidden — reading it for "is the companion on screen" would make
    /// the panel say "Active" forever.
    ///
    /// False while the companion is idle in 「只在对话时出现」/「只在指位置时出现」, and
    /// permanently true in 「一直显示」. Onboarding forces it true regardless, so the
    /// welcome animation never plays to an invisible companion.
    @Published private(set) var isBuddyShown: Bool = true

    /// The three cursor settings, mirrored from `AppSettingsStore`.
    ///
    /// The overlay reads the companion through `@ObservedObject` and never touches
    /// the store itself — that is the pattern every other setting in the app
    /// follows, and it is what makes a save in the settings window redraw the
    /// overlay without a restart.
    @Published private(set) var cursorPresenceMode: CursorPresenceMode = .alwaysVisible
    @Published private(set) var cursorShapeStyle: CursorShapeStyle = .triangle
    @Published private(set) var cursorFollowDistance: CursorFollowDistance = .farBehind

    /// Copies the three cursor settings out of the store and applies the ones
    /// that can be decided without waiting for an interaction.
    ///
    /// 「一直显示」 is a standing answer, so it takes effect the moment it is
    /// saved. The other two modes only ever turn the companion *on* from an
    /// interaction (the push-to-talk press) and turn it *off* on a schedule, so
    /// switching to them hides the companion immediately rather than leaving it up
    /// until the next question.
    private func applyCursorSettings(_ settings: AppSettings) {
        cursorPresenceMode = settings.cursorPresenceMode
        cursorShapeStyle = settings.cursorShapeStyle
        cursorFollowDistance = settings.cursorFollowDistance

        if settings.cursorPresenceMode.showsBuddyWhileIdle {
            transientHideTask?.cancel()
            transientHideTask = nil
            isBuddyShown = true
        } else {
            isBuddyShown = false
        }
    }

    /// Whether the user has completed onboarding at least once. Persisted
    /// to UserDefaults so the Start button only appears on first launch.
    var hasCompletedOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") }
        set { UserDefaults.standard.set(newValue, forKey: "hasCompletedOnboarding") }
    }

    /// Whether the user has submitted their email during onboarding.
    @Published var hasSubmittedEmail: Bool = UserDefaults.standard.bool(forKey: "hasSubmittedEmail")

    /// Submits the user's email to FormSpark.
    func submitEmail(_ email: String) {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEmail.isEmpty else { return }

        hasSubmittedEmail = true
        UserDefaults.standard.set(true, forKey: "hasSubmittedEmail")

        // Submit to FormSpark
        Task {
            var request = URLRequest(url: URL(string: "https://submit-form.com/RWbGJxmIs")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["email": trimmedEmail])
            _ = try? await URLSession.shared.data(for: request)
        }
    }

    func start() {
        refreshAllPermissions()
        print("🔑 Clicky start — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission), onboarded: \(hasCompletedOnboarding)")
        startPermissionPolling()
        bindVoiceStateObservation()
        bindAudioPowerLevel()
        bindShortcutTransitions()

        // Restore the conversation before anything can be asked, so the first
        // question of a launch is answered with the memory of the last one.
        if AppSettingsStore.snapshot().persistsConversationHistory {
            let storedHistory = ConversationHistoryStore.snapshot()
            conversationHistory = storedHistory.entries
            compressedHistorySummary = storedHistory.summary
            print("💬 Clicky: restored \(conversationHistory.count) exchanges from disk")
        }
        // Eagerly touch the Bailian vision client so its TLS warmup handshake
        // completes well before the onboarding demo fires at ~40s into the video.
        // The warmup targets whatever host is configured at launch; the client
        // warms a newly chosen provider's host on the first request after a switch.
        _ = visionChatAPI

        // The panel reads the configuration through computed properties, so there
        // is nothing cached to invalidate when it changes — it only needs a signal
        // to re-render. A stale error is cleared at the same time, because the user
        // has just been given the chance to fix whatever caused it.
        modelConfigurationChangedObserver = NotificationCenter.default.addObserver(
            forName: .clickyModelConfigurationChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // `queue: .main` already guarantees this runs on the main thread, which
            // is what `MainActor` is — but the closure is `@Sendable`, so the
            // compiler can't see that guarantee and would flag the mutation. Stating
            // the assumption keeps the hop-free version instead of adding a `Task`
            // that would reorder it against the rest of the notification delivery.
            MainActor.assumeIsolated {
                self?.lastErrorMessage = nil
                self?.objectWillChange.send()
            }
        }

        // 「清空对话记忆」 on the 对话与记忆 page deletes the file through the store,
        // which cannot reach this object. Without this the next save would write
        // the history the user just deleted straight back to disk.
        conversationHistoryClearedObserver = NotificationCenter.default.addObserver(
            forName: .clickyConversationHistoryCleared,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.conversationHistory = []
                self?.compressedHistorySummary = ""
                self?.historyCompressionTask?.cancel()
                self?.historyCompressionTask = nil
                print("💬 Clicky: conversation memory cleared")
            }
        }

        // Turning 「重启后保留对话」 off has to delete what is already on disk, not
        // just stop future writes — the user is saying they do not want their
        // conversation kept, and a file left behind would make that untrue. Turning
        // it on writes the conversation in memory immediately, so the setting is
        // true from the moment it is saved rather than from the next question.
        appSettingsChangedObserver = NotificationCenter.default.addObserver(
            forName: .clickyAppSettingsChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let settings = AppSettingsStore.snapshot()

                if settings.persistsConversationHistory {
                    self.persistConversationHistory()
                } else {
                    ConversationHistoryStore.clear()
                }

                // The cursor settings are the one group that changes something the
                // overlay draws, so they have to be pushed through to it live.
                self.applyCursorSettings(settings)
            }
        }

        applyCursorSettings(AppSettingsStore.snapshot())

        // If the user already completed onboarding AND all permissions are
        // still granted, put the cursor overlay up now. If permissions were
        // revoked (e.g. signing change), don't — the panel will show the
        // permissions UI instead.
        //
        // The overlay windows then stay up for the life of the app. Whether the
        // companion is *drawn* is `isBuddyShown`'s job, not the window's: taking
        // the windows down and rebuilding them on every question tore down N
        // full-screen hosting views each time, which flashed and reset the
        // companion's position.
        if hasCompletedOnboarding && allPermissionsGranted {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        }
    }

    // MARK: - Settings

    /// Opens the settings window, creating it on first use.
    ///
    /// The panel is dismissed first because it floats above normal windows and
    /// would otherwise sit on top of the settings form, hiding it. The window is
    /// then opened on the next run loop turn rather than immediately, so the
    /// panel's `orderOut` has taken effect before the settings window tries to
    /// become key.
    ///
    /// Clicking inside the settings window cannot re-dismiss the panel: the
    /// panel's outside-click monitor is a global `NSEvent` monitor, which only
    /// ever receives events destined for other applications.
    ///
    /// - Parameter initialPage: The page to open on. Omitted, the window reopens
    ///   on whichever page it was last showing — right for the gear icon, wrong
    ///   for the panel's 「更换…」, which passes `.model` because that is what it
    ///   promises.
    func openSettings(initialPage: SettingsPage? = nil) {
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)

        DispatchQueue.main.async {
            if self.settingsWindowController == nil {
                self.settingsWindowController = SettingsWindowController()
            }
            self.settingsWindowController?.presentWindow(initialPage: initialPage)
        }
    }

    deinit {
        if let modelConfigurationChangedObserver {
            NotificationCenter.default.removeObserver(modelConfigurationChangedObserver)
        }
        if let conversationHistoryClearedObserver {
            NotificationCenter.default.removeObserver(conversationHistoryClearedObserver)
        }
        if let appSettingsChangedObserver {
            NotificationCenter.default.removeObserver(appSettingsChangedObserver)
        }
    }

    /// Called by BlueCursorView after the buddy finishes its pointing
    /// animation and returns to cursor-following mode.
    /// Triggers the onboarding sequence — dismisses the panel and restarts
    /// the overlay so the welcome animation and intro video play.
    func triggerOnboarding() {
        // Post notification so the panel manager can dismiss the panel
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)

        // Mark onboarding as completed so the Start button won't appear
        // again on future launches — the cursor will auto-show instead
        hasCompletedOnboarding = true

        // Play Besaid theme at 60% volume, fade out after 1m 30s
        startOnboardingMusic()

        // Show the overlay for the first time — isFirstAppearance triggers
        // the welcome animation and onboarding video
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }

    /// Replays the onboarding experience from the "Watch Onboarding Again"
    /// footer link. Same flow as triggerOnboarding but the cursor overlay
    /// is already visible so we just restart the welcome animation and video.
    func replayOnboarding() {
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)
        startOnboardingMusic()
        // Tear down any existing overlays and recreate with isFirstAppearance = true
        overlayWindowManager.hasShownOverlayBefore = false
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }

    private func stopOnboardingMusic() {
        onboardingMusicFadeTimer?.invalidate()
        onboardingMusicFadeTimer = nil
        onboardingMusicPlayer?.stop()
        onboardingMusicPlayer = nil
    }

    private func startOnboardingMusic() {
        stopOnboardingMusic()
        guard let musicURL = Bundle.main.url(forResource: "ff", withExtension: "mp3") else {
            print("⚠️ Clicky: ff.mp3 not found in bundle")
            return
        }

        do {
            let player = try AVAudioPlayer(contentsOf: musicURL)
            player.volume = 0.3
            player.play()
            self.onboardingMusicPlayer = player

            // After 1m 30s, fade the music out over 3s
            onboardingMusicFadeTimer = Timer.scheduledTimer(withTimeInterval: 90.0, repeats: false) { [weak self] _ in
                self?.fadeOutOnboardingMusic()
            }
        } catch {
            print("⚠️ Clicky: Failed to play onboarding music: \(error)")
        }
    }

    private func fadeOutOnboardingMusic() {
        guard let player = onboardingMusicPlayer else { return }

        let fadeSteps = 30
        let fadeDuration: Double = 3.0
        let stepInterval = fadeDuration / Double(fadeSteps)
        let volumeDecrement = player.volume / Float(fadeSteps)
        var stepsRemaining = fadeSteps

        onboardingMusicFadeTimer = Timer.scheduledTimer(withTimeInterval: stepInterval, repeats: true) { [weak self] timer in
            stepsRemaining -= 1
            player.volume -= volumeDecrement

            if stepsRemaining <= 0 {
                timer.invalidate()
                player.stop()
                self?.onboardingMusicPlayer = nil
                self?.onboardingMusicFadeTimer = nil
            }
        }
    }

    func clearDetectedElementLocation() {
        detectedElementScreenLocation = nil
        detectedElementDisplayFrame = nil
        detectedElementBubbleText = nil
    }

    func stop() {
        globalPushToTalkShortcutMonitor.stop()
        buddyDictationManager.cancelCurrentDictation()
        overlayWindowManager.hideOverlay()
        transientHideTask?.cancel()

        currentResponseTask?.cancel()
        currentResponseTask = nil
        shortcutTransitionCancellable?.cancel()
        voiceStateCancellable?.cancel()
        audioPowerCancellable?.cancel()
        accessibilityCheckTimer?.invalidate()
        accessibilityCheckTimer = nil
    }

    func refreshAllPermissions() {
        let previouslyHadAccessibility = hasAccessibilityPermission
        let previouslyHadScreenRecording = hasScreenRecordingPermission
        let previouslyHadMicrophone = hasMicrophonePermission

        let currentlyHasAccessibility = WindowPositionManager.hasAccessibilityPermission()
        hasAccessibilityPermission = currentlyHasAccessibility

        if currentlyHasAccessibility {
            globalPushToTalkShortcutMonitor.start()
        } else {
            globalPushToTalkShortcutMonitor.stop()
        }

        hasScreenRecordingPermission = WindowPositionManager.hasScreenRecordingPermission()

        let micAuthStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        hasMicrophonePermission = micAuthStatus == .authorized

        // Debug: log permission state on changes
        if previouslyHadAccessibility != hasAccessibilityPermission
            || previouslyHadScreenRecording != hasScreenRecordingPermission
            || previouslyHadMicrophone != hasMicrophonePermission {
            print("🔑 Permissions — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission)")
        }

        // Screen content permission is persisted — once the user has approved the
        // SCShareableContent picker, we don't need to re-check it.
        if !hasScreenContentPermission {
            hasScreenContentPermission = UserDefaults.standard.bool(forKey: "hasScreenContentPermission")
        }
    }

    /// Triggers the macOS screen content picker by performing a dummy
    /// screenshot capture. Once the user approves, we persist the grant
    /// so they're never asked again during onboarding.
    @Published private(set) var isRequestingScreenContent = false

    func requestScreenContentPermission() {
        guard !isRequestingScreenContent else { return }
        isRequestingScreenContent = true
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first else {
                    await MainActor.run { isRequestingScreenContent = false }
                    return
                }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.width = 320
                config.height = 240
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                // Verify the capture actually returned real content — a 0x0 or
                // fully-empty image means the user denied the prompt.
                let didCapture = image.width > 0 && image.height > 0
                print("🔑 Screen content capture result — width: \(image.width), height: \(image.height), didCapture: \(didCapture)")
                await MainActor.run {
                    isRequestingScreenContent = false
                    guard didCapture else { return }
                    hasScreenContentPermission = true
                    UserDefaults.standard.set(true, forKey: "hasScreenContentPermission")

                    // Now that the last permission has landed, the overlay can go
                    // up if onboarding was already completed.
                    if hasCompletedOnboarding && allPermissionsGranted && !isOverlayVisible {
                        overlayWindowManager.hasShownOverlayBefore = true
                        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                        isOverlayVisible = true
                    }
                }
            } catch {
                print("⚠️ Screen content permission request failed: \(error)")
                await MainActor.run { isRequestingScreenContent = false }
            }
        }
    }

    // MARK: - Private

    /// Triggers the system microphone prompt if the user has never been asked.
    /// Once granted/denied the status sticks and polling picks it up.
    private func promptForMicrophoneIfNotDetermined() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else { return }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor [weak self] in
                self?.hasMicrophonePermission = granted
            }
        }
    }

    /// Polls all permissions frequently so the UI updates live after the
    /// user grants them in System Settings. Screen Recording is the exception —
    /// macOS requires an app restart for that one to take effect.
    private func startPermissionPolling() {
        accessibilityCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAllPermissions()
            }
        }
    }

    private func bindAudioPowerLevel() {
        audioPowerCancellable = buddyDictationManager.$currentAudioPowerLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] powerLevel in
                self?.currentAudioPowerLevel = powerLevel
            }
    }

    private func bindVoiceStateObservation() {
        voiceStateCancellable = buddyDictationManager.$isRecordingFromKeyboardShortcut
            .combineLatest(
                buddyDictationManager.$isFinalizingTranscript,
                buddyDictationManager.$isPreparingToRecord
            )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isRecording, isFinalizing, isPreparing in
                guard let self else { return }
                // Don't override .responding — the AI response pipeline
                // manages that state directly until streaming finishes.
                guard self.voiceState != .responding else { return }

                if isFinalizing {
                    self.voiceState = .processing
                } else if isRecording {
                    self.voiceState = .listening
                } else if isPreparing {
                    self.voiceState = .processing
                } else {
                    self.voiceState = .idle
                    // If the user pressed and released the hotkey without
                    // saying anything, no response task runs — schedule the
                    // transient hide here so the overlay doesn't get stuck.
                    // Only do this when no response is in flight, otherwise
                    // the brief idle gap between recording and processing
                    // would prematurely hide the overlay.
                    if self.currentResponseTask == nil {
                        self.scheduleTransientHideIfNeeded()
                    }
                }
            }
    }

    private func bindShortcutTransitions() {
        shortcutTransitionCancellable = globalPushToTalkShortcutMonitor
            .shortcutTransitionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transition in
                self?.handleShortcutTransition(transition)
            }
    }

    private func handleShortcutTransition(_ transition: BuddyPushToTalkShortcut.ShortcutTransition) {
        switch transition {
        case .pressed:
            guard !buddyDictationManager.isDictationInProgress else { return }
            // Don't register push-to-talk while the onboarding video is playing
            guard !showOnboardingVideo else { return }

            // Recorded so the release can tell a tap (send what's waiting) from a
            // hold (say something new). See `handleFinalTranscript`.
            shortcutPressBeganAt = Date()
            didSendPendingConfirmationThisPress = false

            // Cancel any pending fade-out so the companion stays up for this
            // interaction, and bring it back on screen if the current mode had it
            // hidden. This is the whole of "fade in on the hotkey" — the companion
            // is drawn while `isBuddyShown` is true, and the overlay windows are
            // already up.
            transientHideTask?.cancel()
            transientHideTask = nil
            isBuddyShown = true

            // Dismiss the menu bar panel so it doesn't cover the screen
            NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)

            // Cancel any in-progress response and TTS from a previous utterance
            currentResponseTask?.cancel()

            // Whether a new question cuts off the answer being read aloud. Off, the
            // previous reply plays to the end — which is what someone wants when
            // they stepped away from the screen and are only listening.
            if AppSettingsStore.snapshot().interruptsPlaybackOnNewQuestion {
                bailianTTSClient.stopPlayback()
            }

            // A new question owns the bubble from here on: the previous answer's
            // text goes, and its pending clear (which would otherwise fire
            // mid-stream and wipe this answer's opening words) goes with it.
            clearAnswerBubble()
            clearDetectedElementLocation()

            // Dismiss the onboarding prompt if it's showing
            if showOnboardingPrompt {
                withAnimation(.easeOut(duration: 0.3)) {
                    onboardingPromptOpacity = 0.0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    self.showOnboardingPrompt = false
                    self.onboardingPromptText = ""
                }
            }
    

            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = Task {
                // Read once per recording, for the same reason the response
                // pipeline snapshots: one utterance should be governed by one
                // configuration.
                let appSettings = AppSettingsStore.snapshot()
                let showsLiveTranscript = appSettings.showsLiveTranscript
                let sendsImmediately = appSettings.sendsTranscriptImmediatelyOnRelease

                await buddyDictationManager.startPushToTalkFromKeyboardShortcut(
                    currentDraftText: "",
                    updateDraftText: { [weak self] partialTranscript in
                        // The waveform is the default UI; the words are optional.
                        // Leaving this empty is what keeps the overlay waveform-only,
                        // which is why the setting needs no other support.
                        guard showsLiveTranscript else { return }
                        self?.liveTranscriptText = partialTranscript
                    },
                    submitDraftText: { [weak self] finalTranscript in
                        self?.handleFinalTranscript(
                            finalTranscript,
                            sendsImmediately: sendsImmediately
                        )
                    }
                )
            }
        case .released:
            // Cancel the pending start task in case the user released the shortcut
            // before the async startPushToTalk had a chance to begin recording.
            // Without this, a quick press-and-release drops the release event and
            // leaves the waveform overlay stuck on screen indefinitely.
            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = nil
            buddyDictationManager.stopPushToTalkFromKeyboardShortcut()

            // A tap sends whatever is waiting for confirmation. The rule is stated
            // in terms of how long the key was held rather than in terms of what was
            // said, because the final transcript of this very press has not arrived
            // yet — the recognition service is still being given its grace period —
            // so "did they say anything this time" is not a question the release
            // event can answer. A hold says nothing about it either way, which is
            // what keeps a hold that captured no speech from destroying the pending
            // text: only a *new* transcript replaces it.
            let pressDuration = shortcutPressBeganAt.map { Date().timeIntervalSince($0) } ?? .greatestFiniteMagnitude
            if let pendingTranscript = pendingConfirmationTranscript,
               !didSendPendingConfirmationThisPress,
               pressDuration < Self.confirmationTapMaximumDurationSeconds {
                pendingConfirmationTranscript = nil
                didSendPendingConfirmationThisPress = true
                liveTranscriptText = ""
                lastTranscript = pendingTranscript
                print("🗣️ Companion sending confirmed transcript: \(pendingTranscript)")
                sendTranscriptToVisionChatWithScreenshot(transcript: pendingTranscript)
            } else if pendingConfirmationTranscript == nil {
                // Cleared here as well as in `handleFinalTranscript`: a tap that
                // produced no speech never reaches the submit callback, and a stale
                // transcript hovering next to the cursor is worse than none at all.
                liveTranscriptText = ""
            }
        case .none:
            break
        }
    }

    /// How long the shortcut may be held and still count as a tap.
    ///
    /// 0.6 s is long enough that an ordinary tap is never mistaken for speech and
    /// short enough that a deliberate hold to dictate is never mistaken for a tap.
    /// A press that lasted longer than this is the user starting a new question, so
    /// whatever was waiting for confirmation stays waiting.
    private static let confirmationTapMaximumDurationSeconds: TimeInterval = 0.6

    /// Decides what a finished transcript means, which depends on 快捷键 →
    /// 「松开立即发送」.
    ///
    /// With it on, the transcript is the question and goes straight out — the
    /// behaviour of every version before the setting existed. With it off, the
    /// transcript is *offered*: it waits next to the cursor as text so the user can
    /// read what was heard before committing to it, and a tap on the shortcut sends
    /// it (see the `.released` case).
    ///
    /// An empty transcript never sends anything and never clears anything. That is
    /// the whole reason a press that captured no speech is harmless: it leaves the
    /// pending question exactly where it was, so a user whose first attempt was not
    /// heard can hold the key again and try again without losing what they said.
    private func handleFinalTranscript(
        _ finalTranscript: String,
        sendsImmediately: Bool
    ) {
        let trimmedTranscript = finalTranscript.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedTranscript.isEmpty else {
            // Nothing was heard. With confirmation on, anything already waiting
            // stays waiting; with it off there is nothing to do either way.
            return
        }

        if sendsImmediately {
            pendingConfirmationTranscript = nil
            liveTranscriptText = ""
            lastTranscript = trimmedTranscript
            print("🗣️ Companion sending transcript: \(trimmedTranscript)")
            sendTranscriptToVisionChatWithScreenshot(transcript: trimmedTranscript)
            return
        }

        // Waiting for confirmation. The text is shown next to the cursor rather
        // than sent, so this is the one place `liveTranscriptText` is set from the
        // setting-independent path — the bubble is the confirmation, and hiding it
        // would leave the user with no way to read back what was heard.
        pendingConfirmationTranscript = trimmedTranscript
        liveTranscriptText = trimmedTranscript
        print("🗣️ Companion holding transcript for confirmation: \(trimmedTranscript)")
    }

    // MARK: - Companion Prompt

    private static let companionVoiceResponseSystemPrompt = """
    you're clicky, a friendly always-on companion that lives in the user's menu bar. the user just spoke to you via push-to-talk and you can see their screen(s). your reply will be spoken aloud via text-to-speech, so write the way you'd actually talk. this is an ongoing conversation — you remember everything they've said before.

    rules:
    - reply in whatever language the user spoke to you in. if they spoke chinese, answer in chinese. if they spoke english, answer in english. follow them if they switch languages mid-conversation. this applies to the entire response, including anything outside the square brackets.
    - default to one or two sentences. be direct and dense. BUT if the user asks you to explain more, go deeper, or elaborate, then go all out — give a thorough, detailed explanation with no length limit.
    - casual, warm. no emojis.
    - write for the ear, not the eye. short sentences. no lists, bullet points, markdown, or formatting — just natural speech.
    - don't use abbreviations or symbols that sound weird read aloud. write "for example" not "e.g.", spell out small numbers.
    - if the user's question relates to what's on their screen, reference specific things you see.
    - if the screenshot doesn't seem relevant to their question, just answer the question directly.
    - you can help with anything — coding, writing, general knowledge, brainstorming.
    - never say "simply" or "just".
    - don't read out code verbatim. describe what the code does or what needs to change conversationally.
    - focus on giving a thorough, useful explanation. don't end with simple yes/no questions like "want me to explain more?" or "should i show you?" — those are dead ends that force the user to just say yes.
    - instead, when it fits naturally, end by planting a seed — mention something bigger or more ambitious they could try, a related concept that goes deeper, or a next-level technique that builds on what you just explained. make it something worth coming back for, not a question they'd just nod to. it's okay to not end with anything extra if the answer is complete on its own.
    - if you receive multiple screen images, the one labeled "primary focus" is where the cursor is — prioritize that one but reference others if relevant.

    element pointing:
    you have a small blue triangle cursor that can fly to and point at things on screen. use it whenever pointing would genuinely help the user — if they're asking how to do something, looking for a menu, trying to find a button, or need help navigating an app, point at the relevant element. err on the side of pointing rather than not pointing, because it makes your help way more useful and concrete.

    don't point at things when it would be pointless — like if the user asks a general knowledge question, or the conversation has nothing to do with what's on screen, or you'd just be pointing at something obvious they're already looking at. but if there's a specific UI element, menu, button, or area on screen that's relevant to what you're helping with, point at it.

    when you point, append a coordinate tag at the very end of your response, AFTER your spoken text.

    CRITICAL — coordinate space: express x and y as a normalized position on a 1000x1000 grid laid over the image, NOT as pixel values. 0 is the left edge and 1000 is the right edge for x; 0 is the top edge and 1000 is the bottom edge for y. so the exact center of any screen is (500,500), no matter how big the screen is. the pixel dimensions in the image labels tell you the screen's aspect ratio and where things sit relative to each other — they are NOT the scale to report coordinates in. a value above 1000 means you have made a mistake.

    format: [POINT:x,y:label] where x,y are integers from 0 to 1000 on that normalized grid, and label is a short 1-3 word description of the element (like "search bar" or "save button"). if the element is on the cursor's screen you can omit the screen number. if the element is on a DIFFERENT screen, append :screenN where N is the screen number from the image label (e.g. :screen2). this is important — without the screen number, the cursor will point at the wrong place.

    if pointing wouldn't help, append [POINT:none].

    examples:
    - user asks how to color grade in final cut: "you'll want to open the color inspector — it's right up in the top right area of the toolbar. click that and you'll get all the color wheels and curves. [POINT:860,50:color inspector]"
    - user asks what html is: "html stands for hypertext markup language, it's basically the skeleton of every web page. curious how it connects to the css you're looking at? [POINT:none]"
    - user asks how to commit in xcode: "see that source control menu up top? click that and hit commit, or you can use command option c as a shortcut. [POINT:220,15:source control]"
    - element is on screen 2 (not where cursor is): "that's over on your other monitor — see the terminal window? [POINT:310,360:terminal:screen2]"
    """

    // MARK: - AI Response Pipeline

    /// The system prompt for one reply: the fixed companion prompt above, plus the
    /// two pieces the user controls in 对话与记忆.
    ///
    /// The length line is appended as an explicit *override* rather than spliced
    /// into the base text. The base prompt already carries its own length rule
    /// ("default to one or two sentences… go all out if asked"), so a second,
    /// differently-worded instruction sitting wherever it happened to land would
    /// read as a contradiction the model has to arbitrate. Saying which one wins is
    /// what makes the setting do anything at all — and it is why the default value
    /// of the setting is the same one-or-two-sentences behaviour as before.
    private static func companionSystemPrompt(for settings: AppSettings) -> String {
        var systemPrompt = companionVoiceResponseSystemPrompt
        systemPrompt += "\n\nlength for this conversation — this overrides the length guidance above: \(settings.answerLengthStyle.promptSentence)"

        let extraInstructions = settings.extraSystemPromptInstructions
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !extraInstructions.isEmpty {
            systemPrompt += "\n\nthe user also asked for these, and they come first:\n\(extraInstructions)"
        }

        return systemPrompt
    }

    /// Captures a screenshot, sends it along with the transcript to the Bailian
    /// vision model, and plays the response aloud via Bailian TTS. The cursor
    /// stays in the spinner/processing state until TTS audio begins playing.
    /// The response may include a [POINT:x,y:label] tag which triggers the buddy
    /// to fly to that element on screen.
    private func sendTranscriptToVisionChatWithScreenshot(transcript: String) {
        currentResponseTask?.cancel()
        bailianTTSClient.stopPlayback()

        currentResponseTask = Task {
            // One snapshot for the whole interaction. Re-reading the settings
            // mid-reply would let a save land between the screenshot and the
            // request — or between chunk 1 and chunk 2 of the answer text — and
            // produce one reply built from two different configurations.
            let appSettings = AppSettingsStore.snapshot()

            // Stay in processing (spinner) state — no streaming text displayed
            voiceState = .processing
            clearAnswerBubble()

            do {
                // Capture all connected screens so the AI has full context
                let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG(
                    maximumDimension: appSettings.screenshotMaxDimension == 0
                        ? nil
                        : appSettings.screenshotMaxDimension,
                    compressionQuality: appSettings.screenshotCompressionQuality,
                    capturesAllDisplays: appSettings.capturesAllDisplays
                )

                guard !Task.isCancelled else { return }

                // Build image labels with the actual screenshot pixel dimensions
                // so the model's coordinate space matches the image it sees. We
                // scale from screenshot pixels to display points ourselves.
                let labeledImages = screenCaptures.map { capture in
                    let dimensionInfo = " (image dimensions: \(capture.screenshotWidthInPixels)x\(capture.screenshotHeightInPixels) pixels)"
                    return (data: capture.imageData, label: capture.label + dimensionInfo)
                }

                // Pass conversation history so the model remembers prior exchanges
                let historyForAPI = conversationHistory

                let showsResponseText = appSettings.showsResponseText

                let (fullResponseText, _) = try await visionChatAPI.analyzeImageStreaming(
                    images: labeledImages,
                    systemPrompt: Self.companionSystemPrompt(for: appSettings),
                    conversationHistory: historyForAPI,
                    conversationSummary: compressedHistorySummary,
                    userPrompt: transcript,
                    onTextChunk: { [weak self] accumulatedText in
                        // The vision client hands over the whole accumulated answer,
                        // not just the new piece. Assigning it (rather than appending)
                        // is what keeps the bubble from duplicating text, and it also
                        // means the [POINT:…] tag is visible while it streams and then
                        // disappears when the reply is parsed and read aloud.
                        // Delivered on the main actor, so no hop is needed here.
                        guard showsResponseText else { return }
                        self?.streamingAnswerText = accumulatedText
                    }
                )

                guard !Task.isCancelled else { return }

                // Parse the [POINT:...] tag from the model's response
                let parseResult = Self.parsePointingCoordinates(from: fullResponseText)
                let spokenText = parseResult.spokenText

                // Handle element pointing if the model returned coordinates.
                // Switch to idle BEFORE setting the location so the triangle
                // becomes visible and can fly to the target. Without this, the
                // spinner hides the triangle and the flight animation is invisible.
                //
                // Turning pointing off drops the coordinate rather than asking the
                // model not to produce one: the prompt still asks for the tag, so the
                // reply is unchanged and the setting is reversible mid-conversation.
                // Editing the prompt to remove the pointing section instead would
                // change the prefix of every request.
                let pointCoordinateToPointAt = appSettings.pointsAtReferencedElements
                    ? parseResult.coordinate
                    : nil

                if pointCoordinateToPointAt != nil {
                    voiceState = .idle
                }

                // Pick the screen capture matching the model's screen number,
                // falling back to the cursor screen if not specified.
                let targetScreenCapture: CompanionScreenCapture? = {
                    if let screenNumber = parseResult.screenNumber,
                       screenNumber >= 1 && screenNumber <= screenCaptures.count {
                        return screenCaptures[screenNumber - 1]
                    }
                    return screenCaptures.first(where: { $0.isCursorScreen })
                }()

                if let pointCoordinate = pointCoordinateToPointAt,
                   let targetScreenCapture {
                    // The model reports normalized 0-1000 coordinates, so convert
                    // to the screenshot's pixel space (top-left origin, e.g.
                    // 1280x831) first. Then scale to the display's point space
                    // (e.g. 1512x982), then convert to AppKit global coords.
                    let pointInScreenshotPixels = Self.screenshotPixelCoordinate(
                        fromNormalizedPoint: pointCoordinate,
                        screenshotWidthInPixels: targetScreenCapture.screenshotWidthInPixels,
                        screenshotHeightInPixels: targetScreenCapture.screenshotHeightInPixels
                    )

                    let screenshotWidth = CGFloat(targetScreenCapture.screenshotWidthInPixels)
                    let screenshotHeight = CGFloat(targetScreenCapture.screenshotHeightInPixels)
                    let displayWidth = CGFloat(targetScreenCapture.displayWidthInPoints)
                    let displayHeight = CGFloat(targetScreenCapture.displayHeightInPoints)
                    let displayFrame = targetScreenCapture.displayFrame

                    // Clamp to screenshot coordinate space
                    let clampedX = max(0, min(pointInScreenshotPixels.x, screenshotWidth))
                    let clampedY = max(0, min(pointInScreenshotPixels.y, screenshotHeight))

                    // Scale from screenshot pixels to display points
                    let displayLocalX = clampedX * (displayWidth / screenshotWidth)
                    let displayLocalY = clampedY * (displayHeight / screenshotHeight)

                    // Convert from top-left origin (screenshot) to bottom-left origin (AppKit)
                    let appKitY = displayHeight - displayLocalY

                    // Convert display-local coords to global screen coords
                    let globalLocation = CGPoint(
                        x: displayLocalX + displayFrame.origin.x,
                        y: appKitY + displayFrame.origin.y
                    )

                    detectedElementScreenLocation = globalLocation
                    detectedElementDisplayFrame = displayFrame
                    print("🎯 Element pointing: normalized (\(Int(pointCoordinate.x)), \(Int(pointCoordinate.y))) → pixel (\(Int(pointInScreenshotPixels.x)), \(Int(pointInScreenshotPixels.y))) → \"\(parseResult.elementLabel ?? "element")\"")
                } else {
                    print("🎯 Element pointing: \(parseResult.elementLabel ?? "no element")")
                }

                // Save this exchange to conversation history (with the point tag
                // stripped so it doesn't confuse future context) — and with the
                // screenshots it was answered against when the user asked for
                // history to carry them.
                let historyScreenshots: [ConversationHistoryScreenshot] = appSettings.includesScreenshotsInHistory
                    ? screenCaptures.map {
                        ConversationHistoryScreenshot(imageData: $0.imageData, label: $0.label)
                    }
                    : []

                conversationHistory.append(
                    ConversationHistoryEntry(
                        userTranscript: transcript,
                        assistantResponse: spokenText,
                        userScreenshots: historyScreenshots
                    )
                )

                trimConversationHistory(toRounds: appSettings.rememberedConversationRounds)
                persistConversationHistoryIfEnabled()

                print("🧠 Conversation history: \(conversationHistory.count) exchanges (limit \(appSettings.rememberedConversationRounds))")

                // Play the response via TTS. Keep the spinner (processing state)
                // until the audio actually starts playing, then switch to responding.
                if !spokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    // Swap the raw stream for what is actually about to be said.
                    // The stream still carries the [POINT:…] tag the user never
                    // hears, and the bubble now stays up for the whole reading, so
                    // that tag would otherwise sit on screen for seconds.
                    if showsResponseText {
                        streamingAnswerText = spokenText
                    }

                    do {
                        try await bailianTTSClient.speakText(spokenText)
                        // speakText returns after player.play() — audio is now playing
                        voiceState = .responding
                    } catch {
                        print("⚠️ Bailian TTS error: \(error)")
                        speakCreditsErrorFallback(failure: error)
                    }

                    // Scheduled outside the do/catch on purpose: a failed synthesis
                    // plays no audio at all, and the text that is already on screen
                    // is still worth the linger rather than vanishing the instant
                    // the request errors.
                    if showsResponseText {
                        scheduleAnswerBubbleClear(
                            lingerSeconds: appSettings.answerBubbleLingerSeconds
                        )
                    }
                }
            } catch is CancellationError {
                // User spoke again — response was interrupted
                clearAnswerBubble()
            } catch {
                print("⚠️ Companion response error: \(error)")
                clearAnswerBubble()
                speakCreditsErrorFallback(failure: error)
            }

            if !Task.isCancelled {
                voiceState = .idle
                scheduleTransientHideIfNeeded()
            }
        }
    }

    /// Empties the answer bubble right now, and cancels any clear that was still
    /// waiting to run.
    ///
    /// Every path that takes the bubble over goes through here rather than
    /// assigning `streamingAnswerText` directly, because a clear left pending
    /// from the previous answer would otherwise fire in the middle of the next
    /// one and take its opening words off the screen.
    private func clearAnswerBubble() {
        answerBubbleClearTask?.cancel()
        answerBubbleClearTask = nil
        streamingAnswerText = ""
    }

    /// Keeps the answer on screen until the voice reading it has stopped, then
    /// for `lingerSeconds` longer, then clears it.
    ///
    /// Deliberately waits on `bailianTTSClient.isPlaying` rather than on
    /// `speakText`, which returns the moment playback *starts*: clearing there
    /// showed the answer for the second or two the first chunk took to
    /// synthesize and then removed it at exactly the moment the user began
    /// listening. `isPlaying` also covers the gaps between chunks, so the text
    /// stays put for the whole reply rather than flickering between sentences.
    ///
    /// The linger is read at schedule time, not at fire time: it is part of one
    /// interaction, so a save landing mid-answer should apply to the next
    /// answer rather than silently extending the one on screen.
    private func scheduleAnswerBubbleClear(lingerSeconds: Double) {
        answerBubbleClearTask?.cancel()
        answerBubbleClearTask = Task { [weak self] in
            guard let self else { return }

            while self.bailianTTSClient.isPlaying {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            try? await Task.sleep(nanoseconds: UInt64(lingerSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }

            self.streamingAnswerText = ""
        }
    }

    /// In the two modes that hide the cursor when idle, waits for TTS playback,
    /// any pointing animation and the answer bubble to finish, then takes the
    /// companion off screen after the user's pause. Cancelled automatically if
    /// the user starts another push-to-talk interaction.
    ///
    /// The guard reads the presence mode, which is the fix for the whole feature:
    /// this used to test `!isClickyCursorEnabled`, a switch whose only UI was
    /// commented out and which was therefore always `true` — so this function
    /// returned on its first line every time it was ever called, and the fade-out
    /// never happened at all.
    private func scheduleTransientHideIfNeeded() {
        guard cursorPresenceMode.hidesWhenIdle && isOverlayVisible else { return }

        // Read the delay at schedule time, not at fire time: the pause is part of
        // one interaction, and a save landing mid-pause should apply to the next
        // interaction rather than silently extending or cutting this one short.
        let hideDelaySeconds = AppSettingsStore.snapshot().transientCursorHideDelaySeconds

        transientHideTask?.cancel()
        transientHideTask = Task {
            // Wait for TTS audio to finish playing
            while bailianTTSClient.isPlaying {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Wait for pointing animation to finish (location is cleared
            // when the buddy flies back to the cursor)
            while detectedElementScreenLocation != nil {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Wait for the answer bubble to go. It outlives the voice by the
            // user's chosen linger, and the bubble is drawn *by* the cursor, so
            // fading out while it is still up would take the text away with it.
            // Empty whenever 「回答时显示文字」 is off, which is why the TTS wait
            // above is still needed.
            while !streamingAnswerText.isEmpty {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Pause after everything finishes, then take the companion off screen.
            // The overlay windows stay up — only the companion they draw goes.
            try? await Task.sleep(nanoseconds: UInt64(hideDelaySeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            isBuddyShown = false
        }
    }

    /// Speaks a short apology when the response pipeline fails — the API call or
    /// the TTS request errored, so there is no generated audio to play.
    /// Uses NSSpeechSynthesizer so it still works when the model provider is
    /// unreachable, which is exactly the case this exists to cover.
    ///
    /// `failure` is also recorded in `lastErrorMessage` for the panel to display.
    /// The spoken apology is the same sentence for every kind of failure, so the
    /// audio alone cannot tell the user what went wrong: an exhausted free quota
    /// (403 `AllocationQuota.FreeTierOnly`) and a model that cannot read images
    /// both come out as "抱歉，我这边出了点问题". Keeping the provider's own wording
    /// on screen is what makes those two distinguishable.
    private func speakCreditsErrorFallback(failure: Error) {
        lastErrorMessage = failure.localizedDescription
        print("⚠️ Companion fallback — speaking apology. Reason: \(failure.localizedDescription)")

        let utterance = "抱歉，我这边出了点问题，刚才没能答上来。再试一次好吗？"
        let synthesizer = NSSpeechSynthesizer()
        synthesizer.startSpeaking(utterance)
        voiceState = .responding
    }

    // MARK: - Conversation Memory

    /// Brings the history back down to the user's round limit.
    ///
    /// Zero is a valid choice and means no memory at all — everything is dropped
    /// after each answer, which is how someone turns the feature off without
    /// touching the rest of the pipeline.
    ///
    /// With 「历史自动压缩」 on, the exchanges that fall outside the limit are folded
    /// into the running summary instead of being discarded, so a long conversation
    /// keeps its gist. The folding happens in the background: it costs a model
    /// request, and making the answer wait on a summary of something the user
    /// already heard would be spending their time to save their tokens.
    private func trimConversationHistory(toRounds rememberedConversationRounds: Int) {
        guard conversationHistory.count > rememberedConversationRounds else { return }

        let agedOutEntries = conversationHistory.prefix(
            conversationHistory.count - rememberedConversationRounds
        )
        conversationHistory.removeFirst(agedOutEntries.count)

        guard AppSettingsStore.snapshot().autoCompressesHistory,
              !agedOutEntries.isEmpty,
              historyCompressionTask == nil else { return }

        let entriesToCompress = Array(agedOutEntries)
        let summarySoFar = compressedHistorySummary

        historyCompressionTask = Task { [weak self] in
            defer { self?.historyCompressionTask = nil }

            guard let self else { return }
            guard let foldedSummary = try? await self.summarizeExchanges(
                entriesToCompress,
                previousSummary: summarySoFar
            ) else {
                // The exchanges are already gone from the window. A failed summary
                // means they are simply forgotten, which is the behaviour the
                // setting has when it is off — worth a log line, not an alert.
                print("⚠️ Clicky: could not compress aged-out conversation; those turns are dropped")
                return
            }

            self.compressedHistorySummary = foldedSummary
            self.persistConversationHistoryIfEnabled()
            print("💬 Clicky: compressed \(entriesToCompress.count) aged-out exchanges into the conversation summary")
        }
    }

    /// Folds `entries` into `previousSummary` with one text-only model request.
    ///
    /// Deliberately sends no image: this is a writing task about what was said, and
    /// attaching the screenshots again would put the largest part of the payload on
    /// a request that cannot use it.
    private func summarizeExchanges(
        _ entries: [ConversationHistoryEntry],
        previousSummary: String
    ) async throws -> String {
        let transcriptOfAgedOutExchanges = entries
            .map { "user: \($0.userTranscript)\nassistant: \($0.assistantResponse)" }
            .joined(separator: "\n\n")

        var summarizationRequest = "summarize this conversation so it can be remembered in a few lines.\n"
        if !previousSummary.isEmpty {
            summarizationRequest += "\nyou already have this summary of even earlier turns:\n\(previousSummary)\n"
            summarizationRequest += "\nfold the new turns into it and return one combined summary.\n"
        }
        summarizationRequest += "\nkeep what the user asked about, what they were told, and anything they said about themselves or their work. drop pleasantries. write it as plain notes, not prose, in the language the conversation was in.\n\n"
        summarizationRequest += transcriptOfAgedOutExchanges

        let (summaryText, _) = try await visionChatAPI.analyzeImageStreaming(
            images: [],
            systemPrompt: "you compress conversations into short notes that another assistant will read to keep helping the user. reply with the notes only.",
            userPrompt: summarizationRequest,
            onTextChunk: { _ in }
        )

        return summaryText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Writes the conversation to disk — but only when the user asked for it.
    private func persistConversationHistoryIfEnabled() {
        guard AppSettingsStore.snapshot().persistsConversationHistory else { return }
        persistConversationHistory()
    }

    /// Writes the conversation to disk unconditionally, for the callers that have
    /// already established that persistence is on.
    private func persistConversationHistory() {
        do {
            try ConversationHistoryStore.save(
                StoredConversationHistory(
                    summary: compressedHistorySummary,
                    entries: conversationHistory
                )
            )
        } catch {
            // A failed write costs the user their memory of this conversation
            // across restarts and nothing else — the answer they are waiting for
            // is unaffected, so this is a log line rather than a spoken error.
            print("⚠️ Clicky: could not save conversation history: \(error.localizedDescription)")
        }
    }

    /// Forgets the conversation, in memory and on disk.
    func clearConversationMemory() {
        ConversationHistoryStore.clear()
    }

    // MARK: - Point Tag Parsing

    /// Result of parsing a [POINT:...] tag from the model's response.
    struct PointingParseResult {
        /// The response text with the [POINT:...] tag removed — this is what gets spoken.
        let spokenText: String
        /// The parsed coordinate on the model's normalized 0-1000 grid, or nil if
        /// the model said "none" or no tag was found. Use
        /// `screenshotPixelCoordinate(fromNormalizedPoint:...)` to turn it into a
        /// screenshot pixel position.
        let coordinate: CGPoint?
        /// Short label describing the element (e.g. "run button"), or "none".
        let elementLabel: String?
        /// Which screen the coordinate refers to (1-based), or nil to default to cursor screen.
        let screenNumber: Int?
    }

    /// Converts a coordinate from the model's normalized 0-1000 grid into a pixel
    /// position within the screenshot it was shown.
    ///
    /// Qwen's vision models rescale images internally before looking at them, so
    /// they report positions on a 1000x1000 grid rather than in the screenshot's
    /// own pixels. Alibaba's GUI automation guide documents this and maps back with
    /// `coordinate / 1000 * imageDimension`. Skipping this step made the cursor
    /// point at roughly 78% of the intended distance, because the raw normalized
    /// value looks like a plausible pixel coordinate and fails silently.
    static func screenshotPixelCoordinate(
        fromNormalizedPoint normalizedPoint: CGPoint,
        screenshotWidthInPixels: Int,
        screenshotHeightInPixels: Int
    ) -> CGPoint {
        CGPoint(
            x: normalizedPoint.x / 1000.0 * CGFloat(screenshotWidthInPixels),
            y: normalizedPoint.y / 1000.0 * CGFloat(screenshotHeightInPixels)
        )
    }

    /// Parses a [POINT:x,y:label:screenN] or [POINT:none] tag from the end of the model's response.
    /// Returns the spoken text (tag removed) and the optional coordinate + label + screen number.
    static func parsePointingCoordinates(from responseText: String) -> PointingParseResult {
        // Match [POINT:none] or [POINT:123,456:label] or [POINT:123,456:label:screen2]
        let pattern = #"\[POINT:(?:none|(\d+)\s*,\s*(\d+)(?::([^\]:\s][^\]:]*?))?(?::screen(\d+))?)\]\s*$"#

        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: responseText, range: NSRange(responseText.startIndex..., in: responseText)) else {
            // No tag found at all
            return PointingParseResult(spokenText: responseText, coordinate: nil, elementLabel: nil, screenNumber: nil)
        }

        // Remove the tag from the spoken text
        let tagRange = Range(match.range, in: responseText)!
        let spokenText = String(responseText[..<tagRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)

        // Check if it's [POINT:none]
        guard match.numberOfRanges >= 3,
              let xRange = Range(match.range(at: 1), in: responseText),
              let yRange = Range(match.range(at: 2), in: responseText),
              let x = Double(responseText[xRange]),
              let y = Double(responseText[yRange]) else {
            return PointingParseResult(spokenText: spokenText, coordinate: nil, elementLabel: "none", screenNumber: nil)
        }

        var elementLabel: String? = nil
        if match.numberOfRanges >= 4, let labelRange = Range(match.range(at: 3), in: responseText) {
            elementLabel = String(responseText[labelRange]).trimmingCharacters(in: .whitespaces)
        }

        var screenNumber: Int? = nil
        if match.numberOfRanges >= 5, let screenRange = Range(match.range(at: 4), in: responseText) {
            screenNumber = Int(responseText[screenRange])
        }

        return PointingParseResult(
            spokenText: spokenText,
            coordinate: CGPoint(x: x, y: y),
            elementLabel: elementLabel,
            screenNumber: screenNumber
        )
    }

    // MARK: - Onboarding Video

    /// Sets up the onboarding video player, starts playback, and schedules
    /// the demo interaction at 40s. Called by BlueCursorView when onboarding starts.
    func setupOnboardingVideo() {
        guard let videoURL = URL(string: "https://stream.mux.com/e5jB8UuSrtFABVnTHCR7k3sIsmcUHCyhtLu1tzqLlfs.m3u8") else { return }

        let player = AVPlayer(url: videoURL)
        player.isMuted = false
        player.volume = 0.0
        self.onboardingVideoPlayer = player
        self.showOnboardingVideo = true
        self.onboardingVideoOpacity = 0.0

        // Start playback immediately — the video plays while invisible,
        // then we fade in both the visual and audio over 1s.
        player.play()

        // Wait for SwiftUI to mount the view, then set opacity to 1.
        // The .animation modifier on the view handles the actual animation.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.onboardingVideoOpacity = 1.0
            // Fade audio volume from 0 → 1 over 2s to match visual fade
            self.fadeInVideoAudio(player: player, targetVolume: 1.0, duration: 2.0)
        }

        // At 40 seconds into the video, trigger the onboarding demo where
        // Clicky flies to something interesting on screen and comments on it
        let demoTriggerTime = CMTime(seconds: 40, preferredTimescale: 600)
        onboardingDemoTimeObserver = player.addBoundaryTimeObserver(
            forTimes: [NSValue(time: demoTriggerTime)],
            queue: .main
        ) { [weak self] in
            self?.performOnboardingDemoInteraction()
        }

        // Fade out and clean up when the video finishes
        onboardingVideoEndObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.onboardingVideoOpacity = 0.0
            // Wait for the 2s fade-out animation to complete before tearing down
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                self.tearDownOnboardingVideo()
                // After the video disappears, stream in the prompt to try talking
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    self.startOnboardingPromptStream()
                }
            }
        }
    }

    func tearDownOnboardingVideo() {
        showOnboardingVideo = false
        if let timeObserver = onboardingDemoTimeObserver {
            onboardingVideoPlayer?.removeTimeObserver(timeObserver)
            onboardingDemoTimeObserver = nil
        }
        onboardingVideoPlayer?.pause()
        onboardingVideoPlayer = nil
        if let observer = onboardingVideoEndObserver {
            NotificationCenter.default.removeObserver(observer)
            onboardingVideoEndObserver = nil
        }
    }

    private func startOnboardingPromptStream() {
        let message = "press control + option and introduce yourself"
        onboardingPromptText = ""
        showOnboardingPrompt = true
        onboardingPromptOpacity = 0.0

        withAnimation(.easeIn(duration: 0.4)) {
            onboardingPromptOpacity = 1.0
        }

        var currentIndex = 0
        Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { timer in
            guard currentIndex < message.count else {
                timer.invalidate()
                // Auto-dismiss after 10 seconds
                DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) {
                    guard self.showOnboardingPrompt else { return }
                    withAnimation(.easeOut(duration: 0.3)) {
                        self.onboardingPromptOpacity = 0.0
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        self.showOnboardingPrompt = false
                        self.onboardingPromptText = ""
                    }
                }
                return
            }
            let index = message.index(message.startIndex, offsetBy: currentIndex)
            self.onboardingPromptText.append(message[index])
            currentIndex += 1
        }
    }

    /// Gradually raises an AVPlayer's volume from its current level to the
    /// target over the specified duration, creating a smooth audio fade-in.
    private func fadeInVideoAudio(player: AVPlayer, targetVolume: Float, duration: Double) {
        let steps = 20
        let stepInterval = duration / Double(steps)
        let volumeIncrement = (targetVolume - player.volume) / Float(steps)
        var stepsRemaining = steps

        Timer.scheduledTimer(withTimeInterval: stepInterval, repeats: true) { timer in
            stepsRemaining -= 1
            player.volume += volumeIncrement

            if stepsRemaining <= 0 {
                timer.invalidate()
                player.volume = targetVolume
            }
        }
    }

    // MARK: - Onboarding Demo Interaction

    private static let onboardingDemoSystemPrompt = """
    you're clicky, a small blue cursor buddy living on the user's screen. you're showing off during onboarding — look at their screen and find ONE specific, concrete thing to point at. pick something with a clear name or identity: a specific app icon (say its name), a specific word or phrase of text you can read, a specific filename, a specific button label, a specific tab title, a specific image you can describe. do NOT point at vague things like "a window" or "some text" — be specific about exactly what you see.

    make a short quirky observation about the specific thing you picked — something fun, playful, or curious that shows you actually read/recognized it. no emojis ever. NEVER quote or repeat text you see on screen — just react to it. keep it short, no exceptions.

    CRITICAL COORDINATE RULE: you MUST only pick elements near the CENTER of the screen. your x coordinate must be between 20%-80% of the image width. your y coordinate must be between 20%-80% of the image height. do NOT pick anything in the top 20%, bottom 20%, left 20%, or right 20% of the screen. no menu bar items, no dock icons, no sidebar items, no items near any edge. only things clearly in the middle area of the screen. if the only interesting things are near the edges, pick something boring in the center instead.

    respond with ONLY your short comment followed by the coordinate tag. nothing else.

    write the comment in chinese. this demo bubble is a stand-in for a real reply, and the companion speaks its replies aloud in whatever language the user spoke — for this user that's chinese, so showing chinese here keeps the demo consistent with what the companion actually sounds like.

    format: your comment [POINT:x,y:label]

    the screenshot images are labeled with their pixel dimensions. use those dimensions as the coordinate space. origin (0,0) is top-left. x increases rightward, y increases downward.
    """

    /// Captures a screenshot and asks the model to find something interesting to
    /// point at, then triggers the buddy's flight animation. Used during
    /// onboarding to demo the pointing feature while the intro video plays.
    func performOnboardingDemoInteraction() {
        // Don't interrupt an active voice response
        guard voiceState == .idle || voiceState == .responding else { return }

        Task {
            do {
                let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()

                // Only send the cursor screen so the model can't pick something
                // on a different monitor that we can't point at.
                guard let cursorScreenCapture = screenCaptures.first(where: { $0.isCursorScreen }) else {
                    print("🎯 Onboarding demo: no cursor screen found")
                    return
                }

                let dimensionInfo = " (image dimensions: \(cursorScreenCapture.screenshotWidthInPixels)x\(cursorScreenCapture.screenshotHeightInPixels) pixels)"
                let labeledImages = [(data: cursorScreenCapture.imageData, label: cursorScreenCapture.label + dimensionInfo)]

                let (fullResponseText, _) = try await visionChatAPI.analyzeImageStreaming(
                    images: labeledImages,
                    systemPrompt: Self.onboardingDemoSystemPrompt,
                    userPrompt: "look around my screen and find something interesting to point at",
                    onTextChunk: { _ in }
                )

                let parseResult = Self.parsePointingCoordinates(from: fullResponseText)

                guard let pointCoordinate = parseResult.coordinate else {
                    print("🎯 Onboarding demo: no element to point at")
                    return
                }

                // The model reports normalized 0-1000 coordinates — convert to
                // screenshot pixels before scaling to display points.
                let pointInScreenshotPixels = Self.screenshotPixelCoordinate(
                    fromNormalizedPoint: pointCoordinate,
                    screenshotWidthInPixels: cursorScreenCapture.screenshotWidthInPixels,
                    screenshotHeightInPixels: cursorScreenCapture.screenshotHeightInPixels
                )

                let screenshotWidth = CGFloat(cursorScreenCapture.screenshotWidthInPixels)
                let screenshotHeight = CGFloat(cursorScreenCapture.screenshotHeightInPixels)
                let displayWidth = CGFloat(cursorScreenCapture.displayWidthInPoints)
                let displayHeight = CGFloat(cursorScreenCapture.displayHeightInPoints)
                let displayFrame = cursorScreenCapture.displayFrame

                let clampedX = max(0, min(pointInScreenshotPixels.x, screenshotWidth))
                let clampedY = max(0, min(pointInScreenshotPixels.y, screenshotHeight))
                let displayLocalX = clampedX * (displayWidth / screenshotWidth)
                let displayLocalY = clampedY * (displayHeight / screenshotHeight)
                let appKitY = displayHeight - displayLocalY
                let globalLocation = CGPoint(
                    x: displayLocalX + displayFrame.origin.x,
                    y: appKitY + displayFrame.origin.y
                )

                // Set custom bubble text so the pointing animation uses the model's
                // comment instead of a random phrase
                detectedElementBubbleText = parseResult.spokenText
                detectedElementScreenLocation = globalLocation
                detectedElementDisplayFrame = displayFrame
                print("🎯 Onboarding demo: pointing at \"\(parseResult.elementLabel ?? "element")\" — \"\(parseResult.spokenText)\"")
            } catch {
                print("⚠️ Onboarding demo error: \(error)")
            }
        }
    }
}
