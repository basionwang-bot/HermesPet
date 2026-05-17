# HermesPet — macOS 顶部刘海桌宠 + AI 聊天客户端

Swift + SwiftUI 写的 macOS 应用。点击顶部刘海胶囊呼出聊天窗口，对话对象可以是：
- **Hermes Gateway**（OpenAI 兼容 HTTP API）
- **Claude Code CLI**（spawn `claude -p` 子进程，能读写文件 / 跑命令）

---

## 文件分工

| 文件 | 职责 |
|---|---|
| `HermesPetApp.swift` | AppDelegate，统筹各 controller / 全局热键 / 菜单栏 / 语音热键串联 |
| `ChatViewModel.swift` | `@MainActor @Observable`，多对话状态 + 流式请求 + 持久化 |
| `ChatView.swift` | 聊天主界面，包含 header / messages / 输入栏 / 对话胶囊 / 快捷启动卡片 |
| `ChatComponents.swift` | MessageBubble、ChatInputField、SendButton、SendOnEnterTextEditor、ImageThumb |
| `DynamicIslandController.swift` | 顶部刘海胶囊（NSWindow + SwiftUI），右耳任务状态指示器 |
| `ChatWindowController.swift` | 聊天窗口（NSWindow，从胶囊位置展开/收回动画） |
| `IntelligenceOverlay.swift` | 按住语音时全屏 **Apple Intelligence 风格**彩色光环 |
| `VoiceInputController.swift` | 按住说话录音 + SFSpeechRecognizer 实时识别（zh-CN） |
| `ScreenCapture.swift` | ScreenCaptureKit 截屏（必须，CGDisplayCreateImage 已失效） |
| `GlobalHotkey.swift` | Carbon Event Manager 注册全局热键（含 down/up 双事件） |
| `Models.swift` | ChatMessage / Conversation / AgentMode / API 数据类型 |
| `StorageManager.swift` | `~/.hermespet/conversations.json` 持久化 |
| `APIClient.swift` | Hermes Gateway 流式 HTTP 客户端 |
| `ClaudeCodeClient.swift` | spawn `claude -p`，解析 stream-json 增量输出 |
| `MarkdownRenderer.swift` | 自定义 Markdown 渲染（代码块带复制按钮、行内代码等） |
| `SettingsView.swift` | Form(.grouped) macOS 系统设置风格 |
| `AnimationTokens.swift` | 全局 spring 动画 token（snappy / smooth / bouncy / exit / breathe） |

---

## 全局快捷键

| 组合 | 功能 |
|---|---|
| `Cmd+Shift+H` | 切换聊天窗口显示/隐藏 |
| `Cmd+Shift+J` | 截屏并附加到当前对话 |
| `Cmd+Shift+V` | **按住说话**（push-to-talk），松开自动发送 |

---

## 三个 Shell 脚本

| 脚本 | 用途 | 签名方式 | 权限稳定性 |
|---|---|---|---|
| `build.sh` | 仅构建 `.app` | 自动选 Apple Development 证书，没有就 ad-hoc | — |
| `install.sh` | 构建 + 覆盖装到 `/Applications` + 启动（**日常用这个**） | Apple Development | **永久稳定** |
| `make-dmg.sh` | 生成给别人分发的 DMG | ad-hoc | 接收方升级要重新授权 |

---

## 关键技术决策（含踩过的坑）

### 1. 截屏必须用 ScreenCaptureKit
- macOS 15+ 上 `CGDisplayCreateImage` 已**返回 nil**（即便有权限）
- 改用 `SCShareableContent` + `SCScreenshotManager.captureImage`
- **不要预检 `CGPreflightScreenCaptureAccess`** —— ad-hoc 签名换 CDHash 后会假返回 false。直接尝试 SCK，让它自己决定。
- 返回值用 enum 区分 `.success` / `.needsPermission` / `.failed`

### 2. 签名：用本地证书让 TCC 权限稳定
- ad-hoc 签名（`codesign --sign -`）每次构建 CDHash 都变 → TCC 把每次构建当成新 app → 权限丢失
- 用户已有 **Apple Development 证书**（`1050246343@qq.com`, Team ID `R34KL4X4D9`），TCC 认 (TeamID + BundleID)，永久稳定
- `build.sh` 自动用 `security find-identity` 选证书

