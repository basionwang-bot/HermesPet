<div align="center">

<img src="docs/banner.png" alt="HermesPet — Your AI desktop companion that lives under your MacBook's notch" width="100%" />

<img src="docs/app-icon.png" alt="HermesPet App Icon" width="128" height="128" />

# HermesPet 🐻‍❄️

**An AI chat client that lives under your MacBook's notch · Zero-dependency setup · Multi-engine parallel desktop AI companion**

[![Website](https://img.shields.io/badge/website-hermespet.cc-7B68EE?logo=safari&logoColor=white)](https://hermespet.cc)
[![macOS](https://img.shields.io/badge/macOS-14.0+-000000?logo=apple&logoColor=white)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-6.0-F05138?logo=swift&logoColor=white)](https://www.swift.org/)
[![Latest Release](https://img.shields.io/github/v/release/basionwang-bot/HermesPet?label=latest&color=success&logo=github)](https://github.com/basionwang-bot/HermesPet/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/basionwang-bot/HermesPet/total?label=downloads&color=blue)](https://github.com/basionwang-bot/HermesPet/releases)
[![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)

🌍 [中文](./README.md) · **English**

### 📦 [Download the latest DMG →](https://github.com/basionwang-bot/HermesPet/releases/latest)

### 🌐 [Visit the project site · hermespet.cc →](https://hermespet.cc)

Grab the macOS DMG · double-click to install · pick a provider, paste an API key — **no command-line tools required**

</div>

---

HermesPet is an AI chat client + desktop companion that lives **right below your MacBook's notch**.

**The most important thing**: it works out of the box. No CLI tools required on your machine. Open it → pick an AI provider (DeepSeek / Zhipu / Kimi / MiniMax / OpenAI, etc.) → paste an API Key → start chatting. If you also have `claude` / `codex` CLIs installed, the app auto-detects them and unlocks advanced capabilities like "read/write local files / run commands / generate images".

Tap the notch to summon the chat window, hold `⌘⇧V` to talk, drop files onto the little guy, watch Clawd wander around your desktop sniffing your files — desktop AI should feel alive.

> Swift 6 · SwiftUI · macOS 14+ · Pure native (no Electron / no Web view)

---

## ✨ Highlights

### 🔀 Four AI engines truly running in parallel (not just switching)

Each conversation **independently binds** to one AI backend and locks after the first message is sent. You can have, all at the same time:

- Conversation 1: ask **Online AI** (DeepSeek direct) to translate a tech doc
- Conversation 2: have **Claude Code** modify a SwiftUI component
- Conversation 3: get **Codex** to generate a poster

Up to **8 conversations** can be active simultaneously (`⌘1` ~ `⌘8` jump directly), each independently bound to a mode without cross-contamination. When switching conversations, the header's mode color/icon and the Dynamic Island sprite sync in real time.

### 🏔 Dynamic Island = OS-level status display

The capsule below the notch is not decoration:

- **Left ear** shows the "sprite" for the current mode (Hermes feather / Claude's Clawd / Codex magic wand / Online AI ☁️ cloud), pixel art
- **Right ear** displays task status in real time: rotating pulse → step count → file change count → Face ID-style stroke checkmark ✓
- **Hover → water-drop expansion**: the capsule flows down from the notch like a drop of water, showing the mode color + model name + recent reply preview. Hit zone strictly clipped to the hardware notch geometry — moving the cursor near the menu bar elsewhere on screen won't trigger it
- **Error state** turns the whole capsule amber + click to retry
- **Screenshot shutter** 0.18s white flash + scale bounce
- **Background conversation glow**: when one of your conversations is running in the background, the corresponding spot on the capsule pulses softly

### 🦞 Dual desktop pets · companions

Claude mode has **Clawd 🦞** (orange pixel crab); Online AI mode has **Cloud ☁️** (indigo pixel sprite). The two little critters wander around below the menu bar, blink, breathe, look left and right, and trot over when the cursor gets close — **cute by design**.

They're also useful:

- 🍽 **Drop a file on Clawd** → it chews and swallows → file auto-attaches to the current conversation + sends
- 👃 **Drag Clawd onto a desktop icon** → it stops and sniffs → AI generates a ≤10-character quip about the filename
- 🛡 Filenames pass through a local blocklist before reaching the AI (salary / contract / password / .env etc. are skipped)

### 🎙 Push-to-talk from any app

Hold `⌘⇧V`:

- An **Apple Intelligence-style colorful glow** appears at the screen edge (6-color AngularGradient, 4 seconds per rotation)
- Dynamic Island right ear pulses a red microphone
- Speech recognition uses **SFSpeechRecognizer** (macOS offline model)
- Release to auto-send; a "ding" sound plays when the AI finishes replying

### 📎 Drag files to AI · but the AI reads them itself

When you drop a document (PDF / txt / md / py / ts all work) **the app does not read the full content into context**, instead:

- Claude / Codex mode: appends the **absolute path** to the prompt, letting the AI use its own Read / Bash tools to read on demand
- The client only adds the file's parent directory to the `--add-dir` whitelist

Saves context, saves tokens, runs faster, and the AI gets to decide which parts to actually read.

### 💬 Multimodal · Multi-conversation · Cross-AI shared context

- Image paste / drag / screenshot / Codex generation — all supported
- Up to 8 conversations at once, `⌘N` / `⌘[` / `⌘]` / `⌘1-8` for quick switching
- When you switch modes, the entire conversation history gets passed to the new model — **memory is shared across AIs** (Claude can see what Hermes said earlier, and vice versa)
- Red dot on the capsule when a background conversation finishes

### 🎨 Refined details

- **Markdown rendering** with GFM tables (SwiftUI Grid column alignment + `:--/--:` alignment markers)
- **AI numbered lists auto-render as clickable cards** (`1. xxx\n2. yyy` → a row of cards, tap to send that option)
- **Pin desktop cards**: pin any AI response to the top-right of the desktop, single-click to bring it back into chat
- **Daily briefing**: AI reviews yesterday's activity and proactively gives you a markdown summary in the morning
- **Input bar strictly follows Apple HIG** (Capsule + 28pt round button + iMessage-style placeholder)
- **Optional Dock icon**: defaults to menubar-agent style (no Dock entry); flip a toggle to show the Dock icon and enter Cmd+Tab

### 🔄 Auto-update · One-click feedback

- **In-app auto-update**: 60s after launch + every 24h, checks GitHub Release for updates. New version found → 🔵 indicator in menubar. Click "Download & Install" → background DMG download → auto `hdiutil` mount → Finder window prompts you to drag into Applications (no Sparkle, no telemetry)
- **One-click crash reporting**: Settings → About auto-scans `~/Library/Logs/DiagnosticReports/` for HermesPet crashes. Click "Report to GitHub" → full log copied to clipboard + jumps to issue new page, paste & submit. **Zero backend, zero privacy concerns** — logs only go to the issue you see

---

## 🚀 Quick start

### Option A: Download the DMG (recommended, no Xcode needed)

1. Go to the [Releases page](https://github.com/basionwang-bot/HermesPet/releases) and download the latest `HermesPet-x.x.dmg`
2. Double-click the DMG → drag "Hermes 桌宠" into Applications
3. Right-click → Open (required once to bypass Gatekeeper, since it's ad-hoc signed)
4. Click ✦ in the menu bar → gear ⚙️ → AI Backend → **pick a provider from the dropdown** (DeepSeek / Zhipu / Kimi / MiniMax / OpenAI) → paste API Key → start chatting

No API Key yet? Each provider in the settings panel has a **"Get Key" link** that goes directly to its official signup page.

### Option B: Build from source (developers)

Requires macOS 14+ and Xcode Command Line Tools:

```bash
git clone https://github.com/basionwang-bot/HermesPet.git
cd HermesPet
./install.sh
```

`install.sh` will build → install to `/Applications/Hermes 桌宠.app` → launch.
An Apple Development certificate is recommended — TCC permissions stay stable that way.

### Advanced: unlock CLI modes (optional)

Both of these CLIs are **optional**. Installing them unlocks stronger capabilities (file read/write, command execution, image generation), but you can fully use the Online AI mode without them:

- **Claude Code**: [Official installation guide](https://docs.claude.com/en/docs/agents-and-tools/claude-code/overview)
- **OpenAI Codex**: [Official repository](https://github.com/openai/codex)

After installing, **restart HermesPet and the path is auto-detected** (on launch it runs `zsh -lic 'command -v ...'` once, which reads your real `PATH` as loaded by `~/.zshrc`). If detection fails, open the settings panel and click the "Re-detect" button on the corresponding mode's card.

### First-time permissions

| Permission | Trigger | Used for |
|---|---|---|
| Screen Recording | First `⌘⇧J` screenshot | ScreenCaptureKit |
| Microphone | First `⌘⇧V` | Recording |
| Speech Recognition | First `⌘⇧V` | SFSpeechRecognizer |
| Accessibility | Quick Ask reads selected text | AX API |
| Finder Automation | Enable "Clawd desktop patrol" | osascript reads desktop icons |

After granting any permission, it's recommended to **fully quit and reopen** (menu bar ✦ → Quit → reopen) so the new process picks up the permission.

---

## 🎯 Four AI Backends

| Mode | Icon | Best for | Setup |
|---|---|---|---|
| **Online AI** ⭐ | ☁ | Chat / translation / writing / vision — **zero dependencies, just works** | Pick a provider + paste API Key (DeepSeek / Zhipu / Kimi / MiniMax / OpenAI presets built in) |
| **Hermes** | ✦ | Chat tasks via a self-hosted OpenAI-compatible Gateway | Run [Hermes Gateway](https://github.com/NousResearch/hermes-gateway) or any compatible self-hosted API |
| **Claude Code** | ⌨ | File edits / running commands / deep coding | Install [`claude` CLI](https://docs.claude.com/en/docs/agents-and-tools/claude-code/overview) (optional) |
| **Codex** | ✨ | Image generation + code | Install OpenAI's Codex CLI + `codex login` (optional) |

Open chat → ⚙️ → AI Backend → fill in config. The four modes' configs are **stored fully independently**, and **new conversations inherit "the last mode you used" as default**.

New users default to "Online AI" mode, with a guide card on the welcome page that jumps straight to settings. When switching to Claude / Codex, if the corresponding CLI isn't detected, a toast pops up and that mode is skipped.

---

## ⌨️ Global hotkeys

| Combo | Function |
|---|---|
| `⌘⇧H` | Show / hide chat window |
| `⌘⇧J` | Capture current screen and attach to chat |
| `⌘⇧V` | Hold to talk, release to auto-send |
| `⌘⇧P` | Pin the latest AI reply of the current conversation to the desktop |
| `⌘⇧Space` | Spotlight-style quick-ask floating window |
| `⌘N` | New conversation (inside chat window) |
| `⌘[` / `⌘]` | Switch to previous / next conversation |
| `⌘1` / `⌘2` / `⌘3` | Jump directly to that conversation |
| `⌘⌫` | Close current conversation |

Hotkeys are registered via Carbon Event Manager and **trigger from any app**.

---

## 🧰 Build scripts

| Script | Purpose |
|---|---|
| `./build.sh` | Just build `.app` into `./HermesPet.app` (auto-picks certificate) |
| `./install.sh` | Build + install to `/Applications` + launch (**use this daily**) |
| `./make-dmg.sh` | Generate a distributable DMG (ad-hoc signed, recipient needs right-click → Open) |

---

## 📁 Project structure

```
Sources/
├── HermesPetApp.swift         # AppDelegate, coordinates controllers / global hotkeys
├── ChatViewModel.swift        # Multi-conversation state + streaming + persistence
├── ChatView.swift             # Main chat UI
├── ChatComponents.swift       # MessageBubble / input / SendButton
├── ChatWindowController.swift # Chat NSWindow expand/collapse animations
├── DynamicIslandController.swift # Notch capsule
├── ClawdWalkOverlay.swift     # Desktop Clawd + patrol + drag-to-sniff
├── PinCardOverlay.swift       # Desktop Pin cards
├── QuickAskWindow.swift       # Spotlight-style quick ask window
├── IntelligenceOverlay.swift  # AI glow during push-to-talk
├── VoiceInputController.swift # Recording + SFSpeechRecognizer
├── ScreenCapture.swift        # ScreenCaptureKit screenshotting
├── DesktopIconReader.swift    # osascript reads Finder desktop icon positions
├── APIClient.swift            # Hermes / Online AI HTTP streaming
├── ClaudeCodeClient.swift     # spawn claude -p
├── CodexClient.swift          # spawn codex exec + image capture
├── MarkdownRenderer.swift     # Custom Markdown (GFM tables + choice cards)
├── ActivityRecorder.swift     # User activity sampling (for the briefing)
├── MorningBriefingService.swift # Daily briefing generator
└── ...
```

Technical decision notes (gotchas / Swift 6 isolation / macOS 26 layout cycles) live in [CLAUDE.md](./CLAUDE.md). Roadmap in [TODO.md](./TODO.md).

---

## 🗂 Data storage / Privacy

| Path | Contents |
|---|---|
| `~/.hermespet/conversations.json` | All conversation history (without image Data) |
| `~/.hermespet/images/` | User-attached / Codex-generated image persistence |
| `~/.hermespet/pins.json` | Desktop Pin cards |
| `~/Library/Caches/HermesPet/` | Screenshot temp area + Clawd temp cache |

**Privacy boundary**:
- All AI calls go to backends you configure yourself (self-hosted Hermes / your Claude Code OAuth / your OpenAI account). The project itself does not phone home with any data.
- Clawd's desktop-patrol filenames go through a local blocklist before reaching Hermes (entries containing salary / contract / password / .env keywords are dropped entirely).
- Briefing data stays in a local SQLite database and never leaves the machine.

---

## 🤝 Come hang out

HermesPet is currently a one-person open-source project. Every issue / PR / star genuinely makes my day.

**Found a bug / something feels off / want a feature**: just open an [Issue](https://github.com/basionwang-bot/HermesPet/issues). Include your machine model + macOS version + repro steps and I'll get to it soon.

**Want to send a PR**: open an issue first to chat about the direction — saves both of us time if our visions don't line up. No strict style guide, just match the surrounding files.

**Like the project**: a ⭐ or sharing it with someone who might like it goes a long way — getting this in front of more people is the best reward this project could ask for.

---

## 📄 License

[Apache License 2.0](./LICENSE)

---

<div align="center">

Made with ✦, coffee, and stubborn love on a MacBook

*For everyone who's ever wished their AI felt a little more alive.*

</div>
