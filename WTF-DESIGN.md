# WTF — Work The Flow(场景化工作流子系统)设计文档

> **状态**:设计定稿(2026-06-01) · 待实现
> **一句话**:把 `CanvasTemplate` 升级成通用「工作流容器」—— 用户能在加号里选、桌宠能在对的场景主动"端上来"、走 `workflows.json` 远程下发(不发版)、埋点喂飞轮。

---

## 0. 拍板决策(2026-06-01)

| # | 决策 | 理由 |
|---|---|---|
| D1 | **加密只做本地两档**(`open` + `obfuscated`),**不碰服务端 `cloud` 档** | 守住"本地 / 零依赖"定位;混淆=防君子,够拦住绝大多数人。`cloud` 是未来另一条产品线,不是给本地 workflow 撒的保护粉 |
| D2 | **MVP 只做 single 单发**;容器 schema 预留 `kind:"pipeline"` 字段但暂不实现,留到 M3 | 最快跑通"选→填→出→埋点"全链路验证内核,不卡在多步编排调试 |
| D3 | **积分先不做**,只埋 3 个数据点攒飞轮燃料 | 没规模时积分系统是空的;积分 / 市场是规模 + 有第三方贡献之后的事 |

---

## 1. 为什么做 / 核心判断

- 模型趋同的当下,harness / workflow 是拉开效果的地方 —— 但**单个 workflow 是"门票",不是"护城河"**(明文看一眼就抄走)。
- **真护城河两条**:① **飞轮**(别人抄走今天这版,抄不走你根据 N 万次真实运行调出的下一版);② **绑定独有资源**(桌宠的场景感知 + 用户自己的长期记忆,抄走文本也跑不出同样效果)。
- **差异化定位**:别人的工作流市场是"用户主动去翻、去搜、去装";你有桌宠这层,可以反过来 —— **它识别到用户正处在某场景时,主动把对的 workflow 端到面前**。市场是仓库,桌宠是懂行的管家,这个组合别人抄不走。

---

## 2. 防抄 / 加密的天花板(诚实结论)

> **DRM 铁律**:凡是要在用户自己电脑上运行的东西,最终都能被拆开 —— 能解密来用,就意味着钥匙在用户机器上。

- workflow 本质是**一段发给大模型的明文指令**,模型执行前必有明文。
- **Claude Code / Codex 模式**:指令是直接传给子进程的命令行参数,落盘加密也没用(运行前必解密喂给 `claude -p`)。
- **行为蒸馏**:对手只看"喂进去什么、吐出来什么",多试几次就能反推逻辑 —— **这层连服务端执行都防不住,只有飞轮跑得赢**。

**保护三档(做成容器的 `protection` 字段,逐 workflow 可设):**

| 档位 | 怎么做 | 能防什么 | 本期 |
|---|---|---|---|
| `open` | 明文 JSON | 不防,可共建 / 分享 | ✅ |
| `obfuscated` | 落盘加密 + 运行时解密 | 防君子(把"打开个 JSON"抬高到"逆向整个 app") | ✅ |
| `cloud` | 逻辑在你服务端跑,客户端只发输入收结果 | 唯一的真防 | ❌ 未来 |

> 未来若真要上 `cloud`,折中是**只把"皇冠那一步"(最值钱的规划 prompt)放服务端,其余留本地** —— 既护住核心又不全盘上云。Claude Code / Codex 本地模式天然无法云端化。

---

## 3. 工作流容器结构(WTF Container)

格式 JSON,复用 `ProviderPresetRegistry`(bundled 兜底 + 远程 `workflows.json` 按 id 合并)。