### 3. Claude Code spawn 必须加 permission 参数
spawn `claude -p` 时默认 permission-mode 会拒绝所有需要确认的工具调用，导致 AI 看不到附带图片、写不出文件。必须传：
```
--permission-mode acceptEdits
--add-dir ~/Library/Caches/HermesPet
--add-dir ~/Desktop
```

### 4. Swift 6 并发：避免 @MainActor 类的 closure 被传到后台线程
- `@MainActor` 类的内部 closure 会被自动推断为 @MainActor 隔离
- 把这种 closure 传给 SFSpeechRecognizer / `installTap` / SCStream 等系统 API → 回调在**后台线程**执行 → Swift 6 runtime 检测到 isolation 不匹配 → **SIGTRAP 必崩**
- **大量后台回调的 controller 必须改成 `final class XXX: @unchecked Sendable`**，可变状态用 NSLock 保护
- 已踩过坑的：VoiceInputController（按住 ⌘⇧V 必崩，已修）

### 5. 跨窗口动画的嵌套 layout 坑
- `ChatWindowController.show/hide` 内的 setFrame **不能同步触发别的 window 的 setFrame**
- 否则 NSHostingView.windowDidLayout 触发嵌套 layout cycle → macOS 26 抛 NSException → 必崩
- 跨窗口同步用 `DispatchQueue.main.async` 隔到下一个 runloop（已踩过坑的：灵动岛 compact 形态联动）
- **同一个 window 内 NSWindow.setFrame + SwiftUI overlay 同时变化也会触发**（v1.3 permission UI 崩了两次才搞定）：
  - 触发链：SwiftUI 加 ZStack overlay → SwiftUI 算 intrinsic size 觉得需要更大空间 → **NSHostingView 反向请求 NSWindow.setFrame** → 跟 controller 自己的 setFrame 在 CA transaction commit 期间撞车 → NSException
  - **必须显式禁掉 NSHostingView 反向 resize**：`if #available(macOS 13.0, *) { hosting.sizingOptions = [] }` —— 默认 `.preferredContentSize` 会跟踪 SwiftUI intrinsic size。设空集合后 hosting 只渲染，window 尺寸 100% 由 controller 控制
  - 同时 SwiftUI 那边监听 `pendingXxx` state 设置时**不要用 `withAnimation`**、不要 `.transition()` —— 这些会在 NSWindow setFrame 期间触发额外 layout 触发嵌套
  - NSWindow setFrame 也**不要用 `animate: true`** —— AppKit 动画走自家系统，跟 NSHostingView 嵌套照样崩。要动画就在 SwiftUI 那边内部做，window frame 立即设
  - controller 监听通知 setFrame 仍要包 `DispatchQueue.main.async`，让通知派发的同步 SwiftUI 更新先 stable

### 6. UI 设计：HIG 输入栏
- 输入栏用 Capsule(20pt 圆角) 容器，包输入框 + 28pt 圆按钮
- **Capsule 半径 = height/2，内容必须避开左右半圆**，所以 leading/trailing padding 至少等于半径（容器高 36 → 半径 18 → leading 14pt 起）
- Placeholder 用 1-2 字名词（"消息"），HIG 反对长 hint
- focus 反馈克制（参考 iMessage，不加亮眼描边，靠 NSTextView caret 自己表达）

### 7. ad-hoc 签名要避免 ChatView 的 frame 跟 Window 不一致
- 之前 `.frame(minWidth: 360, minHeight: 360)` + ChatWindow hide 动画缩到 100×30 → SwiftUI 反向请求 window 改 frame → 嵌套 layout → 崩
- 必须用 `.frame(maxWidth: .infinity, maxHeight: .infinity)` + 让 NSWindow.contentMinSize 控制最小尺寸

### 8. 三个 AgentMode 各自怎么传图片（容易漏！）
| Mode | 图片传递方式 |
|---|---|
| **Hermes** | OpenAI 兼容 multimodal：`APIMessage.content` 用 `[{type:"text"},{type:"image_url"}]` 数组，base64 data URL |
| **Claude Code** | `ClaudeCodeClient.saveImagesToTemp()` 把图写到 `~/Library/Caches/HermesPet/`，prompt 里告诉 Claude "图片在 /xxx/xxx.png，请用 Read 工具查看"。**必须配 `--add-dir`** |
| **Codex** | `codex exec -i <path1> -i <path2> -- "prompt"` 原生视觉参数。⚠️ **`-i <FILE>...` 是 clap greedy flag**，会吞掉后面所有参数当图片路径，**必须用 `--` 显式终止**才能让 PROMPT positional 参数被识别，否则 codex 转去等 stdin 报 "No prompt provided via stdin"（踩过两次） |

