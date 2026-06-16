# HermesPet — macOS 顶部刘海桌宠 + AI 聊天客户端

Swift 6 + SwiftUI（macOS 13+，主力测试机 macOS 26.3.1）。点击顶部刘海胶囊呼出聊天窗口，对话对象可以是：

| Mode | 桌宠 / 主色 | 图标 | 实现路径 | 适用场景 |
|---|---|---|---|---|
| **Hermes Gateway** | 金黄小马 #E8C97A | sparkle ✦ | OpenAI 兼容 HTTP API（自部署 / 局域网） | 公司自部署 LLM |
| **在线 AI**（`.directAPI`） | 红怪兽 #FF4A1A | cloud.fill | OpenAI 兼容 HTTP API + bundled opencode runtime | dmg 分发档零依赖（DeepSeek / Kimi / 智谱 / OpenAI 等） |
| **OpenClaw**（`.openclaw`） | fomo 九尾狐 #B4C5E8 | bolt.circle.fill | npm 装的 OpenAI 兼容 gateway，自动读 `~/.openclaw/openclaw.json` | openclaw 用户零配置接入 |
| **Claude Code** | Clawd 螃蟹 #DE886D | terminal.fill | spawn `claude -p` 子进程 | 本地读写文件 / 跑命令 |
| **Codex** | 喷射机器人 #1C2A3A | wand.and.stars | spawn `codex exec -i` 子进程 | 本地写代码 + 原生视觉 |
| **QwenCode**（`.qwenCode`） | 眼镜怪兽 #21B6A8 | q.circle.fill | spawn `qwen` CLI 子进程（`-o stream-json`，复用终端登录态） | 零配置零 Key，qwen 用户开箱即用 |

当前版本：**v1.4.6**。分发已转 Developer ID 签名 + Apple 公证（见决策 #4 / #19）。

---

## 文件分工（约 180 个 .swift / ≈6.8 万行，按职能分组）

> 下面的分组表是 v1.3 前的主干；v1.4 起新增的大子系统见本节末尾的**「新增子系统概览」**。加新 AgentMode / 横切能力时两边都要看。

### 核心架构
| 文件 | 职责 |
|---|---|
| `HermesPetApp.swift` | AppDelegate，统筹各 controller / 全局热键 / 菜单栏 / 语音热键串联 |
| `ChatViewModel.swift` | `@MainActor @Observable`，多对话状态 + 流式请求 + 持久化 |
| `ChatView.swift` | 聊天主界面 header / 消息列表 / 输入栏 / 对话胶囊 / 欢迎页 |
| `ChatWindowController.swift` | 聊天 NSWindow（从胶囊位置展开/收回动画） |
| `Models.swift` | ChatMessage / Conversation / AgentMode / API 数据类型，`kMaxConversations = 8` |

