# HermesPet — macOS 顶部刘海桌宠 + AI 聊天客户端

Swift 6 + SwiftUI（macOS 13+，主力测试机 macOS 26.3.1）。点击顶部刘海胶囊呼出聊天窗口，对话对象可以是：

| Mode | 主色 | 图标 | 实现路径 | 适用场景 |
|---|---|---|---|---|
| **Hermes Gateway** | 绿 | sparkle ✦ | OpenAI 兼容 HTTP API（自部署 / 局域网） | 公司自部署 LLM |
| **在线 AI**（`.directAPI`） | indigo | cloud.fill | OpenAI 兼容 HTTP API + bundled opencode runtime | dmg 分发档零依赖（DeepSeek / Kimi / 智谱 / OpenAI 等） |
| **Claude Code** | 橙 | terminal.fill | spawn `claude -p` 子进程 | 本地读写文件 / 跑命令 |
| **Codex** | 青 | wand.and.stars | spawn `codex exec -i` 子进程 | 本地写代码 + 原生视觉 |

当前版本：**v1.2.9**（build 14）。

---

## 文件分工（60 个 .swift，按职能分组）

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
| `OpenCodeHTTPClient.swift` | 在线 AI 走 opencode HTTP API（替代直接 OpenAI 调用） |
| `OpenCodeClient.swift` | （legacy / subprocess 路径，过渡保留） |
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
| `build.sh` | 仅构建 `~/Desktop/HermesPet/HermesPet.app` | 自动选 Apple Development 证书，没有就 ad-hoc | — |
| `install.sh` | 构建 + 覆盖装到 `/Applications/Hermes 桌宠.app` + 启动（**日常用这个**） | Apple Development | **永久稳定** |
| `make-dmg.sh` | 生成给别人分发的 DMG（Apple Silicon + Intel 双份） | ad-hoc + 内嵌 opencode runtime | 接收方升级要重新授权 |

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

### 4. 签名：用本地证书让 TCC 权限稳定
- ad-hoc 签名（`codesign --sign -`）每次构建 CDHash 都变 → TCC 把每次构建当成新 app → 权限丢失
- 用户已有 **Apple Development 证书**（`1050246343@qq.com`, Team ID `R34KL4X4D9`），TCC 认 (TeamID + BundleID)，永久稳定
- `build.sh` 自动用 `security find-identity` 选证书

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
  - **必须显式禁掉 NSHostingView 反向 resize**：`if #available(macOS 13.0, *) { hosting.sizingOptions = [] }`
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

### 9. 拖入文档：传路径而非读全文
- `DragDropUtil.processFile` 只回传 `URL`（图片仍然读 PNG Data）
- `ChatViewModel.pendingDocuments: [URL]` 维护附件队列
- 发送时写到 `ChatMessage.documentPaths`，prompt 末尾追加路径
  - **Claude Code**：`buildPrompt` 追加路径 + 父目录追加到 `--add-dir`
  - **Codex**：prompt 末尾写路径（已 `--dangerously-bypass-approvals-and-sandbox`，cwd 之外能读）
  - **Hermes / 在线 AI**：`attachDocumentPath` 直接 `errorMessage` 拒绝（HTTP API 读不到本地）

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
- 新用户默认 mode 改成 `.directAPI`（init 里 `?? .directAPI`），老用户保留 UserDefaults
- `.directAPI` 同样拒绝拖入文档（HTTP API 读不到本地）

### 15. v1.2.3 之后在线 AI 走 bundled opencode
DMG 内嵌 opencode binary，避免对方电脑要装 CLI：
- `OpenCodeServerManager` 启动 headless server
- `OpenCodeHTTPClient` 替代直接 OpenAI 调用（享受 opencode 的工具调用 + 推理过滤）
- `ReasoningProxy` 处理 SSE 里的 `reasoning_content` 兼容性（不同服务商字段名不一）
- `OpenCodeConfigGenerator` 翻译 HermesPet 配置 → `opencode.json`
- v1.2.3 用了 9 条 `**` 通配 allow 规则规避权限确认（后续 v1.3 计划走真正的 permission ask 协议，见 `[[v13-permission-ui-design]]`）

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

---

## 多会话设计

- 顶部最多 **8 个**对话胶囊（`kMaxConversations = 8`）
- `ChatViewModel.messages` 是 computed property，读写都落到 `conversations[activeIndex].messages`
- 流式更新用 `(conversationID, messageID)` 精确定位，**用户中途切对话也不会写错位置**
- 存储 `~/.hermespet/conversations.json`，自动从旧版 `session.json` 迁移

---

## 给未来 Claude 的工作流约定

用户对此项目长期维护，已经踩过的坑非常多。每次新会话启动**先做这三件事**：

1. **读这个 CLAUDE.md**（你正在读的）—— 项目结构 + 18 条关键决策
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