加新 AgentMode 时务必检查图片传递路径，别只拼文本 prompt 就完事。

### 9. 图片持久化方案（image Data + imagePaths 双写）
- `ChatMessage` 同时持 `images: [Data]`（内存，UI 显示用）+ `imagePaths: [String]`（磁盘绝对路径，序列化用）
- **encode 只写 imagePaths**（避免 base64 让 JSON 爆 MB），**decode 时从 imagePaths 还原 images**
- 落盘位置：`~/.hermespet/images/<groupID>-<idx>.png`
- 写盘 / 删盘统一走 `StorageManager.persistImages()` / `deleteImageFiles()`
- 用户附图 → 在 `sendMessage` 创建 user message 前就 persist
- Codex 生成的图 → 在 stream 完成后从 `~/.codex/generated_images/` diff 拿到，再 persist

### 10. ViewModel 状态变更必须在 UI 有对应渲染（errorMessage 教训）
踩过的坑：`ChatViewModel.errorMessage` 设了 10+ 处，UI 完全没渲染 → 出错用户看不见。
- 任何 `@Observable var` 添加后**立刻确认 View 层有对应的 UI 渲染**
- 错误类的状态推荐用 toast 显示（`ErrorToast` 已经做好）+ `didSet` 自动 3.5s 清空

### 11. codesign 报 "resource fork / Finder information not allowed"
原因：.app 内部有扩展属性（xattrs，如 `com.apple.FinderInfo`）。
修法：codesign 前 `xattr -cr "$APP_BUNDLE"`，build.sh 已经加好。
如果还报，手动跑：`xattr -cr ~/Desktop/HermesPet/HermesPet.app && ./install.sh`

### 13. 灵动岛工具进度状态机（a/b/c）+ 后台对话发光（d）+ 错误态（e）

PillView 内 `@State` 维护 5 个状态机字段，全部通过 NotificationCenter 驱动：
- `taskStartTime` / `elapsedSeconds` / `elapsedTask` —— TaskStarted 时开始每秒 `Task.sleep(1s)` 自增，TaskFinished 取消
- `stepStarted` / `stepEnded` —— ToolStarted++ / ToolEnded++（按 toolId 在 ClaudeCodeClient 侧已去重）
- `changedFilePaths: Set<String>` —— ToolStarted 通知带 `file_path`，name 在 {Write, Edit, MultiEdit} 时 insert
- `diffSummaryVisible` —— TaskFinished 时若 `changedFilePaths.count > 0`，独立卡片展示 2.5s 再消失
- `backgroundStreamingCount` —— 由 ChatViewModel.broadcastBackgroundStreamingCount() 在 sendMessage 开始/结束、switchConversation 时 post 通知更新

**ClaudeCodeClient 通知 payload 加了 `file_path`**：灵动岛侧统计 Edit/Write/MultiEdit 的去重文件数，输出"已修改 N 个文件"。+/- 行数需要解析 tool_result 文本，留 P2。

**错误态显示**：connectionStatus=.disconnected 时 PillView 直接切琥珀色卡片（status 已由 HermesPetStatusChanged 通知）；点击重试通过 AppDelegate.onTapped 检测 vm.connectionStatus 后调 vm.checkConnection() —— 避免在 NSHostingView 上加第二个 click handler 跟现有 NSClickGestureRecognizer 冲突。

**后台对话发光线**：ConversationPill 新增 `isBackgroundStreaming` 参数，bottom overlay 一条 1.5pt mode 主色 Capsule + 阴影，1.2s 周期呼吸。仅 `conv.isStreaming && conv.id != activeID` 时显示。

