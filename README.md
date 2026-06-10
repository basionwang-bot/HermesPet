<div align="center">

<img src="docs/banner.png" alt="HermesPet — 你的 AI 桌面伙伴，陪你工作，懂你所想" width="100%" />

# HermesPet 
<img src="docs/app-icon.png" alt="HermesPet App Icon" width="28" height="28" />

**让 AI 住在你 MacBook 的刘海里 · 6 种引擎并行 · 6 只像素桌宠陪你工作**

[![Website](https://img.shields.io/badge/官网-hermespet.cc-7B68EE?logo=safari&logoColor=white)](https://hermespet.cc)
[![macOS](https://img.shields.io/badge/macOS-14.0+-000000?logo=apple&logoColor=white)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-6.0-F05138?logo=swift&logoColor=white)](https://www.swift.org/)
[![Latest Release](https://img.shields.io/github/v/release/basionwang-bot/HermesPet?label=最新版&color=success&logo=github)](https://github.com/basionwang-bot/HermesPet/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/basionwang-bot/HermesPet/total?label=下载量&color=blue)](https://github.com/basionwang-bot/HermesPet/releases)
[![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)

🌍 **中文** · [English](./README.en.md)

### 📦 [点这里下载最新版本 DMG →](https://github.com/basionwang-bot/HermesPet/releases/latest)

### 🌐 [访问项目主页 · hermespet.cc →](https://hermespet.cc)

直接拿 macOS DMG · **双击安装即可打开**（已 Apple 公证）· 选服务商粘 API Key 就能用，**不依赖任何命令行工具**

<sub>💡 推荐下载上方官方签名 DMG（免编译、双击即用、权限稳定）· 🤖 AI 助手安装请参考 [AGENTS.md](AGENTS.md)</sub>

</div>

---

> ## 🛡️ 官方声明 · 认准唯一正版来源
>
> HermesPet 由 **[Basion Wang (@basionwang-bot)](https://github.com/basionwang-bot)** 从 2024 年 10 月起独立设计、开发并持续维护至今。所有提交记录、版本发布历史均可在本仓库验证。
>
> ⚠️ 近期发现多起第三方**复制改名、冒充原作者、在网盘 / 二手平台分发修改版**的行为。**官方渠道之外的版本一律不保证安全**，可能被植入恶意代码。
>
> | 官方渠道 | 地址 | 用途 |
> |---|---|---|
> | 🌐 官网 | [hermespet.cc](https://hermespet.cc) | 产品介绍、版本信息 |
> | 📦 仓库 | [github.com/basionwang-bot/HermesPet](https://github.com/basionwang-bot/HermesPet) | 源码、Issues |
> | 📥 下载 | [GitHub Releases](https://github.com/basionwang-bot/HermesPet/releases) | **唯一安全下载源** |
> | 📧 联系 | [basionwang@gmail.com](mailto:basionwang@gmail.com) | 合作、举报 |
>
> **如何验证正版**：从 GitHub Releases 下载 → 设置 → 关于 → **官方版本验证**，正版会显示原作者 Team ID **`R34KL4X4D9`**。验证失败请立即删除重新下载。
>
> 发现盗用请通过 [Issues 盗用举报模板](https://github.com/basionwang-bot/HermesPet/issues/new?template=plagiarism_report.md) 或邮件举报，我们会采取包括 **DMCA Takedown** 在内的法律手段。

---

<div align="center">

<sub>🌟 <b>感谢这些朋友支持 HermesPet ❤️</b></sub>

<table>
<tr>
<td align="center" width="110">
<img src="docs/sponsors/sponsor-01.jpg" width="56" height="56" alt="匿名朋友"/><br/>
<sub><b>匿名</b></sub>
</td>
<td align="center" width="110">
<img src="docs/sponsors/sponsor-02.jpg" width="56" height="56" alt="匿名朋友"/><br/>
<sub><b>匿名</b></sub>
</td>
<td align="center" width="110">
<img src="docs/sponsors/next-slot.svg" width="56" height="56" alt="下一位"/><br/>
<sub><i>下一位？</i></sub>
</td>
</tr>
</table>

</div>

---

HermesPet 是一个常驻在 MacBook **顶部刘海下方**的 AI 聊天客户端 + 桌面伴侣。

**最重要的一点**：装上就能用，不需要在你电脑上装任何命令行工具。打开 → 选个 AI 服务商（DeepSeek / 智谱 / Kimi / MiniMax / OpenAI / OpenClaw / 你自己的云端 Gateway）→ 粘贴 API Key → 开聊。如果你额外装了 `claude` / `codex` CLI，App 会自动检测出来并解锁"读写本地文件 / 跑命令 / 生图"这些高级能力。

按一下刘海呼出聊天窗、按住 `⌘⇧V` 说话、拖文件给小家伙吃掉、让 fomo 小狐狸在桌面闲逛嗅你的文件、AI 完成任务时灵动岛右耳画一个 Face ID 风的对勾 ✓ —— **桌面 AI 应当鲜活**。界面现已支持**中文 / English 一键即时切换**。

> Swift 6 · SwiftUI · macOS 14+ · 纯原生（无 Electron / 无 Web view） · Apache-2.0 开源

---

## ✨ 核心亮点

### 🔀 6 种 AI 引擎，真正同时跑

不是切换，是**真正并行**。每个对话独立绑定一个 AI 引擎，第一条消息发出后锁定，最多挂 8 个对话同时跑（`⌘1`~`⌘8` 秒切）。你可以一边让 Claude 改代码、一边让在线 AI 翻译文档、一边等 Codex 生图 —— **后台跑完时灵动岛对应位置呼吸发光提醒**，不用守着屏幕。

| 引擎 | 适用 | 准备 |
|---|---|---|
| ☁️ **在线 AI** ⭐ | DeepSeek / 智谱 / Kimi / MiniMax / OpenAI —— 一键选服务商粘 Key | DMG 内嵌 opencode runtime，**零依赖开箱即用** |
| ⚡ **OpenClaw** | 局域网网关式 AI 平台接入 | 装 [OpenClaw](https://openclaw.ai)（npm 一行）→ 自动检测 + 零配置首连 |
| ✦ **Hermes Gateway** | 接任何 **OpenAI 兼容 HTTP 端点**（自部署 / 云端 / vLLM / Ollama） | 填 baseURL + Key，内置三档 preset，模型从 `/v1/models` 自动拉 |
| ⌨️ **Claude Code** | 改文件 / 跑命令 / 深度编程 | 装 [`claude` CLI](https://docs.claude.com/en/docs/agents-and-tools/claude-code/overview)（可选） |
| ✨ **Codex** | 写代码 + 原生生图（多图视觉） | 装 [`codex` CLI](https://github.com/openai/codex)（可选） |
| 🧩 **QwenCode** | 通义千问 qwen 用户**零 Key 零配置**（复用终端登录态） | 装 `qwen` CLI 并登录 → 自动检测解锁 |

**新用户默认只见"在线 AI"模式**（最简单），其他五个 mode 装好对应工具后**自动检测并解锁**，不需要手动开关 —— 小白也能用。**用户的意图永远 > 自动检测**，启用过的 mode 可随时在设置里独立关掉。

### 🦊 6 只像素桌宠 · 跟着 mode 切

每个 AI 模式都有自己的**专属像素桌宠**，活在你菜单栏底下：

| 桌宠 | 所属 mode | 性格 |
|---|---|---|
| 🦞 **Clawd** | Claude Code | 橙色像素小螃蟹，最早一只，爱在桌面闲逛嗅图标 |
| ☁️ **云朵** | 在线 AI | indigo 小精灵，戴眼镜认真看你拖的图 |
| 🦊 **fomo** | OpenClaw | 月光银白九尾狐，灵动的大耳朵抖个不停 |
| 🐴 **Pegasus** | Hermes | 金黄飞马，四脚 trot 步态 + 鬃毛随风 |
| ⌨️ **coco** | Codex | 钢铁侠风像素小机器人 |
| 👓 **小青怪** | QwenCode | 青绿色、戴黑框圆眼镜的小怪兽，零配置接入 qwen |

桌宠不只是装饰：

- 🍽 **拖文件给桌宠** → 它嚼嚼吞下 → 文件自动作为附件发到当前对话
- 👃 **拖桌宠到桌面图标** → 它停下嗅一嗅 → AI 给文件名一句 ≤10 字短评
- 🌀 **跨灵动岛传送门**：桌宠走到刘海下方触发**像素艺术风传送门动画**（八边形门框 + 旋转星点 + mode 主色脉冲），从灵动岛另一侧穿出
- 🛡 文件名进 AI 前过本地黑名单（薪资 / 合同 / 密码 / `.env` 等敏感词整条跳过）

### 🏔 灵动岛 = 操作系统级状态显示（含工具权限确认）

刘海下方那个胶囊**不是装饰**，是 HermesPet 真正的"心脏"：

- **左耳** 桌宠精灵跟当前 mode 实时切（6 只独立动画）
- **右耳** 工具运行实时状态：旋转脉冲 → 步骤数 → 文件变更数 → 完成时 **Face ID 风格画线对勾 ✓**
- **鼠标 hover 像水滴展开** —— 胶囊从刘海正下方润下来，展示 mode 主色 + 模型名 + 最近回复预览
- 🛡 **工具权限实时确认**：Claude / Codex 要在你电脑上**写文件 / 跑命令**时，灵动岛下方**紧贴**弹一张黑色卡片（视觉上跟刘海无缝衔接），让你看清工具名 + 主要参数，三按钮 **[拒绝 / 允许 / 总是允许]**，决策后 banner 反馈。聊天窗开着时这套 UI 自动迁移到顶条接管，桌宠切"举手求救"姿势 —— **HermesPet 不会替你做主**
- 💬 **AI 回复摘要卡**：聊天窗关着时，AI 回复完成后灵动岛下方弹摘要卡 8 秒，[复制 / 查看完整]，错过的回复也不会真的错过
- 🎙 **语音字幕条**：按住 `⌘⇧V` 时灵动岛下方实时显示语音识别字幕
- 📊 **系统信息轮播**：右耳轮播实时**内存 / CPU / 网速 / 温度**，鼠标悬停灵动岛展开看全部指标
- ❌ **错误态**整个胶囊切琥珀色 + 点击重试 · 📸 **截屏快门** 0.18s 白色闪光 · 🌊 **后台对话**对应胶囊位置呼吸式微微发光

### 🎙 语音说话 · 📎 拖文件 · 💬 多对话

**按住任意 app 说话（`⌘⇧V` Push-to-Talk）**：屏幕边缘出现 **Apple Intelligence 风格彩色光环** + 灵动岛右耳脉冲红色麦克风 + 实时识别字幕，中文走 **SFSpeechRecognizer**（macOS 离线模型），松开自动发送、回复完成"叮"一声。

**拖文件给 AI · 让 AI 自己按需读**：不是把整个 PDF 塞进 context，而是把**绝对路径**拼到 prompt 末尾，Claude / Codex 用自己的 Read / Bash 工具**按需读哪几页** —— 省 context、省 token、更精准。**在线 AI 现在也能读 PDF（v1.2.15 新）**：把 PDF 拖进聊天框就能让它读懂、总结、问答，拍照 / 扫描版自动 OCR 识别文字。图片支持四路输入：**剪贴板粘贴 / 拖拽 / `⌘⇧J` 截屏 / Codex 直接生图**。

**多对话 · 跨 AI 共享上下文（绝活）**：同时最多 **8 个对话**（`⌘N` 新建 / `⌘[` `⌘]` 切换 / `⌘1`~`⌘8` 直达），每个独立绑定 mode 绝不互相污染；**切 mode 时整段历史传给新模型** —— 让 Claude 接着看 Hermes 刚聊的内容，反之亦然。

### 🌌 知识云图 · 永不遗忘的对话宇宙（v1.3.0 全新 · 杀手锏）

别家 AI 客户端给你一条**越翻越长、越翻越累**的侧边栏列表。HermesPet 给你一片**会呼吸的星空**。

按一下 **`⌘⇧G`**，全屏「知识云图」从桌面浮起 —— 你跟 AI 聊过的**每一段对话都是一颗发光的星**，聊得越深越亮越大；相似主题被**关键词引力自动拉成一个个星团**（健身、旅行、代码、那个折腾了三天的 bug……），团心浮着主题名，一眼看清"我到底跟 AI 聊过些什么"。鼠标扫过一颗星，**只有它的关联线亮起**、其余隐入深空；点一下，**瞬间回到那段对话**接着聊。液态玻璃质感 + mode 主色辉光 + 入场如花绽开 —— 这不是对话列表，是**你和 AI 一起想过的事，第一次被画成一张地图**。

底层是三件一起上的硬功夫：

- **🗂 对话永不丢失**：所有聊过的对话进**永久本地库**（`history.sqlite`，独立于工作集、永不自动删）。以前开满 8 个挤掉最旧的就没了，现在**全在** —— 随时翻、关键词搜（本地中文分词，"上次聊崩溃那个"也搜得到）。
- **🧠 越聊越懂你**：跨对话的长期记忆在你**空闲时自动修订**，换哪个引擎它都接着懂你，不用每次重新交代背景。
- **⭐ 加星置顶 + 🗄 自动归档**：重要对话加颗星，在云图里**放大、镀金、永不被淹没**；超 90 天没碰的琐碎对话**自动沉入归档**（不删、随时一键召回）。数据越攒越多，画面始终清爽 —— **库里存得下一万条，眼前只留最该看的那些**。

> 全程本地、零上传。"回访 / 加星 / 显著度"这套信号让 HermesPet 越用越懂你的节奏，而决定权永远在你手里。

### 🆕 v1.4 新能力 · 越来越像一个"会陪你干活的伙伴"

- 🎙 **语音陪聊（`⌘⇧L`）**：唤起一颗悬浮在刘海下的胶囊，跟 AI **连续语音对话**（听 → 想 → 说 自动循环）。"在听"时是一片会呼吸流动的**星云粒子**，安静好看；它开口时**正在念的词逐个点亮**，像歌词跟读，眼睛能精确跟上它念到哪。
- 📝 **AI 笔记（`⌘⇧N`）+ 写作模式**：桌宠陪你写的**本地 Markdown 笔记本**（三栏窗），边写边让 AI 接续 / 改写 / 整理；写作模式带实时预览。
- 🚀 **全量模式 · 舰队工作流（Beta）**：把一个任务交给一支**有职位分工的"AI 公司"** —— 队长先反问几句澄清目标，再把活拆给调研 / 文案 / 工程 / 质检等多个 AI **并行开干**，满屏"舰队剧场"实时看每路进度，最后汇总成一篇交付。
- 🎬 **会议纪要**：录音 → 自动分段转写 → AI 整理成结构化纪要。
- 👁 **屏幕看 + 操作（实验）**：让 AI **看你的屏幕**（截屏 + OCR）并能**动手操作**（移动鼠标 / 点击 / 输入），帮你接管重复操作。
- 🐣 **桌宠养成**：你用 AI 干活，桌宠跟着**涨经验、升级、变心情**，未来还能解锁 / 收集更多形象。

### 📋 AI 任务规划派发 · 📰 跨天记忆 + 每日陪伴

让 AI 帮你**规划任务并直接派发**给最合适的 AI：你说"帮我列一下今天要做的事"，AI 回一个 ```` ```tasks ```` YAML 块，客户端自动渲染成**可操作卡片**，每张卡 3 个按钮 —— 📌 **Pin** 到桌面（勾完打码不消失）/ 🤖 **让 AI 做**（自动新建对话派发给推荐 mode）/ ✗ **跳过**。不只是聊天客户端，是**任务调度入口**。

它还**默默记得你**（v1.2.13 起更进一步）：本地记录你用了哪些 app / 拖了什么文件 / 问了 AI 什么（全本地 SQLite，敏感词整条丢弃），在合适的时候温温地陪你回顾：

- 🌅 **每日早报**：早上启动时 AI 反向看一遍昨天，生成 Markdown 简报并**主动续接**（"昨天你在调 SwiftUI 动画 —— 要不要我把关键方案 Pin 到桌面？"）
- 🎉 **周报 + 里程碑**：每周回顾一次，认识满 30 / 100 / 365 天会有特别的小庆祝
- 🧠 **跨模式共享记忆**：一份**用户可编辑、全部引擎共享**的本地记忆，切到任何引擎它都"接着懂你"（设置 → 隐私里可编辑 / 清空 / 关闭）

> 所有意图数据**全部在本地、不出机器**，可一键导出 JSON / 清空 / 拉黑某个 app。

### 🌐 中英双语界面（v1.2.13 新）· 🔄 自动更新 · 🛡 防伪验证

- 🌐 **整套界面中英双语**：设置里一键切 **中文 / English**，**即时生效、无需重启**；连 AI 的聊天回复都会**自动跟着你选的语言走**；新用户首次打开就能选语言
- 🔄 **应用内自动更新**：启动 60s 后 + 每 24h 自动检查 GitHub Release，有新版菜单栏 🔵 提示，点「下载并安装」→ 后台拉 DMG → 自动挂载 → Finder 引导（**不靠 Sparkle、不收集任何遥测**）
- 🛡 **官方版本验证**：设置 → 关于 → 一键 codesign 校验，正版显示原作者 Team ID `R34KL4X4D9`（防盗用 / 防冒名）
- 🚨 **崩溃一键上报**：扫描崩溃日志 → 一键复制到剪贴板 + 跳 GitHub Issue 新建页（**零后端、零隐私顾虑**）

### 🎨 还有一堆顺手的细节

**Markdown** 完整渲染（GFM 表格 + 编号列表转可点卡片 + 代码块带"复制"）· **Pin 桌面卡片**把任意 AI 回答钉到桌面 · **快问浮窗焕新（v1.2.14）** `⌘⇧Space` Spotlight 风不开聊天窗也能问，换上 iOS 26 液态玻璃外观，还能**圈选屏幕任意区域识别文字**交给 AI · **聊天窗直接粘贴图片** · **上下文用量进度条**这轮还能聊多久一目了然 · **输入栏严格按 Apple HIG**（Capsule + iMessage 风）· **聊天字号 5 档可调**（`⌘+` / `⌘-` / `⌘0`）· **窗口置顶**随手切 · **Dock 图标可选**（默认菜单栏 agent 风格不占 Dock）· **5 个事件提示音**可独立开关 + 拖入自定义音频。

---

## 🚀 快速开始

### 方式 A：下载 DMG 直接装（推荐，无需 Xcode · 3 分钟开聊）

1. 去 [Releases 页面](https://github.com/basionwang-bot/HermesPet/releases) 下载最新 DMG（**Apple Silicon / Intel 双份**，按你的芯片选；不确定就点  → 关于本机看「芯片」那行）
2. 双击 DMG → 把"Hermes 桌宠"拖进应用程序
3. **从启动台 / Spotlight 双击打开即可** —— 已经过 Apple 公证，不会被 Gatekeeper 拦
4. 菜单栏点图标 → 齿轮 ⚙️ → AI 后端 → **服务商下拉选一家** → 粘贴 API Key → 开聊

没有 API Key？设置面板里每个服务商旁都有一个**"获取 Key"链接**直达官方申请页。

### 方式 B：从源码构建（开发者）

需要 macOS 14+ 和 Xcode 命令行工具：

```bash
git clone https://github.com/basionwang-bot/HermesPet.git
cd HermesPet
./install.sh
```

| 脚本 | 用途 |
|---|---|
| `./build.sh` | 仅构建 `.app` 到 `./HermesPet.app` |
| `./install.sh` | 构建 + 装到 `/Applications` + 启动（**日常用这个**） |
| `./make-dmg.sh` | 生成给别人分发的 DMG（Developer ID 签名 + Apple 公证，双击直开） |

> 三个脚本都用 **Developer ID 证书 + Hardened Runtime** 签名（有证书时），TCC 权限永久稳定 —— "本机装的 == 用户下载的"。

### 进阶：解锁更多 AI 引擎（全部可选）

四个进阶引擎都是**可选**的，装了能解锁更强能力，不装也完全能用在线 AI 聊天：

| 引擎 | 安装命令 | 解锁能力 |
|---|---|---|
| **OpenClaw** | `npm i -g openclaw@latest && openclaw onboard --install-daemon` | 网关式 AI 平台 + 多模型聚合 |
| **Hermes Gateway** | 自部署任何 OpenAI 兼容 API（或填云端 baseURL） | 接公司内部 LLM / vLLM / Ollama |
| **Claude Code** | [官方安装指南](https://docs.claude.com/en/docs/agents-and-tools/claude-code/overview) | 文件读写 + 跑命令 + 深度编程 |
| **OpenAI Codex** | [官方仓库](https://github.com/openai/codex) | 生图 + 多图视觉 + 代码 |

装好后**重启 HermesPet 自动检测路径**（启动时跑一次 `zsh -lic 'command -v ...'`，能读到你 `~/.zshrc` 真实 PATH）。检测不到就进设置对应 mode 卡片点"重新检测"。

### 首次授权

| 权限 | 触发时机 | 用途 |
|---|---|---|
| 屏幕录制 | 首次 `⌘⇧J` 截图 | ScreenCaptureKit |
| 麦克风 + 语音识别 | 首次 `⌘⇧V` | 录音 + SFSpeechRecognizer |
| Accessibility | 快问浮窗读选中文本 | AX API |
| Finder 自动化 | 开启"Clawd 桌面巡视" | osascript 读桌面图标 |

授权完任一权限后建议**完全退出再打开**（菜单栏图标 → 退出 → 重开），新进程才能读到权限。

---

## 🎯 在线 AI：十余家服务商开箱即用

「在线 AI」是新用户默认、零依赖的主力模式。内置 **DeepSeek / 智谱 / Kimi / MiniMax / OpenAI / 通义千问 / 豆包 / 混元 / 文心 / Gemini / Grok / Mistral 等十余家**主流 LLM 预设（**客户端启动自动从云端拉取最新清单 —— 新增服务商不用更新 App**），**回复偏好 3 档可切**（快速 / 平衡 / 深度），自动映射到对应模型；DMG 内嵌 opencode runtime 处理 SSE / 推理过滤 / 工具调用：

| 服务商 | 默认模型 | 注册入口 |
|---|---|---|
| DeepSeek | deepseek-chat | [platform.deepseek.com](https://platform.deepseek.com) |
| 智谱 GLM | glm-4-flash | [open.bigmodel.cn](https://open.bigmodel.cn) |
| Moonshot Kimi | moonshot-v1-8k | [platform.moonshot.cn](https://platform.moonshot.cn) |
| MiniMax | MiniMax-M2.7 | [platform.minimaxi.com](https://platform.minimaxi.com) |
| OpenAI | gpt-4o-mini | [platform.openai.com](https://platform.openai.com) |
| 自定义 | 你填 | 任意 OpenAI 兼容端点 |

每家服务商的 **API Key 独立保存**（不会跨服务商串号），切换时自动写入对应 baseURL。**每个 mode 的配置完全独立保存**，新建对话继承"上次用的" mode，**5 分钟新手就能上手**。

---

## ⌨️ 快捷键

**全局热键**（在任何 app 里都能触发）：

| 组合 | 功能 |
|---|---|
| `⌘⇧H` | 呼出 / 收回聊天窗口 |
| `⌘⇧J` | 截当前屏幕并附加到对话 |
| `⌘⇧V` | 按住说话，松开自动发送 |
| `⌘⇧P` | 把当前对话最新 AI 回复 Pin 到桌面 |
| `⌘⇧Space` | Spotlight 风快问浮窗 |
| `⌘⇧L` | 语音陪聊（连续语音对话） |
| `⌘⇧N` | AI 笔记本 |
| `⌘⇧G` | 知识云图 |

**聊天窗内**（窗口聚焦时）：`⌘N` 新建对话 · `⌘[` / `⌘]` 切换上一/下一对话 · `⌘1`~`⌘8` 直达对应对话 · `⌘⌫` 关闭当前对话 · `⌘+` / `⌘-` / `⌘0` 调字号。

---

## 🗂 数据存储 / 隐私

| 路径 | 内容 |
|---|---|
| `~/.hermespet/conversations.json` | 所有对话历史（不含图片 Data） |
| `~/.hermespet/images/` | 用户附图 / Codex 生图持久化 |
| `~/.hermespet/pins.json` | Pin 桌面卡片 |
| `~/.hermespet/activity.sqlite` | 活动采集 + 用户意图记录（早报 / 记忆数据源） |
| `~/Library/Caches/HermesPet/` | 截图临时区 + 桌宠临时缓存 |

**隐私边界**（HermesPet 把"不收集"做成了硬约束）：

- 🛡 **零遥测**：项目本身不上送任何数据到任何后端。AI 调用都走你自己配的后端（你的 API Key / 你的自部署 Gateway / 你本地的 CLI）
- 🛡 **桌面巡视黑名单**：文件名进 AI 前过本地黑名单（薪资 / 合同 / 密码 / `.env` / `credentials` 等关键词整条丢弃）
- 🛡 **活动采集 + 共享记忆 全本地**：早报 / 记忆数据全部在本地 SQLite **不出机器**；设置里可一键导出 JSON / 清空记录 / 拉黑某个 app / 编辑或关闭共享记忆
- 🛡 **崩溃日志**：扫描本机崩溃文件 → 一键复制到剪贴板 → **你**手动粘贴到 Issue，HermesPet 不会自动上传任何东西

> 技术决策细节（踩过的坑 / Swift 6 isolation / macOS layout cycle）见 [CLAUDE.md](./CLAUDE.md)，路线图见 [TODO.md](./TODO.md)。纯原生 Swift，无 Electron。

---

## 🤝 欢迎一起来玩 · 请我喝杯咖啡

HermesPet 是我业余时间一个人维护的开源项目，每一个 issue / PR / star 都是真的能让我开心半天的那种支持。

- 🐞 **有 Bug / 用得不顺 / 想要某个功能**：直接开 [Issue](https://github.com/basionwang-bot/HermesPet/issues) 说说就行，描述清楚机型 + 系统版本 + 复现步骤，我会尽快看
- 🛠 **想动手改代码**：开干前建议先开 issue 聊聊方向，避免做出来跟项目走向不一致；代码风格跟着现有文件写就好
- ⭐ **用着觉得不错**：点个 Star 或分享给可能感兴趣的朋友 —— 让更多人用上是这个项目最大的成就感来源

> 💡 想把 HermesPet 用在公司内部、定制成你们品牌的 macOS AI 工具？欢迎邮件聊：[basionwang@gmail.com](mailto:basionwang@gmail.com)

---

## 📄 License

[Apache License 2.0](./LICENSE) —— 使用本项目代码时，您**必须**保留原始版权声明和 [NOTICE](./NOTICE) 归属信息、明确标注修改，且**不得使用 HermesPet 的名称 / 商标 / Logo 暗示与原项目的关联或背书**。

详见 [NOTICE](./NOTICE) · [品牌使用指南](./BRAND_GUIDELINES.md) · [贡献指南](./CONTRIBUTING.md)

### ⭐ Star History

[![Star History Chart](https://api.star-history.com/svg?repos=basionwang-bot/HermesPet&type=Date)](https://star-history.com/#basionwang-bot/HermesPet&Date)

---

<div align="center">

Made with ✦ on a MacBook · 桌面 AI 应当鲜活

---

© 2024–2026 [Basion Wang](https://github.com/basionwang-bot). All rights reserved.

HermesPet 是 Basion Wang 的原创作品。未经授权的复制、修改或分发行为将被追究法律责任。

</div>
