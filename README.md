<div align="center">

<img src="docs/banner.png" alt="HermesPet — 你的 AI 桌面伙伴，陪你工作，懂你所想" width="100%" />

# HermesPet 
<img src="docs/app-icon.png" alt="HermesPet App Icon" width="28" height="28" />

**让 AI 住在你 MacBook 的刘海里 · 5 种引擎并行 · 5 只像素桌宠陪你工作**

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

> ## 🛡️ 官方声明 · 认准唯一正版来源
>
> HermesPet 由 **[Basion Wang (@basionwang-bot)](https://github.com/basionwang-bot)** 从 2024 年 10 月起独立设计、开发并持续维护至今。所有代码提交记录、版本发布历史均可在本仓库中验证。
>
> ### ⚠️ 防剽窃警告
>
> 近期发现多起第三方将本项目**复制后改名发布、声称自己是原作者、在网盘/二手平台/其他网站分发修改版**的行为。**所有官方渠道之外的版本均不保证安全和正版**，可能被植入恶意代码或后门。
>
> ### ✅ 官方渠道一览
>
> | 渠道 | 地址 | 用途 |
> |---|---|---|
> | 🌐 官方网站 | [hermespet.cc](https://hermespet.cc) | 产品介绍、版本信息 |
> | 📦 官方仓库 | [github.com/basionwang-bot/HermesPet](https://github.com/basionwang-bot/HermesPet) | 源码、Issues、讨论 |
> | 📥 官方下载 | [GitHub Releases](https://github.com/basionwang-bot/HermesPet/releases) | **唯一安全下载源** |
> | 📧 联系作者 | [basionwang@gmail.com](mailto:basionwang@gmail.com) | 商业合作、举报 |
>
> ### 🔐 如何验证正版
>
> 1. **仅从 GitHub Releases 下载 DMG**
> 2. 安装后打开 **设置 → 关于 → 官方版本验证**
> 3. 正版会显示原作者 Team ID：**`R34KL4X4D9`**
> 4. 如果验证失败，请立即删除并从官方渠道重新下载
>
> ### 📢 举报盗用
>
> 如发现盗用或冒名行为，请通过以下方式举报：
> - [GitHub Issues（选择"盗用举报"模板）](https://github.com/basionwang-bot/HermesPet/issues/new?template=plagiarism_report.md)
> - 邮件：[basionwang@gmail.com](mailto:basionwang@gmail.com)
>
> 我们会采取包括 **DMCA Takedown** 在内的法律手段维护项目权益。

---

<div align="center">

<sub>🌟 <b>感谢这些朋友支持 HermesPet ❤️</b></sub>

<table>
<tr>
<td align="center" width="110">
<a href="https://afdian.com/a/basionwang"><img src="docs/sponsors/sponsor-01.jpg" width="56" height="56" alt="匿名朋友"/></a><br/>
<sub><b>匿名</b></sub>
</td>
<td align="center" width="110">
<a href="https://afdian.com/a/basionwang"><img src="docs/sponsors/sponsor-02.jpg" width="56" height="56" alt="匿名朋友"/></a><br/>
<sub><b>匿名</b></sub>
</td>
<td align="center" width="110">
<a href="https://afdian.com/a/basionwang"><img src="docs/sponsors/next-slot.svg" width="56" height="56" alt="下一位"/></a><br/>
<sub><i>下一位？</i></sub>
</td>
</tr>
</table>

</div>

---

HermesPet 是一个常驻在 MacBook **顶部刘海下方**的 AI 聊天客户端 + 桌面伴侣。

**最重要的一点**：装上就能用，不需要在你电脑上装任何命令行工具。打开 → 选个 AI 服务商（DeepSeek / 智谱 / Kimi / MiniMax / OpenAI / OpenClaw / 你自己的云端 Gateway）→ 粘贴 API Key → 开聊。如果你额外装了 `claude` / `codex` CLI，App 会自动检测出来并解锁"读写本地文件 / 跑命令 / 生图"这些高级能力。

按一下刘海呼出聊天窗、按住 `⌘⇧V` 说话、拖文件给小家伙吃掉、让 fomo 小狐狸在桌面闲逛嗅你的文件、AI 完成任务时灵动岛右耳画一个 Face ID 风的对勾 ✓ —— **桌面 AI 应当鲜活**。

> Swift 6 · SwiftUI · macOS 14+ · 纯原生（无 Electron / 无 Web view） · Apache-2.0 开源

---

## ✨ 核心亮点

### 🔀 5 种 AI 引擎，真正同时跑

不是切换，是**真正并行**。每个对话独立绑定一个 AI 引擎，第一条消息发出后锁定，最多挂 8 个对话同时跑（`⌘1`~`⌘8` 秒切）。你可以一边让 Claude 改代码，一边让在线 AI 翻译文档，一边等 Codex 生图 —— **后台跑完时灵动岛对应位置呼吸发光提醒**，不用守着屏幕。

| 引擎 | 适用 | 准备 |
|---|---|---|
| ☁️ **在线 AI** | DeepSeek / 智谱 / Kimi / MiniMax / OpenAI —— 一键选服务商粘 Key | DMG 内嵌 opencode runtime，**零依赖** |
| ⚡ **OpenClaw**（新）| 局域网网关式 AI 平台接入 | 装 OpenClaw → HermesPet 自动检测 + 零配置首连 |
| ✦ **Hermes Gateway** | 接任何 **OpenAI 兼容的 HTTP 端点**（自部署 / 云端 / vLLM / Ollama 都行） | 填 baseURL + Key |
| ⌨️ **Claude Code** | 改文件 / 跑命令 / 深度编程 | 装 `claude` CLI（可选） |
| ✨ **Codex** | 写代码 + 原生生图 | 装 `codex` CLI（可选） |

**新用户默认只见"在线 AI"模式**（最简单），其他四个 mode 装好对应工具后**自动检测并解锁**，不需要手动开关 —— 小白也能用。

### 🦊 5 只像素桌宠 · 跟着 mode 切

每个 AI 模式都有自己的**专属像素桌宠**，活在你菜单栏底下：

| 桌宠 | 所属 mode | 性格 |
|---|---|---|
| 🦞 **Clawd** | Claude Code | 橙色像素小螃蟹，最早一只，爱在桌面闲逛嗅图标 |
| ☁️ **云朵** | 在线 AI | indigo 小精灵，戴眼镜认真看你拖的图 |
| 🦊 **fomo** | OpenClaw | 月光银白九尾狐，灵动的大耳朵抖个不停（v1.2.9 新）|
| 🐴 **Pegasus** | Hermes | 金黄飞马，四脚 trot 步态 + 鬃毛随风（v1.2.7 新）|
| ⌨️ **coco** | Codex | 钢铁侠风像素小机器人 |

桌宠不只是装饰：

- 🍽 **拖文件给桌宠** → 它嚼嚼吞下 → 文件自动作为附件发到当前对话
- 👃 **拖桌宠到桌面图标** → 它停下嗅一嗅 → AI 给文件名一句 ≤10 字短评
- 🌀 **跨灵动岛传送门**（v1.2.7+）：桌宠走到刘海下方会触发**像素艺术风传送门动画**（八边形门框 + 旋转星点 + mode 主色脉冲），从灵动岛的另一侧穿出去
- 🛡 文件名进 AI 前过本地黑名单（薪资 / 合同 / 密码 / .env 等敏感关键词整条跳过）

### 🏔 灵动岛 = 操作系统级状态显示

刘海下方那个胶囊**不是装饰**，是 HermesPet 真正的"心脏"：

- **左耳** 桌宠精灵跟当前 mode 实时切（5 只独立动画）
- **右耳** 工具运行实时状态：旋转脉冲 → 步骤数 → 文件变更数 → 完成时 **Face ID 风格画线对勾 ✓**
- **鼠标 hover 像水滴展开** —— 胶囊从刘海正下方润下来，展示 mode 主色 + 模型名 + 最近回复预览
- 🛡 **工具权限确认 UI**（v1.2.4 新）：Claude / Codex 要写文件时，灵动岛下方**紧贴**弹一张黑色卡片，三按钮 [拒绝 / 允许 / 总是允许]，**视觉上跟刘海无缝衔接**像一体
- 💬 **AI 回复摘要卡**（v1.2.7 新）：聊天窗关着时，AI 回复完成后灵动岛下方弹摘要卡 8 秒，[复制 / 查看完整]，错过的回复也不会真的错过
- 🎙 **语音字幕条**：按住 `⌘⇧V` 时灵动岛下方实时显示语音识别字幕
- ❌ **错误态**整个胶囊切琥珀色 + 点击重试
- 📸 **截屏快门** 0.18s 白色闪光 + scale 反弹
- 🌊 **后台对话呼吸**：8 个对话其中之一在后台跑时，对应胶囊位置呼吸式微微发光

### 🛡 工具权限实时确认（v1.2.4 新）

Claude Code / Codex 要在你电脑上写文件 / 跑命令的时候，**灵动岛下方弹一张紧贴的卡片**给你看：

- 看到工具名 + 主要参数（哪个文件 / 什么命令）
- 三个按钮：**拒绝 / 允许（本次）/ 总是允许（白名单）**
- 决策后 0.8s 显示 banner 反馈（✓ 允许了 / ✗ 拒绝了 / 已加白名单）
- 聊天窗开着时这套 UI 自动迁移到 PetHeaderStrip 顶条接管，桌宠 sprite 切"举手求救"姿势

**HermesPet 不会替你做主**。

### 🎙 按住任意 app 说话（Push-to-Talk）

按住 `⌘⇧V` 在任何 app 里：

- 🌈 屏幕边缘出现 **Apple Intelligence 风格彩色光环**（6 色 AngularGradient 4 秒一圈）
- 🎤 灵动岛右耳脉冲红色麦克风
- 📝 灵动岛下方实时显示中文识别字幕
- 🔊 中文识别走 **SFSpeechRecognizer**（macOS 离线模型）
- 📤 松开自动发送，AI 回复完成有"叮"音效

### 📎 拖文件给 AI · 让 AI 自己按需读

不是把整个 PDF 塞进 context，而是**让 AI 自己决定读哪几页**：

- 拖入 PDF / txt / md / py / ts 任意文档
- Claude / Codex 模式：把**绝对路径**拼到 prompt 末尾，AI 用自己的 Read / Bash 工具按需读取
- 客户端只负责把文件父目录加进 `--add-dir` 白名单
- 省 context、省 token、更快、AI 还能精准只读相关段落

图片支持四路输入：**剪贴板粘贴 / 拖拽 / `⌘⇧J` 截屏 / Codex 直接生图**，多模态一气呵成。

### 💬 多对话 · 跨 AI 共享上下文（绝活）

- 同时最多 **8 个对话**（`⌘N` 新建 / `⌘[` `⌘]` 切换 / `⌘1`~`⌘8` 直达）
- 每个对话**独立绑定 mode**，绝不互相污染
- **切 mode 时整段历史传给新模型** —— 让 Claude 接着看 Hermes 刚才聊的内容，反之亦然
- 后台对话完成时灵动岛红点提醒
- 顶部 8 个圆角 TabBar，每个标签显示 mini sprite + 序号 + 首条消息派生的智能标题

### 📋 AI 任务规划 → 可派发卡片（独门绝活）

让 AI 帮你**规划任务并直接派发**给最合适的 AI：

- 你说："帮我列一下今天要做的事"
- AI 回 ```` ```tasks ```` YAML 块（每项 title / desc / **推荐 mode** / eta）
- 客户端自动渲染为**可操作卡片**，每张卡 3 个按钮：
  - 📌 **Pin** — 转任务 Pin 钉到桌面右上角，✅ 勾完打码不消失
  - 🤖 **让 AI 做** — 自动新建对话派发给推荐 mode（Claude / Codex 等），任务作首条消息发出
  - ✗ **跳过** — 本地 dismiss

不只是聊天客户端，是**任务调度入口**。

### 📰 每日早报（你睡了它在看）

HermesPet 默默记录你昨天**用了哪些 app / 拖了什么文件 / 问了 AI 什么问题**（所有数据本地 SQLite，敏感词整条丢弃），早上启动时 AI 反向看一遍生成 Markdown 简报：

> 昨天你花了 4h 在 Xcode 上，给 Hermes 模式问了 7 个 Swift 问题，3 次跟 SwiftUI 动画相关。看上去你在调动画 —— 要不要我把昨天的关键解决方案 Pin 到桌面？

数据**全部在本地不出机器**，可在设置里**一键导出 JSON / 清空记录 / 黑名单 app**。

### 🎨 精致到偏执的细节

- **Markdown** 完整渲染（GFM 表格 + 编号列表自动转可点击卡片 + 代码块带"复制"反馈）
- **Pin 桌面卡片**：把任意 AI 回答钉到桌面，单击转回聊天继续
- **快问浮窗** `⌘⇧Space` Spotlight 风快问 —— 不开聊天窗也能问一句
- **输入栏严格按 Apple HIG**（Capsule + 28pt 圆按钮 + iMessage 风 placeholder + 多行自动扩展）
- **聊天字号 5 档可调**（`⌘+` / `⌘-` / `⌘0` 回 100%）
- **窗口置顶切换** 聊天窗 header 📌 图标随手切"始终置顶"和"普通窗口"
- **Dock 图标可选** 默认菜单栏 agent 风格不占 Dock；设置里可开 Dock 图标 + 进入 Cmd+Tab
- **5 个事件提示音**可独立开关 + 可拖入自定义 mp3/wav 当提示音

### 🔄 自动更新 · 防伪验证 · 一键反馈

- 🔄 **应用内自动更新**：启动 60s 后 + 每 24h 自动检查 GitHub Release，有新版菜单栏 🔵 提示，点「下载并安装」→ 后台拉 DMG → 自动 `hdiutil` 挂载 → Finder 弹窗引导 (**不靠 Sparkle、不收集任何遥测**)
- 🛡 **官方版本验证**（v1.2.9 新）：设置 → 关于 → 一键 codesign 校验，正版会显示原作者 Team ID `R34KL4X4D9`（防盗用 / 防冒名）
- 🚨 **崩溃一键上报**：自动扫描崩溃日志 → 一键复制完整日志到剪贴板 + 跳 GitHub Issue 新建页 (**零后端、零隐私顾虑**)

---

## 🚀 快速开始

### 方式 A：下载 DMG 直接装（推荐，无需 Xcode · 3 分钟开聊）

1. 去 [Releases 页面](https://github.com/basionwang-bot/HermesPet/releases) 下载最新 `HermesPet-x.x.dmg`（Apple Silicon / Intel 双份各取所需）
2. 双击 DMG → 把"Hermes 桌宠"拖进应用程序
3. 右键打开（首次需要绕过 Gatekeeper，因为是 ad-hoc 签名）
4. 在菜单栏点 ✦ → 齿轮 ⚙️ → AI 后端 → **服务商下拉选一家**（DeepSeek / 智谱 / Kimi / MiniMax / OpenAI）→ 粘贴 API Key → 开聊

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

### 进阶：解锁更多 AI 引擎（全部可选）

四个进阶引擎都是**可选**的，装了能解锁更强能力，不装也完全能用在线 AI 聊天：

| 引擎 | 安装命令 | 解锁能力 |
|---|---|---|
| **OpenClaw** | `npm i -g openclaw@latest && openclaw onboard --install-daemon` | 网关式 AI 平台 + 多模型聚合 |
| **Hermes Gateway** | 自部署任何 OpenAI 兼容 API（或填云端 baseURL） | 接公司内部 LLM / vLLM / Ollama |
| **Claude Code** | [官方安装指南](https://docs.claude.com/en/docs/agents-and-tools/claude-code/overview) | 文件读写 + 跑命令 + 深度编程 |
| **OpenAI Codex** | [官方仓库](https://github.com/openai/codex) | 生图 + 多图视觉 + 代码 |

装好后**重启 HermesPet 自动检测路径**（启动时跑一次 `zsh -lic 'command -v ...'`，能读到你 `~/.zshrc` 真实 PATH）。如果检测不到，进设置面板对应 mode 卡片点"重新检测"即可。

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

## 🎯 5 个 AI 引擎 · 详解

| Mode | 图标 | 适合场景 | 准备工作 |
|---|---|---|---|
| **在线 AI** ⭐ | ☁ | 对话 / 翻译 / 写作 / 看图 —— **零依赖，开箱即用** | 选服务商 + 填 API Key（DeepSeek / 智谱 / Kimi / MiniMax / OpenAI 内置预设；DMG 内嵌 opencode runtime 处理 SSE / 推理过滤 / 工具调用） |
| **OpenClaw** ⚡ | ⚡ | 局域网网关式 AI 平台 —— v1.2.9 新增 | 装 [OpenClaw](https://openclaw.ai)（npm 一行）→ HermesPet 启动时**自动检测 daemon + 自动 enable chatCompletions 端点 + 零配置首连** |
| **Hermes Gateway** | ✦ | 接**任何 OpenAI 兼容 HTTP 端点**（自托管 / 云端 / vLLM / Ollama / 公司内部 LLM 平台都行） | 填 baseURL + Key，**新 v1.2.x：内置三档 preset**（本地 / 自托管 / 自定义），模型 Picker 自动从 `/v1/models` 拉 |
| **Claude Code** | ⌨ | 改文件 / 跑命令 / 深度编程 / 完整工具调用 | 装 [`claude` CLI](https://docs.claude.com/en/docs/agents-and-tools/claude-code/overview)（可选） |
| **Codex** | ✨ | 生图 + 代码（原生 Codex CLI，支持多图）| 装 [OpenAI Codex CLI](https://github.com/openai/codex) + `codex login`（可选） |

打开聊天 → ⚙️ → AI 后端 → 填配置。**五个 mode 的配置完全独立保存**，**新建对话时继承"上次用的" mode**。

🆕 **v1.2.9 默认隐藏 + 自动检测**：新用户默认只见"在线 AI"模式（最简洁），其他 4 个 mode 装好对应工具后**自动检测并弹出可启用**。已启用过的 mode 可以在设置里独立关掉，**用户的意图永远 > 自动检测**。

### 在线 AI 内置服务商预设

零配置切换六家主流 LLM，每家**回复偏好 3 档可切**（快速 / 平衡 / 深度），自动映射到对应模型：

| 服务商 | 默认模型 | 注册入口 |
|---|---|---|
| DeepSeek | deepseek-chat | [platform.deepseek.com](https://platform.deepseek.com) |
| 智谱 GLM | glm-4-flash | [open.bigmodel.cn](https://open.bigmodel.cn) |
| Moonshot Kimi | moonshot-v1-8k | [platform.moonshot.cn](https://platform.moonshot.cn) |
| MiniMax | MiniMax-M2.7 | [platform.minimaxi.com](https://platform.minimaxi.com) |
| OpenAI | gpt-4o-mini | [platform.openai.com](https://platform.openai.com) |
| 自定义 | 你填 | 任意 OpenAI 兼容端点 |

每家服务商的 **API Key 独立保存**（不会跨服务商串号），切换服务商时自动写入对应 baseURL，**5 分钟新手就能上手**。

---

## ⌨️ 快捷键

**全局热键**（Carbon Event Manager 注册，在任何 app 里都能触发）：

| 组合 | 功能 |
|---|---|
| `⌘⇧H` | 呼出 / 收回聊天窗口 |
| `⌘⇧J` | 截当前屏幕并附加到对话 |
| `⌘⇧V` | 按住说话，松开自动发送 |
| `⌘⇧P` | 把当前对话最新 AI 回复 Pin 到桌面 |
| `⌘⇧Space` | Spotlight 风快问浮窗 |

**聊天窗内快捷键**（窗口聚焦时生效）：

| 组合 | 功能 |
|---|---|
| `⌘N` | 新建对话 |
| `⌘[` / `⌘]` | 切换上一个 / 下一个对话 |
| `⌘1` ~ `⌘8` | 直接切到对应序号对话 |
| `⌘⌫` | 关闭当前对话 |

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
Sources/  (~60 个 .swift，按职能分组)
├── HermesPetApp.swift           # AppDelegate，统筹各 controller / 全局热键
├── ChatViewModel.swift          # 多对话状态 + 流式请求 + 持久化
├── ChatView.swift               # 聊天主界面 (header / 消息 / TabBar)
├── DynamicIslandController.swift # 顶部刘海胶囊（决策 #1 永不 setFrame）
├── PermissionWindowController.swift # 工具权限确认 UI（紧贴灵动岛）
├── ResponseSummaryWindowController.swift # AI 回复摘要卡（聊天窗关时）
├── PetHeaderStrip.swift         # 聊天窗顶 28pt 桌宠状态条
├── ClawdWalkOverlay.swift       # 桌面像素桌宠漫步 + 嗅文件 + 传送门
├── TeleportPortal.swift         # 跨灵动岛传送门像素动画
├── FomoSprite.swift             # 🦊 OpenClaw 九尾狐精灵
├── ModeSprite.swift             # Clawd / 云朵 / Pegasus / coco 精灵
├── PinCardOverlay.swift         # 桌面 Pin 卡片（任意 AI 回答钉桌面）
├── QuickAskWindow.swift         # Spotlight 风快问浮窗
├── IntelligenceOverlay.swift    # 语音热键 Apple Intelligence 光环
├── VoiceInputController.swift   # 录音 + SFSpeechRecognizer 中文识别
├── VoiceTranscriptOverlay.swift # 灵动岛下方实时字幕条
├── ScreenCapture.swift          # ScreenCaptureKit 截屏
├── APIClient.swift              # OpenAI 兼容 HTTP 流式（Hermes / 在线 AI / OpenClaw 共享）
├── OpenClawGatewayManager.swift # OpenClaw daemon 自动检测 + 零配置首连
├── OpenCodeServerManager.swift  # bundled opencode runtime 管理
├── ClaudeCodeClient.swift       # spawn claude -p
├── CodexClient.swift            # spawn codex exec + 图片捕获
├── MarkdownRenderer.swift       # GFM 表格 + 任务规划卡 + 选项卡片
├── ActivityRecorder.swift       # 本地活动采集（早报数据源）
├── MorningBriefingService.swift # 每日早报生成
├── CodeSignVerifier.swift       # 官方版本验证（v1.2.9 防伪）
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
| `~/.hermespet/activity.sqlite` | 活动采集 + 用户意图记录（早报数据源） |
| `~/Library/Caches/HermesPet/` | 截图临时区 + 桌宠临时缓存 |
| `~/Library/Application Support/HermesPet/opencode-global/` | bundled opencode runtime 工作目录（在线 AI 模式用） |

**隐私边界**（HermesPet 把"不收集"做成了硬约束）：

- 🛡 **零遥测**：项目本身不上送任何数据到任何后端。AI 调用都走你自己配置的后端（你的 API Key / 你的自部署 Gateway / 你本地的 CLI）
- 🛡 **桌面巡视黑名单**：文件名进 AI 前过本地黑名单（薪资 / 合同 / 密码 / `.env` / `credentials` 等关键词整条丢弃，不发出去）
- 🛡 **活动采集 全本地**：每日早报数据全部在本地 SQLite，**不出机器**；设置里可一键导出 JSON / 清空记录 / 拉黑某个 app
- 🛡 **官方版本验证**：设置 → 关于 → 一键 codesign 校验（Team ID `R34KL4X4D9`），防止第三方重打包冒名
- 🛡 **崩溃日志**：扫描本机崩溃文件 → 一键复制到剪贴板 → **你**手动粘贴到 GitHub Issue，HermesPet 不会自动上传任何东西

---

## 🤝 欢迎一起来玩

HermesPet 还是个一个人维护的开源项目，每一个 issue / PR / star 都是真的能让我开心半天的那种支持。

**有 Bug / 用得不顺 / 想要某个功能**：直接开 [Issue](https://github.com/basionwang-bot/HermesPet/issues) 说说就行，描述清楚机型 + 系统版本 + 复现步骤，我会尽快看。

**想动手改代码**：开干前建议先开 issue 聊聊方向，避免做出来跟项目走向不一致白费力气。代码风格上没什么硬性要求，跟着现有文件写就好。

**用着觉得不错**：欢迎点个 star ⭐ 或者把它分享给可能感兴趣的朋友 —— 让更多人能用上是这个项目最大的成就感来源。

---

## ☕ 请我喝杯咖啡

如果 HermesPet 帮到你，欢迎在 [**爱发电 · afdian.com/a/basionwang**](https://afdian.com/a/basionwang) 上请我喝杯咖啡。

赞助会帮我覆盖一部分硬性开销（Apple Developer 年费 / 各家 LLM API 测试 token / 服务器），让这个独立项目走得更稳一点。不赞助也完全没关系，点个 ⭐ 或者把它推荐给朋友同样是真心实意的支持。

> 💡 想把 HermesPet 用在公司内部、定制成你们品牌的 macOS AI 工具？欢迎邮件聊：[basionwang@gmail.com](mailto:basionwang@gmail.com)

---

## 📄 License

[Apache License 2.0](./LICENSE)

本项目采用 Apache License 2.0 开源协议。使用本项目代码时，您**必须**：

- 保留原始版权声明和许可证文件
- 保留 [NOTICE](./NOTICE) 文件中的归属信息
- 明确标注对原始代码的修改
- 不得使用 HermesPet 的名称、商标或 Logo 来暗示与原项目的关联或背书

详见 [NOTICE](./NOTICE) · [品牌使用指南](./BRAND_GUIDELINES.md) · [贡献指南](./CONTRIBUTING.md)

---

## ⭐ Star History

[![Star History Chart](https://api.star-history.com/svg?repos=basionwang-bot/HermesPet&type=Date)](https://star-history.com/#basionwang-bot/HermesPet&Date)

---

<div align="center">

Made with ✦ on a MacBook · 桌面 AI 应当鲜活

---

© 2024–2025 [Basion Wang](https://github.com/basionwang-bot). All rights reserved.

HermesPet 是 Basion Wang 的原创作品。未经授权的复制、修改或分发行为将被追究法律责任。

</div>