### 聊天 UI
| 文件 | 职责 |
|---|---|
| `ChatComponents.swift` | MessageBubble / ChatInputField / SendButton / SendOnEnterTextEditor / ImageThumb / DocumentChip |
| `MarkdownRenderer.swift` | Markdown 块解析（header / 代码块 / 表格 / 编号列表 → ChoiceCard / ```tasks → TaskCardList） |
| `ChatFontScale.swift` | 聊天正文字号缩放（5 档 + EnvironmentKey + AppStorage） |

### 灵动岛 + 桌宠
| 文件 | 职责 |
|---|---|
| `DynamicIslandController.swift` | 灵动岛 NSWindow + PillView SwiftUI。**永远不 setFrame**（见决策 #1）；hit-test 走 NSEvent monitor |
| `IntelligenceOverlay.swift` | 按住语音时全屏 Apple Intelligence 风格彩色光环 |
| `VoiceTranscriptOverlay.swift` | 按住说话时灵动岛下方实时字幕条 |
| `ChoiceMenuOverlay.swift` | 灵动岛下方"原生"选项菜单（替代气泡里的 ChoiceCard） |
| `ClawdWalkOverlay.swift` | 桌面漫步：Clawd 螃蟹 🦞（Claude）/ 云朵 ☁️（在线 AI） |
| `ClawdBubbleOverlay.swift` | Clawd 头顶情绪气泡（吃文件 / 嗅桌面图标 / 短评） |
| `ModeSprite.swift` | Mode 精灵动画（Claude 叶 / Hermes 羽毛 / 云朵） |
| `LifeSignsModifier.swift` | 呼吸 / 眨眼 / 跳跃生命感动画 token |
| `MouseTracking.swift` | 全局鼠标位置追踪（Clawd 眼睛跟随光标） |
| `QuestionCardView.swift` | AI 主动问问题的卡片 UI（灵动岛附属窗口） |

### Mode 引擎（streaming clients）
| 文件 | 职责 |
|---|---|
| `APIClient.swift` | OpenAI 兼容 HTTP 流式（Hermes + 在线 AI 共用，按 `ConfigSource` 分流） |
| `ClaudeCodeClient.swift` | spawn `claude -p`，解析 stream-json |
| `CodexClient.swift` | spawn `codex exec -i`，解析事件流 |
| `OpenCodeServerManager.swift` | bundled opencode headless server 启动管理（DMG 内置 runtime） |
| `OpenCodeHTTPClient.swift` | 在线 AI 走 opencode HTTP API（替代直接 OpenAI 调用；legacy 的 `OpenCodeClient.swift` 已于 2026-06-10 删除） |
| `OpenCodeConfigGenerator.swift` | 翻译 HermesPet 配置 → `opencode.json` |
| `ReasoningProxy.swift` | SSE 过滤代理（`reasoning_content` 兼容性，过滤 think 块） |
| `ProviderPreset.swift` | 在线 AI 服务商预设（DeepSeek / 智谱 / Moonshot / OpenAI / 自定义） |
| `CLIAvailability.swift` | actor，探测 claude / codex 是否在 PATH，5 分钟缓存 + 2 秒超时 |
| `CLIProcessEnvironment.swift` | 子进程 PATH 环境补全（~/.local/bin / brew / nvm 路径） |
| `SubprocessRegistry.swift` | 跟踪 claude/codex/opencode 子进程，App 退出统一 SIGTERM |

### 工具权限确认 UI（v1.2.4 上线）
| 文件 | 职责 |
|---|---|
| `PermissionWindowController.swift` | **独立 NSWindow**，紧贴灵动岛下方（不动灵动岛 frame，见决策 #1） |
| `PermissionCardView.swift` | 权限决策卡 SwiftUI（Deny / Allow / Always Allow 三按钮） |
| `PermissionHookServer.swift` | 本地 HTTP server 接收 hook 转发的权限请求 |
| `PermissionHookInstaller.swift` | 注入 hook 到 `~/.claude/settings.json` |

### 桌面 Pin / 画布 / 早简
| 文件 | 职责 |
|---|---|
| `PinCardOverlay.swift` | 桌面 Pin 卡片系统（每张独立 NSWindow，持久化到 `~/.hermespet/pins.json`） |
| `CanvasView.swift` | 画布模式主视图 + 灯箱预览（Codex 批量生图） |
| `CanvasService.swift` | 画布两阶段生成（规划 → 填充图文） |
| `CanvasTemplates.swift` | 画布模板库（电商主图 / 课件 / 故事板） |
| `MorningBriefingService.swift` | 每日早简（活动汇总 + AI 总结） |
| `ActivityRecorder.swift` | 用户活动采集（app 切换 / 键鼠事件） |
| `ActivityStore.swift` | SQLite3 持久化活动数据 |

### 输入交互
| 文件 | 职责 |
|---|---|
| `GlobalHotkey.swift` | Carbon Event Manager 注册全局热键（含 down/up 双事件） |
| `HotkeySettings.swift` | 5 个 HotkeyAction 的默认绑定 + UserDefaults 持久化 |
| `VoiceInputController.swift` | 按住说话录音 + SFSpeechRecognizer 实时识别（zh-CN） |
| `ScreenCapture.swift` | ScreenCaptureKit 截屏（决策 #2） |
| `DragDropUtil.swift` | 拖文件统一处理（图片读 PNG / 文档只传路径） |
| `QuickAskWindow.swift` | Spotlight 风快问浮窗（⌘⇧Space） |
| `AccessibilityReader.swift` | 读取焦点文本 / 模拟键盘粘贴（Accessibility API） |
| `IdleStateTracker.swift` | 用户空闲检测（鼠标键盘 3min） |

### 系统支撑
| 文件 | 职责 |
|---|---|
| `CrashReporter.swift` | 扫描崩溃日志 + 一键上报 GitHub Issue |
| `UpdateChecker.swift` | GitHub Release API 自动更新检查 |
| `SoundManager.swift` | 5 类事件提示音 + 自定义音频文件 |
| `Haptic.swift` | trackpad 触觉反馈 |
| `DesktopIconReader.swift` | osascript 读桌面图标名称 + 位置（Clawd 桌面巡视） |
| `WindowLevels.swift` | NSWindow z-order 全局规范（灵动岛 / 聊天 / Pin / Permission 各自层级） |
| `AnimationTokens.swift` | 全局 spring 动画 token（snappy / smooth / bouncy / exit / breathe） |
| `SchemaMigrator.swift` | UserDefaults 配置版本迁移 |

### 设置 / 数据持久化
| 文件 | 职责 |
|---|---|
| `SettingsView.swift` | Form 风格设置（后端 / 桌宠 / 音效 / 隐私 / 系统 / 关于）|
| `StorageManager.swift` | `~/.hermespet/conversations.json` + 图片 PNG 持久化 |

### 新增子系统概览（v1.4+，2026-06-10 登记；文件数 60→177 的主体）

| 子系统 | 主要文件 | 职责一句话 |
|---|---|---|
| **全量模式 / 舰队（Beta）** | `FleetEngine` / `FleetRun` / `FleetTheater` / `FleetArchive` / `FleetInputCharge` | 多 agent 按依赖 DAG 并行干活 + 满屏剧场可视化（坑全在 memory `fleet_*` 系列） |
| **WTF 工作流** | `Workflow` / `WorkflowRunner` / `WorkflowRun` / `WorkflowEval` / `WorkflowGallery` / `RunPanel` | 多阶段工作流引擎 + 运行轨迹持久化（`~/.hermespet/runs/`），设计见仓库根 WTF-DESIGN.md |
| **会议纪要** | `MeetingRecorder` / `MeetingFileTranscriber` / `MeetingAnalysisPipeline` / `MeetingOverlayController` / `MeetingArena` | 录音 → SFSpeech 分段转写 → AI 整理成纪要 |
| **语音陪聊（⌘⇧L）** | `VoiceChatController` / `VoiceChatMic` / `SpeechSynthesizer` / `ListeningNebulaView` | 听→想→说连续陪聊 + TTS 卡拉OK逐词高亮 + 聆听态星云粒子 |
| **屏幕看+操作（v1.6）** | `ScreenAgent` / `ScreenPerception` / `ScreenActuator` / `ScreenTakeover` / `VisionOCR` / `RegionSelectOverlay` | 眼(截屏+OCR) → 脑(AI 决策) → 手(鼠标键盘)；接管窗口自动回复。⚠️ ~2700 行未全量审计 |
| **意图识别** | `IntentPatternDetector` / `IntentNotificationManager` / `IntentSuggestionWindowController` / `IntentCopyWriter` / `IntentInstantFeedback` / `IntentFeedbackBudget` / `UserIntentRecorder` | 观察用户行为 → 安静地给建议（克制原则，见 memory） |
| **系统监控** | `SystemMonitor` / `SystemStatsViews` / `SystemStatsPanelController` / `SystemStatsPinController` | CPU/内存等 2s 采样 + 灵动岛面板 / 桌面钉住卡片 |
| **桌宠成长 / 形象** | `PetProgress(+Store/Card)` / `PetGenome` / `PetSpecies` / `PetSprite` / `PixelPetView` / `FomoSprite` / `PetPalette` | 等级/心情/形象基因 + 6 mode 桌宠调色板 |
| **AI 笔记（⌘⇧N）** | `NotesAssist` 等 Notes* | 桌宠陪写的本地 Markdown 笔记（三栏窗） |
| **知识图谱（⌘⇧G）** | `KnowledgeGraph` / `KnowledgeGraphView` / `KnowledgeGraphOverlayController` | 对话/笔记的图谱可视化 |
| **计费 / 用量** | `ModelPricing` / `TokenUsageStore` / `TokenConsumptionView` / `ModelCatalog` | token 用量本地估价 + 省钱面板（公开价目表估算） |
| **账号 / 云** | `CloudAccount` / `CloudRelayClient` / `RemoteTerminal` / `AccountSettingsView` / `UserProfile` / `AvatarCropView` | 账号中心雏形 + 云中继/远程终端（服务器侧未建） |
| **历史 / 记忆** | `ConversationHistoryStore` / `UserMemoryStore` / `PeriodicReviewService` | history.sqlite 永久对话库 + 用户画像记忆 + 周报 |
| **新 mode client** | `QwenCodeClient` / `ProviderPresetRegistry` | qwen CLI 子进程；远程服务商预设清单（公开仓 presets.json） |
| **其他 UI** | `ArtifactGallery(+Store/WebView)` / `Museum` / `ArenaWindow` / `WritingModeChrome` / `GlassSurface` / `MiniIslandController` / `TeleportPortal` / `ResponseSummaryWindowController` | Artifact 陈列 / 写作模式 / 玻璃面板 / 迷你岛 / 传送门动效等 |

---

## 全局快捷键（Carbon 注册，UserDefaults 可改）

| 默认组合 | HotkeyAction | 功能 |
|---|---|---|
| `⌘⇧H` | toggleChat | 切换聊天窗口显示/隐藏 |
| `⌘⇧J` | captureScreen | 截屏并附加到当前对话 |
| `⌘⇧V` | voiceInput | **按住说话**（push-to-talk），松开自动发送 |
| `⌘⇧Space` | quickAsk | Spotlight 风快问浮窗 |
| `⌘⇧P` | pinLastAnswer | Pin 当前对话最新 AI 回答到桌面 |

## 聊天窗内快捷键（SwiftUI keyboardShortcut）

| 组合 | 功能 |
|---|---|
| `⌘N` | 新对话 |
| `⌘[` / `⌘]` | 上一/下一对话 |
| `⌘1` ~ `⌘8` | 直达对应序号对话（对应 kMaxConversations = 8） |
| `⌘⌫` | 关闭当前对话（保留 ⌘W 给 macOS 默认关窗口） |
| `⌘+` / `⌘=` | 字号放大一档 |
| `⌘-` | 字号缩小一档 |
| `⌘0` | 字号回 100% |

字号 5 档：85% / 100% / 115% / 130% / 150%，AppStorage 持久化。仅作用于消息正文、Markdown header、代码块、表格、ChoiceCard；输入栏 / 灵动岛 / 设置面板不缩放。

---

## 三个 Shell 脚本

| 脚本 | 用途 | 签名方式 | 权限稳定性 |
|---|---|---|---|
| `build.sh` | 仅构建 `~/Desktop/HermesPet/HermesPet.app` | Developer ID + Hardened Runtime + entitlements（与 make-dmg 一致；没证书才退 ad-hoc） | 跟线上一致 |
| `install.sh` | 构建 + 覆盖装到 `/Applications/Hermes 桌宠.app` + 启动（**日常用这个**） | 同 build.sh（Developer ID + Hardened Runtime） | **永久稳定** |
| `make-dmg.sh` | 生成给别人分发的 DMG（Apple Silicon + Intel 双份） | Developer ID + Hardened Runtime + Apple 公证 + staple | 双击直接打开，升级不丢权限 |

---

## 关键技术决策（含踩过的坑）

> 决策按"现在还在踩 / 还在生效"组织，弃用方案见 memory 文件 `[[notch-island-morph-animation]]`。

### 1. ⭐ 灵动岛 NSWindow **永远不能 setFrame**（macOS 26.3.1 mac01 100% 必崩）

任何让 `pillWindow.setFrame()` 改 width/height 的方案在 mac01 macOS 26.3.1 上 100% 必崩：
```
NSHostingView.updateAnimatedWindowSize  ← SwiftUI 反推 setFrame
NSHostingView.windowDidLayout
-[NSWindow setNeedsUpdateConstraints:]  ← 嵌套 layout
NSException SIGABRT
```

`NSHostingController.sizingOptions = []` 也挡不住反推（PR #13 三次崩验证）。**结论**：

- 灵动岛 NSWindow frame 永远固定 280×74pt（实际宽度 = 物理刘海宽 + 80pt buffer）
- 形态变化只在 SwiftUI 内部做（NotchShape 的 .frame() + bouncy spring）
- 需要"长大"的场景（permission card / question card / Pin 等）都用**独立 NSWindow 紧贴灵动岛底部**伪装"一体感"

详见 memory `[[notch-island-morph-animation]]` + `[[permission-card-lessons]]`。

### 2. 灵动岛 hover/click hit-test 必须走 NSEvent monitor

SwiftUI 在 macOS 26 上 **`.onHover` 不读 `.contentShape`** —— 鼠标在 NSWindow 整个 280×74pt 任意位置都触发 hover（包括视觉透明区）。

**最终方案**：
```swift
panel.ignoresMouseEvents = true       // NSWindow 完全不接事件
panel.acceptsMouseMovedEvents = false
// NSEvent.addLocalMonitorForEvents + addGlobalMonitorForEvents 监听 mouseMoved / leftMouseDown
// 屏幕坐标 hitRect.contains(NSEvent.mouseLocation) 自检
// click 用**当前 hover 状态**对应的 hit area（不是固定用 hover 大矩形），否则 idle 状态用户在视觉空白区也能点
```

PillView 端只 `.onReceive` 监听 `HermesPetIslandHoverChanged` 通知更新 `isHovering`。

详见 memory `[[island-hover-hittest-lessons]]`。

### 3. 截屏必须用 ScreenCaptureKit
- macOS 15+ 上 `CGDisplayCreateImage` 已**返回 nil**（即便有权限）
- `SCShareableContent` + `SCScreenshotManager.captureImage`
- **不要预检 `CGPreflightScreenCaptureAccess`** —— ad-hoc 签名换 CDHash 后会假返回 false。直接尝试 SCK，让它自己决定
- 返回值用 enum 区分 `.success` / `.needsPermission` / `.failed`

### 4. 签名：Developer ID + Apple 公证（v1.2.12 起，原 ad-hoc / Apple Development 已弃用）
- ad-hoc 签名（`codesign --sign -`）每次构建 CDHash 都变 → TCC 把每次构建当成新 app → 权限丢失
- 现统一用 **Developer ID Application 证书**（`basion wang`, Apple ID `1050246343@qq.com`, Team ID `R34KL4X4D9`，账号 2027-05-20 到期），TCC 认 (TeamID + BundleID)，永久稳定
- **分发（make-dmg.sh）**：Developer ID + Hardened Runtime + Apple 公证（notarytool）+ staple → 别人下载双击直接打开，不再被 Gatekeeper 拦
- **本地（build.sh / install.sh）**：也用 Developer ID + Hardened Runtime + 同一份 `HermesPet.entitlements` → "本机装的 == 用户下载的"，能提前暴露决策 #19 那类坑
- 公证凭据：keychain profile `HermesPetNotary`；`make-dmg.sh` 的 `notarytool` 轮询已抗断网（合盖睡眠不会废）
- bundle id 已从 `com.nousresearch.hermespet` 改成 `com.basionwang.hermespet`（设置靠 `SchemaMigrator.migrateLegacyBundleIDDomain` 迁移；**但 TCC 权限按 bundle id 记，老用户这一次升级所有权限要重新授权一次**，不可避免）
- ⚠️ **公开发布仓库 `basionwang-bot/HermesPet` 绝不能设私有**，否则 UpdateChecker 匿名 GET 变 404，全员自动更新失效

### 5. Swift 6 并发：避免 @MainActor 类的 closure 被传到后台线程
- `@MainActor` 类的内部 closure 会被自动推断为 @MainActor 隔离
- 把这种 closure 传给 SFSpeechRecognizer / `installTap` / SCStream / NotificationCenter `addObserver(queue: .main)` 闭包 等系统 API → 回调在**后台线程**或 Sendable 上下文执行 → Swift 6 runtime 检测到 isolation 不匹配 → **SIGTRAP 必崩**
- **大量后台回调的 controller 必须 `final class XXX: @unchecked Sendable`**，可变状态用 NSLock 保护
- NotificationCenter `addObserver(queue: .main)` 闭包是 `Sendable` 即便在 main 线程执行，访问 @MainActor 属性时用 `MainActor.assumeIsolated { ... }` hop
- 已踩过坑的：VoiceInputController / SendOnEnterTextEditor focus observer

### 6. 跨窗口动画的嵌套 layout 坑
- `ChatWindowController.show/hide` 内的 setFrame **不能同步触发别的 window 的 setFrame**
- 否则 NSHostingView.windowDidLayout 触发嵌套 layout cycle → macOS 26 抛 NSException → 必崩
- 跨窗口同步用 `DispatchQueue.main.async` 隔到下一个 runloop（已踩过坑的：灵动岛 compact 形态联动）
- **同一个 window 内 NSWindow.setFrame + SwiftUI overlay 同时变化也会触发**（permission UI 崩过两次）：
  - 触发链：SwiftUI 加 ZStack overlay → SwiftUI 算 intrinsic size 觉得需要更大空间 → **NSHostingView 反向请求 NSWindow.setFrame** → 跟 controller 自己的 setFrame 在 CA transaction commit 期间撞车 → NSException
  - **必须显式禁掉 hosting 反向 resize**。**⭐2026-06-11 升级：裸 `NSHostingView` 即便 `sizingOptions=[]` 在 macOS 26 上仍会经 `updateAnimatedWindowSize` 反推 setFrame**（00:09 未归因崩溃实锤，栈：`windowDidLayout → updateAnimatedWindowSize → _setFrameCommon → invalidateSafeAreaInsets → NSException`）。**内容会变尺寸/自动出现的窗口一律 `NSHostingController` + `sizingOptions=[]` + `window.contentViewController = host` + `setContentSize` 锁回原几何**（语音陪聊/迷你岛/灵动岛/Clawd气泡早已验证；2026-06-11 已转换全部 11 处动态内容窗口：会议双窗/摘要卡/意图卡/选项菜单/语音字幕/快问/接管徽章/桌宠+传送门+漫步气泡）。纯静态固定尺寸窗口（画廊/博物馆类）可继续 NSHostingView+sizingOptions=[]
  - **⭐⭐2026-06-14 再升级（issue #143/#144/#145 v1.4.4 大面积启动崩溃）：又一条反推新路径 `NSHostingView.updateWindowContentSizeExtremaIfNecessary → updateConstraints → setNeedsUpdateConstraints → -[NSWindow _postWindowNeedsUpdateConstraints]`**（CA commit/display cycle `stepIdle`/`stepTransactionFlush` 期间抛 NSException，reason=「more Update Constraints in Window passes than there are views」无限约束循环）。**这条只要"裸 NSHostingView 直接当窗口 contentView"就会中，跟有没有 setFrame、有没有动画无关**——窗口每次显示周期重算 content-size 极值即触发。教训：2026-06-11 那次升级只盯"内容会变尺寸/自动出现"的窗口，**漏审了"启动即 orderFront 但尺寸固定"的 Pin 卡片(`PinCardOverlay` bootstrap)+系统状态常驻卡(`SystemStatsPinController` restoreIfNeeded)+hover 面板(`SystemStatsPanelController`)** → 任何 ⌘⇧P pin 过回答的用户一升级 v1.4.4 就**启动崩**（已于 2026-06-14 全转 NSHostingController 修复）。**铁律修正：判断标准不是"会不会变尺寸/会不会动画"，而是"是不是裸 NSHostingView 直接当某个会被显示的窗口的 contentView"——是就必须转 NSHostingController（连固定尺寸、纯启动展示的也要）。加新窗口/审计时，把"启动 applicationDidFinishLaunching 链里 orderFront 的所有窗口"单独过一遍。** ⚠️ 此崩**只在 macOS 26.5.1+ 触发，作者机 26.3.1 测不出**，无法本地复现，只能靠栈签名 + 本范式定位。
  - **⭐⭐2026-06-15 转换配套铁律（v1.4.5 偏移回归 + 全项目收口）**：把裸 `NSHostingView` 转 `NSHostingController` 时，**必须在 `window.contentViewController = host` 之后补一行 `host.view.autoresizingMask = [.width, .height]`**——否则 AppKit 默认用约束把 hosting view 钉到窗口的 `contentLayoutGuide`/safe-area，**贴刘海顶的无边框窗口**（系统状态卡/权限卡/Pin/工作台）内容会被往下顶移一截（v1.4.5 实锤：6 处转换漏了这行 → 用户「展开的卡片/工作台位置偏移」）。参考范式是灵动岛 `DynamicIslandController` line 106——它转 NSHostingController 后**显式补了** autoresizingMask，所以同样贴屏幕顶却不偏。**判断要点**：① 旧的裸 NSHostingView 本来有 `host.autoresizingMask=[.width,.height]`（填满 contentView），转 controller 后这行必须挪到 `host.view` 上、否则丢失；② 复用分支（`window?.contentViewController = host` 重建 hosting）也要补，但**别 setContentSize**（会重置用户拖过的窗口尺寸）；③ titled 窗口（主聊天窗/我的数据面板）contentViewController 不补 mask 也能正常铺满（安全区在标题栏外、为 0），偏移只在**贴刘海顶的无边框窗口**出现，但统一补齐做防御无害。**2026-06-15 一并把 10 个残留裸 NSHostingView 窗口全转（FleetTheater/RunPanel/ArtifactWebView/ArenaWindow/Museum/ArtifactGallery/WorkflowGallery/AvatarCropView/IntelligenceOverlay/RegionSelectOverlay）+ 13 个已转但漏 mask 的无边框窗口补齐。**
  - SwiftUI 那边监听 `pendingXxx` state **不要 `withAnimation`、不要 `.transition()`**
  - NSWindow setFrame **不要 `animate: true`**

### 7. UI 设计：HIG 输入栏
- 输入栏用 Capsule(20pt 圆角) 容器，包输入框 + 28pt 圆按钮
- **Capsule 半径 = height/2，内容必须避开左右半圆**，所以 leading/trailing padding 至少等于半径
- Placeholder 用 1-2 字名词（"消息"），HIG 反对长 hint
- focus 反馈克制（参考 iMessage，不加亮眼描边，靠 NSTextView caret 自己表达）
- ChatView 用 `.frame(maxWidth: .infinity, maxHeight: .infinity)` —— **不写 minWidth/minHeight**，最小尺寸由 `NSWindow.contentMinSize` 在动画外控制（避免 hide 动画缩到 100×30 时 SwiftUI 反向请求 frame）

### 8. 四个 AgentMode 各自怎么传图片（容易漏！）
| Mode | 图片传递方式 |
|---|---|
| **Hermes / 在线 AI** | OpenAI 兼容 multimodal：`APIMessage.content` 用 `[{type:"text"},{type:"image_url"}]` 数组，base64 data URL |
| **Claude Code** | `ClaudeCodeClient.saveImagesToTemp()` 写到 `~/Library/Caches/HermesPet/`，prompt 告诉 Claude "图片在 /xxx.png 请用 Read 工具"。**必须配 `--add-dir`** |
| **Codex** | `codex exec -i <path1> -i <path2> -- "prompt"` 原生视觉参数。⚠️ **`-i <FILE>...` 是 clap greedy flag**，会吞掉后面所有参数当图片路径，**必须用 `--` 显式终止**才能让 PROMPT positional 参数被识别 |

加新 AgentMode 时务必检查图片传递路径，别只拼文本 prompt 就完事。

### 9. 拖入文档：传路径而非读全文（在线 AI PDF 例外：本地抽文本）
- `DragDropUtil.processFile` 只回传 `URL`（图片仍然读 PNG Data）
- `ChatViewModel.pendingDocuments: [URL]` 维护附件队列；`attachDocumentPath` 现在**四个 mode 全都接收**（旧版"Hermes / 在线 AI 直接拒绝"已废，别再照那条改）
- 发送时写到 `ChatMessage.documentPaths`：
  - **Claude Code**：`buildPrompt` 追加路径 + 父目录追加到 `--add-dir`，让 Claude 用 Read 工具读
  - **Codex**：prompt 末尾写路径（已 `--dangerously-bypass-approvals-and-sandbox`，cwd 之外能读）
  - **Hermes**：路径拼进 prompt（system prompt 告知"用自带文件工具按路径打开"），自部署 agent 有本机文件工具
  - **在线 AI（`.directAPI`）**：`OpenCodeHTTPClient.buildParts`（`async`）把文档当 opencode `file part`（`file://` URL）传过去；**⭐ PDF 例外**——OpenAI 兼容模型（DeepSeek/Kimi/智谱）读不了 PDF 二进制 file part（opencode 报「file part media type not supported」或被模型忽略），所以改用 `PDFTextExtractor` 本地 PDFKit 抽文字层（**扫描版无文字层 → 逐页渲染 + 复用 `VisionOCR` OCR**）内联成 text part；文字截 6 万字 / OCR 最多 30 页防爆 context。**加新二进制文档格式（docx/xlsx 等）走在线 AI 时，记得它们和 PDF 同病——模型读不了二进制，要么本地转文本要么明确拒绝**

