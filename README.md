Update: April 27, 2026.

Hi there! I'm Farza, the guy that made Clicky.

The existing codebase remains open source. Tinker with it, make it yours, start a company out of it, do whatever you want I don't mind. But, for all the new stuff I'm hacking on, gonna keep it private. To get the latest Clicky, you can go [here](https://www.heyclicky.com/).

I also tweeted about this [here](https://x.com/FarzaTV/status/2043402737828962489).

Go crazy with this repo!! It's an MIT license.

# Hi, this is Clicky.
It's an AI teacher that lives as a buddy next to your cursor. It can see your screen, talk to you, and even point at stuff. Kinda like having a real teacher next to you.

Download it [here](https://www.clicky.so/) for free.

Here's the [original tweet](https://x.com/FarzaTV/status/2041314633978659092) that kinda blew up for a demo for more context.

![Clicky — an ai buddy that lives on your mac](clicky-demo.gif)

This is the open-source version of Clicky for those that want to hack on it, build their own features, or just see how it works under the hood.

## Get started with Claude Code

The fastest way to get this running is with [Claude Code](https://docs.anthropic.com/en/docs/claude-code).

Once you get Claude running, paste this:

```
Hi Claude.

Clone https://github.com/farzaa/clicky.git into my current directory.

Then read the CLAUDE.md. I want to get Clicky running locally on my Mac.

Help me set up my Bailian API key and endpoint, then get it building in Xcode. Walk me through it.
```

That's it. It'll clone the repo, read the docs, and walk you through the whole setup. Once you're running you can just keep talking to it — build features, fix bugs, whatever. Go crazy.

## Manual setup

If you want to do it yourself, here's the deal.

### Prerequisites

- macOS 14.2+ (for ScreenCaptureKit)
- Xcode 15+
- An [Alibaba Cloud Bailian / Model Studio](https://bailian.console.aliyun.com) account with an API key

### 1. Get your Bailian API key and workspace endpoint

In the Bailian console, create an API key and note your workspace-scoped endpoint. It looks like `https://ws-xxxxxxxxxxxx.maas.aliyuncs.com` — **not** the public `dashscope.aliyuncs.com` host. Both the key and the endpoint are needed; every request the app makes goes to that host.

### 2. Install the secrets file

The app reads `BailianAPIKey` and `BailianWorkspaceBaseURL` from a plist that is **not** committed to this repo. Create `leanring-buddy/BailianSecrets.plist`:

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

Then put a copy outside the repo so a clean checkout can't leave the app without a key:

```bash
mkdir -p ~/Library/Application\ Support/Clicky
cp leanring-buddy/BailianSecrets.plist ~/Library/Application\ Support/Clicky/BailianSecrets.plist
chmod 600 ~/Library/Application\ Support/Clicky/BailianSecrets.plist
```

`AppBundleConfiguration` looks in the app bundle first and falls back to that Application Support copy, so it works either way. Never commit `BailianSecrets.plist` — it's in `.gitignore`.

### 3. Open in Xcode and run

```bash
open leanring-buddy.xcodeproj
```

In Xcode:
1. Select the `leanring-buddy` scheme (yes, the typo is intentional, long story)
2. Set your signing team under Signing & Capabilities
3. Hit **Cmd + R** to build and run

The app will appear in your menu bar (not the dock). Click the icon to open the panel, grant the permissions it asks for, and you're good.

### 4. Choose your models (optional)

Click the **gear icon** in the menu bar panel to open 模型设置. It shows the three models Clicky uses — 👂 speech-to-text, 🧠 vision, 👄 text-to-speech — and lets you change which provider serves each one, along with its URL, API key and model name. Anything OpenAI-compatible works for 🧠, including DeepSeek; 👂 and 👄 need a provider that offers streaming speech recognition and synthesis, which today means Bailian. There's a **测试连接** button that tells you whether each one actually works before you rely on it, and **保存** takes effect immediately — no restart.

The plist from step 2 still works: it seeds the first-run configuration, so a fresh install with a valid `BailianSecrets.plist` needs no setup at all. Once you've saved anything in the settings window, that window becomes the source of truth.

### Permissions the app needs

- **Microphone** — for push-to-talk voice capture
- **Accessibility** — for the global keyboard shortcut (Control + Option)
- **Screen Recording** — for taking screenshots when you use the hotkey
- **Screen Content** — for ScreenCaptureKit access

## Architecture

If you want the full technical breakdown, read `CLAUDE.md`. But here's the short version:

**Menu bar app** (no dock icon) with two `NSPanel` windows — one for the control panel dropdown, one for the full-screen transparent cursor overlay. Push-to-talk streams audio over a websocket to a realtime ASR model, sends the transcript + screenshot to a vision model via streaming SSE, and plays the response through a TTS model. The model can embed `[POINT:x,y:label:screenN]` tags in its responses to make the cursor fly to specific UI elements across multiple monitors. Every request goes straight to the provider you configured — no proxy in between.

All three models are configurable in the settings window (gear icon in the panel), and the configuration is read fresh on every request, so changing a model takes effect on your next question.

## Project structure

```
leanring-buddy/          # Swift source (yes, the typo stays)
  CompanionManager.swift    # Central state machine
  CompanionPanelView.swift  # Menu bar panel UI
  ModelSettingsView.swift   # Model settings form
  ModelConfiguration.swift  # Provider/role data model
  ModelConfigurationStore.swift  # Reads + writes the saved configuration
  BailianVisionChatAPI.swift      # Vision streaming client
  BailianTTSClient.swift          # Text-to-speech playback
  BailianConfiguration.swift      # Model resolution + defaults
  BailianRealtime*.swift          # Real-time transcription
  OverlayWindow.swift       # Blue cursor overlay
  BuddyDictation*.swift     # Push-to-talk pipeline
worker/                  # Retired Cloudflare Worker proxy (kept for reference)
CLAUDE.md                # Full architecture doc (agents read this)
```

## Contributing

PRs welcome. If you're using Claude Code, it already knows the codebase — just tell it what you want to build and point it at `CLAUDE.md`.

Got feedback? DM me on X [@farzatv](https://x.com/farzatv).
