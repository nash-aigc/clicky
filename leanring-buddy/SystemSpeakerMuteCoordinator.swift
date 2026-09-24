//
//  SystemSpeakerMuteCoordinator.swift
//  leanring-buddy
//
//  「录制期间自动静音系统扬声器」— mutes the system's default output device
//  while the microphone is recording and nothing is being played back, and
//  restores it exactly afterwards.
//
//  Two jobs, both born 2026-09-23:
//
//  1. THE SILENCE BETWEEN REPLIES. The app's echo defence while an answer is
//     actually being read aloud is Apple's voice processing on the shared
//     playback engine (VoicePlaybackEngine's header) — that is what cancels
//     Clicky's own voice out of the microphone. But voice processing is only
//     wanted while this engine carries a microphone tap, and it costs macOS
//     ducking every other application's audio while it runs. So the other half
//     of the job is here: while the microphone is open and NOTHING is playing,
//     the speakers are simply muted at the CoreAudio level, and silenced
//     speakers cannot reach the microphone at all. Between the two, every
//     window is covered and the ducking is only paid while an answer plays.
//
//  2. THE USER'S OWN REQUEST. While listening (recording), system audio —
//     music, video, other apps' speech — must not be captured into the
//     transcript. Muting the speakers at the CoreAudio level does that for
//     every application at once.
//
//  The mute NEVER covers the app's own spoken answers: `playbackActiveProvider`
//  reports TTS playback, and the desired state is
//  `setting && recording && !playback` — during a reply the speakers come
//  back up so the user hears it. That unmuted playback window is why the AEC
//  is load-bearing there, and why the content-gated barge-in defences in
//  BuddyDictationManager stay in force underneath it.
//
//  Restore discipline: before muting a device its prior mute state is
//  captured, and only a device we actually muted is un-muted (a speaker the
//  USER had muted stays muted). Restore happens when recording ends, on
//  application termination, and — via a UserDefaults leak flag — at the next
//  launch if a crash left the speakers muted.
//

import AudioToolbox
import CoreAudio
import Foundation

// MARK: - CoreAudio mute primitives

/// Raw mute read/write on one audio device. `nonisolated` because these are
/// stateless C-API wrappers; the coordinator serializes all use on the main
/// actor.
private nonisolated enum SystemOutputDeviceMuteController {

    /// Reads the default output device's id. nil when there is none (no
    /// output configured, or CoreAudio refused).
    static func defaultOutputDeviceID() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress, 0, nil, &dataSize, &deviceID)
        guard status == noErr, deviceID != 0, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    /// The property element that carries this device's mute control. Most
    /// output devices expose it on the main element; a few put it on stream
    /// element 1, so both are probed for an existing property.
    static func workingMuteElement(forDeviceID deviceID: AudioDeviceID) -> AudioObjectPropertyElement? {
        let candidateElements: [AudioObjectPropertyElement] = [
            kAudioObjectPropertyElementMain,
            AudioObjectPropertyElement(1)
        ]
        for candidateElement in candidateElements {
            var propertyAddress = mutePropertyAddress(element: candidateElement)
            var dataSize = UInt32(0)
            let status = AudioObjectGetPropertyDataSize(deviceID, &propertyAddress, 0, nil, &dataSize)
            guard status == noErr, dataSize > 0 else { continue }
            return candidateElement
        }
        return nil
    }

    static func isMuted(deviceID: AudioDeviceID, element: AudioObjectPropertyElement) -> Bool {
        var muteValue: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        var propertyAddress = mutePropertyAddress(element: element)
        let status = AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &dataSize, &muteValue)
        guard status == noErr else { return false }
        return muteValue != 0
    }

    @discardableResult
    static func setMuted(_ muted: Bool, deviceID: AudioDeviceID, element: AudioObjectPropertyElement) -> Bool {
        var muteValue: UInt32 = muted ? 1 : 0
        let dataSize = UInt32(MemoryLayout<UInt32>.size)
        var propertyAddress = mutePropertyAddress(element: element)
        let status = AudioObjectSetPropertyData(deviceID, &propertyAddress, 0, nil, dataSize, &muteValue)
        return status == noErr
    }

    private static func mutePropertyAddress(element: AudioObjectPropertyElement) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element)
    }
}

// MARK: - The coordinator

@MainActor
final class SystemSpeakerMuteCoordinator {

    /// Whether a recording session (push-to-talk or continuous listening) is
    /// open right now. Injected by CompanionManager, which owns the dictation
    /// manager.
    private let recordingActiveProvider: () -> Bool