### 10. 图片持久化方案（image Data + imagePaths 双写）
- `ChatMessage` 同时持 `images: [Data]`（内存）+ `imagePaths: [String]`（磁盘绝对路径）
- encode 只写 imagePaths（避免 base64 让 JSON 爆 MB），decode 时从 imagePaths 还原
- 落盘位置：`~/.hermespet/images/<groupID>-<idx>.png`
- 写盘 / 删盘统一走 `StorageManager.persistImages()` / `deleteImageFiles()`
- 用户附图 → `sendMessage` 创建 user message 前 persist
- Codex 生成的图 → stream 完成后从 `~/.codex/generated_images/` diff 拿到，再 persist

### 11. ViewModel 状态变更必须在 UI 有对应渲染
踩过的坑：`errorMessage` 设了 10+ 处，UI 完全没渲染 → 用户看不见。
- 任何 `@Observable var` 添加后**立刻确认 View 层有对应的 UI 渲染**
- 错误类的状态用 toast 显示（`ErrorToast` 已经做好）+ `didSet` 自动 3.5s 清空

### 12. codesign 报 "resource fork / Finder information not allowed"
- 原因：.app 内部有扩展属性（xattrs）
- 修法：codesign 前 `xattr -cr "$APP_BUNDLE"`，build.sh 已经加好
- 手动：`xattr -cr ~/Desktop/HermesPet/HermesPet.app && ./install.sh`