### 12. 拖入文档：传路径而非读全文
拖入 PDF / txt / md 等文档时，**不再用 PDFKit 提文本或 UTF-8 读全文**塞进输入框，而是：
- `DragDropUtil.processFile` 只回传 `URL`（图片仍然读 PNG Data，因为图片必须传 base64）
- `ChatViewModel.pendingDocuments: [URL]` 维护附件队列，`ChatInputField` 用 `DocumentChip` 横排显示
- 发送时把路径写到 `ChatMessage.documentPaths` 字段（持久化），并通过 client 拼到 prompt 末尾
  - **Claude Code**：`buildPrompt` 末尾追加"附带的文档（请用 Read 工具按这些绝对路径查看）"+ 路径列表；`streamRaw` 把每个文档的**父目录**追加到 `--add-dir`（否则 Read 被权限拦）
  - **Codex**：`buildPrompt` 末尾追加"请用 shell 工具按这些绝对路径读取"+ 路径列表（已开 `--dangerously-bypass-approvals-and-sandbox`，cwd 之外能读）
  - **Hermes**：`attachDocumentPath` 检测 mode 为 hermes 直接 `errorMessage` 拒绝（HTTP API 访问不了本地文件系统）

**为什么这么做**：以前拖个大 PDF 要先在客户端读完全部文本（慢 + 占 context），现在桌宠本来就在用户机器上，让 AI 用自己的 Read 工具按路径访问更快、不占 context、还能让 AI 自己决定要不要只读某些段落。

### 14. 第 4 个 AgentMode：`.directAPI`（"在线 AI"，零依赖 dmg 分发档）

把 dmg 给朋友时，对方电脑大概率没装 `claude` / `codex` CLI，也没自部署 Hermes Gateway。**`.directAPI`** 这个独立 mode 就是为这种场景做的：UI 上跟 Hermes / Claude / Codex 并列，颜色 indigo / 图标 cloud.fill，只要 API Key 就能用。

**重要：跟 Hermes 完全独立**，不复用任何配置：

- **AgentMode 扩展**：Models.swift 加 `case directAPI = "direct_api"`，label "在线 AI"，iconName "cloud.fill"。10 个文件的 switch 必须全部补 case（Swift 编译器会逼着改完）：ChatView / ChatComponents / DynamicIslandController / MarkdownRenderer / ModeSprite（共用 Hermes 羽毛精灵）/ PinCardOverlay / QuickAskWindow / SettingsView / ChatViewModel / Models 自己。
- **`APIClient.ConfigSource` 嵌套 enum**（`.hermes` / `.direct`）—— 决定从哪些 UserDefaults key 读配置。ChatViewModel 同时持有两个 APIClient 实例：`apiClient` (source=.hermes，读 `apiBaseURL` / `apiKey` / `modelName`) + `directClient` (source=.direct，读 `directAPIBaseURL` / `directAPIKey` / `directAPIModel`)。
- **`checkHealth()` 按 source 分流**：Hermes 走 `<host>/health`（Gateway 自定义端点），directAPI 走 `<baseURL>/models`（OpenAI 标准）。**directAPI 把 401/403 也当"连通"** —— 智谱的 GET /models 是 403 但 chat completions 能用，不能因为 /models 403 就把状态标 disconnected。
- **`ProviderPreset.swift`**：DeepSeek / 智谱 / Moonshot / OpenAI 四家预设 + 自定义 + 本地 Hermes。模型字符串以 2026-05 各家官方文档为准（旗舰款 `deepseek-v4-pro` / `glm-5` / `kimi-k2.6` / `gpt-5.4`）。**改模型时不要凭印象拍**，去各家文档查最新 API name。
- **`SettingsView`**：configViewingMode Picker 加 4 个 case，`directAPIConfig` 视图独享 ProviderPreset Picker；Hermes 配置区恢复成原始简版（只有 baseURL/key/model 三行）。`testConnection` 按当前 configViewingMode 决定测哪一组（`ConfigSource.direct/.hermes`）。
- **`CLIAvailability` actor**：探测 `claude` / `codex` 是否在 PATH。**不能复用 ClaudeCodeClient.checkAvailable()** —— 那个走 hardcoded path `/Users/mac01/.local/bin/claude`，对方电脑上 100% 失败。这里 spawn `/bin/zsh -lic 'command -v <name>'`（必须 -l + -i 才能加载用户 PATH，GUI app 默认 PATH 缺 ~/.local/bin、brew、nvm/asdf 安装路径）；带 5 分钟缓存 + 2 秒超时（防 .zshrc 死循环）；找到的真实路径写回 UserDefaults `claudeExecutablePath` / `codexExecutablePath` 让后续 spawn 用对路径。**Swift 6 注意**：必须 actor 而非 NSLock —— async context 调 NSLock 直接编译失败。
- **`ChatViewModel.toggleAgentMode()` async cycle**：Hermes → directAPI → Claude → Codex → Hermes，切到需要 CLI 的档时探测，缺失则继续往下跳并 toast"切到「在线 AI」就能只用 API Key 聊天"。**新用户默认 mode 改成 `.directAPI`**（init 里 `?? .directAPI`），老用户保留 UserDefaults 已存的 agentMode 不动。
- **`attachDocumentPath`**：`.hermes` 和 `.directAPI` 都拒绝拖入文档（HTTP API 都读不到本地文件，只有 Claude / Codex CLI 能本地 Read）。
- **`OnboardingCard`**：`agentMode == .directAPI && directAPIKey.isEmpty` 时在欢迎页显示引导，点击跳设置。
- **`make-dmg.sh`** 内置说明文档强调"最快上手不需要装任何命令行工具" + 各家 API Key 入口。

