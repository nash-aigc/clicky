import AVFoundation

/// One-shot UI sound effects — the chime set ported from HeyClicky's own
/// resources. Raw values are the bundle resource filenames (without extension).
///
/// Playback design copied from HeyClicky's recovered `ClickyChimeWarmer`
/// behaviour: every chime gets its own long-lived `AVAudioPlayer` created on
/// first use and kept alive, so replaying is just `currentTime = 0; play()` —
/// no per-play allocation, no risk of a player being deallocated mid-sound.
/// Players are built lazily on the first `play()` rather than at app launch
/// so a cold start does no audio work at all.
@MainActor
final class SoundEffectPlayer {
    static let shared = SoundEffectPlayer()

    /// Fixed playback volume for every chime. Kept well below full scale so a
    /// chime never shouts over a spoken answer; the two overlap by design
    /// (HeyClicky behaves the same way) and the chimes are all under a second.
    private static let fixedPlaybackVolume: Float = 0.5

    enum SoundEffect: String, CaseIterable {
        /// Recording started — the user pressed the talk shortcut.
        case listeningStarted = "clicky-text-open"
        /// Transcript sent — the talk shortcut was released.
        case transcriptSent = "clicky-text-send"
        /// The model's answer started arriving.
        case answerStarted = "clicky-text-receive"
        /// Something failed — the companion says so out loud too.
        case errorSurprised = "clicky-surprised"
        /// The notch sheet expanded.
        case notchRevealed = "home-reveal"
        /// One-shot boot chime for the notch presence itself.
        case notchBoot = "reveal-boot"
        /// The answer finished playing.
        case answerFinished = "agent-done"
        /// A question needs the user's attention.
        case attentionNeeded = "agent-needs-you"

        /// 语音会话挂断（用户主动）：刘海右翼的挂断图标、语音聊天页的挂断按钮、
        /// 以及再次按下连接快捷键 —— 全部走 `disconnectCurrentSession` 这一个漏斗。
        case sessionHungUp = "session-hangup"
    }

    private var playersByEffect: [SoundEffect: AVAudioPlayer] = [:]
    private var warmedUp = false

    /// Pre-build every player once. Called lazily from `play` so the first
    /// chime pays the (small) setup cost and every later one is instant.
    private func warmUpIfNeeded() {
        guard !warmedUp else { return }
        warmedUp = true
        for effect in SoundEffect.allCases {
            guard let url = Bundle.main.url(forResource: effect.rawValue, withExtension: "wav") else {
                // A missing resource must never break a state transition — the
                // chime is decoration, not information.
                continue
            }
            let player = try? AVAudioPlayer(contentsOf: url)
            player?.prepareToPlay()
            player?.volume = Self.fixedPlaybackVolume
            playersByEffect[effect] = player
        }
    }

    /// Plays one chime from the start. Silent no-op when the settings gate is
    /// off or the resource is missing — callers never need to check either.
    func play(_ effect: SoundEffect) {
        guard AppSettingsStore.snapshot().playsNotchSoundEffects else { return }
        warmUpIfNeeded()
        guard let player = playersByEffect[effect] else { return }
        player.currentTime = 0
        player.play()
    }
}
