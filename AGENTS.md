# Clicky - Agent Instructions

<!-- This is the single source of truth for all AI coding agents. CLAUDE.md is a symlink to this file. -->
<!-- AGENTS.md spec: https://github.com/agentsmd/agents.md — supported by Claude Code, Cursor, Copilot, Gemini CLI, and others. -->

## Overview

macOS menu bar companion app. Lives entirely in the macOS status bar (no dock icon, no main window). Clicking the menu bar icon opens a custom floating panel with companion voice controls. Uses push-to-talk (ctrl+option) to capture voice input, transcribes it via Alibaba Bailian streaming ASR, and sends the transcript + a screenshot of the user's screen to a Qwen vision model. The model responds with text (streamed via SSE) and voice (Bailian TTS). A blue cursor overlay can fly to and point at UI elements the model references on any connected monitor.

This fork talks to Alibaba Cloud Bailian (Model Studio) directly. The upstream Cloudflare Worker proxy is no longer in the request path — the API key lives in a gitignored plist on the user's machine.

## Architecture

- **App Type**: Menu bar-only (`LSUIElement=true`), no dock icon or main window
- **Framework**: SwiftUI (macOS native) with AppKit bridging for menu bar panel and cursor overlay
- **Pattern**: MVVM with `@StateObject` / `@Published` state management
- **AI Chat**: Qwen VL (`qwen3-vl-plus` default, `qwen3-vl-flash` optional) via the workspace-scoped Bailian MaaS endpoint with SSE streaming
- **Speech-to-Text**: Bailian real-time streaming (`qwen3-asr-flash-realtime` model) over websocket, with OpenAI and Apple Speech as fallbacks
- **Text-to-Speech**: Bailian (`qwen-audio-3.1-tts-flash` model, cloned voice 赵今麦 via voice-enrollment) via the Qwen-Audio-TTS `SpeechSynthesizer` endpoint
- **Screen Capture**: ScreenCaptureKit (macOS 14.2+), multi-monitor support
- **Voice Input**: Push-to-talk via `AVAudioEngine` + pluggable transcription-provider layer. System-wide keyboard shortcut via listen-only CGEvent tap.
- **Element Pointing**: The model embeds `[POINT:x,y:label:screenN]` tags in responses, where `x` and `y` are on a **normalized 0–1000 grid**, not screenshot pixels. The overlay converts them to pixels, maps them to the correct monitor, and animates the blue cursor along a bezier arc to the target.
- **Concurrency**: `@MainActor` isolation, async/await throughout
- **Analytics**: None. The upstream PostHog integration was removed — it reported to the original author's account, uploaded the user's raw transcripts, the model's raw responses and the user's email address, and did synchronous disk writes on the main thread on every message.

### Bailian Configuration

Every request goes straight to the user's Bailian workspace endpoint. There is no proxy.

| Setting | Where it comes from | Purpose |
|---------|---------------------|---------|
| `BailianAPIKey` | `BailianSecrets.plist` (gitignored) | Bearer token for every Bailian route |
| `BailianWorkspaceBaseURL` | `BailianSecrets.plist` (gitignored) | Workspace-scoped MaaS host, e.g. `https://ws-….maas.aliyuncs.com` |

| Route | Upstream | Purpose |
|-------|----------|---------|
| `POST {base}/compatible-mode/v1/chat/completions` | OpenAI-compatible mode | Qwen VL vision + streaming chat |
| `POST {base}/api/v1/services/audio/tts/SpeechSynthesizer` | DashScope native | Qwen-Audio-TTS audio (returns a 24h WAV URL) |
| `WSS {base}/api-ws/v1/realtime?model=qwen3-asr-flash-realtime` | OpenAI Realtime-style protocol | Streaming ASR |

`BailianConfiguration.swift` reads those two settings through `AppBundleConfiguration`, which checks (in order) the bundle Info dictionary, `Info.plist`, a bundled `BailianSecrets.plist`, then `~/Library/Application Support/Clicky/BailianSecrets.plist`. The last path exists so the key is still found even if Xcode doesn't copy the loose plist into the bundle.