```jsonc
{
  "schemaVersion": 1,
  "id": "ecom-hero-5",
  "version": "1.0.0",            // ← workflow 自己的版本 = 飞轮迭代号,远程随时升

  // ① 身份 —— 双语内联(远程包自带,不依赖代码 L10n 表;bundled 的 CanvasTemplate 用 nameKey,远程包没有 key)
  "name":    { "zh": "电商主图 5 张套图", "en": "E-com Hero ×5" },
  "summary": { "zh": "淘宝规范 5 张 800×800,带精确中文排版", "en": "..." },
  "icon": "cart.fill",          // 沿用 CanvasTemplate.icon 的 SF Symbol
  "accent": "#FF8A3D",
  "category": "ecommerce",
  "tags": ["图片", "电商", "批量"],

  // ② 兼容性章 —— 你独有的信任锚,5 个 mode 实测盖章(hermes/directAPI/openclaw/claudeCode/codex)
  "compatibility": {
    "supported":   ["codex", "directAPI", "claudeCode"],
    "tested":      ["codex", "directAPI"],   // ✓ 实测过的才进这里,只有你(5 mode 环境)盖得了
    "recommended": "codex"
  },

  // ③ 要用户喂什么 —— 直接映射现有 ChatMessage 的 images/imagePaths/documentPaths + 文本变量
  "inputs": [
    { "key": "topic",     "type": "text",  "required": true,  "label": {"zh":"产品","en":"Product"} },
    { "key": "reference", "type": "image", "required": false, "max": 5, "label": {"zh":"真实产品图","en":"Reference"} },
    { "key": "style",     "type": "enum",  "options": ["天猫旗舰","小红书","极简"], "default": "天猫旗舰" }
  ],

  // ④ 这次对话要的权限 / 工具 / 目录(对接 permission 体系 + Claude --add-dir,见决策 #8/#9)
  "requires": { "tools": ["image_generation"], "addDirs": [], "permissions": [] },

  // ⑤ 行为本体 —— 单发 or 多步
  "engine": {
    "kind": "single",                                 // "single" 单发 | "pipeline" 多步
    "role":         { "zh": "你是资深电商视觉设计师…", "en": "..." },   // ← system 注入(= CanvasTemplate.systemPrompt)
    "userTemplate": { "zh": "按【{style}】给【{topic}】出 5 张主图…", "en": "..." },  // {var} 用 inputs 填
    "steps": [
      // pipeline 时填,对应 CanvasService 两阶段:
      // { "id": "plan", "prompt": {...}, "outputs": "plan" },
      // { "id": "fill", "prompt": {...}, "forEach": "plan.items" }
    ]
  },

  // ⑥ 出来怎么呈现 —— 复用已有四种落地
  "output": { "render": "canvas", "choiceCards": false },   // canvas | chat | pins | notes

  // ⑦ 桌宠什么时候"端上来" —— 呼应"克制、不刻意"
  "trigger": {
    "manual": true,                                   // 加号菜单 / 库里能选
    "proactive": {
      "enabled": true,
      "when": {
        "frontmostApp":  ["*photoshop*", "com.apple.finder"],
        "fileTypes":     ["psd", "png", "jpg"],
        "screenKeywords":["主图", "详情页", "sku"]      // 复用 v1.6 VisionOCR 读屏
      },
      "cooldownMinutes": 120,                          // 端过一次先闭嘴
      "pitch": { "zh": "在弄电商主图?要我批量出几张候选吗?", "en": "..." }
    }
  },

  // ⑧ 保护级别 —— 本期只用 open / obfuscated(见决策 D1)
  "protection": { "level": "obfuscated", "cloudEndpoint": null },

  // ⑨ 飞轮燃料 —— 先埋这 3 个点,别急着做积分(决策 D3)
  "telemetry": { "track": ["runCount", "modeUsed", "userEditedResult"] },

  // ⑩ 分发 —— 照抄 ProviderPreset:bundled 兜底 + 远程按 id 覆盖/追加
  "distribution": { "source": "remote", "author": "official", "minAppBuild": 21, "signature": "..." }
}
```

**十块设计逻辑:**