### 13. 灵动岛工具进度状态机
PillView 内 `@State` 维护 5 个状态机字段，全部通过 NotificationCenter 驱动：
- `taskStartTime` / `elapsedSeconds` —— TaskStarted 时每秒 `Task.sleep(1s)` 自增，TaskFinished 取消
- `stepStarted` / `stepEnded` —— ToolStarted++ / ToolEnded++（按 toolId 在 client 侧去重）
- `changedFilePaths: Set<String>` —— ToolStarted 通知带 `file_path`，name ∈ {Write, Edit, MultiEdit} 时 insert
- `diffSummaryVisible` —— TaskFinished 时若 `changedFilePaths.count > 0`，独立卡片展示 2.5s
- `backgroundStreamingCount` —— ChatViewModel 在 sendMessage 开始/结束、switchConversation 时 broadcast

**错误态**：connectionStatus=.disconnected 时 PillView 切琥珀色卡片；点击重试通过 AppDelegate.onTapped 检测 vm.connectionStatus 后调 vm.checkConnection()。

**后台对话发光线**：ConversationPill bottom overlay 一条 1.5pt mode 主色 Capsule，1.2s 周期呼吸。仅 `conv.isStreaming && conv.id != activeID` 时显示。

### 14. 在线 AI（`.directAPI`）独立 mode：跟 Hermes 完全解耦
v1.2.3 引入。要点：
- 独立 UserDefaults：`directAPIBaseURL` / `directAPIKey` / `directAPIModel`（不复用 Hermes 三件套）
- `APIClient.ConfigSource` enum（`.hermes` / `.direct`）—— ChatViewModel 持两个 APIClient 实例
- `checkHealth()` 按 source 分流：Hermes 走 `<host>/health`（Gateway 自定义端点），directAPI 走 `<baseURL>/models`（OpenAI 标准）。**directAPI 把 401/403 也当"连通"** —— 智谱的 GET /models 是 403 但 chat completions 能用
- `ProviderPreset.swift` 维护服务商预设。**改模型字符串时去各家文档查最新 API name，不要凭印象拍**
- ⭐ **远程预设清单（2026-05-27）**：`ProviderPreset.all` = 内置兜底 `bundledDefaults` + 远程 `presets.json`（公开仓根目录 raw，`ProviderPresetRegistry` 拉取/缓存/合并，按 id 覆盖/追加）。**加新厂商优先改公开仓 `presets.json` push 一下（不发版、不公证），源码里的 `bundledDefaults` 只作离线兜底**。配套：`ReasoningProxy` 的 upstream 表已从写死 static 改成**运行时注册**（`registerUpstream`/`upstream(for:)`），`ProviderPresetRegistry` + `OpenCodeConfigGenerator` 把各 provider（含远程的、用户自定义的）真实 baseURL 注册进来 → **所有厂商都走 proxy、推理过滤普适化**（含修掉自定义 provider 直连泄漏）；proxy 同时剥 `reasoning_content` 和 `reasoning` 两种字段名。详见 memory `[[remote-provider-preset-registry]]`
- 新用户默认 mode 改成 `.directAPI`（init 里 `?? .directAPI`），老用户保留 UserDefaults
- `.directAPI` 拖入文档走 opencode `file part`；**PDF 本地 PDFKit 抽文本内联**（OpenAI 兼容模型读不了 PDF 二进制，扫描版走 VisionOCR），见决策 #9