The `worker/` directory is kept for reference but is **not built or called** by the app.

### Key Architecture Decisions

**Menu Bar Panel Pattern**: The companion panel uses `NSStatusItem` for the menu bar icon and a custom borderless `NSPanel` for the floating control panel. This gives full control over appearance (dark, rounded corners, custom shadow) and avoids the standard macOS menu/popover chrome. The panel is non-activating so it doesn't steal focus. A global event monitor auto-dismisses it on outside clicks.

**Cursor Overlay**: A full-screen transparent `NSPanel` hosts the blue cursor companion. It's non-activating, joins all Spaces, and never steals focus. The cursor position, response text, waveform, and pointing animations all render in this overlay via SwiftUI through `NSHostingView`.

**Global Push-To-Talk Shortcut**: Background push-to-talk uses a listen-only `CGEvent` tap instead of an AppKit global monitor so modifier-based shortcuts like `ctrl + option` are detected more reliably while the app is running in the background.

**Shared URLSession for Streaming ASR**: A single long-lived `URLSession` is shared across all streaming transcription sessions (owned by the provider, not the session). Creating and invalidating a URLSession per session corrupts the OS connection pool and causes "Socket is not connected" errors after a few rapid reconnections.

**Provider teardown must never escape `self` out of `deinit`**: Every transcription provider serializes its mutable state on a private `stateQueue` and reaches it through `stateQueue.async { self… }`, so `cancel()` implicitly retains `self`. Calling `cancel()` from `deinit` therefore retains an object whose reference count has already reached zero. When that queued block is later released, the extra release over-releases `self` and the process dies with `EXC_BAD_ACCESS` inside `_Block_release` on the `stateQueue` thread. `BailianRealtimeTranscriptionSession` did exactly this and crashed immediately after every final transcript. `deinit` may only message objects directly (such as closing the websocket) — the owner calls `cancel()` explicitly on every teardown path.

**Normalized Point Coordinates**: Qwen's vision models rescale images internally before looking at them, so `[POINT:x,y:...]` values arrive on a 1000×1000 grid rather than in screenshot pixels. `CompanionManager.screenshotPixelCoordinate(fromNormalizedPoint:…)` performs the documented `value / 1000 × dimension` mapping before the display-point conversion. Skipping it fails silently, because a normalized value is indistinguishable from a plausible pixel coordinate — the cursor simply lands short.

**TTS Chunking**: Bailian's TTS endpoint documents a per-request character limit, so `BailianTTSClient` splits the response into sentence-aligned chunks, plays the first immediately, and queues the rest. This also means playback starts as soon as the first chunk's audio arrives rather than after the whole response is synthesized.

**TTS endpoint families are not interchangeable**: Bailian serves speech synthesis from two different routes and picking the wrong pairing fails with a misleading `InvalidParameter: url error, please check url` rather than anything that names the mismatch. Qwen-Audio-TTS / CosyVoice models (`qwen-audio-3.1-tts-flash`) live on `/api/v1/services/audio/tts/SpeechSynthesizer` and take `input.{text, voice, format, sample_rate}`; Qwen-TTS models (`qwen3-tts-flash`) live on `/api/v1/services/aigc/multimodal-generation/generation` and take `input.{text, voice, language_type}`. Voice names are model-family specific too — the Qwen-TTS name `Cherry` is rejected by Qwen-Audio-TTS with `[cosyvoice:]Engine error [411]`, whose correct voices are `yuxiaoyun_v3.1`, `yeqinghe_v3.1` and friends. Model, voice, body fields and path therefore have to move together. Alibaba's own list (`bl model code --model …`) is the way to tell which family a model belongs to: it emits the `tts_v2` websocket sample for Qwen-Audio-TTS and the HTTP sample for Qwen-TTS.