    /// Whether the app is reading an answer aloud right now — the speakers
    /// must be UP during playback so the user hears the reply.
    private let playbackActiveProvider: () -> Bool

    /// The poll loop. A poll (rather than property listeners) keeps the mute
    /// state converging to the desired value whatever the transitions of the
    /// two input signals are.
    private var mutePollTask: Task<Void, Never>?

    /// Devices this coordinator muted and their captured prior mute state,
    /// keyed by device id. The default output device can change while the mic
    /// is open (user plugs in headphones), so an entry is kept per device we
    /// touched until its restore runs.
    private var mutedDevicesPriorState: [AudioDeviceID: (element: AudioObjectPropertyElement, wasMutedBefore: Bool)] = [:]

    private static let pollIntervalNanoseconds: UInt64 = 500_000_000
    private static let leakedMuteFlagKey = "clickySystemSpeakersLeftMutedByRecordingMute"

    init(
        recordingActiveProvider: @escaping () -> Bool,
        playbackActiveProvider: @escaping () -> Bool
    ) {
        self.recordingActiveProvider = recordingActiveProvider
        self.playbackActiveProvider = playbackActiveProvider

        restoreMutesLeakedByAPreviousRun()
        startMutePollLoop()
    }

    /// Synchronous restore for application termination — the poll loop cannot
    /// be trusted to fire one last time during shutdown.
    func restoreAllMutesNow() {
        // Deliberately synchronous: this is the termination path, and there the
        // blocking is the requirement — the restore has to finish before the
        // process goes away, which an async hop cannot promise.
        guard !mutedDevicesPriorState.isEmpty else { return }
        _ = Self.restoreMutes(mutedDevicesPriorState)
        mutedDevicesPriorState.removeAll()
        UserDefaults.standard.set(false, forKey: Self.leakedMuteFlagKey)
    }

    // MARK: - Poll loop