### 15. v1.2.3 之后在线 AI 走 bundled opencode
DMG 内嵌 opencode binary，避免对方电脑要装 CLI：
- `OpenCodeServerManager` 启动 headless server
- `OpenCodeHTTPClient` 替代直接 OpenAI 调用（享受 opencode 的工具调用 + 推理过滤）
- `ReasoningProxy` 处理 SSE 里的 `reasoning_content` 兼容性（不同服务商字段名不一），剥掉推理过程不让它泄漏成正文
- `OpenCodeConfigGenerator` 翻译 HermesPet 配置 → `opencode.json`
- v1.2.3 用了 9 条 `**` 通配 allow 规则规避权限确认（后续 v1.3 计划走真正的 permission ask 协议，见 `[[v13-permission-ui-design]]`）
- ⭐ **启动竞态坑（2026-05-27 修）**：`ReasoningProxy` 监听**系统随机端口**，`OpenCodeConfigGenerator.buildConfig` 在 proxy 没就绪（`baseURL==nil`）时会 **fallback 成直连真实 provider，绕过 reasoning 过滤** → 智谱/DeepSeek 等推理模型的思考过程泄漏成正文（用户「有时输出不好」）。修复：proxy **先于** opencode server start；`OpenCodeServerManager.start()` 在 `ensureConfig` 前 `await ReasoningProxy.shared.waitUntilReady()`；buildConfig 直连推理服务商时 NSLog 告警。**铁律：随机端口本地代理 + 异步就绪的链路，配置生成必须先 await 代理就绪，绝不让"没就绪→绕过代理"成为静默 fallback。** 详见 memory `[[reasoning-leak-proxy-startup-race]]`

