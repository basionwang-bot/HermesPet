<div align="center">

<img src="docs/banner.png" alt="HermesPet — 你的 AI 桌面伙伴，陪你工作，懂你所想" width="100%" />
# HermesPet 
<img src="docs/app-icon.png" alt="HermesPet App Icon" width="28" height="28" />

**让 AI 住在你 MacBook 的刘海里 · 零依赖开箱即用 · 多引擎并行的桌面 AI 伴侣**

[![Website](https://img.shields.io/badge/官网-hermespet.cc-7B68EE?logo=safari&logoColor=white)](https://hermespet.cc)
[![macOS](https://img.shields.io/badge/macOS-14.0+-000000?logo=apple&logoColor=white)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-6.0-F05138?logo=swift&logoColor=white)](https://www.swift.org/)
[![Latest Release](https://img.shields.io/github/v/release/basionwang-bot/HermesPet?label=最新版&color=success&logo=github)](https://github.com/basionwang-bot/HermesPet/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/basionwang-bot/HermesPet/total?label=下载量&color=blue)](https://github.com/basionwang-bot/HermesPet/releases)
[![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)

🌍 **中文** · [English](./README.en.md)

### 📦 [点这里下载最新版本 DMG →](https://github.com/basionwang-bot/HermesPet/releases/latest)

### 🌐 [访问项目主页 · hermespet.cc →](https://hermespet.cc)

直接拿 macOS DMG · 双击安装 · 选服务商粘 API Key 就能用，**不依赖任何命令行工具**

</div>

---

HermesPet 是一个常驻在 MacBook **顶部刘海下方**的 AI 聊天客户端 + 桌面伴侣。

**最重要的一点**：装上就能用，不需要在你电脑上装任何命令行工具。打开 → 选个 AI 服务商（DeepSeek / 智谱 / Kimi / OpenAI 等）→ 粘贴 API Key → 开聊。如果你额外装了 `claude` / `codex` CLI，App 会自动检测出来并解锁"读写本地文件 / 跑命令 / 生图"这些高级能力。

按一下刘海呼出聊天窗、按住 `⌘⇧V` 说话、拖文件给小家伙吃掉、让 Clawd 在桌面闲逛嗅你的文件 —— 桌面 AI 应当鲜活。

> Swift 6 · SwiftUI · macOS 14+ · 纯原生（无 Electron / 无 Web view）

---

## ✨ 核心亮点

### 🔀 四种 AI 真正并行（不只是切换）

每个对话**独立绑定**一个 AI 后端，发出第一条消息后锁定。你可以同时开：

- 对话 1：让 **在线 AI**（DeepSeek 直连）翻一段技术文档
- 对话 2：让 **Claude Code** 改一个 SwiftUI 组件
- 对话 3：让 **Codex** 生成一张海报

最多同时挂 **8 个对话**（`⌘1` ~ `⌘8` 直达），每个独立绑定 mode 不互相污染。切换对话时 header 的 mode 颜色和图标实时同步，灵动岛精灵也跟着切。

### 🏔 灵动岛 = 操作系统级状态显示

刘海下方那个胶囊不是装饰：

- **左耳**显示跟当前 mode 走的"精灵"（Hermes 羽毛 / Claude 的 Clawd / Codex 魔法棒 / 在线 AI ☁️ 云朵），像素风
- **右耳**实时显示任务状态：旋转脉冲 → 步骤数 → 文件变更数 → Face ID 风画线对勾 ✓
- **鼠标 hover → 水滴展开**：胶囊从刘海正下方像一滴水润下来，展示 mode 主色 + 模型名 + 最近回复预览。命中区严格收紧到硬件刘海几何，鼠标在屏幕中段贴近菜单栏不会误触发
- **错误态**整个胶囊切琥珀色 + 点击重试
- **截屏快门**0.18s 白色闪光 + scale 反弹
- **后台对话发光**：3 个对话其中之一在后台跑时，胶囊上对应的位置呼吸式微微发光

### 🦞 双桌宠 · 桌面伴侣

Claude 模式有 **Clawd 🦞**（橙色像素小螃蟹），在线 AI 模式有 **云朵 ☁️**（indigo 像素小精灵）。两个像素小家伙在菜单栏下方闲逛，会眨眼、呼吸、看左看右、被鼠标蹭一下小跑过来打招呼 —— **可可爱爱**。

也是有点用的：

- 🍽 **拖文件喂 Clawd** → 它嚼嚼吞下 → 文件自动作为附件附到当前对话发出去
- 👃 **拖 Clawd 到桌面图标** → 它在那儿停下嗅一嗅 → AI 给文件名一句 ≤10 字中文短评
- 🛡 文件名进 AI 前过本地黑名单（薪资 / 合同 / 密码 / .env 等敏感关键词整条跳过）

### 🎙 按住任意 app 说话（Push-to-Talk）

按住 `⌘⇧V`：

- 屏幕边缘出现 **Apple Intelligence 风格的彩色光环**（6 色 AngularGradient 4 秒一圈）
- 灵动岛右耳脉冲红色麦克风
- 中文识别走 **SFSpeechRecognizer**（macOS 离线模型）
- 松开自动发送，AI 回复完成有 "叮" 音效

### 📎 拖文件给 AI · 但 AI 自己读

拖入文档（PDF / txt / md / py / ts 都行）**不读全文塞 context**，而是：

- Claude / Codex 模式：把**绝对路径**拼到 prompt 末尾，让 AI 用自己的 Read / Bash 工具按需读取
- 客户端只负责把文件父目录加进 `--add-dir` 白名单

省 context、省 token、更快，且 AI 可以决定只读哪几段。

### 💬 多模态 · 多对话 · 跨 AI 共享上下文

- 图片粘贴 / 拖拽 / 截图 / Codex 生图 全部支持
- 同时最多 3 个对话，⌘N / ⌘[ / ⌘] / ⌘1-3 快速切换
- 切换 mode 时整个 conversation history 跟着传给新模型 —— **跨 AI 也能共享记忆**（让 Claude 看 Hermes 之前的回答，反之亦然）
- 后台对话完成时胶囊红点提醒

### 🎨 精致细节

- **Markdown 渲染**含 GFM 表格（SwiftUI Grid 列宽对齐 + `:--/--:` 对齐符）
- **AI 给编号列表自动转可点击卡片**（`1. xxx\n2. yyy` → 一组卡片，点哪个发哪个）
- **Pin 桌面卡片**：把任意 AI 回答钉到桌面右上角，单击转回聊天继续
- **每日早报**：AI 反向看你昨天的活动，早上主动给你一份 markdown 简报
- **输入栏严格按 Apple HIG**（Capsule + 28pt 圆按钮 + iMessage 风 placeholder）
- **Dock 图标可选**：默认菜单栏 agent 风格不占 Dock；设置里一键开启显示 Dock 图标 + 进入 Cmd+Tab

### 🔄 自动更新 · 一键反馈

- **应用内自动更新**：启动 60s 后 + 每 24h 自动检查 GitHub Release，有新版时菜单栏 🔵 提示。点「下载并安装」→ 后台拉 DMG → 自动 `hdiutil` 挂载 → Finder 弹窗引导拖到 Applications（不靠 Sparkle，不收集任何遥测）
- **崩溃一键上报**：设置「关于」自动扫描 `~/Library/Logs/DiagnosticReports/` 里的 HermesPet 崩溃文件，点「一键上报到 GitHub」→ 完整日志复制到剪贴板 + 跳转 issue new 页面，用户粘贴提交即可。**零后端、零隐私顾虑**，日志只发到你看到的 GitHub issue

---

## 🚀 快速开始

### 方式 A：下载 DMG 直接装（推荐，无需 Xcode）

1. 去 [Releases 页面](https://github.com/basionwang-bot/HermesPet/releases) 下载最新 `HermesPet-x.x.dmg`
2. 双击 DMG → 把"Hermes 桌宠"拖进应用程序
3. 右键打开（首次需要绕过 Gatekeeper，因为是 ad-hoc 签名）
4. 在菜单栏点 ✦ → 齿轮 ⚙️ → AI 后端 → **服务商下拉选一家**（DeepSeek / 智谱 / Kimi / OpenAI）→ 粘贴 API Key → 开聊

没有 API Key？设置面板里每个服务商旁都有一个**"获取 Key"链接**直达官方申请页。

### 方式 B：从源码构建（开发者）

需要 macOS 14+ 和 Xcode 命令行工具：

```bash
git clone https://github.com/basionwang-bot/HermesPet.git
cd HermesPet
./install.sh
```

`install.sh` 会构建 → 装到 `/Applications/Hermes 桌宠.app` → 启动。
推荐有 Apple Development 证书 —— TCC 权限永久稳定。

### 进阶：解锁 CLI 模式（可选）

下面这两个 CLI 都是**可选**的。装了能解锁更强能力（文件读写 / 跑命令 / 生图），不装也完全能用在线 AI 聊天：

- **Claude Code**：[官方安装指南](https://docs.claude.com/en/docs/agents-and-tools/claude-code/overview)
- **OpenAI Codex**：[官方仓库](https://github.com/openai/codex)

装好后**重启 HermesPet 自动检测路径**（启动时会跑一次 `zsh -lic 'command -v ...'`，能读到你 `~/.zshrc` 加载的真实 PATH）。如果检测不到，进设置面板对应 mode 的卡片点"重新检测"按钮即可。

### 首次授权

| 权限 | 触发时机 | 用途 |
|---|---|---|
| 屏幕录制 | 首次 `⌘⇧J` 截图 | ScreenCaptureKit |
| 麦克风 | 首次 `⌘⇧V` | 录音 |
| 语音识别 | 首次 `⌘⇧V` | SFSpeechRecognizer |
| Accessibility | 快问浮窗读选中文本 | AX API |
| Finder 自动化 | 开启"Clawd 桌面巡视" | osascript 读桌面图标 |

授权完任一权限后建议**完全退出再打开**（菜单栏 ✦ → 退出 → 重开），新进程才能读到权限。

---

## 🎯 四种 AI 后端

| Mode | 图标 | 适合场景 | 准备工作 |
|---|---|---|---|
| **在线 AI** ⭐ | ☁ | 对话 / 翻译 / 写作 / 看图 —— **零依赖，开箱即用** | 选服务商 + 填 API Key（DeepSeek / 智谱 / Kimi / OpenAI 内置预设） |
| **Hermes** | ✦ | 对话型任务，走自部署的 OpenAI 兼容 Gateway | 接 [Hermes Gateway](https://github.com/NousResearch/hermes-gateway) 或自部署兼容 API |
| **Claude Code** | ⌨ | 改文件 / 跑命令 / 深度编程 | 装 [`claude` CLI](https://docs.claude.com/en/docs/agents-and-tools/claude-code/overview)（可选） |
| **Codex** | ✨ | 生图 + 代码 | 装 OpenAI 官方 Codex CLI + `codex login`（可选） |

打开聊天 → ⚙️ → AI 后端 → 填配置。四个 mode 的配置**完全独立保存**，**新建对话时继承"上次用的"那个 mode 作为默认**。

新用户默认就在「在线 AI」模式，欢迎页有引导卡片直接跳设置。切到 Claude / Codex 时如果检测不到对应 CLI，会 toast 提示并跳过这一档。

---

## ⌨️ 全局快捷键

| 组合 | 功能 |
|---|---|
| `⌘⇧H` | 呼出 / 收回聊天窗口 |
| `⌘⇧J` | 截当前屏幕并附加到对话 |
| `⌘⇧V` | 按住说话，松开自动发送 |
| `⌘⇧P` | 把当前对话最新 AI 回复 Pin 到桌面 |
| `⌘⇧Space` | Spotlight 风快问浮窗 |
| `⌘N` | 新建对话（聊天窗内） |
| `⌘[` / `⌘]` | 切换上一个 / 下一个对话 |
| `⌘1` / `⌘2` / `⌘3` | 直接切到对应序号对话 |
| `⌘⌫` | 关闭当前对话 |

热键用 Carbon Event Manager 注册，在**任何 app 里都能触发**。

---

## 🧰 构建脚本

| 脚本 | 用途 |
|---|---|
| `./build.sh` | 仅构建 `.app` 到 `./HermesPet.app`（自动选证书） |
| `./install.sh` | 构建 + 装到 `/Applications` + 启动（**日常用这个**） |
| `./make-dmg.sh` | 生成给别人分发的 DMG（ad-hoc 签名，接收方需右键打开） |

---

## 📁 项目结构

```
Sources/
├── HermesPetApp.swift         # AppDelegate，统筹各 controller / 全局热键
├── ChatViewModel.swift        # 多对话状态 + 流式请求 + 持久化
├── ChatView.swift             # 聊天主界面
├── ChatComponents.swift       # MessageBubble / 输入框 / SendButton
├── ChatWindowController.swift # 聊天 NSWindow 展开/收回动画
├── DynamicIslandController.swift # 顶部刘海胶囊
├── ClawdWalkOverlay.swift     # 桌面 Clawd + 巡视 + 拖动嗅文件
├── PinCardOverlay.swift       # 桌面 Pin 卡片
├── QuickAskWindow.swift       # Spotlight 风快问浮窗
├── IntelligenceOverlay.swift  # 语音热键时的 AI 光环
├── VoiceInputController.swift # 录音 + SFSpeechRecognizer
├── ScreenCapture.swift        # ScreenCaptureKit 截屏
├── DesktopIconReader.swift    # osascript 读 Finder 桌面图标位置
├── APIClient.swift            # Hermes HTTP 流式
├── ClaudeCodeClient.swift     # spawn claude -p
├── CodexClient.swift          # spawn codex exec + 图片捕获
├── MarkdownRenderer.swift     # 自定义 Markdown（含 GFM 表格 + 选项卡片）
├── ActivityRecorder.swift     # 用户活动采集（给早报用）
├── MorningBriefingService.swift # 每日早报生成
└── ...
```

技术决策细节（踩过的坑 / Swift 6 isolation / macOS 26 layout cycle）见 [CLAUDE.md](./CLAUDE.md)。路线图见 [TODO.md](./TODO.md)。

---

## 🗂 数据存储 / 隐私

| 路径 | 内容 |
|---|---|
| `~/.hermespet/conversations.json` | 所有对话历史（不含图片 Data） |
| `~/.hermespet/images/` | 用户附图 / Codex 生图持久化 |
| `~/.hermespet/pins.json` | Pin 桌面卡片 |
| `~/Library/Caches/HermesPet/` | 截图临时区 + Clawd 临时缓存 |

**隐私边界**：
- 所有 AI 调用都走你自己配置的后端（Hermes 自托管 / Claude Code 你的 OAuth / Codex 你的 OpenAI 账号），项目本身不上送任何数据
- Clawd 桌面巡视的文件名进 Hermes 前过本地黑名单（薪资 / 合同 / 密码 / .env 等关键词整条丢弃）
- 早报数据全部在本地 SQLite，不出机器

---

## 🤝 欢迎一起来玩

HermesPet 还是个一个人维护的开源项目，每一个 issue / PR / star 都是真的能让我开心半天的那种支持。

**有 Bug / 用得不顺 / 想要某个功能**：直接开 [Issue](https://github.com/basionwang-bot/HermesPet/issues) 说说就行，描述清楚机型 + 系统版本 + 复现步骤，我会尽快看。

**想动手改代码**：开干前建议先开 issue 聊聊方向，避免做出来跟项目走向不一致白费力气。代码风格上没什么硬性要求，跟着现有文件写就好。

**用着觉得不错**：欢迎点个 star ⭐ 或者把它分享给可能感兴趣的朋友 —— 让更多人能用上是这个项目最大的成就感来源。

---

## 📄 License

[Apache License 2.0](./LICENSE)

---

<div align="center">

Made with ✦ on a MacBook · 桌面 AI 应当鲜活

</div>