1. **身份双语内联** —— bundled 的 `CanvasTemplate` 用 `nameKey` 查代码翻译表,但远程加的 workflow 代码里没 key,名字 / 文案必须自带 zh/en(同 `ProviderPreset.localizedDisplayName` 取舍)。
2. **兼容性章** —— 把"跨 agent 都好用"产品化;`tested` 实测盖章只有你盖得了,单模型产品做不到。
3. **inputs** —— 不发明新附件体系,`image` 走 `images/imagePaths`,文件走 `documentPaths`,文本 / 枚举填进 `userTemplate`。
4. **requires** —— 对接现有 permission 卡片 + `--add-dir`。
5. **engine** —— `single` 覆盖约 80% 场景(= 现在的 CanvasTemplate);`pipeline` 才需 `steps`,对应 `CanvasService` 两阶段 / 早简。
6. **output** —— 复用已有四种落地:画布 / 聊天气泡 / 桌面 Pin / 笔记。
7. **trigger** —— "用户主动选 manual" + "桌宠主动荐 proactive"两入口同一容器;`cooldown` 守克制调性。
8. **protection** —— 见第 2 节,本期前两档。
9. **telemetry** —— 仅 3 点,先攒数据。
10. **distribution** —— `WorkflowRegistry` 克隆 `ProviderPresetRegistry`。

> **超集验证**:现有 `ecommerce` CanvasTemplate 用这套容器能 100% 表达(`engine.kind=pipeline` + 5 slot fill + `output.render=canvas`)—— 但它是多步,**留到 M3 pipeline 实现后再迁**;MVP 首发用 single 场景。**新框架是旧模板的超集,不推翻任何现有东西。**

---

## 4. 接入现有代码

| 要做的 | 照着谁抄 / 接到哪 | 改动量 |
|---|---|---|
| `WorkflowRegistry`(bundled + 远程 `workflows.json` 按 id 合并) | 克隆 `ProviderPresetRegistry` | 小 |
| workflow "应用"到一次对话(注入 role + 收集 inputs + 锁 mode) | ⚠️ `Conversation.mode` 发首条消息后**锁死**,所以选 workflow 必须在**建对话时** | 中 |
| 载体 | **挂在现有 `.chat` 对话上**(注入 role + 输入 + 输出渲染),不新增 ConversationKind | 中 |
| 加号里多一个"选 workflow"入口 | 现有附件菜单;⚠️ 它是"选剧本"不是"加附件",层级要比图片 / 文件突出 | 小 |
| 桌宠 proactive 端上来 | 复用 `IdleStateTracker` + `DesktopIconReader` + v1.6 `VisionOCR` 读屏关键词 | 中 |
| 埋 3 个数据点 | 新建轻量本地计数(先不联网) | 小 |

> ⚠️ 决策 #18:加 workflow 这类横切能力,记得 grep `case \.hermes` 全补完(涉及 10+ 文件)+ 5 个 AgentMode(含 `openclaw`)。

---

## 5. 实现里程碑