### 16. 工具权限确认 UI（v1.2.4 上线）必须用独立 NSWindow
受决策 #1 约束，permission 卡片**不能让灵动岛 setFrame**。`PermissionWindowController` 路线：
- 独立 NSWindow，顶部紧贴菜单栏底部（`cardTopY = screenFrame.maxY - notchHeight`）
- 顶部直角 + 底部圆角，纯 `Color.black` 背景跟灵动岛 NotchShape 无缝衔接
- `cardWidth` 用 computed 直接读 `NSScreen.auxiliaryTopLeftArea/RightArea` + 80pt（DynamicIslandController.idleExtraWidth），**不要靠 NotificationCenter 拿 dynamicNotchWidth** —— 初始化顺序问题永远拿不到首发通知
- 三按钮（Deny / Always / Allow）横排底部，每个 `.frame(maxWidth: .infinity)` 均分宽度；用 `Color(NSColor.systemGray/Orange/Blue)` 自动适配 light/dark
- 详见 memory `[[permission-card-lessons]]`

### 17. ChoiceCard 点击 = 填入输入框（不直接发送）
之前编号列表 ≥ 2 项自动渲染成 ChoiceCard，点击直接发送 → AI 用编号列表纯叙述（"先做 A / 再做 B"）时被当成选项误触。

修复：`onChoiceSelected` 把内容**填到 inputText**，post `HermesPetFocusInputField` 通知让 NSTextView 抢回 firstResponder + 光标移到末尾，用户确认后按回车再发送。视觉提示从 `paperplane.fill` 改成 `text.cursor`。

### 18. 加新 AgentMode 时记得 grep 一遍 `case \.hermes`
Swift 编译器会逼着补 switch，但还是建议先 grep 一遍。涉及 10+ 文件：ChatView / ChatComponents / DynamicIslandController / MarkdownRenderer / ModeSprite / PinCardOverlay / QuickAskWindow / SettingsView / ChatViewModel / Models。同时检查图片传递路径（决策 #8）、文档传递路径（决策 #9）。

### 19. ⭐ 新增任何 TCC 受保护能力，必须同步往 `HermesPet.entitlements` 加 entitlement（v1.2.11 麦克风事故）

正式版开了 **Hardened Runtime**（公证强制要求），这种模式下访问受保护资源**必须显式声明对应 entitlement**，Info.plist 里的 `NSXxxUsageDescription` 只是必要条件、不充分。缺了不会报错，而是**系统连授权框都不弹、直接静默拒绝**。

- v1.2.11 真实事故：转 Developer ID 后麦克风"权限获取没有了" —— 因为 entitlements 只写了 JIT 三条，漏了 `com.apple.security.device.audio-input`。v1.2.12 补上才修好。
- 对照表（用到就加）：麦克风 `com.apple.security.device.audio-input`；摄像头 `com.apple.security.device.camera`；控制别的 app / osascript 发 Apple Events `com.apple.security.automation.apple-events`（+ Info.plist `NSAppleEventsUsageDescription`）；定位 `com.apple.security.device.location`。
- 当前 `HermesPet.entitlements` 已有：JIT 三条（opencode bun runtime 必需）+ `device.audio-input` + `automation.apple-events`。
- 屏幕录制 / 输入监控 / 辅助功能是纯 TCC，**不需要** Hardened Runtime entitlement，正常弹框即可。
- **为什么以前 ad-hoc 测不出**：旧 `build.sh` 不开 Hardened Runtime，本机怎么测都正常，一公证发出去才坏。现已让 build.sh 也开 Hardened Runtime（决策 #4），本机就能复现。
- 加新能力时：改完 entitlements → `./install.sh` 装本地 Hardened Runtime 版 → `tccutil reset <Service> com.basionwang.hermespet` 让框重弹 → 实测能授权，再发版。

### 20. ⭐ 界面国际化（i18n）：自建轻量 L10n + 应用内即时切换（v1.4 Phase 5，中英双语）

纯 SPM + build.sh 手动组装 bundle，苹果官方 String Catalog 不好用，所以自建一套：

- **核心**：`LocaleManager`（`@Observable` 单例，语言存 UserDefaults）+ 全局 `L("key")` / `L("key", args)`（都是 `@MainActor`，`%@`/`%d` 占位）+ Swift 字典翻译表。翻译按模块拆：`L10nCommon`/`Settings`/`Chat`/`Onboarding`/`Island`/`App`/`Canvas`/`Misc`/`Pet`，在 `L10n.swift` 的 `zhTable`/`enTable` 用 reduce 合并（新模块加一行登记）。
- **即时切换靠 Observation**：SwiftUI body 里调 `L()` → 读 `LocaleManager.shared.language`（@Observable）→ 自动建立依赖 → 切语言自动重渲染，**不用 `@Environment` 注入、不用 `.id()` 重建**。纯 AppKit：NSMenu 每次弹出动态重建（天然拿最新语言）；横幅等监听 `.hermesPetLanguageChanged`。
- **缺翻兜底**：英文缺 key → 回退中文 → 再缺 → 返回 key 本身（方便发现漏翻）。
- **⭐ 外部 enum 显示名的坑**：nonisolated 的 enum 计算属性**不能直接调** `@MainActor` 的 `L()`。两种模式：① 给 enum 加「返回 key 字符串」的属性（`AgentMode.labelKey`/`petNameKey`、`HotkeyAction.titleKey`、`SoundEvent.titleKey`/`captionKey`、`CanvasTemplate.nameKey`/`summaryKey`、`BriefingStyle.labelKey`），UI 渲染层写 `L(x.someKey)`；② 加 `@MainActor var localizedXxx`（`ProviderPreset.localizedDisplayName`、`DirectResponsePreference.localizedLabel`）。**原中文 `displayName`/`label`/`title` 一律保留**——它们还被非 MainActor 代码拼进 prompt / opencode.json / 导出 Markdown。
- **桌宠台词池**：每池**单 key + `|` 分隔多句**，代码 `L(key).split(separator:"|")` 随机选（避免几百个 key 爆炸）；带 `%@` 的每段最多 1 个占位，先 split 选中再 `String(format:)`。
- **⭐ AI 跟随语言（5-3）**：不翻整个 system prompt（中文 prompt 措辞精调过、风险高），而是注入一句强语言指令。`LocaleManager.aiReplyLanguageInstruction()`（**nonisolated**，直读 UserDefaults——各 client 的 prompt 在后台构建，碰不到 @MainActor 的 `shared.language`；`storageKey` 也标了 `nonisolated`）拼到各 client prompt 末尾（APIClient/Claude/Codex/OpenCodeConfigGenerator）+ 早报/记忆/周报/`sniffPrompt`。user 消息类 prompt 不用动（回复语言由 system prompt 控制）。
- **相对时间**：`RelativeDateTimeFormatter.locale` 要跟 `LocaleManager.currentLanguage()` 走，别硬编码 `zh_CN`（踩过：SettingsView 的 crash/更新时间一直输出中文）。
- ⚠️ **加新 UI 文案**：用 `L("key")` + 往对应 L10n 模块补中英两份；**加新 mode/enum 显示名时连带加 key 属性**（跟决策 #18 的 grep 一起做）。

