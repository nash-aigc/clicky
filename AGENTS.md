# Clicky - Agent Instructions

<!-- This is the single source of truth for all AI coding agents. CLAUDE.md and cloud.md are symlinks to this file, so there is only ever one copy of these instructions. -->
<!-- AGENTS.md spec: https://github.com/agentsmd/agents.md — supported by Claude Code, Cursor, Copilot, Gemini CLI, and others. -->

## 改完代码必须自己编译、自己重启，直接把能用的成品交给用户（最高优先级）

**这一节高于本文件的其他所有内容。** 任何时候改动了 `leanring-buddy/` 下的代码，先把它编译出来、跑起来，再去做别的事。

### 三条规则

1. **改完代码必须重新编译，并重新启动 App。** 不重新编译，用户跑的是旧版本，改动等于没做。
2. **编译和启动由 agent 自己做，不要交给用户。** 不要写「你在 Xcode 里按 Cmd+R 试一下」——用下面的 CLI 流程自己跑完。终端 `xcodebuild` 在当前签名配置下是安全的（见 [Code signing](#code-signing)）。
3. **交付的是一个能直接用的成品。** 用户的参与度越低越好，不要留半成品给用户收尾。

### 标准流程

```bash
# ① 最快的语法检查（不碰签名、不碰 TCC）
cd /Users/mjm/Desktop/clicky/leanring-buddy
xcrun swiftc -typecheck -sdk $(xcrun --show-sdk-path --sdk macosx) \
  -target arm64-apple-macos14.2 -swift-version 5 -default-isolation MainActor \
  $(ls *.swift | grep -v leanring_buddyApp.swift)

# ② 完整构建
cd /Users/mjm/Desktop/clicky
xcodebuild -project leanring-buddy.xcodeproj -scheme leanring-buddy -configuration Debug build

# ③ 问构建系统 app 落在哪 —— 不要写死 DerivedData 里那段哈希，每台机器都不一样
APP_DIR=$(xcodebuild -project leanring-buddy.xcodeproj -scheme leanring-buddy \
  -configuration Debug -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2}')

# ④ 关掉旧进程，再启动新的
pkill -TERM -f "$APP_DIR/Clicky.app/Contents/MacOS/Clicky" || true
open "$APP_DIR/Clicky.app"
```

**④ 一步都不能省。** macOS 不会给正在运行的进程换代码——这是设计，不是 bug（[`开发经验/10-踩过的坑.md`](开发经验/10-踩过的坑.md) F3）。只做 ①②③ 就宣布做完，用户屏幕上跑的还是旧代码，他只会看到「为什么我没看到任何功能」。这个项目真的这么错过一次，不要再犯。

（`$(ls *.swift | grep -v leanring_buddyApp.swift)` 里的 `grep -v` 不能省：裸 `swiftc` 解析不了 SwiftPM 的 Sparkle 模块，而那个文件是唯一 import 它的。）

### 怎么确认真的生效了

**编译成功 ≠ 改动生效。** 启动完之后要复核——新进程的启动时间必须**晚于**你改过的源文件的修改时间：

```bash
# 新进程的启动时间
ps -eo pid,lstart,command | grep "Clicky.app/Contents/MacOS/Clicky" | grep -v grep

# 源文件的修改时间（上面那个时间必须比这些晚）
ls -lT leanring-buddy/*.swift | tail -5

# 没有新的崩溃报告
ls -lt ~/Library/Logs/DiagnosticReports/ | head -5
```

### 只有这三种情况可以留给用户

| 情况 | 为什么躲不掉 |
|---|---|
| 系统权限弹窗（录屏 / 辅助功能 / 麦克风） | TCC 弹窗只能由人在系统对话框里点。证书签名下**只需要点一次**，之后重建不会再问 |
| 纯主观的视觉判断（淡出快慢好不好看、箭头尖有没有对准鼠标） | 这是审美，agent 判断不了，必须用户自己看一眼 |
| 用户自己的密钥 | 密钥只能由用户提供。拿到之后写进 gitignored 的 `BailianSecrets.plist` 或仓库外的 `0600` JSON，**永远不要在输出里回显** |

**除这三种之外，一律自己做完。**

### 一个例外：改「设置」不用重启

`AppSettings.json` / `ModelConfiguration.json` 里改的是**数据**，存储类会发通知，运行中的 App **立刻生效**，不需要重启。改**代码**才必须走上面的流程。别把这条规则用过头。

## Overview

macOS menu bar companion app. Lives entirely in the macOS status bar (no dock icon, no main window). Clicking the menu bar icon opens a custom floating panel with companion voice controls. Uses push-to-talk (ctrl+option) to capture voice input, transcribes it via Alibaba Bailian streaming ASR, and sends the transcript + a screenshot of the user's screen to a Qwen vision model. The model responds with text (streamed via SSE) and voice (Bailian TTS). A blue cursor overlay can fly to and point at UI elements the model references on any connected monitor.

This fork talks to Alibaba Cloud Bailian (Model Studio) directly. The upstream Cloudflare Worker proxy is no longer in the request path — the API key lives in a gitignored plist on the user's machine.

## Architecture

- **App Type**: Menu bar-only (`LSUIElement=true`), no dock icon or main window
- **Framework**: SwiftUI (macOS native) with AppKit bridging for menu bar panel and cursor overlay
- **Pattern**: MVVM with `@StateObject` / `@Published` state management
- **AI Chat**: any vision model the user configures (default Qwen VL `qwen3-vl-plus` on Bailian), with SSE streaming
- **Speech-to-Text**: Bailian real-time streaming (`qwen3-asr-flash-realtime` by default) over websocket, with OpenAI and Apple Speech as fallbacks
- **Text-to-Speech**: Bailian Qwen-Audio-TTS (`qwen-audio-3.1-tts-flash` by default, cloned voice 赵今麦 via voice-enrollment) via the `SpeechSynthesizer` endpoint
- **Model Configuration**: all three models above are user-configurable — see [Model Configuration](#model-configuration). Provider/model choices are made in the settings window, not in code.
- **Settings**: one window, seven pages — 通用 / 模型 / 对话与记忆 / 听（识别）/ 说（播报）/ 看与截图 / 快捷键 — see [Settings](#settings). 30 of the 33 settings live in `AppSettings.json`; the other three are the model roles.
- **Screen Capture**: ScreenCaptureKit (macOS 14.2+), multi-monitor support
- **Voice Input**: Push-to-talk via `AVAudioEngine` + pluggable transcription-provider layer. System-wide keyboard shortcut via listen-only CGEvent tap.
- **Element Pointing**: The model embeds `[POINT:x,y:label:screenN]` tags in responses, where `x` and `y` are on a **normalized 0–1000 grid**, not screenshot pixels. The overlay converts them to pixels, maps them to the correct monitor, and animates the blue cursor along a bezier arc to the target.
- **Concurrency**: `@MainActor` isolation, async/await throughout
- **Analytics**: None. The upstream PostHog integration was removed — it reported to the original author's account, uploaded the user's raw transcripts, the model's raw responses and the user's email address, and did synchronous disk writes on the main thread on every message.

### Model Configuration

Every request goes straight to whichever provider the user configured. There is no proxy.

The app needs three models, called **roles**:

| Role | What it does | Default |
|------|--------------|---------|
| 👂 `transcription` | Speech-to-text | `qwen3-asr-flash-realtime` over websocket |
| 🧠 `vision` | Looks at the screenshot and answers | `qwen3-vl-plus` |
| 👄 `speech` | Reads the answer aloud | `qwen-audio-3.1-tts-flash` + cloned 赵今麦 voice |

Which provider serves each role, and that provider's URL, API key and model names, are the user's to set. The settings window (gear icon in the menu bar panel) is the supported way to change them; it writes:

| Setting | Where it comes from | Purpose |
|---------|---------------------|---------|
| everything | `~/Library/Application Support/Clicky/ModelConfiguration.json` (0600) | Source of truth |
| `BailianAPIKey` | `BailianSecrets.plist` (gitignored) | Seed only — read once, when no `ModelConfiguration.json` exists yet |
| `BailianWorkspaceBaseURL` | `BailianSecrets.plist` (gitignored) | Seed only, same as above |

The JSON files live outside the repo so they survive a clean checkout and never need a `.gitignore` entry. They are **not** watched for changes: editing one by hand takes effect after a restart. `AppSettings.json` is the same idea for the 30 settings the [Settings](#settings) page writes, and `ConversationHistory.json` is the conversation itself — written only when 「重启后保留对话」 is on, and deleted when it is turned off.

Request paths are a property of the provider's protocol, not something the user types:

| Route | Protocol | Serves |
|-------|----------|--------|
| `POST {base}/compatible-mode/v1/chat/completions` | Bailian | 🧠 |
| `POST {base}/api/v1/services/audio/tts/SpeechSynthesizer` | Bailian | 👄 (returns a 24h WAV URL) |
| `WSS {base}/api-ws/v1/realtime?model=…` | Bailian | 👂 |
| `POST {base}/chat/completions` | DeepSeek | 🧠 only — DeepSeek has no ASR or TTS |

`ProviderProfile.effectiveFlavor` is the single source of path truth; the three clients ask it rather than hardcoding endpoints. DeepSeek is OpenAI-shaped but its chat route has **no `/v1` prefix**, which is why the protocol — not the base URL — decides the path.

**The reasoning pass is switched off by default, and it was most of the latency.** Measured 2026-09-21 with the app's real payload (1280×827 JPEG + the 4923-character system prompt), asked "屏幕右上角有什么？": `deepseek-flash` emitted **664–868 reasoning tokens before the first word of the answer**, so of a 4.5 s request 3.4 s was thinking, 0.5 s was upload, and 0.3 s was the answer. Clicky's questions are perception questions answered out loud — that thinking is time the user spends watching a spinner and cannot hear. `BailianVisionChatAPI.reasoningSuppressionBodyFields(for:)` now sends `thinking: {"type": "disabled"}`, which returns the first token in **817 ms median over four rounds** (vs 4298 ms) and still emitted a well-formed `[POINT:x,y:label]` on the 0–1000 grid **4 times out of 4**.

**That suppression is the user's setting, not a DeepSeek special case.** Each provider card in the settings window carries a 「推理」 switch writing `ProviderProfile.visionReasoningEnabled`, and the field is sent whenever the provider's `allowsVisionReasoning` is false — which is the default, so a user who never opens the settings window gets the fast path and a user who wants a reasoning model can ask for it. Two details are deliberate. The stored property is `Bool?` **so an existing configuration file still decodes** — the synthesized `Codable` throws on a missing key, so a plain `Bool` added now would make every file written before this setting existed fail to load; `nil` reads as off in the accessor, and the toggle writes an explicit `true`/`false` so a file records the choice once it has been made. And the field is only ever *sent* when it is on the suppression side: Bailian accepts `thinking` and ignores it (HTTP 200, no change in output, on a model with no reasoning frames to suppress), which is what lets one user-facing switch cover whichever provider serves 🧠, but there is no reason to spend the bytes otherwise. Of the candidate switches only `thinking:{type:disabled}` and `reasoning_effort:"none"` actually work — **`enable_thinking:false` (629 reasoning tokens still) and `chat_template_kwargs.thinking:false` (378 still) look plausible and do nothing**, which is why the constant is documented rather than guessed at. `ResolvedModelRole.allowsVisionReasoning` carries the decision to the request body the way `requestPath` already carries the protocol to the route.

**The second cost is TTS, and it is linear in the answer's length.** Measured 2026-09-21 on `qwen-audio-3.1-tts-flash` + the cloned voice: synthesis plus download runs ~19 ms per character plus ~450 ms fixed — 10 characters 0.72 s, 90 characters 1.98 s, 250 characters 5.85 s, 600 characters 9.43 s. Because `maximumCharactersPerChunk` is 500, a normal spoken answer is a *single* chunk, so the user waits for the whole thing before hearing anything. Unlike the reasoning pass there is no switch to flip here; the levers are shorter answers (the system prompt already asks for one or two sentences) and, for long ones, starting synthesis on the first sentence while the rest still streams.

**Only `deepseek-flash` can serve 🧠 on DeepSeek.** Measured 2026-09-21: the endpoint exposes exactly two models, and `deepseek-v4-pro` rejects the screenshot outright ("Unsupported Image") while `deepseek-flash` answers it — including emitting `[POINT:…]` tags on the normalized grid, which is the part that could not be assumed. `deepseek-flash` is therefore what the DeepSeek provider pre-fills as its 🧠 model. It is also a reasoning model — see the reasoning-suppression paragraph above for how that is handled, and why the `max_tokens` budget still has to stay generous: reasoning tokens are spent before any content is emitted, and a small budget returns HTTP 200 with an empty `content` — a silent failure the vision client now turns into a thrown error rather than "nothing happened".

**The `max_tokens` budget is capped by Bailian, not DeepSeek.** One value serves every provider, so it has to be legal on all of them, and their ceilings are an order of magnitude apart. Measured 2026-09-21 by probing each service: DeepSeek accepts `[1, 393216]` and Bailian rejects above `[1, 32768]` with `InternalError.Algo.InvalidParameter`. 32768 is therefore the largest value that is legal everywhere, and that is what `AppSettings.visionMaxCompletionTokens` defaults to — raising it toward DeepSeek's ceiling would break 🧠 the moment the user switched back to Bailian. Both were re-verified at 32768 with a real 1.2 MB screenshot and the app's own 4923-character prompt, and both still answer and still emit `[POINT:…]`. The 看与截图 page exposes it as 「单次回答字数上限」, a slider over `256...32768`, and `clamped()` keeps a hand-edited file inside that range. The budget has to stay generous for a second reason: a reasoning model bills its chain of thought against it, and an exhausted budget returns HTTP 200 with an empty `content` — a silent failure the vision client turns into a thrown error rather than "nothing happened". (The separate small `max_tokens` values in `ElementLocationDetector` and `ModelConnectionTester` are unrelated paths and deliberately tiny.)

`ModelConfigurationStore` holds the configuration behind an `NSLock` and is deliberately `nonisolated` (see the Concurrency note below); `BailianConfiguration` is now only a façade over it (`resolvedTranscription` / `resolvedVision` / `resolvedSpeech`) plus the seed constants. All three clients read the configuration **per request**, so a save is live: nothing needs rebuilding, and a change mid-utterance can't split one request across two providers.

The `worker/` directory is kept for reference but is **not built or called** by the app.

### Settings

One window, opened from the gear in the menu bar panel or from 「更换…」 on the panel's model row. It has a 178pt sidebar and seven pages, in this order:

| Page | Holds | Stored in |
|------|-------|-----------|
| 通用 | 开机自启动、启动时自动打开面板、光标的显示方式/形状/跟随距离/闲置后自动隐藏、回答时显示文字、回答文字多留一会儿、说话时实时显示识别文字 | `AppSettings.json` |
| 模型 | the three roles and their providers | `ModelConfiguration.json` |
| 对话与记忆 | 记住最近多少轮对话、重启后保留对话、历史自动压缩、历史里带截图、回答长度、补充指令 — plus 清空对话记忆, an action rather than a setting | `AppSettings.json` |
| 听（识别） | 识别语言、热词（专有名词偏置）、松键后等最终结果、静音自动断句（免按键连续对话） | `AppSettings.json` |
| 说（播报） | 语速、播报音量、新提问立刻打断播报、长回答分段合成 | `AppSettings.json` |
| 看与截图 | 截图清晰度、截图压缩质量、多显示器发送策略、回答里的位置自动飞过去指、单次回答字数上限 | `AppSettings.json` |
| 快捷键 | 按住说话快捷键、松开立即发送 | `AppSettings.json` |

Every row is wired to real behaviour — the sidebar's per-page number is the count of live settings on that page, so a page that grew a decorative row would have to lie about its own size. The three model roles are the only settings outside `AppSettings.json`.

Five settings need a subsystem rather than a flag, because a setting that saves but does nothing is worse than no setting:

- **「显示方式」** — whether the blue cursor is up all the time, only during a conversation, or only while pointing. It is the setting the app used to have and not honour: `isClickyCursorEnabled` (UserDefaults, default `true`) was the only gate, its only control was a commented-out toggle in the panel, and `scheduleTransientHideIfNeeded`'s first line read `guard !isClickyCursorEnabled && …` — so the transient machinery never ran once. It is now three settings in the 通用 page's 「蓝色光标」 group, and `CompanionManager.isBuddyShown` is what the overlay multiplies into everything it draws. See **Cursor Presence** below for why the overlay *windows* stay up and only the drawing is gated.

- **「重启后保留对话」 / 「历史自动压缩」 / 「历史里带截图」** — the memory pipeline. `CompanionManager` replays the last N exchanges as real conversation turns (each with its own screenshots when 「历史里带截图」 is on), compresses the ones that age out into a running summary, and skips all of it when the persistence setting is off. The summary is sent as a **second system message**, not appended to the system prompt — a drifted summary must not read as an instruction the user gave.
- **「松开立即发送」 off** — confirmation mode. The transcript is held and shown next to the cursor instead of being sent, and a *tap* of the shortcut (under 0.6 s — see `confirmationTapMaximumDurationSeconds`) sends it. The tap rule is phrased in press duration rather than in what was said, because at release the recognition service has not yet returned this press's final transcript, so "did they say something this time" is not a question the release event can answer. An empty transcript never sends and never clears, which is what lets a user whose first attempt was not heard hold the key again without losing what they said.
- **「回答时显示文字」 / 「说话时实时显示识别文字」** — one bubble in the overlay showing whichever of the streaming answer or the live transcript is current. An empty string is the single gate the overlay keys off, so "show nothing" and "nothing to show" are the same state. The bubble is also what confirmation mode reads back from.
- **「回答文字多留一会儿」** — how long the answer bubble outlives the voice reading it. The reading time is not the user's to set: `scheduleAnswerBubbleClear(lingerSeconds:)` polls `bailianTTSClient.isPlaying`, which is true until the *last* chunk is done, and only then starts the user's linger. Clearing at `speakText` return instead — which is what the app did — showed the answer for the second or two the first chunk took to synthesize and removed it at exactly the moment the user began listening, because `speakText` returns when playback *starts*. Two consequences are deliberate: the streamed text is replaced by `spokenText` at that point, since the raw stream still carries the `[POINT:…]` tag and it would now sit on screen for seconds; and every path that takes the bubble over goes through `clearAnswerBubble()`, because a clear left pending from the previous answer would otherwise fire mid-stream and take the next one's opening words. `scheduleTransientHideIfNeeded` waits for the bubble too — the bubble is drawn *by* the cursor, so fading out during the linger would take the text with it.

`AppSettingsStore` and `ConversationHistoryStore` both follow `ModelConfigurationStore`'s shape exactly — `nonisolated`, `NSLock`-guarded cache, atomic write followed by `setAttributes([.posixPermissions: 0o600])` — because `.atomic` writes land as 0644 and every one of these files holds something the user would not want world-readable. Both live outside the repo, and both post a notification on change so the running app picks the change up without a restart.

### Key Architecture Decisions

**Menu Bar Panel Pattern**: The companion panel uses `NSStatusItem` for the menu bar icon and a custom borderless `NSPanel` for the floating control panel. This gives full control over appearance (dark, rounded corners, custom shadow) and avoids the standard macOS menu/popover chrome. The panel is non-activating so it doesn't steal focus. A global event monitor auto-dismisses it on outside clicks.

**Cursor Overlay**: A full-screen transparent `NSPanel` hosts the blue cursor companion. It's non-activating, joins all Spaces, and never steals focus. The cursor position, response text, waveform, and pointing animations all render in this overlay via SwiftUI through `NSHostingView`.

**Global Push-To-Talk Shortcut**: Background push-to-talk uses a listen-only `CGEvent` tap instead of an AppKit global monitor so modifier-based shortcuts like `ctrl + option` are detected more reliably while the app is running in the background.

**Shared URLSession for Streaming ASR**: A single long-lived `URLSession` is shared across all streaming transcription sessions (owned by the provider, not the session). Creating and invalidating a URLSession per session corrupts the OS connection pool and causes "Socket is not connected" errors after a few rapid reconnections.

**Provider teardown must never escape `self` out of `deinit`**: Every transcription provider serializes its mutable state on a private `stateQueue` and reaches it through `stateQueue.async { self… }`, so `cancel()` implicitly retains `self`. Calling `cancel()` from `deinit` therefore retains an object whose reference count has already reached zero. When that queued block is later released, the extra release over-releases `self` and the process dies with `EXC_BAD_ACCESS` inside `_Block_release` on the `stateQueue` thread. `BailianRealtimeTranscriptionSession` did exactly this and crashed immediately after every final transcript. `deinit` may only message objects directly (such as closing the websocket) — the owner calls `cancel()` explicitly on every teardown path.

**Normalized Point Coordinates**: Qwen's vision models rescale images internally before looking at them, so `[POINT:x,y:...]` values arrive on a 1000×1000 grid rather than in screenshot pixels. `CompanionManager.screenshotPixelCoordinate(fromNormalizedPoint:…)` performs the documented `value / 1000 × dimension` mapping before the display-point conversion. Skipping it fails silently, because a normalized value is indistinguishable from a plausible pixel coordinate — the cursor simply lands short.

**TTS Chunking**: Bailian's TTS endpoint documents a per-request character limit, so `BailianTTSClient` splits the response into sentence-aligned chunks, plays the first immediately, and queues the rest. This also means playback starts as soon as the first chunk's audio arrives rather than after the whole response is synthesized.

**TTS endpoint families are not interchangeable**: Bailian serves speech synthesis from two different routes and picking the wrong pairing fails with a misleading `InvalidParameter: url error, please check url` rather than anything that names the mismatch. Qwen-Audio-TTS / CosyVoice models (`qwen-audio-3.1-tts-flash`) live on `/api/v1/services/audio/tts/SpeechSynthesizer` and take `input.{text, voice, format, sample_rate}`; Qwen-TTS models (`qwen3-tts-flash`) live on `/api/v1/services/aigc/multimodal-generation/generation` and take `input.{text, voice, language_type}`. Voice names are model-family specific too — the Qwen-TTS name `Cherry` is rejected by Qwen-Audio-TTS with `[cosyvoice:]Engine error [411]`, whose correct voices are `yuxiaoyun_v3.1`, `yeqinghe_v3.1` and friends. Model, voice, body fields and path therefore have to move together. Alibaba's own list (`bl model code --model …`) is the way to tell which family a model belongs to: it emits the `tts_v2` websocket sample for Qwen-Audio-TTS and the HTTP sample for Qwen-TTS.

**A 403 on TTS speaks the apology, not the answer**: `speakCreditsErrorFallback(failure:)` reads a fixed Chinese apology through `NSSpeechSynthesizer` whenever the vision call or the TTS call throws, so a billing-side failure (`AllocationQuota.FreeTierOnly` — free quota exhausted with "use free tier only" still on in the Alibaba console) presents to the user as the companion repeating "抱歉，我这边出了点问题" no matter what they ask. The vision model is unaffected and answers correctly, which makes it look like a model problem when it is an account problem. The apology is kept — the user is waiting for audio — but the same error is now also recorded in `CompanionManager.lastErrorMessage` and shown verbatim in the panel, so the actual cause is never hidden behind the apology alone. Check the account before touching the pipeline.

**Model configuration reads are per-request, never frozen at launch**: all three clients (`BailianVisionChatAPI`, `BailianTTSClient`, `BailianRealtimeTranscriptionProvider`) resolve their role from `ModelConfigurationStore` inside the request they are about to send, rather than capturing a URL/key/model in an initializer. This is what makes saving in the settings window take effect immediately, with no client rebuild and no "changed it but nothing happened" trap. Two consequences are deliberate: `BailianTTSClient.speakText` snapshots the role **once** at the top and reuses it for every chunk, so one answer can never be half-read in one provider's voice and half in another's; and a transcription session receives its `websocketURL` and `apiKey` as plain values, so a save landing mid-recording cannot produce a socket whose host and model disagree.

**The configuration layer is `nonisolated` on purpose**: the target builds with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` and `SWIFT_VERSION = 5.0`, so an unannotated type is main-actor-isolated. Everything in the configuration path — `ModelConfiguration`'s value types, `BailianConfiguration`, `AppBundleConfiguration`, `ModelConfigurationStore` — is therefore marked `nonisolated`: the value types have no shared mutable state, the store guards its one cache with an `NSLock`, and marking them keeps a configuration read from having to hop actors. Without the annotation the compiler flags the store's use of these types, since `nonisolated` on the store alone does not extend to the types it touches.

**The settings window must call `NSApp.activate()`**: this is an `LSUIElement` app, so it is never the active application on its own. Without activating first, the window appears but never becomes key — and a non-key window's text fields silently swallow every keystroke, which looks exactly like a broken form. The controller also needs both a strong reference (held by `CompanionManager`) and `isReleasedWhenClosed = false`; either one alone gives a crash on close or a vanished window.

**Deleting a provider never hands its roles to another provider**: `ModelSettingsViewModel.removeProvider(withID:)` unassigns the roles it served and leaves them unassigned. Silently reassigning would start sending the user's screenshots to a company they did not choose. The confirmation dialog names exactly which roles will stop working before the deletion happens.

**Cursor Presence**: The overlay *windows* are permanent — they are built once when onboarding is done and permissions are granted, and never torn down. What the three 显示方式 modes control is whether the companion is *drawn*, through `CompanionManager.isBuddyShown`, which `OverlayWindow` multiplies into the triangle, the waveform and the spinner. Rebuilding the windows instead would flash, lose `cursorPosition` (it is only initialised in `onAppear`), and dismantle the onboarding video player. Three details are deliberate. The fade animation is keyed to `isBuddyShown` **alone**, so 「只在指位置时出现」 shows the companion the instant a flight starts rather than materialising mid-arc. The waveform and spinner are gated only on the voice state, never on `buddyIdleAppearanceIsAllowed` — hiding them too would mean recording with no feedback at all. And onboarding forces the presence factor to 1, so the welcome animation never plays to an invisible companion. `isOverlayVisible` keeps its original meaning ("the windows exist") and is no longer what the panel's status row reads — with permanent windows that value is always true, so the panel would have said "Active" forever; it reads `isBuddyShown` instead.

**Cursor Shape and Follow Distance**: `ArrowCursorShape` draws the macOS pointer with its **tip at `rect` centre**, matching `Triangle`, so `.position(cursorPosition)` means the same thing for both and no anchor correction is needed. `CursorFollowDistance` replaces the four hardcoded `+35 / +25` sites — the `init` default, the `onAppear` placement, the per-frame follow in `startTrackingCursor`, and the landing point in `startFlyingBackToCursor`. Missing the last one makes the companion fly back to the old spot and then jump. The pointing offset in `startNavigatingToElement` (`+8 / +12`) is deliberately untouched: "rest beside the element" is a different idea from "follow the mouse".

## Key Files

| File | Lines | Purpose |
|------|-------|---------|
| `leanring_buddyApp.swift` | ~89 | Menu bar app entry point. Uses `@NSApplicationDelegateAdaptor` with `CompanionAppDelegate` which creates `MenuBarPanelManager` and starts `CompanionManager`. No main window — the app lives entirely in the status bar. |
| `CompanionManager.swift` | ~1624 | Central state machine. Owns dictation, shortcut monitoring, screen capture, the vision chat API, TTS, and overlay management. Tracks voice state (idle/listening/processing/responding), conversation history, whether the cursor is drawn (`isBuddyShown`, plus the three cursor settings it mirrors from `AppSettingsStore`), and the last error message shown in the panel. Owns the settings window and re-renders the panel when either configuration changes. Coordinates the full push-to-talk → screenshot → vision → TTS → pointing pipeline, and owns 对话与记忆's memory: replaying past turns, compressing old ones, and holding a transcript back when 快捷键 → 「松开立即发送」 is off. |
| `MenuBarPanelManager.swift` | ~243 | NSStatusItem + custom NSPanel lifecycle. Creates the menu bar icon, manages the floating companion panel (show/hide/position), installs click-outside-to-dismiss monitor. |
| `CompanionPanelView.swift` | ~806 | SwiftUI panel content for the menu bar dropdown. Shows companion status, push-to-talk instructions, a read-only vision-model summary with 「更换…」, a gear that opens the settings window, the last error verbatim, permissions UI, DM feedback button, and quit button. Dark aesthetic using `DS` design system. |
| `OverlayWindow.swift` | ~1064 | Full-screen transparent overlay hosting the blue cursor, response text, waveform, and spinner. Handles cursor animation (`Triangle` and `ArrowCursorShape`), element pointing with bezier arcs, multi-monitor coordinate mapping, and fade-out transitions. Also hosts the conversation bubble, which shows whichever of the streaming answer or the live transcript is current. |
| `CompanionResponseOverlay.swift` | ~217 | Dead code — nothing instantiates `CompanionResponseOverlayManager`; the bubble described above is what actually renders answers and transcripts. Kept only because removing it is out of scope. |
| `CompanionScreenCaptureUtility.swift` | ~132 | Multi-monitor screenshot capture using ScreenCaptureKit. Returns labeled image data for each connected display. |
| `BuddyDictationManager.swift` | ~889 | Push-to-talk voice pipeline. Handles microphone capture via `AVAudioEngine`, provider-aware permission checks, keyboard/button dictation sessions, transcript finalization, shortcut parsing, contextual keyterms, and live audio-level reporting for waveform feedback. Re-resolves its transcription provider at the start of a recording if the current one is unconfigured, so fixing the 👂 role in the settings window does not require a restart. |
| `BuddyTranscriptionProvider.swift` | ~82 | Protocol surface and provider factory for voice transcription backends. Resolves provider based on `VoiceTranscriptionProvider` in Info.plist — Bailian, AssemblyAI, OpenAI, or Apple Speech. |
| `BailianRealtimeTranscriptionProvider.swift` | ~637 | Streaming transcription provider. Opens a realtime websocket at the URL its resolved role supplies, sends a `session.update`, streams base64 PCM16 audio in 100ms chunks, and delivers interim + final transcripts on key-up. Shares a single URLSession across all sessions. |
| `BailianConfiguration.swift` | ~127 | Façade over the stored configuration: `resolvedTranscription` / `resolvedVision` / `resolvedSpeech` resolve the three roles fresh on every access. Also holds the seed constants (`Models.*`, the cloned `textToSpeechVoice`) and the legacy plist readers used only when no configuration file exists yet. |
| `BailianVisionChatAPI.swift` | ~388 | Vision chat client with streaming (SSE) and non-streaming modes, resolving its provider per request. Parses `delta.content` for text and `delta.reasoning_content` for thinking, tolerates the trailing usage-only frame whose `choices` array is empty, and detects image MIME types. |
| `BailianTTSClient.swift` | ~377 | TTS client, resolving its provider per request. Splits text into sentence-aligned chunks, requests audio from the configured endpoint, and plays back via `AVAudioPlayer`. Exposes `isPlaying` for transient cursor scheduling. |
| `AssemblyAIStreamingTranscriptionProvider.swift` | ~478 | Unused fallback streaming provider kept from upstream. Fetches temp tokens from the retired Worker, opens an AssemblyAI v3 websocket, streams PCM16 audio. |
| `OpenAIAudioTranscriptionProvider.swift` | ~317 | Upload-based transcription provider. Buffers push-to-talk audio locally, uploads as WAV on release, returns finalized transcript. |
| `AppleSpeechTranscriptionProvider.swift` | ~147 | Local fallback transcription provider backed by Apple's Speech framework. |
| `BuddyAudioConversionSupport.swift` | ~108 | Audio conversion helpers. Converts live mic buffers to PCM16 mono audio and builds WAV payloads for upload-based providers. |
| `GlobalPushToTalkShortcutMonitor.swift` | ~132 | System-wide push-to-talk monitor. Owns the listen-only `CGEvent` tap and publishes press/release transitions. |
| `OpenAIAPI.swift` | ~142 | OpenAI GPT vision API client. |
| `ElementLocationDetector.swift` | ~335 | Detects UI element locations in screenshots for cursor pointing. |
| `DesignSystem.swift` | ~880 | Design system tokens — colors, corner radii, shared styles. All UI references `DS.Colors`, `DS.CornerRadius`, etc. |
| `WindowPositionManager.swift` | ~262 | Window placement logic, Screen Recording permission flow, and accessibility permission helpers. |
| `AppBundleConfiguration.swift` | ~88 | Runtime configuration reader. Checks the bundle Info dictionary, `Info.plist`, a bundled `BailianSecrets.plist`, then the Application Support copy. Now only used to seed a first-run configuration. |
| `ModelConfiguration.swift` | ~440 | Pure data + resolution, no I/O. `ModelRole` (👂/🧠/👄), `APIProviderFlavor` (owns request paths and preset model IDs), `ProviderProfile`, `ModelConfiguration`, `ResolvedModelRole`, and `RoleConfigurationStatus` — the last of which carries *why* a role is unusable, not just that it is. |
| `ModelConfigurationStore.swift` | ~271 | Reads/writes `ModelConfiguration.json` (atomic write, then `0600`), caches it behind an `NSLock`, seeds a first-run configuration from the legacy plist, and posts `.clickyModelConfigurationChanged` on save. Seeding is in memory only — nothing is written until the user presses 保存. |
| `ModelConnectionTester.swift` | ~242 | One minimal request per role (chat without an image, two characters of TTS, a real websocket handshake) run against a *draft* configuration, so the user learns whether a provider works before committing to it. Reports the service's own error text. |
| `ModelSettingsViewModel.swift` | ~277 | `@MainActor` state for the settings window: the draft configuration, dirty tracking, role assignment, and save/test actions. All provider bindings resolve by id rather than array index. |
| `AppSettings.swift` | ~434 | Pure data, no I/O: every user-facing setting that is not a model choice, plus `AnswerLengthStyle`, `TranscriptionLanguage`, `CursorPresenceMode`, `CursorShapeStyle`, `CursorFollowDistance` and `clamped()`. The 30 stored properties are the 30 rows the settings pages show — the sidebar's per-page counts are derived from the same set. |
| `AppSettingsStore.swift` | ~155 | Reads/writes `AppSettings.json` (atomic write, then `0600`), caches it behind an `NSLock`, and posts `.clickyAppSettingsChanged` on save. Same `nonisolated` + `NSLock` shape as `ModelConfigurationStore`, and the reason that shape exists: the project builds with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so an isolation mistake in a store would be silent. |
| `GeneralSettingsView.swift` | ~931 | The six non-模型 settings pages (通用 / 对话与记忆 / 听 / 说 / 看 / 快捷键) and the components they share — `SettingsRow`, `SettingsCard`, `SettingsSwitch`, `SettingsSlider`, `SettingsStepper`, the two pickers. All 30 settings are here; none of them is decorative. |
| `GeneralSettingsViewModel.swift` | ~194 | `@MainActor` draft-and-save state for those pages, mirroring `ModelSettingsViewModel`. Also owns 清空对话记忆, which is deliberately *not* routed through the draft — deleting a file should not depend on the user also pressing 保存. |
| `ConversationHistoryStore.swift` | ~207 | Reads/writes `ConversationHistory.json` (atomic write, then `0600`) and posts `.clickyConversationHistoryCleared`. The only place the user's own words reach the disk, which is why the setting that enables it defaults to off and why turning it off deletes the file rather than only stopping future writes. Screenshots are held in memory and excluded from `CodingKeys`, so a restart drops them as the setting's description promises. |
| `SettingsWindowController.swift` | ~321 | `NSWindowController` hosting all seven pages: a 178pt sidebar plus the selected page, with `ModelSettingsView` swapped in for 模型. Calls `NSApp.activate()` before showing — see the key decisions. |
| `ModelSettingsView.swift` | ~602 | The 模型 page: 「当前使用」 (one row per role) and 「服务商」 (credentials only), with the test/save bar pinned outside the scroll view. Rendered inside the settings window's content area, so it draws no window chrome of its own. |
| `worker/src/index.ts` | ~142 | Retired Cloudflare Worker proxy, kept for reference only. |

## Build & Run

**Build and launch from the terminal, not from the Xcode GUI** — the full sequence is at the top of this file, under [改完代码必须自己编译、自己重启](#改完代码必须自己编译自己重启直接把能用的成品交给用户最高优先级). What goes wrong if you skip the relaunch step is written up there too.

```bash
# Build
cd /Users/mjm/Desktop/clicky
xcodebuild -project leanring-buddy.xcodeproj -scheme leanring-buddy -configuration Debug build

# Known non-blocking warnings: Swift 6 concurrency warnings,
# deprecated onChange warning in OverlayWindow.swift. Do NOT attempt to fix these.
```

Opening the project in Xcode (`open leanring-buddy.xcodeproj`) is still fine for reading code or inspecting build settings — it is just not how a change gets shipped to the user.

**Terminal `xcodebuild` is safe only while the target is certificate-signed** — see [Code signing](#code-signing). Under ad-hoc signing it resets TCC (Screen Recording / Accessibility / Microphone), because that signature's identity is the binary hash, so a rebuild looks like an entirely new app. The target is certificate-signed today, so `xcodebuild … build` works and is a faster way to get a compile error than opening Xcode. If the target is ever switched back to ad-hoc, go back to building from the Xcode GUI.

### Code signing

The app target is **certificate-signed**: `CODE_SIGN_STYLE = Automatic`, `CODE_SIGN_IDENTITY = "Apple Development"`, `DEVELOPMENT_TEAM = 8WS2Z3JL4F`, against an Apple ID added in Xcode → Settings → Accounts. This is the configuration that stopped macOS re-asking for Screen Recording / Accessibility / Microphone after every rebuild, and it is what makes terminal `xcodebuild` safe here.

The stability comes from the designated requirement being **certificate**-based rather than hash-based:

```
designated => identifier "com.yourcompany.leanring-buddy" and anchor apple generic
              and certificate leaf[subject.CN] = "Apple Development: … (WR9S5P4Y38)"
```

An ad-hoc signature's requirement is instead `cdhash H"…"` — bound to the binary — so every rebuild is a brand-new app to TCC and all three permissions reset. That was the cause of the repeated permission prompts.

Upstream shipped the app target pinned to `DEVELOPMENT_TEAM = 2UDAY4J48G`, the original author's team. On any other machine that fails before compiling with:

```
error: No signing certificate "Mac Development" found: No "Mac Development"
signing certificate matching team ID "..." with a private key was found.
```

Do not "fix" that by setting a team ID that isn't installed — with no certificate in the keychain, automatic signing fails for any team. **Ad-hoc** (`CODE_SIGN_STYLE = Manual`, `CODE_SIGN_IDENTITY = "-"`, `DEVELOPMENT_TEAM = ""`) is the fallback for a machine with no Apple ID at all: it compiles, because the app is not sandboxed and every entitlement it declares (`network.client`, `device.camera`, `device.audio-input`, the ScreenCaptureKit mach-lookup exception) needs no provisioning profile — but it costs stable TCC permissions, and it is the only reason terminal builds would be off-limits.

## Secrets and First-Run Setup

`leanring-buddy/BailianSecrets.plist` is gitignored and holds two keys:

```xml
<key>BailianAPIKey</key>
<string>sk-…</string>
<key>BailianWorkspaceBaseURL</key>
<string>https://ws-….maas.aliyuncs.com</string>
```

Because it must not be committed, a fresh clone has no secrets and the app will fail every network call. Install a copy outside the repo so it survives a clean checkout:

```bash
mkdir -p ~/Library/Application\ Support/Clicky
cp leanring-buddy/BailianSecrets.plist ~/Library/Application\ Support/Clicky/BailianSecrets.plist
chmod 600 ~/Library/Application\ Support/Clicky/BailianSecrets.plist
```

`AppBundleConfiguration` falls back to that path automatically, so it works whether or not Xcode copies the in-repo plist into the bundle.

That plist is now a **first-run seed only**. The first time the app starts with no `ModelConfiguration.json` present, these two values become the URL and API key of an 「阿里云百炼」 card, and all three roles are pointed at it. From then on the settings window owns the configuration and the plist is never read again — so an existing user who upgrades needs to change nothing, and a user who edits the plist afterwards will see no effect until they delete the JSON file.

The recommended way to configure the app is the **gear icon in the menu bar panel**, which opens the settings window on 通用. It writes `~/Library/Application Support/Clicky/ModelConfiguration.json` and `~/Library/Application Support/Clicky/AppSettings.json`, both with `0600` permissions, and both take effect immediately — no restart, no rebuild.

## Cloudflare Worker (retired)

`worker/` is kept for reference. It is **not built and not called** — the app talks to the configured provider directly.

## Code Style & Conventions

### Variable and Method Naming

IMPORTANT: Follow these naming rules strictly. Clarity is the top priority.

- Be as clear and specific with variable and method names as possible
- **Optimize for clarity over concision.** A developer with zero context on the codebase should immediately understand what a variable or method does just from reading its name
- Use longer names when it improves clarity. Do NOT use single-character variable names
- Example: use `originalQuestionLastAnsweredDate` instead of `originalAnswered`
- When passing props or arguments to functions, keep the same names as the original variable. Do not shorten or abbreviate parameter names. If you have `currentCardData`, pass it as `currentCardData`, not `card` or `cardData`

### Code Clarity

- **Clear is better than clever.** Do not write functionality in fewer lines if it makes the code harder to understand
- Write more lines of code if additional lines improve readability and comprehension
- Make things so clear that someone with zero context would completely understand the variable names, method names, what things do, and why they exist
- When a variable or method name alone cannot fully explain something, add a comment explaining what is happening and why

### Swift/SwiftUI Conventions

- Use SwiftUI for all UI unless a feature is only supported in AppKit (e.g., `NSPanel` for floating windows)
- All UI state updates must be on `@MainActor`
- Use async/await for all asynchronous operations
- Comments should explain "why" not just "what", especially for non-obvious AppKit bridging
- AppKit `NSPanel`/`NSWindow` bridged into SwiftUI via `NSHostingView`
- All buttons must show a pointer cursor on hover
- For any interactive element, explicitly think through its hover behavior (cursor, visual feedback, and whether hover should communicate clickability)

### Do NOT

- Do not add features, refactor code, or make "improvements" beyond what was asked
- Do not add docstrings, comments, or type annotations to code you did not change
- Do not try to fix the known non-blocking warnings (Swift 6 concurrency, deprecated onChange)
- Do not rename the project directory or scheme (the "leanring" typo is intentional/legacy)
- Do not run terminal `xcodebuild` while the target is ad-hoc signed — it resets TCC permissions. It is safe while the target is certificate-signed (see [Code signing](#code-signing)); check before assuming.

## Git Workflow

- Branch naming: `feature/description` or `fix/description`
- Commit messages: imperative mood, concise, explain the "why" not the "what"
- Do not force-push to main

## 开发经验

`开发经验/` in the repo root holds the retrospective of this fork's changes — one document per category, in Chinese, aimed at whoever touches this code next rather than at users. It is the place to look before changing a subsystem: `02-光标与覆盖层.md` for the cursor and overlay, `03-设置与配置.md` for how to add a setting (and the offscreen render probe used to check a settings page without relaunching the app), `04-模型接入.md` for provider routing, `09-实测数据.md` for every measured number with its date and payload, `10-踩过的坑.md` for the bugs and their root causes. `开发经验/README.md` is the index.

Add to it rather than duplicating this file: this file states what the app *is*, 开发经验 states what was *learned* building it.

## Self-Update Instructions

<!-- AI agents: follow these instructions to keep this file accurate. -->

When you make changes to this project that affect the information in this file, update this file to reflect those changes. Specifically:

1. **New files**: Add new source files to the "Key Files" table with their purpose and approximate line count
2. **Deleted files**: Remove entries for files that no longer exist
3. **Architecture changes**: Update the architecture section if you introduce new patterns, frameworks, or significant structural changes
4. **Build changes**: Update build commands if the build process changes
5. **New conventions**: If the user establishes a new coding convention during a session, add it to the appropriate conventions section
6. **Line count drift**: If a file's line count changes significantly (>50 lines), update the approximate count in the Key Files table

Do NOT update this file for minor edits, bug fixes, or changes that don't affect the documented architecture or conventions.