- **M1 — 地基**:容器数据模型(`Workflow` struct,Codable)+ `WorkflowRegistry`(bundled + 远程 `workflows.json` 合并,克隆 `ProviderPresetRegistry`)+ 内置 1 个 `single` 首发 workflow(选单发就能完成的场景,如"写作润色 / 会议纪要整理 / 一句话生 commit",**别用多步的 ecommerce**)。
- **M2 — 单发全链路**:加号选 workflow → 收集 inputs → 注入 role + 填 `userTemplate` → 出结果(`output.render`)→ 埋 3 个点。**这一步打通就证明内核可用**。
- **M3 — pipeline 引擎**:把画布"调研 → 逐卡生成"两阶段抽成通用 `steps` 引擎(plan → fill / forEach),并把现有 `ecommerce` 模板迁过来验证超集。
- **M4 — 桌宠主动端**:`trigger.proactive` 匹配(frontmostApp / fileTypes / screenKeywords)+ cooldown + pitch 卡片(灵动岛附属窗,守决策 #1 不动灵动岛 frame)。
- **M5 — obfuscated 档**:落盘加密 + 运行时解密。
- **M6 — 库 UI**:浏览 / 搜索 / 分类 / 展示兼容性章。
- **远期**:`cloud` 档(或"皇冠那一步上云")/ 积分 / 第三方市场(全是埋点攒够数据、有人真用之后)。

---

## 6. 待定 / 风险

- pipeline 调试复杂 → 已定先 single 后 pipeline(D2)。
- 桌宠主动"端上来"别越界 → cooldown + 安静信号,呼应 memory `feedback_subtle_proactive_tone`。
- 积分 / 市场是规模后的事 → 现在只埋点(D3)。
- 远程 `workflows.json` 要做完整性校验(`signature`)防被篡改下发恶意 prompt。

---

## 7. 第一个落地案例:AI 会议纪要(2026-06-01 与用户定)

> **定位**:会议纪要 = 一条「录音输入管道」+ 一个「会议纪要整理」single workflow —— WTF 的**第一个真实用例**。
> AI 整理那步(文字稿 → 议题/决议/待办/负责人)就是 WTF single workflow;录音 + 转录是配套的输入管道。

### 三段架构(难度天差地别)

| 段 | 干什么 | 难度 | 说明 |
|---|---|---|---|
| ① 录音 | 把开会声音录下来 | ⚠️ 中~高 | 真正的功夫在这 |
| ② 转文字 | 录音 → 文字稿 | ⚠️ 中 | SFSpeech ~1 分钟会断,要分段接力 |
| ③ AI 整理 | 文字稿 → 结构化纪要 | ✅ 简单 | 就是一个 prompt = WTF single workflow |

### 用户拍板(2026-06-01)
- **场景**:线上 + 线下**都要**(线上会议对方声音在扬声器,必须录系统音频)
- **转录**:**实时字幕**(边录边出字)
- **纪要落地**:存进 **AI 笔记**(复用昨天做的笔记本,闭环)

### 三个绕不开的坎
1. **SFSpeech 单 task ~1 分钟会断** → 必须分段接力(录一段转一段、自动起新 task 拼接)。已用 `generation` 计数防旧段回调污染新段。
2. **线上会议对方声音麦克风录不到** → 对方声音从扬声器放出,麦克风只能录到自己。要录到对方必须用 ScreenCaptureKit 开 `capturesAudio` 录系统音频(= Phase 2)。
3. **录音先落盘保命** → 开一小时万一转录中途挂了,录音还在能重转。落 `~/.hermespet/meetings/<id>.m4a`。
> (题外:macOS 26 有专给长音频的新语音框架,以后可升级换上;MVP 先用兼容老系统的分段方案。)

### 分期(最终交付 = 用户要的全部,分两步每步可见)
- **Phase 1(线下闭环)**:麦克风单路 + 实时字幕 + 分段接力 + 落盘 + AI 整理存笔记。
  - **已做**:`MeetingRecorder.swift` 地基(@unchecked Sendable + NSLock 照 VoiceInputController / 决策 #5;50 秒切段;generation 防 race;m4a 落盘;通知 Started/Partial/Finished/Cancelled/Error/Level)。
  - **待接**:UI 入口(开始/结束 + 实时字幕条)→ 调 AI 整理(先内联 prompt,待 WTF 容器就绪迁成正式 workflow)→ 存 AI 笔记。
- **Phase 2(线上覆盖)**:加 SCStream 系统音频(`capturesAudio=true`)第二路 + 双路并行转录 → 天然区分「我 / 对方」说话人。+1~2 天,主要是 SCStream 音频流 + Swift 6 后台回调隔离(决策 #5)。

### 难度总评
- 线下 MVP:中等,几天跑通。
- 加线上:再 +1~2 天。**主要时间花在让「长时录音 + 转录」稳,不是 AI 那段。**

### 与 WTF 的关系
「会议纪要整理」这步在 WTF 容器就绪前**先用内联 prompt** 跑通,不阻塞;待 WTF M1/M2 落地后,把它迁成第一个正式的 `single` workflow 容器(`engine.kind=single`、`inputs=[transcript]`、`output.render=notes`),正好验证容器设计。