### 21. ⭐ 别用"ScrollView 内 GeometryReader+preference 测滚动位置"驱动自动滚动 —— 会成布局反馈环 100% 卡死/崩溃（v1.4，2026-05-24）

聊天窗反复 100% CPU **卡死**（主线程，非崩溃）+ 偶发 **SIGTRAP 崩溃**（同一不收敛撞 CA commit 抛 NSException）。`sample <pid> 3` 栈全是 `StackLayout → _PaddingLayout.sizeThatFits → LayoutProxy.size` 无限自递归（SwiftUI 布局永不收敛），入口 `ChatView.messagesView`。

- **❌ 不是坐标系问题（踩过坑，别重走）**：第一反应以为底部"滚到底检测" GeometryReader 读 `.named(scrollSpace)` 反推 ScrollView 重测，改 `.global` —— **无效，原样复发**（采样出现 `GlobalCoordinateSpace` 证明改动生效但没用）。坐标系不是根因，GeometryReader 只是被卷进环里反复求值的"果"。
- **✅ 真根因 = 布局反馈环**：底部 `GeometryReader` **每轮布局**发 `preference`（锚点 Y）→ `onPreferenceChange` 改 `@State`（是否到底）→ 流式每 token `onChange` 触发 `scrollToBottom` → 滚动改 offset → 锚点几何变 → preference 再发，**首尾相接**；外层 `.animation(spring, value:)` 包裹整个 LazyVStack 让布局 never-settle 给环续命 → 一次事务永不收敛 → 烧满主线程。
- **🚫 铁律**：**不要用"ScrollView 内塞 GeometryReader+preference 实时测滚动位置"来驱动自动滚动** —— 这套与 `scrollTo` 必成反馈环。① 自动贴底用 Apple 官方 `.defaultScrollAnchor(.bottom)`（macOS 14+）；② 要实时跟随就直接 `onChange(数据变化) → proxy.scrollTo`（**数据驱动**），**绝不能有 preference 把"滚动/布局结果"再喂回触发条件**。本项目最终方案：删光底部 GeometryReader+preference+`isMessagesNearBottom`，`defaultScrollAnchor(.bottom)` + `onChange(messages.count/content.count)→scrollTo` 数据驱动跟随。**⚠️ 但 `defaultScrollAnchor(.bottom)` 已于 2026-05-27 移除（它与手动 scrollTo 双机制并存导致流式抖动）—— 见下方「续篇·流式抖动」。**
- **卡死定位手法**：app "卡死"先 `sample <pid> 3`，栈反复出现 `_PaddingLayout.sizeThatFits`/`StackLayout.sizeThatFits` 自递归 = 布局不收敛；`grep 'in HermesPet' 采样文件` 捞业务入口视图。崩溃版栈是 `_crashOnException → updateConstraintsForSubtreeIfNeeded → CA::Transaction::commit`。
- **复现/压测**：`CommandServer`（`POST 127.0.0.1:8765/command`，body `{"text":...}`）可程序化发消息触发真实流式；连发长 markdown 消息 + `ps -o %cpu` 循环 + 定点 `sample` grep `_PaddingLayout`。⚠️ 卡死只在**聊天窗打开 ChatView 渲染**时触发，窗口关着测不到（CommandServer 开不了窗口，需用户配合打开）。
- 与 sprite 走动高 CPU（memory `[[chat-window-idle-cpu-drain]]`，26-53%）是**不同问题**，但 sprite 持续占主线程会让本类布局隐患更易爆。详见 memory `[[chat-view-geometryreader-layout-deadlock]]`。
- **⚠️ 续篇（2026-05-25，issue #46/#48/#49/#50「切屏幕必崩」）**：上面删的是**底部**那个发 preference 的 GeometryReader，但 `messagesView` 当时**还残留一层把整个 `ScrollView` 包起来的外层 `GeometryReader { _ in ScrollView }`**（proxy 都没用）。它平时不发作，一旦**切显示器 / 切 Space / 改分辨率**让窗口几何突变就成新反馈环：GeometryReader 报新尺寸 → `ScrollView.updateContext` 改 frameSize → 几何再变 → 反复 `setNeedsUpdateConstraints` → CA commit 期间永不收敛 → `NSException`（栈见 `_postWindowNeedsUpdateConstraints` / `updateWindowContentSizeExtremaIfNecessary` / `HostingScrollView.updateContext`），**跨 macOS 15 & 26 都崩**。修复：**直接删掉这层外包装**，`ScrollView` 在 VStack 里本就占满剩余高度、无需 GeometryReader。**铁律升级：ScrollView 不论哪个方向都不要被 GeometryReader 包裹**（不只 preference 那种）—— 它与窗口几何变化必成环。
- **⚠️ 续篇·流式抖动 + 翻不动（2026-05-27，用户反馈"聊天文字自动上下滚动 + 流式时翻不上去"）**：决策 #21 修崩溃时引入/保留了**两套贴底机制并存** —— `.defaultScrollAnchor(.bottom)`（系统在 content size 变化时自动重锚到底）+ `onChange(content.count)` 每 32ms 手动 `scrollTo`。两套各自修正滚动位置、互相打架 → 流式逐字时**肉眼可见上下抖动**；且手动 scrollTo **无条件**执行 → 用户想往上翻看历史会被每 32ms 拽回底部。**修复（`ChatView.messagesView`）**：① 删 `.defaultScrollAnchor(.bottom)`，贴底**只保留单一数据驱动 scrollTo**（初始/切会话/新消息/窗口展开各 discrete 事件 + 流式 content.count）；② 加 `autoFollow` 门控 + `userScrollFollowGate`（`onScrollPhaseChange`，macOS 15+）——**只在用户主动滚动**（tracking/decelerating/拖完落 idle）时按落点离底距离更新 autoFollow，**内容增长 / 程序化 scrollTo 是 `.animating` 相不在判定之列**，故流式增长不会被误判成"上翻"而关跟随；回调只写 Bool、绝不 scrollTo，不构成反馈环（守本决策）。macOS 14 无 `onScrollPhaseChange` → autoFollow 恒 true = 始终跟随（优雅降级）。**铁律补充：贴底永远只用一套机制；要"上翻暂停跟随"用 onScrollPhaseChange 读落点、绝不在回调里 scrollTo。** 同批还修了 `MarkdownRenderer` —— `parseBlocks` + `InlineMarkdownView` 的 AttributedString 各加按内容字符串的 NSCache（之前 `body` 每帧整段重解析 O(n²)），见 memory `[[chat-view-geometryreader-layout-deadlock]]`。

