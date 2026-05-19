<div align="center">

<img src="docs/banner.png" alt="HermesPet — Your AI desktop companion that lives under your MacBook's notch" width="100%" />

<img src="docs/app-icon.png" alt="HermesPet App Icon" width="128" height="128" />

# HermesPet 🐻‍❄️

**An AI chat client living under your MacBook's notch · 5 parallel engines · 5 pixel pets keeping you company**

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

> ## 🛡️ Official Download Source
>
> HermesPet is independently developed and open-sourced by **[Basion (@basionwang-bot)](https://github.com/basionwang-bot)**.
>
> **The only official download source**: [github.com/basionwang-bot/HermesPet/releases](https://github.com/basionwang-bot/HermesPet/releases)
>
> Third parties have been re-uploading this project to personal cloud drives / secondary marketplaces / unrelated websites and impersonating the original author. **DMGs from anywhere outside the official channel are NOT guaranteed safe or authentic** — please download only from the GitHub Releases page above.
>
> After installation, check **Settings → About → Official Version Verification** inside the App for codesign verification (the authentic build shows the original author's Team ID `R34KL4X4D9`).
>
> If you spot impersonation or unauthorized distribution, please report via [GitHub Issues](https://github.com/basionwang-bot/HermesPet/issues).

---

<div align="center">

<sub>🌟 <b>Thanks to these friends who support HermesPet ❤️</b></sub>

<table>
<tr>
<td align="center" width="110">
<a href="https://afdian.com/a/basionwang"><img src="docs/sponsors/sponsor-01.jpg" width="56" height="56" alt="Anonymous supporter"/></a><br/>
<sub><b>Anonymous</b></sub>
</td>
<td align="center" width="110">
<a href="https://afdian.com/a/basionwang"><img src="docs/sponsors/sponsor-02.jpg" width="56" height="56" alt="Anonymous supporter"/></a><br/>
<sub><b>Anonymous</b></sub>
</td>
<td align="center" width="110">
<a href="https://afdian.com/a/basionwang"><img src="docs/sponsors/next-slot.svg" width="56" height="56" alt="Next?"/></a><br/>
<sub><i>You next?</i></sub>
</td>
</tr>
</table>

</div>

---

HermesPet is an AI chat client + desktop companion that lives **right below your MacBook's notch**.

**The most important thing**: it works out of the box. No CLI tools required on your machine. Open it → pick an AI provider (DeepSeek / Zhipu / Kimi / MiniMax / OpenAI / OpenClaw / your own cloud gateway) → paste an API Key → start chatting. If you also have `claude` / `codex` CLIs installed, the app auto-detects them and unlocks advanced capabilities like "read/write local files / run commands / generate images".

Tap the notch to summon the chat window, hold `⌘⇧V` to talk, drop files onto the little pet, watch fomo the nine-tailed fox wander around your desktop sniffing your files, see the Dynamic Island draw a Face ID-style checkmark ✓ when the AI is done — **desktop AI should feel alive**.

> Swift 6 · SwiftUI · macOS 14+ · Pure native (no Electron / no Web view) · Apache-2.0 open source

---

## ✨ Highlights

### 🔀 5 AI engines, truly running in parallel

Not switching — **truly in parallel**. Each conversation independently binds to one AI engine and locks after the first message. Run up to 8 conversations at once (`⌘1`~`⌘8` jumps instantly). Have Claude editing code, Online AI translating docs, and Codex generating an image — **all at the same time**. When a background conversation finishes, the corresponding spot on the Dynamic Island pulses softly so you don't have to babysit.

| Engine | Best for | Setup |
|---|---|---|
| ☁️ **Online AI** | DeepSeek / Zhipu / Kimi / MiniMax / OpenAI — just pick a provider and paste a Key | DMG ships with bundled opencode runtime, **zero dependencies** |
| ⚡ **OpenClaw** (new) | Gateway-style AI platform on your network | Install OpenClaw → HermesPet auto-detects + zero-config first connect |
| ✦ **Hermes Gateway** | Connect to **any OpenAI-compatible HTTP endpoint** (self-hosted / cloud / vLLM / Ollama — all work) | Fill in baseURL + Key |
| ⌨️ **Claude Code** | File edits / shell commands / deep coding | Install `claude` CLI (optional) |
| ✨ **Codex** | Code + native image generation | Install `codex` CLI (optional) |

**New users see only "Online AI" mode by default** (the simplest experience); the other four modes **auto-appear and unlock** when the matching tool is installed — no manual toggling required. Built for non-technical users from day one.

### 🦊 5 pixel pets · one per AI mode

Every AI mode gets its own **pixel-art pet** living in your menu bar:

| Pet | Mode | Vibe |
|---|---|---|
| 🦞 **Clawd** | Claude Code | Orange pixel crab, the OG — wanders the desktop sniffing your icons |
| ☁️ **Cloud** | Online AI | Indigo sprite, puts on glasses when you drop an image to inspect |
| 🦊 **fomo** | OpenClaw | Moonlight silver-white nine-tailed fox, with twitchy ears (new in v1.2.9) |
| 🐴 **Pegasus** | Hermes | Golden flying horse with mane fluttering in trot rhythm (new in v1.2.7) |
| ⌨️ **coco** | Codex | Iron Man-style pixel robot |

Pets aren't just decoration:

- 🍽 **Drop a file on the pet** → it chews and swallows → file auto-attaches to the current conversation
- 👃 **Drag the pet onto a desktop icon** → it stops and sniffs → AI generates a ≤10-character quip about the filename
- 🌀 **Cross-island teleport portal** (v1.2.7+): when the pet walks under the notch, a **pixel-art teleport portal** appears (octagonal frame + rotating star points + mode-color pulse) and the pet warps to the other side of the island
- 🛡 Filenames pass through a local blocklist before reaching the AI (salary / contract / password / .env etc. are dropped)

### 🏔 Dynamic Island = OS-level status display

The capsule below the notch is the **heart** of HermesPet:

- **Left ear** sprite follows the current mode in real time (5 independent animations)
- **Right ear** real-time tool status: rotating pulse → step count → file change count → **Face ID-style stroke checkmark ✓** on completion
- **Hover → water-drop expansion** — the capsule flows down from the notch like a drop of water, showing mode color + model name + recent reply preview
- 🛡 **Tool permission UI** (new in v1.2.4): when Claude / Codex wants to write a file, a black card pops out **flush below** the island with three buttons [Deny / Allow / Always Allow]. Visually seamless with the notch — feels like one piece
- 💬 **AI response summary card** (new in v1.2.7): when the chat window is closed, a summary card pops below the island for 8s after the AI finishes — never miss a reply you weren't watching for
- 🎙 **Live speech transcription**: when you hold `⌘⇧V`, a real-time transcript bar appears below the island
- ❌ **Error state** turns the whole capsule amber + click to retry
- 📸 **Screenshot shutter** 0.18s white flash + scale bounce
- 🌊 **Background conversation breathing**: when one of your 8 conversations is running in the background, the corresponding spot on the capsule pulses softly

### 🛡 Real-time tool permission confirmation (new in v1.2.4)

When Claude Code / Codex wants to write a file or run a command on your machine, **a card pops out flush below the Dynamic Island**:

- Shows the tool name + key arguments (which file? which command?)
- Three buttons: **Deny / Allow (once) / Always Allow (whitelist)**
- 0.8s feedback banner after decision (✓ Allowed / ✗ Denied / Added to whitelist)
- When the chat window is open, the UI hops into the PetHeaderStrip with the pet sprite shown in a "arms-up help-me" pose

**HermesPet won't decide for you.**

### 🎙 Push-to-talk from any app

Hold `⌘⇧V` from any app:

- 🌈 An **Apple Intelligence-style colorful glow** appears at the screen edge (6-color AngularGradient, 4s rotation)
- 🎤 Dynamic Island right ear pulses a red microphone
- 📝 Live Chinese transcription appears below the island
- 🔊 Speech recognition uses **SFSpeechRecognizer** (macOS offline model)
- 📤 Release to auto-send; a "ding" sound plays when the AI finishes replying

### 📎 Drag files to AI · AI reads them on demand

Not stuffing the whole PDF into context — **the AI decides which pages to read**:

- Drop a PDF / txt / md / py / ts file
- Claude / Codex mode: appends the **absolute path** to the prompt; AI uses its own Read / Bash tools to read on demand
- The client only adds the file's parent directory to the `--add-dir` whitelist
- Saves context, saves tokens, runs faster, and the AI can read just the relevant sections

Images support **four input paths**: clipboard paste / drag / `⌘⇧J` screenshot / Codex direct generation — multimodal in one breath.

### 💬 Multi-conversation · cross-AI shared context (signature feature)

- Up to **8 conversations** at once (`⌘N` new / `⌘[` `⌘]` switch / `⌘1`~`⌘8` jump)
- Each conversation **independently bound to a mode** — never any cross-contamination
- **When you switch a conversation's mode, the entire history gets passed to the new model** — Claude can keep going from what Hermes was discussing, and vice versa
- Red dot on the capsule when a background conversation finishes
- Top 8 rounded TabBar shows mini sprite + index + smart title derived from the first message

### 📋 AI task planner → dispatchable cards (a HermesPet exclusive)

Let the AI **plan tasks and dispatch them to the right AI**:

- You: "Help me list what to do today"
- AI replies with a ```` ```tasks ```` YAML block (each item has title / desc / **recommended mode** / eta)
- The client renders them as **actionable cards**, each with 3 buttons:
  - 📌 **Pin** — convert into a task Pin on the top-right of the desktop, with ✅ checkbox that strikes-through (doesn't disappear)
  - 🤖 **Let AI do it** — auto-create a new conversation in the recommended mode (Claude / Codex etc.) and send the task as the first message
  - ✗ **Skip** — local dismiss

Not just a chat client — a **task dispatch hub**.

### 📰 Daily briefing (it's watching while you sleep)

HermesPet quietly records what apps you used yesterday, what files you dropped, what you asked the AI (all data in local SQLite, sensitive keywords stripped at the source). In the morning, the AI reviews everything and gives you a Markdown briefing:

> You spent 4h in Xcode yesterday, asked Hermes 7 Swift questions, 3 of them about SwiftUI animation. Looks like you're tuning animations — want me to Pin yesterday's best solution to the desktop?

**All data stays on your machine.** Export to JSON / clear history / blocklist an app — one click each in settings.

### 🎨 Obsessive attention to detail

- **Markdown** full render (GFM tables + numbered lists auto-converted to clickable cards + code blocks with "copied" feedback)
- **Pin desktop cards**: pin any AI reply to the desktop, single-click brings it back into chat
- **Quick-ask window** (`⌘⇧Space` Spotlight-style) — ask a quick question without even opening the chat window
- **Input bar strictly follows Apple HIG** (Capsule + 28pt round button + iMessage placeholder + auto-expanding multi-line)
- **5 chat font sizes** (`⌘+` / `⌘-` / `⌘0` back to 100%)
- **Window pinning toggle** — 📌 in chat header switches between "always on top" and "normal window"
- **Optional Dock icon** — defaults to menubar-agent style; flip a toggle to show Dock + enter Cmd+Tab
- **5 event sounds**, each independently togglable, supports custom mp3/wav drop-in

### 🔄 Auto-update · authenticity verification · one-click feedback

- 🔄 **In-app auto-update**: 60s after launch + every 24h checks GitHub Release. New version → 🔵 indicator in menu bar. Click "Download & Install" → background DMG fetch → auto `hdiutil` mount → Finder prompts you to drag into Applications (**no Sparkle, no telemetry**)
- 🛡 **Official version verification** (new in v1.2.9): Settings → About → one-click codesign check; authentic build shows the original author's Team ID `R34KL4X4D9` (defeats third-party repackaging)
- 🚨 **One-click crash reporting**: auto-scan local crash logs → copy full log to clipboard + open GitHub Issue page; you paste & submit (**zero backend, zero privacy concerns**)

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

### Advanced: unlock more AI engines (all optional)

All four advanced engines are **optional**. Installing them unlocks stronger capabilities; you can fully use the Online AI mode without any of them:

| Engine | Install command | Unlocks |
|---|---|---|
| **OpenClaw** | `npm i -g openclaw@latest && openclaw onboard --install-daemon` | Gateway-style AI platform + multi-model aggregation |
| **Hermes Gateway** | Self-host any OpenAI-compatible API (or fill in a cloud baseURL) | Connect to your company's internal LLM / vLLM / Ollama |
| **Claude Code** | [Official installation guide](https://docs.claude.com/en/docs/agents-and-tools/claude-code/overview) | File read/write + shell commands + deep coding |
| **OpenAI Codex** | [Official repository](https://github.com/openai/codex) | Image generation + multi-image vision + code |

After installing, **restart HermesPet and the path is auto-detected** (on launch it runs `zsh -lic 'command -v ...'`, which reads your real `PATH` as loaded by `~/.zshrc`). If detection fails, open the settings panel and click "Re-detect" on the corresponding mode's card.

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

## 🎯 5 AI Engines · Deep dive

| Mode | Icon | Best for | Setup |
|---|---|---|---|
| **Online AI** ⭐ | ☁ | Chat / translation / writing / vision — **zero dependencies, just works** | Pick a provider + paste API Key (DeepSeek / Zhipu / Kimi / MiniMax / OpenAI presets built in; DMG ships with bundled opencode runtime that handles SSE / reasoning filtering / tool calling) |
| **OpenClaw** ⚡ | ⚡ | Gateway-style AI platform on your network — new in v1.2.9 | Install [OpenClaw](https://openclaw.ai) (one-line npm) → HermesPet **auto-detects daemon + auto-enables chatCompletions endpoint + zero-config first connect** |
| **Hermes Gateway** | ✦ | Connect to **any OpenAI-compatible HTTP endpoint** (self-hosted / cloud / vLLM / Ollama / internal company LLM platform — all work) | Fill in baseURL + Key. **New in v1.2.x: 3 preset levels** (local / self-hosted / custom); model Picker auto-pulls from `/v1/models` |
| **Claude Code** | ⌨ | File edits / shell commands / deep coding / full tool calling | Install [`claude` CLI](https://docs.claude.com/en/docs/agents-and-tools/claude-code/overview) (optional) |
| **Codex** | ✨ | Image generation + code (native Codex CLI with multi-image support) | Install [OpenAI Codex CLI](https://github.com/openai/codex) + `codex login` (optional) |

Open chat → ⚙️ → AI Backend → fill in config. **All 5 modes' configs are stored fully independently**, and **new conversations inherit "the last mode you used"**.

🆕 **v1.2.9 hidden-by-default + auto-detection**: new users see only "Online AI" mode (cleanest); the other 4 modes **auto-detect their tools and become enableable** when you install them. Already-enabled modes can be toggled off in settings — **user intent always wins over auto-detection**.

### Online AI built-in provider presets

Zero-config switching between six mainstream LLM providers, each with **3-level response preference** (fast / balanced / deep) auto-mapped to the right model:

| Provider | Default model | Sign up |
|---|---|---|
| DeepSeek | deepseek-chat | [platform.deepseek.com](https://platform.deepseek.com) |
| Zhipu GLM | glm-4-flash | [open.bigmodel.cn](https://open.bigmodel.cn) |
| Moonshot Kimi | moonshot-v1-8k | [platform.moonshot.cn](https://platform.moonshot.cn) |
| MiniMax | MiniMax-M2.7 | [platform.minimaxi.com](https://platform.minimaxi.com) |
| OpenAI | gpt-4o-mini | [platform.openai.com](https://platform.openai.com) |
| Custom | You decide | Any OpenAI-compatible endpoint |

Each provider's **API Key is stored separately** (no cross-contamination across providers); switching providers auto-fills the matching baseURL. **5 minutes from install to first chat.**

---

## ⌨️ Keyboard shortcuts

**Global hotkeys** (registered via Carbon Event Manager, trigger from any app):

| Combo | Function |
|---|---|
| `⌘⇧H` | Show / hide chat window |
| `⌘⇧J` | Capture current screen and attach to chat |
| `⌘⇧V` | Hold to talk, release to auto-send |
| `⌘⇧P` | Pin the latest AI reply of the current conversation to the desktop |
| `⌘⇧Space` | Spotlight-style quick-ask floating window |

**In-window shortcuts** (active when the chat window is focused):

| Combo | Function |
|---|---|
| `⌘N` | New conversation |
| `⌘[` / `⌘]` | Switch to previous / next conversation |
| `⌘1` ~ `⌘8` | Jump directly to that conversation |
| `⌘⌫` | Close current conversation |

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
Sources/  (~60 .swift files, organized by responsibility)
├── HermesPetApp.swift             # AppDelegate, coordinates controllers / global hotkeys
├── ChatViewModel.swift            # Multi-conversation state + streaming + persistence
├── ChatView.swift                 # Main chat UI (header / messages / TabBar)
├── DynamicIslandController.swift  # Notch capsule (decision #1: never setFrame)
├── PermissionWindowController.swift # Tool permission UI (flush below island)
├── ResponseSummaryWindowController.swift # AI reply summary card (when chat is closed)
├── PetHeaderStrip.swift           # 28pt pet status strip atop the chat window
├── ClawdWalkOverlay.swift         # Desktop pixel pet walk + sniff + teleport
├── TeleportPortal.swift           # Cross-island pixel-art teleport animation
├── FomoSprite.swift               # 🦊 OpenClaw nine-tailed fox sprite
├── ModeSprite.swift               # Clawd / Cloud / Pegasus / coco sprites
├── PinCardOverlay.swift           # Desktop Pin cards
├── QuickAskWindow.swift           # Spotlight-style quick-ask window
├── IntelligenceOverlay.swift      # AI glow during push-to-talk
├── VoiceInputController.swift     # Recording + SFSpeechRecognizer (Chinese)
├── VoiceTranscriptOverlay.swift   # Live transcript bar below the island
├── ScreenCapture.swift            # ScreenCaptureKit screenshotting
├── APIClient.swift                # OpenAI-compatible HTTP streaming (shared by Hermes / Online AI / OpenClaw)
├── OpenClawGatewayManager.swift   # OpenClaw daemon auto-detect + zero-config first connect
├── OpenCodeServerManager.swift    # Bundled opencode runtime manager
├── ClaudeCodeClient.swift         # spawn claude -p
├── CodexClient.swift              # spawn codex exec + image capture
├── MarkdownRenderer.swift         # GFM tables + task planner cards + choice cards
├── ActivityRecorder.swift         # Local activity sampling (briefing data source)
├── MorningBriefingService.swift   # Daily briefing generator
├── CodeSignVerifier.swift         # Official version verification (v1.2.9 anti-piracy)
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
| `~/.hermespet/activity.sqlite` | Activity sampling + user intent records (briefing data source) |
| `~/Library/Caches/HermesPet/` | Screenshot temp area + pet temp cache |
| `~/Library/Application Support/HermesPet/opencode-global/` | Bundled opencode runtime working dir (Online AI mode) |

**Privacy boundary** (HermesPet makes "no data collection" a hard constraint):

- 🛡 **Zero telemetry**: the project itself does NOT phone home to any backend. All AI calls go to backends you configure yourself (your API Key / your self-hosted Gateway / your local CLI)
- 🛡 **Desktop patrol blocklist**: filenames pass through a local blocklist before reaching the AI (salary / contract / password / `.env` / `credentials` keywords are dropped entirely)
- 🛡 **Activity sampling stays local**: all daily briefing data lives in a local SQLite database and **never leaves your machine**; one-click export to JSON / clear history / blocklist an app in settings
- 🛡 **Official version verification**: Settings → About → one-click codesign check (Team ID `R34KL4X4D9`) to defeat third-party repackaging
- 🛡 **Crash logs**: HermesPet scans local crash files → copies the full log to clipboard → **you** manually paste into GitHub Issue. HermesPet does not auto-upload anything.

---

## 🤝 Come hang out

HermesPet is currently a one-person open-source project. Every issue / PR / star genuinely makes my day.

**Found a bug / something feels off / want a feature**: just open an [Issue](https://github.com/basionwang-bot/HermesPet/issues). Include your machine model + macOS version + repro steps and I'll get to it soon.

**Want to send a PR**: open an issue first to chat about the direction — saves both of us time if our visions don't line up. No strict style guide, just match the surrounding files.

**Like the project**: a ⭐ or sharing it with someone who might like it goes a long way — getting this in front of more people is the best reward this project could ask for.

---

## ☕ Buy me a coffee

If HermesPet has been useful to you, you're welcome to [**buy me a coffee on Afdian · afdian.com/a/basionwang**](https://afdian.com/a/basionwang) (the Chinese equivalent of Buy Me a Coffee).

Sponsorships help cover the hard costs (Apple Developer fee, LLM API testing tokens, servers) and let this independent project keep going. No pressure though — a ⭐ or sharing the project with friends is equally meaningful support.

> 💡 Want to use HermesPet inside your company, or customize it as your branded macOS AI tool? Email me: [basionwang@gmail.com](mailto:basionwang@gmail.com)

---

## 📄 License

[Apache License 2.0](./LICENSE)

---

## ⭐ Star History

[![Star History Chart](https://api.star-history.com/svg?repos=basionwang-bot/HermesPet&type=Date)](https://star-history.com/#basionwang-bot/HermesPet&Date)

---

<div align="center">

Made with ✦, coffee, and stubborn love on a MacBook

*For everyone who's ever wished their AI felt a little more alive.*

</div>
