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
        /// The notch sheet expanded —— 用户 2026-09-25 指定**苹果官方音效 08（导航推入）**：
        /// 「点击刘海时，音效08（导航推入）」。
        case notchRevealed = "ui-navigation-push"
        /// One-shot boot chime for the notch presence itself.
        case notchBoot = "reveal-boot"
        /// The answer finished playing.
        case answerFinished = "agent-done"
        /// A question needs the user's attention.
        case attentionNeeded = "agent-needs-you"

        /// 语音会话挂断（用户主动）：刘海右翼的挂断图标、语音聊天页的挂断按钮、
        /// 以及再次按下连接快捷键 —— 全部走 `disconnectCurrentSession` 这一个漏斗。
        case sessionHungUp = "session-hangup"

        /// 语音会话连接成功（页面回报 ready）。挂断音的反向（上行双音），
        /// 一对听感对称的确认音；只在真正连上时响一次。
        case sessionConnected = "session-connect"

        /// **苹果官方音效 12（焦点切换・应用图标）**—— 用户 2026-09-25 指定：
        /// 「点击（左侧边栏的任何按钮）都发出声音：12-焦点切换・应用图标。
        /// 包括设置页面的左侧边栏的按钮」。供侧栏那批按钮共用。
        case sidebarButton = "ui-focus-change"

        /// **苹果官方音效 23（相机倒计时）**—— 用户 2026-09-25 指定：
        /// 「摄像头、屏幕声音（右上角的位置：点击时=23）」。
        case deviceToggle = "ui-device-toggle"

        /// 录音面板「编辑」入口的点击音。**用户在 24 个候选里亲自选的（第 24 条）。**
        ///
        /// 试听页：`design-preview/音效试听/音效试听2.html`（↑↓ / ←→ 换一条并自动播放）。
        ///
        /// 合成参数（要微调时照这个改，不用重新试）：
        ///   音色「木块」—— 分音 [(1.0, 1.0, 衰减7.0), (2.72, 0.28, 衰减16)]
        ///   基频 659 Hz（E5）· 时长 0.6s · 起振斜坡 6ms · 峰值 0.36
        ///
        /// 两个关键点，缺一个就变成「咔」的一声爆音（第一版 20 条全被否掉就是这个原因）：
        ///   ① **多个分音，且高次分音衰减更快** —— 真实打击乐器就是这样：高频先没、
        ///      基频留得久。所有分音同样衰减就是爆音。
        ///   ② **几毫秒的起振斜坡** —— 波形从 0 平滑升上去，去掉音头的「呲」。
        case recordingEditorOpened = "ui-recording-open"
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
        // TEMPORARY PROBE (2026-09-25)：用户报「点击按钮之后……有两个声音，应该只有
        // 一个声音才对」。音效本身没有日志，所以"响了几次"只能靠猜 —— 这一行让它可数：
        // 点一次刘海，日志里应该**只有一条**。
        print(String(format: "🔊 [sfx] t=%.3f %@", Date().timeIntervalSince1970, effect.rawValue))
        warmUpIfNeeded()
        guard let player = playersByEffect[effect] else { return }
        player.currentTime = 0
        player.play()
    }
}