加新预设服务商时只改 `ProviderPreset.all` 数组；不要在 SettingsView 里硬编码服务商分支。加新 AgentMode 时记得 grep 一下 `case \.hermes` 把所有 switch 都补全。

---

## 多会话设计

- 顶部最多 3 个对话胶囊（`kMaxConversations = 3`）
- `ChatViewModel.messages` 是 computed property，读写都落到 `conversations[activeIndex].messages`
- 流式更新用 (conversationID, messageID) 精确定位，**用户中途切对话也不会写错位置**
- 存储 `~/.hermespet/conversations.json`，自动从旧版 `session.json` 迁移

---

## 状态
- `TODO.md` 是优先级路线图（**做完任何一项立即从 `[ ]` 改成 `[x]` 并写明做了什么**）
- 大部分 P0-P3 已完成；P0-Bug 还剩：截图 250ms 硬编码 / GlobalHotkey 注册失败检测
- 当前版本：v1.0

---

## 给未来 Claude 的工作流约定

用户对此项目长期维护，已经踩过的坑非常多。每次新会话启动**先做这三件事**：

1. **读这个 CLAUDE.md**（你正在读的）—— 项目结构 + 14 条关键决策
2. **读 `TODO.md`** —— 知道当前进度和待办优先级
3. **改代码前看 README.md** —— 用户视角的功能说明

### 工作时的硬规则

- **做完任何一个 task / 修完一个 bug，立刻更新 `TODO.md`**：把对应项从 `[ ]` 改成 `[x]`，写一句做了啥。这是用户明确要求的。
- **改完代码立即编译验证**：`cd ~/Desktop/HermesPet && ./build.sh 2>&1 | grep -E "error:|Build complete"`
- **部署用 `./install.sh` 而非 `./build.sh`**：build.sh 只产出 `~/Desktop/HermesPet/HermesPet.app`（用户不会跑这个），install.sh 才会覆盖到 `/Applications`。用户启动的永远是 `/Applications/Hermes 桌宠.app`
- **codesign 失败常见原因**：xattr 没清，`xattr -cr ~/Desktop/HermesPet/HermesPet.app` 再 install
- **macOS 26 + Swift 6 对 isolation 极严**：碰到回调类系统 API（Speech / AVFoundation / SCStream / TCC），class 改 `@unchecked Sendable`+NSLock，**不要**用 @MainActor 类
- **任何 `@Observable var` 加上时必须确认 View 有对应渲染**，否则等于 dead state（errorMessage 那次教训）
- **加新 AgentMode 时**：检查 `streamCompletion` 是否传图（Hermes/Claude/Codex 各有不同方式，见上文决策 #8）

### 用户偏好（已观察到的）

- 中文沟通（全局 CLAUDE.md 已规定）
- 极简 UI、避免突兀悬浮、用图标不用文字
- 设计风格参考 Apple HIG（特别是 iMessage 输入栏）
- 对 UI 细节敏感（光标偏移、padding、Capsule 半圆都被指出来过）
- 喜欢"一键修完 + 立即看到效果"的体验，不爱反复打补丁
- 编程经验有限，**不要扔代码片段让他自己拼**，要完整 Write 文件 + Edit 文件 + 跑脚本