### 22. ⭐⭐ `NSItemProvider.loadDataRepresentation` 的 completionHandler 在 macOS 26 SDK 里是 `@MainActor`，后台回调必 SIGTRAP（2026-06-02，拖文件进对话框闪退，修了三轮才对）

拖文件进聊天/画布 100% 闪退：`EXC_BREAKPOINT/SIGTRAP`，崩溃线程 = `com.apple.Foundation.NSItemProvider-callback-queue`（后台），栈 `closure #2 in DragDropUtil.handleProviders → swift_task_isCurrentExecutor → dispatch_assert_queue_fail`。

**真根因（`nm`+`otool -tvV`+`swift demangle` 反汇编实锤）**：`NSItemProvider.loadDataRepresentation(forTypeIdentifier:completionHandler:)` 的 completionHandler 在 macOS 26 SDK 里被标 **`@MainActor`**。于是你传的闭包**无论怎么写都被钉成 `@MainActor`**（demangle 出 `closure #2 @MainActor @Sendable (Data?,Error?)->()`），闭包入口编译器插 `swift_task_isCurrentExecutor` 断言；NSItemProvider 在后台队列回调 → 断言失败 → 崩。

**三个无效修法（别再走，全部反汇编证实没动到 @MainActor）**：① 给闭包加 `@Sendable`；② 把外层函数标 `nonisolated`；③ 回主线程用 `Task { @MainActor in ... }`（它在**构造点**就插 isCurrentExecutor 检查，本身也会 trap）。三者崩溃栈字节级不变。

**唯一正确修法**：
- **文件 URL 别用 `loadDataRepresentation(forTypeIdentifier: fileURL)`，改用 `loadObject(ofClass: URL.self)`** —— 后者的 completionHandler 是纯 `@Sendable`（非 @MainActor），反汇编 0 断言。`loadObject(ofClass: NSImage.self)` 同样安全。（`CanvasView.handleDrop` 一直用 `loadObject(URL.self)` 从没崩，是佐证。）
- 回调参数类型从 `@MainActor (T)->Void` 改 **纯 `@Sendable (T)->Void`**；跳主线程用 `DragDropUtil.mainActorForwarder`（内部 `DispatchQueue.main.async { MainActor.assumeIsolated { body(v) } }`，**纯 GCD 派发不带执行器断言**），`@MainActor` 边界上移到调用方（onDrop 闭包本就在主线程）。
- **验证靠反汇编、不靠肉眼**：`otool -tvV` 数目标闭包里 `isCurrentExecutor`/`reportUnexpectedExecutor` 指令必须 = 0（拖拽 onDrop 没法从 CommandServer 程序化触发，反汇编=0 是最强静态证明）。判断"改动是否真进运行的二进制"用 ≥30 字节唯一 marker + `strings`（决策见 memory `[[buildsh-stale-binary-deploy-trap]]`，Swift ≤15 字节小串 strings 看不到）。
- ⚠️ **子 agent 自报"已修/已验证 0 断言"不可全信**：本次工作流 agent 漏了 closure #2 仍有 2 条断言，主线程亲自反汇编复核才发现。**凡 agent 报的崩溃修复，主线程必须独立反汇编/复现核验。**

---

## 多会话设计

- 顶部最多 **8 个**对话胶囊（`kMaxConversations = 8`）
- `ChatViewModel.messages` 是 computed property，读写都落到 `conversations[activeIndex].messages`
- 流式更新用 `(conversationID, messageID)` 精确定位，**用户中途切对话也不会写错位置**
- 存储 `~/.hermespet/conversations.json`，自动从旧版 `session.json` 迁移

---

## 给未来 Claude 的工作流约定

用户对此项目长期维护，已经踩过的坑非常多。每次新会话启动**先做这三件事**：

1. **读这个 CLAUDE.md**（你正在读的）—— 项目结构 + 19 条关键决策
2. **读 `TODO.md`** —— 当前进度和待办优先级
3. **看 memory 索引** `/Users/mac01/.claude/projects/-Users-mac01-Desktop-HermesPet/memory/MEMORY.md` —— 灵动岛崩溃 / permission UI / hover hit-test 等历史坑

### 工作时的硬规则

- **做完任何一个 task / 修完一个 bug，立刻更新 `TODO.md`**：对应项从 `[ ]` 改成 `[x]`，写一句做了啥。用户明确要求的。
- **改完代码立即编译验证**：`cd ~/Desktop/HermesPet && ./build.sh 2>&1 | grep -E "error:|warning:|Build complete"`
- **部署用 `./install.sh` 而非 `./build.sh`**：build.sh 只产出 `~/Desktop/HermesPet/HermesPet.app`（用户不会跑这个）；install.sh 覆盖到 `/Applications/Hermes 桌宠.app` 才是用户实际启动的
- **codesign 失败常见原因**：xattr 没清 → `xattr -cr ~/Desktop/HermesPet/HermesPet.app && ./install.sh`
- **不要让灵动岛 NSWindow 改 frame**（决策 #1）—— 任何"灵动岛长大"想法都改用独立 NSWindow 路线（permission / question / Pin 都这么做）
- **macOS 26 + Swift 6 isolation 极严**（决策 #5）：碰到回调类系统 API（Speech / AVFoundation / SCStream / TCC / NotificationCenter Sendable closure），class 改 `@unchecked Sendable`+NSLock 或显式 `MainActor.assumeIsolated`
- **任何 `@Observable var` 加上时必须确认 View 有对应渲染**（决策 #11）
- **加新 AgentMode 时**：检查图片传递（#8）+ 文档传递（#9）+ grep `case \.hermes` 全补完（#18）

### 用户偏好（已观察到的）

- 中文沟通（全局 CLAUDE.md 已规定）
- 极简 UI、避免突兀悬浮、用图标不用文字
- 设计风格参考 Apple HIG（特别是 iMessage 输入栏）
- 对 UI 细节敏感（光标偏移、padding、Capsule 半圆、视觉边界 = 交互边界 都被指出过）
- 喜欢"一键修完 + 立即看到效果"的体验，不爱反复打补丁
- 编程经验有限，**不要扔代码片段让他自己拼**，要完整 Write 文件 + Edit 文件 + 跑脚本
