<div align="center">

<img src="docs/banner.png" alt="HermesPet — 住在 MacBook 刘海里的 AI 桌宠" width="100%" />

# HermesPet · AI Mission Control

**让 AI 住进 MacBook 的刘海，也让不同 AI 终端进入同一块可观察的控制面。**

原生 macOS AI 桌面伙伴 · 7 类 AI 终端 · 系统遥测 · 多任务并行 · 手机配套端持续开发中

[![Latest Release](https://img.shields.io/github/v/release/basionwang-bot/HermesPet?label=Latest&color=2ea44f&logo=github)](https://github.com/basionwang-bot/HermesPet/releases/latest)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-111111?logo=apple&logoColor=white)](https://github.com/basionwang-bot/HermesPet/releases/latest)
[![Apple Notarized](https://img.shields.io/badge/Apple-Notarized-5c6cff?logo=apple&logoColor=white)](https://github.com/basionwang-bot/HermesPet/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/basionwang-bot/HermesPet/total?label=Downloads&color=0aa8d8)](https://github.com/basionwang-bot/HermesPet/releases)

### [下载最新版 DMG](https://github.com/basionwang-bot/HermesPet/releases/latest) · [访问官网](https://hermespet.cc) · [提交反馈](https://github.com/basionwang-bot/HermesPet/issues)

<sub>官方 DMG 已完成 Developer ID 签名与 Apple 公证。打开镜像，将「Hermes 桌宠」拖入“应用程序”即可。</sub>

</div>

---

## AI 不该只住在一个聊天框

HermesPet 把 AI 变成 macOS 桌面的一部分：刘海下方是实时任务入口，屏幕边缘是随叫随到的操作台，桌宠会跟随当前 AI 模式切换、提醒任务完成，也能接住你拖来的图片和文件。

它既可以连接在线模型，也能接入本机已经登录的 Claude Code、Codex、QwenCode、Kimi 等终端。不同对话可以独立运行；你看到的不只是最终答案，还包括连接状态、执行步骤、系统负载与任务进度。

> HermesPet 的目标不是再做一个“套壳聊天窗口”，而是成为你桌面上的 **AI Mission Control**。

<div align="center">

<img src="docs/mission-control.png" alt="HermesPet AI Mission Control — 侧边任务控制台、iPhone Agent 看板与实时系统诊断舱" width="100%" />

<sub>从屏幕边缘的快捷操作，到手机端任务看板，再到另一侧的实时系统诊断舱。</sub>

</div>

---

## 一分钟看懂 HermesPet

| 刘海与屏幕边缘 | 多 Agent 控制面 | 跨设备接力 |
|---|---|---|
| 从聊天、截图、语音到任务完成提醒，都可以在不打断当前工作的情况下完成。 | Cloud、Hermes、OpenClaw、Claude Code、Codex、QwenCode、Kimi 的状态集中展示，未来可继续扩展多 Agent 编排。 | Mac 负责真正执行，iPhone 与 Apple Watch 用来查看、确认和接力；配套端仍在持续开发。 |

### 01 · 屏幕边缘就是任务控制台

鼠标碰到桌宠后，侧边栏从屏幕边缘展开。常用操作在近侧，另一侧展示实时系统诊断：CPU、内存、温度、存储、网络和 AI 节点状态，不需要先打开一个完整窗口。

### 02 · 一个桌面，同时连接 7 类 AI 终端

| 节点 | 最适合做什么 | 接入方式 |
|---|---|---|
| **Cloud / 在线 AI** | 日常问答、写作、总结、视觉理解 | App 内选择服务商并配置自己的 API Key |
| **Hermes** | OpenAI 兼容网关、自部署模型、公司内部模型 | 配置兼容端点与模型 |
| **OpenClaw** | 网关式 AI 平台与多模型聚合 | 安装并启动 OpenClaw |
| **Claude Code** | 读写文件、运行命令、复杂工程任务 | 复用本机 Claude Code 登录态 |
| **Codex** | 编程任务、工具调用与视觉生成 | 复用本机 Codex 登录态 |
| **QwenCode** | 通义千问终端工作流 | 复用本机 QwenCode 登录态 |
| **Kimi** | Kimi 终端工作流与长上下文任务 | 复用本机 Kimi 登录态 |

未安装的终端不会阻塞基础使用。第一次打开时，普通用户只需要选择一家在线 AI 服务商；高级终端可以之后再按需解锁。

### 03 · Mac 干活，手机负责看、问、确认

iPhone 配套端围绕“遥控 Mac 上的 Agent”设计：查看进行中的任务、接收执行进度、批准高风险操作、上传图片或文件，并在离开电脑后继续对话。Apple Watch 负责更轻量的状态与提醒。

> 手机端与手表端目前仍在持续开发和打磨，不包含在 macOS DMG 中；正式获取方式会在发布时单独说明。

---

## 真实界面

<table>
<tr>
<td width="50%" align="center">
<img src="docs/desktop/chat.png" alt="HermesPet macOS 聊天窗口" width="100%" />
<br/><sub><b>原生聊天工作台</b><br/>多对话、Markdown、文件、图片与执行步骤</sub>
</td>
<td width="50%" align="center">
<img src="docs/desktop/knowledge-graph.png" alt="HermesPet 知识云图" width="100%" />
<br/><sub><b>知识云图</b><br/>把长期对话变成可搜索、可回访的主题星图</sub>
</td>
</tr>
</table>

<table>
<tr>
<td align="center" width="33%">
<img src="docs/mobile/welcome.png" width="220" alt="iPhone 主页与早报" />
<br/><sub><b>每日陪伴</b><br/>早报、常用 AI 与跨设备入口</sub>
</td>
<td align="center" width="33%">
<img src="docs/mobile/taskboard.png" width="220" alt="iPhone 多 Agent 任务看板" />
<br/><sub><b>Agent 任务看板</b><br/>看进度、停止任务、批准敏感操作</sub>
</td>
<td align="center" width="33%">
<img src="docs/mobile/attach.png" width="220" alt="iPhone 向 Mac 发送图片与文件" />
<br/><sub><b>随手交给 Mac</b><br/>照片、文件、语音和远程任务</sub>
</td>
</tr>
</table>

---

## 你可以用它做什么

- **多对话并行**：每条对话绑定自己的 AI 模式，任务在后台继续运行，完成后由灵动岛和桌宠提醒。
- **看得见的执行过程**：文件读取、命令、工具调用与错误状态统一呈现，不只给一个“正在思考”。
- **截图与圈选提问**：截取全屏或指定区域，直接交给当前 AI 解释、提取或处理。
- **按住说话**：在任意 App 中使用全局快捷键输入语音，松开后自动发送。
- **拖文件给桌宠**：图片与文档可以拖进聊天，也可以直接拖给屏幕边缘的桌宠。
- **系统诊断**：集中查看 CPU、内存、温度、存储、实时网速和各 AI 终端连接状态。
- **长期记忆与知识云图**：历史对话保留在本机，并可按关键词、主题和重要程度重新找到。
- **计划任务与自动化**：定时早报、周期复盘与任务调度正在逐步汇入同一套控制面。

<details>
<summary><b>查看常用快捷键</b></summary>

| 快捷键 | 功能 |
|---|---|
| `⌘⇧H` | 显示或隐藏聊天窗口 |
| `⌘⇧J` | 截图并附加到当前对话 |
| `⌘⇧V` | 按住说话，松开发送 |
| `⌘⇧Space` | 打开快问浮窗 |
| `⌘⇧L` | 连续语音陪聊 |
| `⌘⇧N` | 打开 AI 笔记 |
| `⌘⇧G` | 打开知识云图 |

</details>

---

## 安装

### 推荐：下载官方 DMG

1. 打开 [GitHub Releases](https://github.com/basionwang-bot/HermesPet/releases/latest)。
2. 根据“关于本机”中的芯片类型选择版本：

   | 你的 Mac | 下载文件 |
   |---|---|
   | Apple M 系列芯片 | `HermesPet-*-AppleSilicon.dmg` |
   | Intel 芯片 | `HermesPet-*-Intel.dmg` |

3. 双击 DMG，将「Hermes 桌宠」拖入“应用程序”。
4. 从启动台或 Spotlight 打开，在设置中选择 AI 服务商并填写自己的配置。

HermesPet 内置更新检查。正式版经过签名与公证，因此系统权限在升级后更稳定；普通用户不需要从源码自行构建。

### 可选：解锁终端型 Agent

Claude Code、Codex、QwenCode、Kimi 与 OpenClaw 都属于可选能力。先在终端完成对应工具的官方安装与登录，再回到 HermesPet 重新检测即可。未安装这些工具时，在线 AI 仍可正常使用。

---

## 数据、隐私与联网边界

我们希望把“数据会去哪里”说得简单而准确：

- 对话、图片、任务记录等桌面数据优先保存在你的 Mac 本地目录中。
- 当你向 AI 提问时，请求会发送到你主动选择并配置的模型服务商或终端工具；不同服务商有各自的隐私政策。
- API Key 与连接配置由 Mac 客户端在本机保存，HermesPet 不会替你创建或转售模型账户。
- 只有启用手机远程功能时，Mac 与配套端才会使用账号鉴权和官方中转服务进行外网通信。
- 远程功能不是“只走 iCloud、完全不经过服务端”；我们会在正式发布前继续公开说明账号、传输与数据保留边界。
- 屏幕查看、麦克风、辅助功能等系统权限均按功能触发，由 macOS 弹窗交给你决定。

---

## 官方渠道与正版验证

| 渠道 | 地址 |
|---|---|
| 官网 | [hermespet.cc](https://hermespet.cc) |
| 公共仓库 | [github.com/basionwang-bot/HermesPet](https://github.com/basionwang-bot/HermesPet) |
| 正式下载 | [GitHub Releases](https://github.com/basionwang-bot/HermesPet/releases/latest) |
| 问题反馈 | [GitHub Issues](https://github.com/basionwang-bot/HermesPet/issues) |
| 联系作者 | [basionwang@gmail.com](mailto:basionwang@gmail.com) |

官方正式版使用 Team ID **`R34KL4X4D9`** 签名。本仓库与官网之外提供的安装包不属于官方发布，无法保证未被修改。

> 本公共仓库主要用于产品介绍、正式下载、更新记录与 Issue 反馈。安装 HermesPet 请优先使用签名并公证的 DMG。

---

## 路线图

HermesPet 正在从“单个 AI 桌宠”演进为“可观察、可调度的多 Agent 桌面系统”。接下来的重点包括：

- 更可靠的 AI 终端健康检查与登录状态识别
- 多 Agent 并行编排、角色创建与结果汇总
- 定时任务、运行监控与异常提醒
- Mac、iPhone、Apple Watch 之间更完整的任务接力
- 更明确的远程访问隐私说明和权限控制

公开事项见 [todo.md](./todo.md)。欢迎通过 [Issues](https://github.com/basionwang-bot/HermesPet/issues) 提交使用反馈和功能建议。

---

## 支持项目

HermesPet 由独立开发者长期设计、开发和维护。一个 Star、一条能复现问题的 Issue，或者把它分享给真正需要桌面 AI 的朋友，都会让项目走得更远。

<details>
<summary><b>联系作者 / 微信交流</b></summary>

<div align="center">

<img src="docs/wechat-qr.jpg" alt="作者微信二维码" width="220" />

<sub>添加时请备注「HermesPet」</sub>

</div>

</details>

### Star History

[![Star History Chart](https://api.star-history.com/svg?repos=basionwang-bot/HermesPet&type=Date)](https://star-history.com/#basionwang-bot/HermesPet&Date)

---

<div align="center">

**Made with ✦ on a MacBook**

桌面 AI 应当鲜活，也应当透明、可控。

© 2024–2026 [Basion Wang](https://github.com/basionwang-bot). All rights reserved.

</div>