**A 403 on TTS speaks the apology, not the answer**: `speakCreditsErrorFallback()` reads a fixed Chinese apology through `NSSpeechSynthesizer` whenever the vision call or the TTS call throws, so a billing-side failure (`AllocationQuota.FreeTierOnly` — free quota exhausted with "use free tier only" still on in the Alibaba console) presents to the user as the companion repeating "抱歉，我这边出了点问题" no matter what they ask. The vision model is unaffected and answers correctly, which makes it look like a model problem when it is an account problem. Check the account before touching the pipeline.

**Transient Cursor Mode**: When "Show Clicky" is off, pressing the hotkey fades in the cursor overlay for the duration of the interaction (recording → response → TTS → optional pointing), then fades it out automatically after 1 second of inactivity.

## Key Files

| File | Lines | Purpose |
|------|-------|---------|
| `leanring_buddyApp.swift` | ~89 | Menu bar app entry point. Uses `@NSApplicationDelegateAdaptor` with `CompanionAppDelegate` which creates `MenuBarPanelManager` and starts `CompanionManager`. No main window — the app lives entirely in the status bar. |
| `CompanionManager.swift` | ~1084 | Central state machine. Owns dictation, shortcut monitoring, screen capture, the Qwen vision chat API, Bailian TTS, and overlay management. Tracks voice state (idle/listening/processing/responding), conversation history, model selection, and cursor visibility. Coordinates the full push-to-talk → screenshot → Qwen → TTS → pointing pipeline. |
| `MenuBarPanelManager.swift` | ~243 | NSStatusItem + custom NSPanel lifecycle. Creates the menu bar icon, manages the floating companion panel (show/hide/position), installs click-outside-to-dismiss monitor. |
| `CompanionPanelView.swift` | ~767 | SwiftUI panel content for the menu bar dropdown. Shows companion status, push-to-talk instructions, model picker (Plus/Flash), permissions UI, DM feedback button, and quit button. Dark aesthetic using `DS` design system. |
| `OverlayWindow.swift` | ~881 | Full-screen transparent overlay hosting the blue cursor, response text, waveform, and spinner. Handles cursor animation, element pointing with bezier arcs, multi-monitor coordinate mapping, and fade-out transitions. |
| `CompanionResponseOverlay.swift` | ~217 | SwiftUI view for the response text bubble and waveform displayed next to the cursor in the overlay. |
| `CompanionScreenCaptureUtility.swift` | ~132 | Multi-monitor screenshot capture using ScreenCaptureKit. Returns labeled image data for each connected display. |
| `BuddyDictationManager.swift` | ~868 | Push-to-talk voice pipeline. Handles microphone capture via `AVAudioEngine`, provider-aware permission checks, keyboard/button dictation sessions, transcript finalization, shortcut parsing, contextual keyterms, and live audio-level reporting for waveform feedback. |
| `BuddyTranscriptionProvider.swift` | ~82 | Protocol surface and provider factory for voice transcription backends. Resolves provider based on `VoiceTranscriptionProvider` in Info.plist — Bailian, AssemblyAI, OpenAI, or Apple Speech. |
| `BailianRealtimeTranscriptionProvider.swift` | ~602 | Streaming transcription provider. Opens a Bailian v3 realtime websocket, sends a `session.update`, streams base64 PCM16 audio in 100ms chunks, and delivers interim + final transcripts on key-up. Shares a single URLSession across all sessions. |
| `BailianConfiguration.swift` | ~86 | Reads `BailianAPIKey` / `BailianWorkspaceBaseURL` through `AppBundleConfiguration`, and declares the selectable vision-chat model IDs. |
| `BailianVisionChatAPI.swift` | ~316 | Qwen VL vision chat client with streaming (SSE) and non-streaming modes. Parses `delta.content` for text and `delta.reasoning_content` for thinking, tolerates the trailing usage-only frame whose `choices` array is empty, and detects image MIME types. |
| `BailianTTSClient.swift` | ~325 | Bailian TTS client. Splits text into sentence-aligned chunks, requests audio from the Qwen-Audio-TTS `SpeechSynthesizer` endpoint, and plays back via `AVAudioPlayer`. Exposes `isPlaying` for transient cursor scheduling. |
| `AssemblyAIStreamingTranscriptionProvider.swift` | ~478 | Unused fallback streaming provider kept from upstream. Fetches temp tokens from the retired Worker, opens an AssemblyAI v3 websocket, streams PCM16 audio. |
| `OpenAIAudioTranscriptionProvider.swift` | ~317 | Upload-based transcription provider. Buffers push-to-talk audio locally, uploads as WAV on release, returns finalized transcript. |
| `AppleSpeechTranscriptionProvider.swift` | ~147 | Local fallback transcription provider backed by Apple's Speech framework. |
| `BuddyAudioConversionSupport.swift` | ~108 | Audio conversion helpers. Converts live mic buffers to PCM16 mono audio and builds WAV payloads for upload-based providers. |
| `GlobalPushToTalkShortcutMonitor.swift` | ~132 | System-wide push-to-talk monitor. Owns the listen-only `CGEvent` tap and publishes press/release transitions. |
| `OpenAIAPI.swift` | ~142 | OpenAI GPT vision API client. |
| `ElementLocationDetector.swift` | ~335 | Detects UI element locations in screenshots for cursor pointing. |
| `DesignSystem.swift` | ~880 | Design system tokens — colors, corner radii, shared styles. All UI references `DS.Colors`, `DS.CornerRadius`, etc. |
| `WindowPositionManager.swift` | ~262 | Window placement logic, Screen Recording permission flow, and accessibility permission helpers. |
| `AppBundleConfiguration.swift` | ~85 | Runtime configuration reader. Checks the bundle Info dictionary, `Info.plist`, a bundled `BailianSecrets.plist`, then the Application Support copy. |
| `worker/src/index.ts` | ~142 | Retired Cloudflare Worker proxy, kept for reference only. |

