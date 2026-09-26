# Wanna

A macOS companion that lives in the notch. Press a shortcut, speak, and it answers
out loud — while looking at your screen, pointing at the things it mentions, and
acting on the machine when you ask it to.

No dock icon, no main window, no menu bar icon. The app is a black pill fused into
the hardware notch; a click expands it into its main sheet — sessions sidebar,
conversation, and the whole settings set.

## What it does

- **Voice in, voice out.** Push-to-talk records, a realtime model transcribes, a
  vision model answers, and a TTS model reads the answer back. Speaking over the
  answer interrupts it.
- **It looks at your screen.** Every question carries a screenshot, so "what's
  wrong with this error" works without pasting anything.
- **It points.** The model can fly the blue cursor to a UI element and label it,
  on any connected monitor.
- **It can act.** Clicking, scrolling, typing, key presses and opening apps run for
  real, as a step-by-step loop with a fresh screenshot between each step.
- **It can delegate.** Background agents run in a project folder of your choosing,
  report back, and show up as chips beside the notch.
- **Long-form recording.** A separate recorder transcribes hours of audio, rotating
  its connection so nothing is lost, and can rewrite the transcript through a model
  afterwards.

## Requirements

- macOS 14.2 or later (ScreenCaptureKit)
- Xcode 15 or later
- An [Alibaba Cloud Bailian / Model Studio](https://bailian.console.aliyun.com)
  account, or any provider that can serve the three roles described below

## Setup

### 1. Secrets

The app reads `BailianAPIKey` and `BailianWorkspaceBaseURL` from a plist that is
**not** committed to this repository. Create `Wanna/BailianSecrets.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>BailianAPIKey</key>
	<string>sk-your-key-here</string>
	<key>BailianWorkspaceBaseURL</key>
	<string>https://ws-xxxxxxxxxxxx.maas.aliyuncs.com</string>
</dict>
</plist>
```

Then put a copy outside the repository, so a clean checkout can never leave the app
without a key:

```bash
mkdir -p ~/Library/Application\ Support/Wanna
cp Wanna/BailianSecrets.plist ~/Library/Application\ Support/Wanna/BailianSecrets.plist
chmod 600 ~/Library/Application\ Support/Wanna/BailianSecrets.plist
```

The endpoint is the workspace-scoped host (`https://ws-….maas.aliyuncs.com`), **not**
the public `dashscope.aliyuncs.com` one. Both values are needed.

That plist is a **first-run seed only**: the first launch turns it into a provider
card, and after that the app's own settings own the configuration.

### 2. Build and run

```bash
cd /Users/mjm/Documents/SuperAgent/Wanna
xcodebuild -project Wanna.xcodeproj -scheme Wanna -configuration Debug build
```

The built app lands in Xcode's DerivedData. To launch the copy the app actually
runs from, install it to `/Applications`:

```bash
APP_DIR=$(xcodebuild -project Wanna.xcodeproj -scheme Wanna \
  -configuration Debug -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2}')
cp -R "$APP_DIR/Wanna.app" /Applications/
open /Applications/Wanna.app
```

Building from the Xcode GUI works too — only the relaunch matters, because macOS
will not swap code under a running process.

### 3. Permissions

On first launch the app raises all four prompts itself:

- **Microphone** — push-to-talk capture
- **Accessibility** — the global shortcut, and every action it takes on the machine
- **Screen Recording** — screenshots
- **Screen Content** — ScreenCaptureKit

The target is certificate-signed, which is what makes these survive a rebuild. An
ad-hoc signature would reset all four on every build, because that signature's
identity is the binary hash.

### 4. Models

Open the notch, then 设置 → 模型. Wanna needs three roles:

| Role | What it does | Default |
|---|---|---|
| 👂 `transcription` | Speech-to-text | `qwen3-asr-flash-realtime` |
| 🧠 `vision` | Looks at the screenshot and answers | `qwen3-vl-plus` |
| 👄 `speech` | Reads the answer aloud | `qwen-audio-3.1-tts-flash` |

Which provider serves each role — its URL, API key and model names — is yours to
set. The 测试连接 button tells you whether each one actually works before you rely
on it. Saves take effect immediately; nothing reads the configuration once at
launch.

## Architecture

The short version: a `CompanionManager` state machine owns the pipeline —
push-to-talk → screenshot → vision model (streaming SSE) → TTS playback → cursor
pointing → acting. A full-screen transparent `NSPanel` hosts the cursor overlay; a
second panel per notched screen is the notch itself.

The model speaks a small tag grammar. `[POINT:x,y:label:screenN]` moves the cursor,
where `x` and `y` are on a normalized 0–1000 grid rather than screenshot pixels.
`[CLICK:]`, `[SCROLL:]`, `[TYPE:]`, `[PRESS:]`, `[OPEN:]`, `[WAIT:]` and `[AX_TREE]`
do things for real, executed one per step with a fresh screenshot between steps.

The app talks to whichever provider you configured, directly — there is no proxy in
the request path.

`AGENTS.md` is the full technical reference and is kept current as the code changes:
every subsystem, every measured number, and the reason behind each non-obvious
decision. Read it before changing anything.

## Project layout

```
Wanna/                              # Swift source
  CompanionManager.swift               # Central state machine
  ActionTagParser.swift                # The tag grammar, and nothing else
  MacosUseController.swift             # The only file that imports MacosUseSDK
  NotchWindowController.swift          # The notch panel: expand, collapse, hit testing
  NotchActivityView.swift              # The resting pill, its wings and animations
  NotchSheetRootView.swift             # The expanded sheet's root
  OverlayWindow.swift                  # Cursor overlay: triangle, waveform, answer card
  AnswerCardView.swift                 # The reply card and its stream animation
  VoicePlaybackEngine.swift            # The one AVAudioEngine playback and capture share
  BuddyDictationManager.swift          # Push-to-talk and continuous listening
  LongFormRecorderController.swift     # The long-form recorder
  AgentSessionManager.swift            # The agent roster and turn pipeline
  AppSettings.swift / AppSettingsStore.swift   # Settings data and storage
  ModelConfiguration.swift / ModelConfigurationStore.swift  # The three model roles
  WorkspaceDirectory.swift             # Where the checkout is, and the four output folders
  DesignSystem.swift                   # Colour, radius and style tokens
Wanna.xcodeproj
AGENTS.md                           # Full architecture reference
开发经验/                            # What was learned building this, one doc per subsystem
解决方案/                            # One doc per solved problem, written as the full story
参考资料/                            # Research material kept beside the code, not in git
```

Four folders at the root are the app's own output rather than source — `Wanna录音/`
(recordings and transcripts), `Wanna图形/` (rendered figures), `Wanna复盘/` (review
reports) and `WannaAgents/` (the background agents' project roots). They sit beside the
code so a person can find them in one place, and they are gitignored because they are
runtime data: `Wanna录音/` alone is thousands of files. `WorkspaceDirectory` is the one
place that names them — moving the checkout is an edit there and nowhere else.

## Configuration lives outside the repo

Every stored setting is a JSON file under
`~/Library/Application Support/Wanna/`, written with `0600`:

| File | Holds |
|---|---|
| `ModelConfiguration.json` | The three roles, providers, URLs, keys, model names |
| `AppSettings.json` | Everything the settings pages write |
| `ConversationSessions.json` | The conversations themselves, when persistence is on |

They are not watched for changes, so editing one by hand takes effect after a
restart. Everything the settings pages change takes effect immediately.