    private func startMutePollLoop() {
        mutePollTask?.cancel()
        mutePollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.convergeMuteStateOnce()
                try? await Task.sleep(nanoseconds: Self.pollIntervalNanoseconds)
            }
        }
    }

    /// One convergence step: compute the desired mute state from the setting
    /// and the two live signals, and bring the default output device there.
    private func convergeMuteStateOnce() async {
        let recordingMuteSettingEnabled = AppSettingsStore.snapshot().mutesSystemSpeakersDuringRecording
        let isRecordingActive = recordingActiveProvider()
        let isTTSPlaybackActive = playbackActiveProvider()
        let desiredMute = recordingMuteSettingEnabled && isRecordingActive && !isTTSPlaybackActive

        let currentDeviceID = await Self.offMainActor {
            SystemOutputDeviceMuteController.defaultOutputDeviceID()
        }
        guard let currentDeviceID else {
            // No output device to mute; still drop any stale entries so a
            // device that disappeared mid-recording does not leak state.
            if !mutedDevicesPriorState.isEmpty {
                await restoreAllMutedDevices()
            }
            return
        }

        if desiredMute {
            await muteDeviceIfNeeded(deviceID: currentDeviceID)
        } else {
            await restoreAllMutedDevices()
        }
    }

    /// Runs a synchronous CoreAudio call away from the main actor.
    ///
    /// The HAL is a synchronous IPC to coreaudiod, and a WRITE to it can block
    /// for hundreds of milliseconds while the device underneath is being
    /// reconfigured — which is exactly what is happening when this fires, because
    /// the push-to-talk engine is starting on the same device at that moment.
    /// Measured 2026-09-24 from the app's own marks: stalls of 80 / 82 / 118 /
    /// 234 ms of main thread, every one landing beside 「system speakers MUTED for
    /// recording」, and a 1920 ms one on another run. The 0.5 s poll decides
    /// where in the cycle that lands, so it sometimes falls inside the notch
    /// wings' 380 ms slide — which is the 「listening 展开时卡一下」 the user
    /// reports, and why it is not every single time.
    nonisolated private static func offMainActor<T: Sendable>(
        _ work: @escaping @Sendable () -> T
    ) async -> T {
        await Task.detached(priority: .userInitiated) { work() }.value
    }

    /// Mutes `deviceID` for the recording, capturing its prior mute state
    /// first — unless it is already muted by us. A device the user muted
    /// themselves is left as-is and simply recorded.
    private func muteDeviceIfNeeded(deviceID: AudioDeviceID) async {
        guard mutedDevicesPriorState[deviceID] == nil else { return }

        let muteElement = await Self.offMainActor {
            SystemOutputDeviceMuteController.workingMuteElement(forDeviceID: deviceID)
        }
        guard let muteElement else {
            print("🔇 SystemSpeakerMuteCoordinator: output device \(deviceID) exposes no mute control — cannot mute for recording")
            return
        }

        let wasMutedBefore = await Self.offMainActor {
            SystemOutputDeviceMuteController.isMuted(deviceID: deviceID, element: muteElement)
        }
        if !wasMutedBefore {
            // THE blocking call. The stall that has to be seen to be believed is
            // this one, and it is the reason this whole method is async.
            let didMute = await Self.offMainActor {
                SystemOutputDeviceMuteController.setMuted(true, deviceID: deviceID, element: muteElement)
            }
            guard didMute else {
                print("🔇 SystemSpeakerMuteCoordinator: muting output device \(deviceID) failed (CoreAudio set rejected)")
                return
            }
            print("🔇 SystemSpeakerMuteCoordinator: system speakers MUTED for recording (was unmuted before)")
        } else {
            print("🔇 SystemSpeakerMuteCoordinator: system speakers were already muted before recording — recording proceeds, nothing to change")
        }

        mutedDevicesPriorState[deviceID] = (element: muteElement, wasMutedBefore: wasMutedBefore)
        UserDefaults.standard.set(true, forKey: Self.leakedMuteFlagKey)
    }

    /// Un-mutes the devices this coordinator muted, off the main actor.
    ///
    /// `nonisolated static` so the same loop serves both callers: the poll path
    /// runs it detached, and termination runs it inline — there the blocking IS
    /// the requirement, because the restore has to finish before the process
    /// goes away. Returns the devices whose restore failed, so the caller can
    /// leave the leak flag set for the next launch to retry.
    nonisolated private static func restoreMutes(
        _ priorStates: [AudioDeviceID: (element: AudioObjectPropertyElement, wasMutedBefore: Bool)]
    ) -> [AudioDeviceID] {
        var failedDeviceIDs: [AudioDeviceID] = []
        for (deviceID, priorState) in priorStates where !priorState.wasMutedBefore {
            let restoreSucceeded = SystemOutputDeviceMuteController.setMuted(
                false, deviceID: deviceID, element: priorState.element
            )
            if !restoreSucceeded {
                failedDeviceIDs.append(deviceID)
            }
        }
        return failedDeviceIDs
    }

    /// Restores every device this coordinator muted to its captured prior
    /// state. A speaker the user had muted themselves stays muted.
    private func restoreAllMutedDevices() async {
        guard !mutedDevicesPriorState.isEmpty else { return }

        let priorStatesToRestore = mutedDevicesPriorState
        let failedDeviceIDs = await Self.offMainActor { Self.restoreMutes(priorStatesToRestore) }

        guard failedDeviceIDs.isEmpty else {
            // Keep the state and the leak flag so the next launch retries — the
            // same contract the per-device loop had.
            print("⚠️ SystemSpeakerMuteCoordinator: restoring output device(s) \(failedDeviceIDs) failed — will retry at next launch")
            return
        }

        print("🔊 SystemSpeakerMuteCoordinator: system speakers RESTORED after recording")
        mutedDevicesPriorState.removeAll()
        UserDefaults.standard.set(false, forKey: Self.leakedMuteFlagKey)
    }

    // MARK: - Crash-leak recovery

    /// A crash (or a force-quit) between a mute and its restore leaves the
    /// system speakers muted with nobody to lift it. The leak flag survives
    /// that: if it is set at launch, the default output device is un-muted
    /// before anything else happens. A speaker the user muted THEMSELVES in
    /// that crash window is un-muted too — one false positive per crash is
    /// far cheaper than a permanently silent machine.
    private func restoreMutesLeakedByAPreviousRun() {
        guard UserDefaults.standard.bool(forKey: Self.leakedMuteFlagKey) else { return }

        if let deviceID = SystemOutputDeviceMuteController.defaultOutputDeviceID(),
           let muteElement = SystemOutputDeviceMuteController.workingMuteElement(forDeviceID: deviceID),
           SystemOutputDeviceMuteController.isMuted(deviceID: deviceID, element: muteElement) {
            let restoreSucceeded = SystemOutputDeviceMuteController.setMuted(false, deviceID: deviceID, element: muteElement)
            print(restoreSucceeded
                ? "🔊 SystemSpeakerMuteCoordinator: recovered speakers left muted by a previous run"
                : "⚠️ SystemSpeakerMuteCoordinator: could not recover the leaked mute (CoreAudio set rejected)")
        }

        UserDefaults.standard.set(false, forKey: Self.leakedMuteFlagKey)
    }
}