## Build & Run

```bash
# Open in Xcode
open leanring-buddy.xcodeproj

# Select the leanring-buddy scheme, set signing team, Cmd+R to build and run

# Known non-blocking warnings: Swift 6 concurrency warnings,
# deprecated onChange warning in OverlayWindow.swift. Do NOT attempt to fix these.
```

**Do NOT run `xcodebuild` from the terminal** — it invalidates TCC (Transparency, Consent, and Control) permissions and the app will need to re-request screen recording, accessibility, etc.

### Code signing

The app target is set to **ad-hoc signing** (`CODE_SIGN_STYLE = Manual`, `CODE_SIGN_IDENTITY = "-"`, `DEVELOPMENT_TEAM = ""`) so it builds on a machine with no Apple Developer certificate.

Upstream shipped the app target pinned to `DEVELOPMENT_TEAM = 2UDAY4J48G`, which is the original author's team. On any other machine that fails before compiling with:

```
error: No signing certificate "Mac Development" found: No "Mac Development"
signing certificate matching team ID "..." with a private key was found.
```

Do not "fix" this by setting a team ID that isn't installed — with no certificate in the keychain, automatic signing fails for any team. Ad-hoc works because the app is not sandboxed and every entitlement it declares (`network.client`, `device.camera`, `device.audio-input`, the ScreenCaptureKit mach-lookup exception) is one that needs no provisioning profile.

Consequence to expect: an ad-hoc signature has no stable identity, so macOS keys TCC permissions off the binary hash and may re-ask for Screen Recording / Accessibility / Microphone after a rebuild. To get stable permissions, sign in with an Apple ID in Xcode → Settings → Accounts and switch the target back to automatic signing with that team.

## Bailian Secrets

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

## Cloudflare Worker (retired)

`worker/` is kept for reference. It is **not built and not called** — the app talks to Bailian directly.

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
- Do not run `xcodebuild` from the terminal — it invalidates TCC permissions

## Git Workflow

- Branch naming: `feature/description` or `fix/description`
- Commit messages: imperative mood, concise, explain the "why" not the "what"
- Do not force-push to main

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
