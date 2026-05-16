# HermesPet 优化路线图

## [Review] 2026-05-16 hover trinity 10 人评审 + 修复 ✅
- [x] 10 个并行 reviewer 审查本分支 (feat/mini-reply-card) 全部新增/改动
- [x] R1 MiniReplyCardController（新文件 333 行）/ R2 hover 进出判定 / R3 ChatViewModel / R4 AppDelegate / R5 Swift 6 并发 / R6 ChatComponents IME / R7 ChoiceMenuOverlay / R8 CLIAvailability+Settings / R9 内存泄漏 / R10 编译验证
- [x] 真实修复 2 处：
  - ChatWindowController Esc handler 去掉冗余 `Task { @MainActor in }` 包装（类已 @MainActor，省 1 runloop hop）
  - MiniReplyCardController.show() 的 16ms insertion task 现在存到 `insertionTask` 字段，快速重复 show / hideNow 时先 cancel，避免两个 task 都翻 isVisible
- [x] 误报排查：R2 三个 Critical（hoverExitHideTask race / gap geometry / NSApp.windows）均基于"@MainActor 非串行"错误前提；R9 两个 HIGH（singleton observer 永不 remove）agent 自承认"singleton 永驻无害"
- [x] 编译 + install.sh 全绿，PID 15514 启动验证

## [P0] 界面体验 ✅
- [x] Markdown 渲染：标题、粗体、斜体、行内代码、链接
- [x] **Markdown GFM 表格渲染** —— `MarkdownRenderer` 加 `Block.table` + `TableBlockView`（SwiftUI Grid 列宽自动对齐）。解析支持 `:--/--/-:/:-:` 列对齐符；表头加底色+加粗+底部 hairline、隔行底色、行间细线、单元格内复用 InlineMarkdownView（bold/italic/code/link 全部生效）、长内容自动换行不横滚。流式期间至少 header+separator 两行齐了才进入表格识别，避免半截被错位渲染。空 cell 用 `Text(" ")` 占位防列塌缩
- [x] 代码块：深色背景 + 语言标签 + 复制按钮（带"已复制"反馈）
- [x] 输入框：Enter 发送，Shift+Enter 换行（NSTextView 原生拦截）
- [x] 输入框多行自动扩展：内容长高时容器跟随，最高 100pt 内部滚动
- [x] 输入框 Apple HIG 重做：Capsule 容器 + 28pt 圆按钮 + focus 克制反馈
- [x] 光标对齐：消除 NSTextView lineFragmentPadding，placeholder 严格对齐光标
- [x] 消息气泡：头像 + 渐变色 + 时间戳 + 角色标签
- [x] 流式打字光标：assistant 流式生成时末尾闪烁窄方块
- [x] 每条消息 hover 复制：右上角浮现复制图标，复制后短暂显示对勾
- [x] 错误消息可重试：`❌` 开头的消息底部加"重试"按钮
- [x] 拖拽图片到输入框：tint 色虚线框反馈，自动加入待发送队列
- [x] 连接状态指示：菜单栏 + 灵动岛实时显示
- [x] 流式打字机节流：40ms 间隔刷新，减少 SwiftUI 重渲染压力
- [x] MessageBubble 跟随 mode 切换头像/标签（Hermes 绿 / Claude 橙 / Codex 青）
- [x] 图标统一：兔子 → sparkle ✦（Claude 品牌风）
- [x] AI 编号列表自动渲染为可点击选项卡片：点击直接发送对应内容

## [P1] 功能增强 ✅
- [x] 对话历史持久化（JSON 存储 + 自动保存/加载 + 旧版自动迁移）
- [x] 全局快捷键 **Cmd+Shift+H** 呼出/隐藏
- [x] 全局快捷键 **Cmd+Shift+J** 截屏并附加
- [x] 全局快捷键 **Cmd+Shift+V** 按住说话（push-to-talk）+ Apple Intelligence 屏幕光环 + 音效
- [x] 导出对话为 Markdown（聊天头部一键导出，含时间戳/角色）
- [x] 多会话胶囊：最多 3 个，顶部数字胶囊切换，独立 messages
- [x] 对话胶囊右键重命名：popover 输入框，回车确认
- [x] 新对话快捷启动建议：欢迎页 4 个分类卡片，点击填入输入框
- [x] 截图功能（ScreenCaptureKit）：替换 deprecated CGDisplayCreateImage，自动排除桌宠自己窗口
- [x] 图片附件：粘贴板 / 拖拽 / 截屏 → pendingImages 统一处理
- [x] **接入 OpenAI Codex CLI**：第三种 AgentMode，支持代码 + 生图
- [x] **Codex 生成的图片自动显示在 assistant 气泡里**（单图大显示 / 多图 2 列网格 / 点击放大）
- [x] 音效系统：按住语音 + 任务完成两个时机的音效可在设置里换 / 关掉

## [P2] 技术质量 ✅
- [x] 菜单栏图标状态指示（绿色=连接正常 / 红色=断开 / 灰色=未配置）
- [x] 菜单栏右键菜单：打开 / 关闭、截屏、退出
- [x] 自动重连机制（每 30 秒自动检测连接状态）
- [x] 友好错误提示（401/404/cannot-connect 等都汉化）
- [x] 支持取消正在进行的请求（loading 时按钮变停止）
- [x] 多 Agent 支持：Hermes Gateway + Claude Code CLI + OpenAI Codex CLI **三模式**
- [x] 开机自启（SMAppService）
- [x] 稳定签名：build.sh 自动用 Apple Development 证书 → TCC 权限不再丢失
- [x] Claude Code 权限：`--permission-mode acceptEdits` + `--add-dir` 让 Read/Write 工具可用
- [x] 分发打包：make-dmg.sh 生成 ad-hoc 签名的 DMG，含安装指引
- [x] 本地安装脚本：install.sh 一键构建 + 覆盖装到 /Applications + 启动
- [x] 项目文档：README.md / CLAUDE.md / TODO.md 三层文档体系

## [P3] 灵动岛 ✅
- [x] 灵动岛胶囊：刘海下方浮动药丸，实时连接状态
- [x] 刘海屏融合：极简 idle 态 + 悬停展开，左右两端图标布局
- [x] 任务状态指示：右耳显示 Claude 风三点脉冲 loading + Face ID 风格画线对勾
- [x] 按住语音时显示红色脉冲麦克风图标
- [x] 截图通知：截屏成功 / 失败短暂展开胶囊提示
- [x] 聊天内切换模型/Provider（点头部直接切，无需进设置）

---

## [P0-Bug] 🔥 优先修的 Bug
- [x] **CPU 100% 卡死全面修复**（2026-05-16）—— 10 人审查团队 R1+R2 + lead 实证 sample 文件，根因锁定 ClawdWalk 30Hz Timer→setFrameOrigin→跨进程 XPC fence + AppDelegate 启动 16 服务对称率 31%。一次性修 6 处：(1) ClawdWalkOverlay 加 `setWindowOriginIfNeeded` helper，5 处 setFrameOrigin 改用 deltaPos<0.5pt 跳帧（保 30Hz 视觉、消 ~60% 跨进程 XPC fence）；(2) ClawdWalk Timer closure `Task { @MainActor in self?.tick() }` 改 `MainActor.assumeIsolated { self?.tick() }`（省 30 Task/秒 spawn）；(3) AppDelegate.applicationWillTerminate 补 iconTimer.invalidate / MouseTracking.stop / IdleStateTracker.stop / 2 个 removeObserver；(4) ChatViewModel.checkConnection 4 case 合并成单个 connectionCheckTask 句柄 + [weak self]，每次调用前 cancel 上次（消 5s 轮询堆积）；(5) MarkdownTextView parseBlocks 加 NSCache by content（countLimit=100），消流式 30fps 全文 re-parse；(6) APIClient.watchdog sleep 后立即 `if Task.isCancelled { return }`，避免 sleep 期间被 cancel 还继续 await。Sample 实证 `_setFrameCommon` 主线程帧从 26→10（-62%）+ WMClient XPC 3→1（-33%）。R1 同时证伪 5 个 false alarm（A#2 layout cycle 回归、A#6 ForEach diff、C#2 errorMessage dead state、D#3 Key 隔离、A#1 MouseTracking idle 主因）
- [x] **errorMessage 没显示到 UI** —— 加了顶部 ErrorToast，3.5s 自动消失，可手动 ×
- [x] **截图前隐藏窗口的 250ms 硬编码** —— sleep 缩到 50ms（alphaValue=0 是即时变化，CALayer 一帧 commit + 余量足够），慢电脑也更稳
- [x] **GlobalHotkey 注册失败检测** —— RegisterEventHotKey 返回值检查，被占用时灵动岛弹通知告知具体哪个热键失败
- [x] **Codex 模式不识别附图** —— 修了，spawn `codex exec` 时加 `-i <path>` 传图（codex CLI 原生支持视觉），且必须用 `--` 终止 flag 解析
- [x] **多对话 streaming 时切换被卡住** —— isLoading 改 computed property 反映 active 对话的 isStreaming；task 改字典按 conversationID 存；切对话不影响其他对话
- [x] **AI 任务规划 → 可派发任务卡片** —— Pin 从静态摘要升级成"AI 任务调度入口"。AI 识别"今天要做哪些事"类输入时输出 ` ```tasks fence YAML`（每项 title/desc/mode/eta），客户端解析为 `PlannedTask` 数组，聊天气泡里渲染成可操作卡片（标题加粗 + 描述 + mode 徽章 + ETA + 3 个按钮）：📌 Pin（转任务 Pin，左侧 checkbox 可勾、勾了删除线+灰但不消失）/ 🤖 让 AI 做（自动新建对话派发给推荐 mode + 把任务作首条消息 sendMessage）/ ✗ 跳过（本地 dismissed state）。配套：`kMaxConversations` 3→8 + ConversationPills 改横向 ScrollView 自动滚到 active + ⌘1~⌘8 直达 + 三个 client（Hermes/Claude/Codex）prompt 都加任务规划约定，Hermes 走 OpenAI 兼容 system message
- [x] **Pin layoutAll 改 animate:false 修第二轮闪退** —— v3 重做去掉 hover 展开后还是崩。从最后一个 NSException backtrace 看：`NSHostingView.windowDidLayout → updateAnimatedWindowSize → invalidateSafeAreaInsets → setNeedsUpdateConstraints → NSException`。根源是 `layoutAll` 在用 `setFrame(animate:true)` 让多个 pin 窗口同时跑动画 → macOS 26 + SwiftUI 多 NSHostingView 同时 animated setFrame 在 commit 阶段反向调 setNeedsUpdateConstraints 触发 AppKit 异常。修法：layoutAll 改 `animate: false`（瞬移），pin 重排本来就不是入场动画，瞬间到位体验完全自然
- [x] **Pin 卡片 v3 重做（精致静态摘要 + 单击转聊天）** —— 直接去掉 hover 展开整套逻辑，从根本上消除嵌套 layout 崩溃源。新设计：固定 280x124pt 卡片、顶部 mode 主色渐变细色条作视觉锚点、22pt mode icon 圆形徽章 + 标题、2 行内容摘要（PinCard.summary 智能跳过标题行+markdown 前缀符号）、footer 显示 "mode label · 相对时间"（刚刚/X 分钟前/昨天/M月d日）。交互：hover 仅描边+阴影+1.015 scale 强调不变形（彻底没 setFrame 嵌套）；单击=转聊天（替代双击）；hover 时复制按钮淡入、footer 右侧显示"打开 ↗"。删除 expandedMaxHeight/handleHoverExpand/PinContentHeightKey/onHoverExpandedChange/contentHeight 整套
- [x] **底部输入栏长文本布局修复** —— 输入框从 Capsule HStack 改成固定圆角输入面板，发送按钮 overlay 固定在右下角；文本区加足左右/底部安全内边距，多行中文不再贴边、裁切或挤到发送按钮下面
- [x] **关于页全局快捷键可自定义** —— 关于页四个快捷键行改成可点击录制按钮；按下新组合后写入 UserDefaults，并通知 GlobalHotkey 立即注销旧热键、注册新热键，无需重启。录制支持单键和 fn 参与的组合键；fn/地球仪单独作为系统级 modifier 时取决于 macOS 是否发送普通 keyDown
- [x] **聊天窗打开后第一次按键被吞** —— `ChatWindowController.show` 在入场动画 0.34s 完成后才调 `window.makeKey()`，且**从来没显式 makeFirstResponder** 给 NSTextView。后果：用户打开聊天窗立刻打字，前 340ms 因为 window 不是 key、按键吞掉；动画完后 firstResponder 默认是 contentView 仍不接键盘，必须用户主动点输入框才能开始打字。修法：(1) `orderFront` 后立刻 `makeKey` + `activate` + `focusInputField()`（递归找 contentView 里第一个 NSTextView 并 `makeFirstResponder`）；(2) 动画完成 handler 兜底再 focusInputField 一次（防 SwiftUI 的 NSHostingView 在动画期间才 mount 完输入框）
- [x] **GUI 启动 Codex 报 `env: node: No such file or directory` / 一直打转** —— Dock/Finder 启动的 App 拿不到终端里的 PATH，npm 安装的 `codex` / `claude` shebang 走 `/usr/bin/env node` 时找不到 Node。新增 `CLIProcessEnvironment` 统一构造子进程环境：复用 `CLIAvailability` 从 login shell 探测到的 PATH，并追加 executable 所在目录、Homebrew、~/.local/bin、mise/asdf 常见目录；Claude/Codex spawn 全部接入。随后补齐 stdin=/dev/null + 持续 drain stderr，避免 Codex 等额外 stdin 或 warning pipe 堵塞导致聊天气泡一直显示 thinking dots。StorageManager 启动加载时也会把历史里残留的 `message.isStreaming=true` 标成"上次生成被中断"，防止安装/退出半路留下永久转圈
- [x] **Codex 每条消息都像新会话一样慢** —— 之前 `CodexClient.streamCompletion` 每轮都重新 `codex exec` 并把完整聊天历史拼进 prompt，导致 Codex 每条消息都经历冷启动/插件加载/WebSocket 预热。现在按 HermesPet `conversationID` 持久化 Codex `thread_id`：首次请求收到 `thread.started.thread_id` 后写入 UserDefaults，后续同一对话走 `codex exec resume <thread_id>`，只发送最新用户输入 + 附件路径；清空/关闭对话时同步清掉绑定 session
- [x] **聊天区手动上滑会被流式输出拉回底部** —— `ChatView.messagesView` 之前在最后一条 streaming content 每次变化时无条件 `scrollToLast`，用户双指上滑看历史会马上被抢回底部。新增底部 invisible anchor + `MessagesBottomYPreferenceKey` 监听是否贴近底部；只有用户本来在底部附近才自动跟随流式输出，手动上滑后不再抢滚动；主动发送消息时仍强制恢复到底部
- [x] **在线 AI 选了服务商还要手填模型 / 测试连接报不支持 URL** —— SettingsView 首次打开时 Picker 默认显示 DeepSeek 但没有把 preset.baseURL 写进 `directAPIBaseURL`，预设模式又隐藏 API 地址，导致用户看起来选了服务商实际请求空 URL。修法：进入设置时 `ensureDirectProviderConfig()` 真正写入预设 baseURL/defaultModel；非自定义服务商时“模型”改成预设模型 Picker（默认模型 + altModels），只有自定义服务商才显示可手填模型名
- [x] **在线 AI 增加回复偏好（默认平衡）** —— 新增 `DirectResponsePreference`：快速 / 平衡 / 深度，`ChatViewModel.directAPIResponsePreference` 持久化到 UserDefaults，默认 `.balanced`。ProviderPreset 为每家服务商维护 fast/balanced/deep 到实际模型字符串的映射；SettingsView 预设服务商下显示“回复偏好”分段控件 + 当前模型只读预览，切换偏好自动更新 `directAPIModel`，自定义服务商仍保留手填模型名
- [x] **在线 AI 测试连接误把错误 Key 当已连接** —— 之前 directAPI 的测试先走 `/models`，为了兼容智谱 GET /models 403，把 401/403 也当“服务商连通”，导致 DeepSeek Key 切到智谱也显示已连接。现在 SettingsView 的在线 AI 测试连接直接发一条真实 `chat/completions` ping，只有 Key + 服务商 + 模型都可用才显示“Key 与模型可用”；401/403 明确提示“API Key 不属于当前服务商或无权限”
- [x] **在线 AI 的 API Key 按服务商独立保存** —— 之前所有预设共用 `directAPIKey`，用户填了 DeepSeek 后切到智谱输入框仍显示 DeepSeek key，容易误导。现在 SettingsView 切换服务商时读写 `directAPIKey.<providerID>`，没配置过的服务商显示空并提示“当前服务商尚未配置 Key”；`directAPIProviderID` 记录当前服务商，ChatViewModel 初始化时优先恢复对应 Key，保留旧 `directAPIKey` 作为迁移兜底
- [x] **在线 AI Key 迁移与真实请求读取修正** —— 修掉服务商独立 Key 的两个边缘坑：设置页首次打开时如果旧版全局 `directAPIKey` 尚未迁移，会按当前识别出的服务商迁到 `directAPIKey.<providerID>`，不会先写空把旧 Key 清掉；APIClient direct 请求也改为优先读取当前 `directAPIProviderID` 对应的服务商专属 Key，只有专属 Key 尚不存在时才回退旧全局 Key，避免 UI 显示对了但实际请求仍用错 Key
- [x] **在线 AI 自我身份幻觉成 Codex/Claude** —— APIClient 的 system prompt 从静态字符串改为动态 prompt：Hermes 注入当前模式/模型；directAPI 注入“当前模式：在线 AI”、服务商名、真实模型、回复偏好，并明确要求除非当前模式就是 Claude Code/Codex，否则不要自称 Claude/Codex 或说自己处在 Codex 模式。streaming 与非 streaming 请求共用同一份 prompt，避免测试和正式聊天不一致
- [x] **恢复对话数字胶囊 hover 关闭按钮** —— 用户更喜欢原来的“鼠标放上去展开，点小叉关闭”体验。ConversationPill 恢复 hover 展开，但把数字切换区和 `xmark` 关闭区分开：数字仍负责切换，右侧小叉仅 hover 时淡入；右键菜单和 ⌘⌫ 继续保留
- [x] **Pin hover 展开 / 创建 / 关闭闪退（SIGABRT 嵌套 layout）** —— 崩栈是 `NSDisplayCycleObserverInvoke → CA::Transaction::commit → _objc_terminate`。原因：`PinCardController.handleHoverExpand` 在 SwiftUI `.onPreferenceChange` / `.onHover` 同步栈里直接调 `win.setFrame(animate:true)` + `layoutAll` 改其他 pin 窗口 frame；NSHostingView 重测高度 → preference 又上报 → 死循环引发多窗口嵌套 layout cycle，macOS 26 抛 NSException 必崩。修法（同 CLAUDE.md 决策 #5）：1) `handleHoverExpand` / `pin()` / `close()` 内部 setFrame + layoutAll 全部用 `DispatchQueue.main.async` 隔到下一个 runloop；2) 幂等短路（当前高度 vs target 差 < 4pt 跳过 setFrame）；3) `onPreferenceChange` 加 4pt 节流避免反复上报
- [x] **mode 绑定到 Conversation（多 CLI 真并行）** —— 以前 agentMode 是全局变量，切对话不切 mode，三个对话间互相污染（用户切到对话2 还在用对话1 的 CLI）。改成 `Conversation.mode` 字段，新建时继承 lastUsedMode，**发出第一条 user 消息后锁死**。Header 的 mode 切换器同步：未锁定时显示 chevron 可切；锁定时显示 `lock.fill` 图标，点一下弹 toast 提示新建对话。切换/关闭/新建/Pin/早报/快问迁移对话时统一 post `HermesPetModeChanged` + `checkConnection()`，让灵动岛精灵和连接状态都跟着 active 对话走。设置面板的"聊天对象"Picker 改成"查看配置"，仅切换显示哪一个 mode 的配置项，不动正在进行的对话
- [x] **issue #3：语音唤醒和截屏高占用 / SIGABRT 嵌套 layout（2026-05-15 hotfix）** —— 用户 .ips 是 `NSHostingView.windowDidLayout → updateAnimatedWindowSize → setFrame → setNeedsUpdateConstraints → NSException`，跟决策 #7 一字不差。sample 显示主线程 1273/1273 全在 SwiftUI `GraphHost.flushTransactions` + LazyVStack 布局，物理内存 2.6 GB。三处修法：(1) `ChatView.body` 的 `.frame(minWidth: 360, minHeight: 360)` → `.frame(maxWidth: .infinity, maxHeight: .infinity)`，让 NSWindow.contentMinSize 单点控制最小尺寸 —— 直接消除 ChatWindow hide() 缩到 100×30 时 SwiftUI 反推 setFrame 的崩源；(2) `VoiceTranscriptOverlay.updateText` 每次 partial 都 `setFrame(... display:true)` + `.animation(value: state.text)` 一秒堆 20+ 段动画，改成"宽度等级 + 120ms 节流"才 setFrame、删 text animation；(3) `IntelligenceOverlay.AnimatedGlow` TimelineView 从 `.animation` 改成 `.periodic(1/30s)`、最贵的"内反光"第 4 层删掉、外层 blur 半径 36~52pt 减到 18~24pt —— GPU/CPU 工作量直接减半

## [P1-推荐] 💎 高价值低成本优化
- [x] **错误 Toast 系统**：errorMessage 在聊天窗口顶部 toast 显示
- [x] **清空对话加 confirm**：点垃圾桶弹 confirmationDialog
- [x] **Codex 图片持久化**：图片复制到 `~/.hermespet/images/`，message 存路径，重启后从路径恢复 Data
- [x] **后台对话完成未读 dot**：胶囊右上角红点 + Conversation.hasUnread 持久化
- [x] **用户消息气泡显示图片缩略图**：user 气泡上方加附图网格 + 用户上传图也走持久化
- [x] **用户消息气泡显示文档附件芯片**：user 气泡上方在图片下方再叠 AttachedDocumentsRow，DocumentChip 加 isReadOnly 模式，重启后历史里也能看到附了哪些文档

## [P1-体验] 体验型升级

- [x] **Hover 体验三件套**（2026-05-16）—— 用户提议"hover 灵动岛自动展开聊天框"。调研后判断完整 hover 自动展聊天窗有崩溃风险（CLAUDE.md 决策 #5 跨窗口 setFrame 嵌套 layout，过去半年的 [P0-Bug] 里约 1/3 跟这个相关）+ HIG 反模式（hover 触发主交互）+ macOS 顶部高鼠标流量误展开。跟用户对齐后分三层落地：
  - **默认始终生效（PR1：hoverCard 增强）** —— `DynamicIslandController.hoverCard` 在原 mode 图标 + 状态点 + 模型名基础上，加最近一条 AI 回复预览（60 字截断，markdown 已 strip 通过 `ChatViewModel.stripMarkdownForPreview`）+ 未读后台对话数胶囊。`ChatViewModel.broadcastHoverContext()` 在 TaskFinished / switchConversation / newConversation / init 末尾 post `HermesPetHoverContextChanged` 携带 `preview` + `unreadCount`。View 端 @State 缓存。**hotfix（2026-05-16）**：第一版让 `currentHeight` 在 hover+preview 时多让 22pt → SwiftUI 反推 NSHostingView.updateAnimatedWindowSize → 嵌套 layout SIGABRT（CLAUDE.md 决策 #5/#7 同一类坑）。改成 preview 用 **`.overlay(alignment: .bottom)` 不参与 SwiftUI layout** + offset y=22 推到 hoverCard 下方 + 自带黑底胶囊作视觉容器，`currentHeight` 完全恢复原状
  - **任务完成迷你卡片（PR2：MiniReplyCardController）** —— 新建 `Sources/MiniReplyCardController.swift`（照搬 ClawdBubbleOverlayController 模式：独立 NSWindow + canBecomeKey=false + level=auxiliary）。订阅 `HermesPetTaskFinished`（新增 `conversationID` / `isActive` / `preview` / `mode` userInfo），仅 `success && isActive && !preview.isEmpty && !chatWindow.isVisible` 四个门禁同时满足才弹。320×150pt 卡片在灵动岛正下方，3.5s 自动淡出（hover 暂停淡出 → 离开 1.5s 后继续）。"展开聊天"按钮 = 打开聊天窗 + 立即收卡片；"复制"按钮 = 复制 preview + "已复制"反馈
  - **Hover 展开聊天窗（PR3：opt-in 开关）** —— ChatViewModel 加 `hoverExpandChatEnabled` UserDefaults 持久化字段（默认 false）；SettingsView 桌宠 section 加 toggle。`DynamicIslandPillView.handleHoverForExpand` 500ms 防误触 task：hover 进入启动，hover 离开 cancel，500ms 到 post `HermesPetHoverExpandRequested`。`ChatWindowController.show(near:hoverMode:)` 加 `hoverMode` 参数，hoverMode=true 时装 `NSEvent.addLocalMonitorForEvents` 监听 Esc → hide；`windowDidResignKey` 仅在 hoverMode 时通过 `DispatchQueue.main.async` 异步 hide（CLAUDE.md 决策 #5 跨窗口 setFrame 安全）；hide() 总是重置 isInHoverMode=false + 卸载 key monitor。⌘⇧H / 单击灵动岛走原 toggle 通道，hoverMode=false，不受 focus 锁定影响
- [x] **按住语音时实时显示识别字幕** —— 新建 VoiceTranscriptOverlayController（独立 NSWindow），订阅 HermesPetVoiceStarted/Partial/Finished/Cancelled；灵动岛下方约 18pt 浮一个 ultraThinMaterial Capsule 显示"🎙 正在听… / 实时识别文字"，宽度按字数自适应（220~700pt）。让用户按住时就能确认说没说对，不必等松手
- [x] **键盘快捷键**：`⌘N` 新对话 / `⌘[` 上一对话 / `⌘]` 下一对话 / `⌘1/2/3` 直达序号 / `⌘⌫` 关闭对话（⌘W 留给关窗口）
- [ ] 跨对话搜索历史消息
- [x] **拖入文档（PDF / txt / md）让 AI 读** —— ChatView 顶层全窗口接收拖入；DragDropUtil 统一处理：图片→pendingImages、文档→只回传 URL（不读全文）；拖入时全窗口出现 tint 虚线框 + "释放以附加"卡片提示
- [x] **拖入文档改为传路径而非读全文** —— 拖入只记录 URL 到 `pendingDocuments`，发送时 Claude 模式把父目录追加到 `--add-dir`、prompt 末尾附路径让 Claude 用 Read 工具自己读；Codex 同样在 prompt 写路径靠已绕沙箱的 shell 读；Hermes 模式直接 errorMessage 拒绝（OpenAI API 没法访问本地）。ChatInputField 增 DocumentChip 横向列表显示附件，hover × 删除，tooltip 显示完整路径
- [x] **用户消息里的图片支持点击放大预览** —— user 气泡复用 AssistantImagesGrid 自动获得
- [x] **流式 Markdown 渲染 debounce** —— throttle 从 40ms 改 80ms，长回复 CPU 减半（视觉仍流畅 ≈12fps）
- [x] **聊天窗口超出屏幕底部时自适应** —— defaultFrame 检测 anchor 到屏幕底的可用空间，超出时收紧高度（min 360pt）；横向也夹回 visibleFrame
- [x] **欢迎语视觉升级** —— WelcomeView 替代纯文字：大号 mode 图标 + 渐变光晕 + 呼吸动画 + 标题 + 副标题（按 mode 定制文案）
- [x] **时间戳跨天显示日期** —— 今天 HH:mm，昨天 "昨天 HH:mm"，更早 M月D日 HH:mm
- [x] **独立的「在线 AI」模式（无 CLI / 零依赖）** —— 为分发给没装 claude/codex 的朋友做。设计上是**第 4 个 AgentMode**（`.directAPI`，cloud.fill 图标 + indigo 主色），跟 Hermes / Claude Code / Codex 并列，独立的 UserDefaults 三件套（`directAPIBaseURL` / `directAPIKey` / `directAPIModel`），不复用 Hermes 那一套。具体内容：
  - **AgentMode 扩展**：Models.swift 加 `case directAPI = "direct_api"`，label "在线 AI"，iconName cloud.fill。10 个文件的 switch 全部补 case（ChatView / ChatComponents / DynamicIslandController / MarkdownRenderer / ModeSprite 让它共用 Hermes 羽毛精灵 / PinCardOverlay / QuickAskWindow / SettingsView / ChatViewModel）。
  - **APIClient 改造**：引入 `ConfigSource` 嵌套 enum（.hermes / .direct），决定从哪些 UserDefaults key 读 baseURL/apiKey/modelName。ChatViewModel 持两个 APIClient 实例：`apiClient` (source=.hermes) + `directClient` (source=.direct)。checkHealth 按 source 分流：Hermes 走 `/health`，directAPI 走 OpenAI 标准 `/models`，对 401/403 也算"连通"（智谱 GET /models 不开放是 403 但 chat 能用）。
  - **ProviderPreset.swift**：内置 DeepSeek / 智谱 GLM / Moonshot Kimi / OpenAI 四家 OpenAI 兼容服务商预设（旗舰模型：`deepseek-v4-pro` / `glm-5` / `kimi-k2.6` / `gpt-5.4`，备选模型也写进 altModels）。
  - **SettingsView**：configViewingMode Picker 加 4th case，directAPIConfig 视图含 ProviderPreset Picker + 三个独立字段 + 服务商注册链接 + 备选模型提示。Hermes 配置区恢复成原始简版（不含预设 Picker）。`testConnection` 按 configViewingMode 决定测哪一组（ConfigSource.direct/.hermes）。
  - **CLIAvailability.swift**（actor）：`zsh -lic 'command -v <name>'` 探测 claude/codex CLI 是否在 PATH，带 5min 缓存 + 2s 超时；发现的真实路径写回 UserDefaults 让 ClaudeCodeClient/CodexClient 后续 spawn 用对路径。
  - **ChatViewModel**：toggleAgentMode 改成 async 4 态 cycle（Hermes → 在线 AI → Claude → Codex），切到需要 CLI 的 mode 时探测，缺失则跳过并 toast "切到「在线 AI」就能只用 API Key 聊天"；attachDocumentPath 现在 `.hermes` 和 `.directAPI` 都拒绝拖入文档（HTTP API 都读不到本地文件）；**新用户默认 mode 改成 `.directAPI`**，老用户保留原 mode（UserDefaults 已存的 agentMode 优先）。
  - **ChatView OnboardingCard**：`agentMode == .directAPI && directAPIKey.isEmpty` 时在欢迎页显示"先选个 AI 服务商再聊天"卡片，点击跳设置。
  - **dmg 分发**：make-dmg.sh 说明文档强调"最快上手不需要装命令行工具" + 各家 API Key 入口链接。dmg 体积 1.8MB

## [P0-生命感] 🪄 灵动岛多状态 + 桌宠生命感（v1 已落地）

> 目标：让灵动岛从"静态指示器"变成有性格的小精灵，把"AI 在干啥"透出来，让用户不打开聊天窗就能监工。
> 三个 mode 各自有标志性视觉元素，状态切换全部用 `matchedGeometryEffect` 形变，永不"消失再出现"。
>
> **v1 已发布**：ModeSprite + LifeSigns + 设置开关。后续 v2 再做工具事件透出 / 后台发光 / 偷瞄打哈欠。

### 1. 状态形态系统（8 种，从小到大形变）
- [x] **idle 极简圆点** —— `IdleModeDot` 12pt mode 主色 + 2s 周期呼吸（alpha 0.6→0.85），替代之前 14pt sprite。5min 系统无活动 → 圆点 dim 缩 0.82 + 飘 "z"（由 `IdleStateTracker` 用 `CGEventSource.secondsSinceLastEventType` 监测）
- [x] **hover 展开** —— hoverCard 里 sprite 从 18pt 升到 22pt，跟 idle 圆点形成视觉对比
- [ ] **thinking 三点脉冲** —— 已有，确认在新形变系统里平滑接入
- [ ] **工具调用透出（Claude only）** —— `[ ✦ 正在读 README.md ]` 文件名跑马灯，文本超出 200pt 时滚动
- [x] **按住说话波形** —— ListeningMic 重写：5 段竖条 + 红色脉冲背景；VoiceInputController 已发的 HermesPetVoiceLevel(0~1) 通知直接喂给灵动岛 voiceLevel @State，每段按阶梯映射高度（2pt → 10pt）
- [x] **截屏快门** —— 0.18s 白色闪光（blendMode .plusLighter 叠加在 NotchShape 上）+ scale 1.0→1.06→1.0 反弹（spring response=0.18, damping=0.55），通过 HermesPetCaptureShutter 通知触发
- [x] **完成对勾** —— Face ID 风画线对勾基础上增加 3 层：① 白色 shimmer 25% 长度段沿路径扫过（plusLighter 混合）② mode 主色光晕环从中心扩散到 2x（0.7→0 淡出）③ 整体动画时序：0.42s 描边 → shimmer + glow 同时启动
- [x] **错误态** —— connectionStatus=.disconnected 时灵动岛切琥珀色 `⚠️ 连接已断开 · 点击重试`；AppDelegate.onTapped 检测到 .disconnected 状态时同步调用 viewModel.checkConnection() 再 toggle 聊天窗

### 2. 三个 Mode 的"小精灵"动画
- [x] **Claude 模式 —— Clawd 像素小家伙** 🦞 —— 从 claude CLI 二进制挖出 4 个姿势 (rest/lookLeft/lookRight/armsUp) 的 Unicode 半块字符像素图，用 Canvas 解析 2×2 子像素绘制。橘色 #D77757。1.5:1 终端真实比例。**4 套动画**：idle rest / 偶尔 look 左右看 (25-50s 随机) / 工作中 armsUp↔rest jump / 完成时 3 次 armsUp celebrate。Claude 模式下不挂 LifeSignsModifier 避免 scale 让像素糊 (ModeSprite.swift::ClaudeKnotSprite + ClawdView + ClawdPose)
- [x] **Clawd 整体放大（不重画像素图）** —— 12×4 重画方案试过但**丢失原版可爱感**，已回退到 9×3 原版。保留 clawdHeight 系数 1.15→1.4 + 灵动岛 size 11→14 (idle) / 13→18 (hover/工具/diff)，靠 nearest-neighbor 放大让原版 Clawd 显示更大但保留萌态。**经验**：Anthropic 设计师精调过的像素图不要乱拼，只调显示尺寸即可
- [x] **Hermes 模式 —— 绿色羽毛** —— `leaf.fill` SF Symbol + 绿渐变；常驻 ±4° 摆动，工作时摆幅升到 ±12°，频率从 3s 加快到 1.2s (HermesFeatherSprite)
- [x] **Codex 模式 —— 青色 `</>`** —— `chevron.left.forwardslash.chevron.right` SF Symbol + 青渐变；工作中右侧叠一个 0.45s 闪烁的细竖线作为光标 (CodexCursorSprite)
- [x] **Claude 工具事件细分动画** —— ClaudeCodeClient 解析 stream-json 的 tool_use（assistant content）+ tool_result（user content），按 tool_id 去重发 HermesPetToolStarted/Ended 通知。ToolKind 映射 9 类工具到 SF Symbol + 中文动词 + 渐变色（Read→🔎放大镜银 / Write→✏️钢笔金 / Bash→🔧扳手银 / Search→搜索文档 / Web→🌍 / Todo→checklist紫 / Task→👥橘 / 默认扳手）。ToolOverlay 替换 WrenchOverlay。Clawd 收到 ToolStarted 自动切换手持工具。灵动岛收到 ToolStarted 展开成"工具状态卡片"：[Clawd 拿工具] [verb] [arg(monospaced)]，例如"正在读 README.md"。TaskFinished/TaskStarted 时收回
- [x] **Codex 工具事件透出** —— CodexClient 解析 item.started/completed（非 agent_message/reasoning）按 item.id 去重发 HermesPetToolStarted/Ended；codexArgSummary 抽 command/path/query/url 摘要；ToolKind.from 加小写关键字兜底匹配（command_execution→.bash 等）
- [ ] Codex 生图中调色盘彩条 —— 留到能区分"生图"事件后再做

### 3. Idle 生命感（让它"活着"）
- [x] **慢呼吸** —— LifeSignsModifier scale 1.0↔1.05，2s 一周期 easeInOut (LifeSignsModifier.swift)
- [x] **随机眨眼** —— 8~15s 随机间隔，180ms 完成（opacity 1→0.25→1）
- [x] **完成跳跃** —— `HermesPetTaskFinished` (success=true) 触发，向上跳 4pt + spring 回原位 + 一圈白色光晕 0.55s 扩散
- [x] **鼠标眼神跟踪（v2 替代偷瞄）** —— MouseTrackingController.shared 全局 mouse monitor + 仅 area 变化时 post `HermesPetMouseAreaChanged`；Clawd idle 时根据 left/center/right 自动切 lookLeft/rest/lookRight，鼠标在中间时回归原有随机扫
- [x] **Clawd 工具姿势细分** —— ClaudeKnotSprite.startWorkingJump 改成根据 currentTool 切 frame 序列：Read 慢扫 / Write 快打字 / Bash 中速敲 / Search 快切 / Web 慢环顾 / Task 双弹；currentTool 切换时重启 task 自动用新节奏
- [x] **Clawd 头顶情绪气泡** —— 新建 ClawdBubbleOverlayController（独立 NSWindow），灵动岛 onChange(elapsedSeconds) 在 30s/90s/180s 触发耐心提示，TaskFinished 失败 + Claude 模式触发"糟糕 😵"。气泡 1.8s 自动淡出
- [ ] **偷瞄** —— 已被鼠标眼神跟踪覆盖（更主动的"看用户"逻辑）
- [x] **打哈欠** —— `IdleStateTracker` 用 `CGEventSource.secondsSinceLastEventType` 监测系统 idle 时间，5min 无鼠标/键盘活动 → post `HermesPetUserIdleChanged` 通知；`IdleModeDot` 收到后切 sleeping 态：圆点透明度 0.6→0.4 + scale 1.0→0.82 + 浮 "z" 字（2.4s 上浮淡出循环）

### 4. Claude Code 工具事件透出（高价值）
- [x] **解析 stream-json 的 tool_use 事件** —— `ClaudeCodeClient` 通过 `HermesPetToolStarted`/`HermesPetToolEnded` 通知透出（按 tool_id 去重）
- [x] **灵动岛订阅工具事件** —— Read/Write/Bash/Edit 时灵动岛显示工具名 + 参数预览（ToolKind + ToolOverlay）
- [x] **多步任务进度** —— `[ ✦ 第 M/N 步 ]`，工具卡片 subtitle 显示，≥2 步才显示
- [x] **长思考耗时** —— 流式开始后超过 10s 在工具卡片显示 `· Xs` 实时秒数
- [x] **完成 diff 摘要** —— `[ ✦ 已修改 N 个文件 ]`，按 Edit/Write/MultiEdit 的 file_path 去重，TaskFinished 后展示 2.5s 再回 idle（+/- 行数需 tool_result 解析，留 P2）

### 5. 后台对话发光（多 conversation 视觉透出）
- [x] **数字胶囊底部点亮发光线** —— ConversationPill `isBackgroundStreaming` 时底部加 1.5pt mode 主色 Capsule + 阴影，1.2s 周期呼吸；触发条件 conv.isStreaming && conv.id != activeID
- [x] **灵动岛右耳显示后台对话计数** —— ChatViewModel.broadcastBackgroundStreamingCount 计算激活之外的流式数，post `HermesPetBackgroundStreamingChanged`；灵动岛 idle 状态右耳左侧显示 `BackgroundStreamingBadge`（小呼吸点 + 数字）

### 6. 视觉细节升级
- [ ] **mode 主色用 conicGradient 缓慢旋转** —— 流式时主色不是死的，90s 一周；静态回归纯色
- [ ] **状态切换音效** —— 已有音效系统扩展，每种状态可选系统短音（极轻）
- [x] **触觉反馈** —— 新建 Haptic.swift 静态 `tap(kind)` 入口；ChatViewModel.hapticEnabled 持久化（默认开）；SettingsView 加 Toggle；触发点：mode 切换 / 截屏成功 / 任务完成 / 按住语音 down
- [x] **形变全用 spring** —— 14 处状态切换的 `.easeOut(<0.3)` / `.easeInOut(<0.3)` 单次动画统一换成 `AnimTok.snappy`，0.3~0.5s 的换 `AnimTok.smooth`。**保留**装饰循环（呼吸/眨眼/光环旋转，repeatForever）+ 4 处有意 easing（对勾笔触手写感、光晕扩散、audio meter 0.08s 实时反应、眨眼 0.09s 瞬间）

### 7. 实现路径（按依赖顺序）
- [x] **Step 1** 现状：DynamicIslandPillView 用 3 个 @State（isHovering / isShowingNotification / taskStatus）已经覆盖大部分场景，先不抽 enum；保留作为后续 v2 的清理目标
- [x] **Step 2** Idle 生命感的精灵保持渲染常驻 + 用 transition.opacity 在 hover/idle/notification 间切换 —— v1 不强行上 matchedGeometryEffect，避免跨 NSWindow 形变的坑
- [x] **Step 3** `LifeSignsModifier` 已建，独立挂在 ModeSpriteView 上，零开销禁用
- [x] **Step 4** `ModeSprite.swift` 三个 mode 精灵已建，工作中切到各自动画
- [x] **设置开关** —— "桌宠动效" 总开关进入 SettingsView，反向语义存 `quietMode` to UserDefaults
- [x] **agentMode 同步** —— ChatViewModel.agentMode.didSet 多发一条 `HermesPetModeChanged` 通知给灵动岛
- [x] **Step 5** `ClaudeCodeClient` 透出 tool_use 事件，串到灵动岛（HermesPetToolStarted/Ended 通知）
- [x] **Step 6** 后台对话发光：ConversationPill `isBackgroundStreaming` overlay + 灵动岛右耳 `BackgroundStreamingBadge`
- [ ] **Step 7** 节流 + 性能：所有动画检查能否在 idle 时停掉（节能）

### 8. 彩蛋（P3 可选，做 1~2 个即可）
- [ ] 节假日皮肤（圣诞雪花 / 春节红光）
- [ ] 用户启动满一年灵动岛弹小蛋糕
- [ ] 天气联动早晚色温
- [ ] "摸鱼检测"：30 分钟无新消息时灵动岛轻摆提醒（默认关）

---

## [P1-结构] 灵动岛↔聊天窗一体形变（方向 A）

> 目标：聊天窗顶部"长出"自灵动岛，不再是两个独立窗口的弹出关系。
> 加开关：经典模式（现状）/ 一体模式（新）。

- [ ] 聊天窗顶部 28pt 区域永久承袭灵动岛形状（mask 跟随）
- [ ] 展开/收起：灵动岛本体不动，下方聊天体 spring 形变
- [ ] 重构 hit-testing：顶部胶囊区域穿透到灵动岛窗口
- [ ] 设置加 toggle：`一体形变 / 经典弹窗` 二选一
- [ ] 跨窗口 matchedGeometryEffect 跨不了 NSWindow，方案：合并成一个变形窗口或用 CALayer presentation 模拟

---

## [P2-治理] 稳定性 / 数据治理
- [ ] `conversations.json` 大小上限 / 自动归档（聊几个月可能几 MB，启动加载慢）
- [x] streaming 时切换对话的行为明确化：switchConversation 检测离开的对话仍 isStreaming 时，通过 ScreenshotAdded 通道弹 toast「对话 N 仍在生成中」
- [x] **NSWindow level 全局梳理** —— 新建 `Sources/WindowLevels.swift` 定义 `HermesWindowLevel` 枚举（`.chat` = floating, `.intelligence` = floating, `.auxiliary` = mainMenu, `.dynamicIsland` = statusBar），5 个 controller 引用同一规范；ClawdBubble / VoiceTranscript 从 statusBar 降到 mainMenu 永不挡灵动岛
- [ ] release 版本号自动化：改版本不用手动改 Info.plist
- [ ] 设置页加"重置所有数据"按钮，排错用
- [x] **App 图标设计** —— 霓虹线条风智慧小熊（戴眼镜沉思 + 彩色光环 + 三色光点对应 Hermes/Claude/Codex 三模式）。流程：`appicon.jpg` → `sips` 切 10 尺寸 → `iconutil` 打包 `AppIcon.icns` → 写入 `Info.plist` 的 `CFBundleIconFile` → `build.sh` 自动拷贝 → `lsregister -f` 刷新 LaunchServices 缓存。换图标只需替换 `appicon.jpg` 重跑切片命令
- [x] **App 图标 v2 (米白底猫咪线条风)**（2026-05-14）—— 用户提供新源图 `已生成图像 1.png` (1254×1254 米白底 + 黑色猫咪轮廓 + 装饰星星/圆点)，sips 缩到 1024×1024 后批量生成 10 个标准 iconset 尺寸 → iconutil 打包成 `AppIcon.icns`（1.4M）→ install.sh 部署 → `killall Dock` 强制刷新缓存让 Dock 立即显示新图标。旧图标作为暗色模式备选保留 `AppIcon.icns.bak`
- [x] **install.sh pkill 路径 bug**（2026-05-14）—— 之前用 `pkill -f "$APP_NAME.app/Contents/MacOS/$APP_NAME"` 匹配进程，但 /Applications 下的 bundle 是中文 "Hermes 桌宠.app" 而 source 端是 "HermesPet.app"，pattern 匹配不到 → 旧进程残留 → install 完成但用户跑的还是旧版代码（导致一次部署后调试半天发现新代码没运行）。修法：改成 `pkill -x "$APP_NAME"` 精确匹配 binary 名（HermesPet），跨路径都能命中
- [x] **稳定性专项**（2026-05-13）一轮系统审计 + 修复：
  - 🔴 5 个潜在崩溃点：`ChatWindowController` / `ClaudeCodeClient` / `CodexClient` 的 force unwrap、`ChatComponents` 强制 cast、`ChatViewModel` 空数组保护
  - 🟡 资源/反馈：`StorageManager` corrupt JSON 自动备份 + 弹 toast 提示；`APIClient` SSE idle timeout 90s（取代之前卡 180s 的 timeoutIntervalForRequest）+ watchdog + 友好错误消息；errorMessage 保留 HTTP body 摘录（前 120 字）便于排错
  - 🟢 生命周期：新增 `SubprocessRegistry`，AppDelegate.applicationWillTerminate 兜底杀掉所有 Claude/Codex 子进程，避免僵尸；`Models.imagePaths` 文件缺失时 console 日志

## [P1-Widget] 桌面小组件三件套（确认要做）

> 目标：让桌宠从灵动岛"溢出"到整个桌面。三件套覆盖三种使用场景：临时需求 / 内容沉淀 / 陪伴趣味。
> 详细计划与决策点见会话记录；三个完全独立，建议顺序 ① → ② → ③。

### ① ⚡ 全局 AI 上下文工具 ✅（原 Spotlight 快问，重新定位为"处理选中文本"）
- [x] 全局热键 ⌘⇧Space 唤起屏幕中央 680pt 浮动输入框（毛玻璃 + 16pt 圆角）
- [x] **自动捕获选中文本作为 AI 上下文**：双路径回退 —— ① AXUIElement 直读（原生 app 0 延迟）② AX 失败则模拟 ⌘C → 等 150ms → 读剪贴板 → 异步恢复原剪贴板（覆盖 Electron / Java / WebView 等 AX 残废的 app）；顶部显示"已选中 N 字 · 来自 Safari"卡片 + 2 行预览
- [x] **回填粘贴**：⌘↩ 快捷键 + "粘回去"按钮，回答内容自动 ⌘V 到原 app 光标位置替换原选区。`KeyboardSimulator.pasteText` 用 CGEvent 模拟
- [x] **复制到剪贴板**："复制"按钮，不切焦点，便于粘贴到其他位置
- [x] 没选中文字时退化为无脑快问（顶部 context 卡片隐藏）
- [x] 回车 → 就地展开流式回答（不打开聊天窗、不写 conversations.json）
- [x] 回答右上角 3 按钮：📌 Pin / 💬 转聊天窗 / ✕ 关
- [x] **Apple Intelligence 6 色 angular gradient 边框**：待机 8s/周慢转 + 流式 3s/周加速 + plusLighter 混合
- [x] **顶级设计师 UI 打磨**：① 4pt 网格统一所有 padding（圆角 16→20）② 边框含蓄化（opacity 0.75→0.55 / blur 0.4→0.8 / lineWidth 1.5→1.2）+ 内层白色 0.5pt 玻璃描边 ③ 双层阴影（close 浅 + far 深） ④ 输入框左侧 mode icon + 光标 tint 跟随 mode 主色 ⑤ Q chat bubble + A 纯页面渲染 + "粘回去"做 mode 主色渐变主按钮（含 mode 主色阴影）"复制"做 ghost 次按钮
- [x] **失焦行为分段**：输入态（未提交）失焦立刻关；提交后自动"钉住"不消失，只能 Esc / ✕ 关，并在 header 显示 `📌 已固定 · Esc 关` 提示。解决"切到原 app 对照内容/查资料 → 浮窗消失 → 回答丢了"的体验断裂
- [x] 输入框 17pt 字 + 回车提示徽章
- [x] `QuickAskPanel` (NSPanel + canBecomeKey=true) + level=intelligence（同 IntelligenceOverlay）
- [x] `streamOneShotAsk` + `migrateQuickAskToNewConversation` 复用现有 client 路由
- [x] 第一次唤起弹一次系统 Accessibility 引导窗（已授权静默）
- [x] Pin 桌面功能接通（② 已完成）
- [ ] **v2**: 选中后右键菜单加 "用 Hermes 询问"系统 Service；多 app 兼容性测试（Safari/VS Code/Notes/Pages 等）

### ② 📌 Pin 到桌面 ✅
- [x] 聊天气泡 hover 时 assistant 消息多一个 📌 按钮（旁边复制按钮）
- [x] QuickAsk 浮窗的 Pin 按钮接通真 Pin（之前是兜底复制剪贴板）
- [x] 每张 pin 独立 NSWindow 320×100，毛玻璃 + 圆角 14pt，level=floating + NSWindow.hasShadow（系统级阴影沿 alpha mask）
- [x] 头部：mode icon + 标题（首行去 markdown 前缀截断 40 字）+ 复制 + ✕；hover 时背景微亮 + mode 主色描边光晕
- [x] 自上而下堆叠（最新在最顶），spacing 8pt，关闭后自动重排（带动画）
- [x] **最多 8 张**（`PinStore.maxPins`），超出时调用方收到 false 返回值并提示用户
- [x] persist 到 `~/.hermespet/pins.json`，启动时 `PinCardController.bootstrap()` 恢复全部
- [x] 内容预览 3 行截断（lineLimit 3）— v1 不做"hover 展开完整"，单击复制按钮一键复制完整内容到剪贴板自己处理
- [x] `isMovableByWindowBackground` 允许 session 内拖动单张 pin 调整位置（重启后恢复堆叠）
### ② Pin 未来拓展（v2~v3 规划，按价值排序）

> 当前 v1 是"功能可用"，未来这些拓展能让 Pin 从"备忘卡"升级成"AI 工作面板"。

**🟢 高价值（明确痛点）**
- [x] **hover 展开完整内容** —— PinCardView 用 PreferenceKey 测内容自然高度，hover 时 lineLimit(nil) + 窗口高度展开（compactHeight=100 / expandedMaxHeight=360，contentHeight+44 自适应），其他 pin 自动重排让位
- [x] **双击 pin 转聊天窗** —— PinCardView 加 onTapGesture(count:2) → PinCardController.onOpenInChat 注入回调 → ChatViewModel.openPinAsConversation 新建对话（user msg "📌 来自桌面 Pin 的内容" + assistant msg = pin.content）+ 切到 pin.mode + 发 HermesPetOpenChatRequested 打开聊天窗
- [x] **拖动 reorder 持久化** —— PinCard 加 customX/Y (Codable 兼容旧版)；每个 NSWindow 加 PinWindowDelegate 监听 windowDidMove → 250ms 防抖 → PinStore.updatePosition 写盘；layoutAll 跳过 hasCustomPosition 的 pin（用户拖到哪重启就在哪）
- [x] **Pin 三个致命 bug 一次修齐**（2026-05-14）：① `windowDidMove` 不区分代码 setFrame vs 用户拖动 → bootstrap/layoutAll/handleHoverExpand 触发的 setFrame 全被误判为"用户拖动"持久化为 customX/Y → 之后所有 pin 永久不参与堆叠（修：PinWindowDelegate 加 `ignoreMovesUntil` 时间窗，controller setFrame 前调 `suppressMoveTracking` 刷 0.5s 覆盖 animate 动画期）② 双击 pin 必崩 —— `openInChat` 同步链路 `onTapGesture → ChatViewModel → NotificationCenter post → handleOpenChatRequested → chatWindow.show + NSApp.activate`，整条链跑在 SwiftUI 事件处理同步栈里，触发 macOS 26 跨窗口嵌套 layout NSException（CLAUDE.md 决策 #5 同样的坑），修法：openInChat 改 `Task { @MainActor in cb?(pin) }` 异步派发到下个 runloop ③ `close(id:)` 释放 delegate 时没 cancel 它的 saveTask，250ms 后还会回调到已删除的 pin（修：加 `cancelPendingSave`，close/closeAll 释放前调用）
- [ ] **"全部关闭" / 菜单栏管理面板** —— 菜单栏图标右键加"Pin 管理"子菜单：N 张 pin / 全部关 / 查看所有
- [ ] **支持 Pin Codex 生图** —— pin 不只是文字，Codex assistant 消息附带的图也能 pin（卡片显示缩略图）
- [ ] **半透明 idle 态** —— 鼠标离开 5s 后 pin 自动变 60% 透明不挡视线，hover 时恢复 100%

**🟡 中价值（工具型）**
- [ ] **键盘快捷键** —— `⌘⇧P` 列出所有 pin 浮动菜单 / 按数字键复制对应 pin / `⌘⇧X` 关闭所有
- [ ] **AI 整理 pin** —— "把这些 pin 总结/合并/分类"一键调 AI（差异化亮点）
- [ ] **跳转到原对话** —— pin 来自某次对话时存 conversationID + messageID，按钮"在聊天里查看"自动定位
- [ ] **导出全部 pin 为 Markdown 文档** —— 一键生成 `pins-<date>.md` 整理稿
- [ ] **Pin 分组 / 标签 / 颜色** —— 用户给 pin 加 tag，按 tag 折叠 / 高亮（避免桌面塞太多杂物）

**🔵 长期想法**
- [ ] **Pin 之间链接** —— 类似 Obsidian 双括号引用，pin A 里引用 pin B → 显示连线
- [ ] **Pin 自动归档** —— N 天后自动从桌面收起到"归档库"，可手动恢复
- [ ] **多屏支持** —— 跟随鼠标所在屏 / 或者用户指定哪个屏堆叠
- [ ] **菜单栏 badge** —— 当前 pin 数显示在菜单栏图标右下角小数字
- [ ] **Stage Manager 联动** —— pin 可参与 macOS Stage Manager 分组
- [ ] **Pin 模板视觉**：代码片段（深色 + 代码字号）/ 待办（左侧 checkbox）/ 参考资料（左侧书本图标）各有不同样式

### ③ 🐾 Clawd 桌面漫步（已完成 v1，默认开）
- [x] **触发条件**：Claude 模式 + IdleStateTracker.isSleeping（3min，原 5min）+ 设置启用 + 无 streaming，全满足才出来
- [x] **行为**：菜单栏正下方水平漫步 28 pt/s，左右屏幕 18pt margin 反弹；每 4-8s 随机暂停 1.4-2.8s，表演 lookLeft / lookRight / armsUp（伸懒腰）
- [x] **入场 / 退场**：从灵动岛位置 fade+slide 出场（0.32s easeOut）；条件不满足时 fade+slide 回灵动岛位置（0.35s easeIn）
- [x] **交互**：单击 → 打开聊天窗；双击 → 切 Claude mode（已在 Claude 则等同单击）；hover → 暂停 + 转头看着鼠标方向
- [x] **多屏处理**：优先选有 notch 的屏（同灵动岛逻辑），无 notch 屏取 main
- [x] **设置开关**：`clawdWalkEnabled`，**默认开**（让用户首次体验到这个彩蛋）；设置 → 桌宠 → "Clawd 桌面漫步"
- [x] **idle 阈值**：从 5min 降为 3min（同时影响灵动岛圆点 dim / 飘 z）
- [x] **桌面巡视 v1**：漫步期间偶尔下到桌面，挑一个图标走过去，让 Hermes 用一句 ≤10 字短评文件名。新增 `DesktopIconReader.swift`（osascript 调 Finder 拿 name+position+kind，缓存 5min，本地黑名单关键词过滤敏感文件名）。`ClawdWalkOverlay` 加 `PatrolPhase` 状态机（goingTo / sniffing / returning）+ 看门狗超时兜底。AI 调用走 `streamOneShotAsk(modeOverride:.hermes, recordToActivity:false)`，失败回退到本地 ClawdQuotes 兜底句。设置 → 桌宠 加"桌面巡视（Clawd 嗅文件）"toggle，**默认 OFF**（需要 Finder 自动化权限，让用户主动开）
- [x] **桌面巡视 v1.1：频率调高 + 拖动交互**：自动巡视间隔从 90~180s 改 45~90s（首次延迟 30~60s → 15~30s）。新增"用户用鼠标拽起 Clawd 扔到桌面图标上 → 触发 sniff"交互（`ClawdWalkView` 加 DragGesture 与 onTap 共存；controller 加 `handleClawdDragStarted/Changed/Ended`；松手时遍历 DesktopIconReader 缓存找 60pt 内最近图标命中触发 sniff，未命中走回菜单栏）。被拖动时 `state.isBeingDragged=true` → tick 跳过自动位移、pose 切 armsUp、轻微 1.08x 放大反馈。⚠️ 跟"文件→Clawd"（吃文件深度处理 vm.sendMessage）方向相反 / 处理逻辑完全独立

未来 v2 扩展想法：
- [ ] 避让活动应用窗口（检测 frontmost window frame 反向走）
- [ ] 多屏跟随鼠标所在屏漫步
- [ ] 工作中模式：Claude 在跑长任务时 Clawd 在桌面"巡查"显示进度
- [ ] 用户操作恢复时让 Clawd 加快脚步跳回岛而不是平移（更"机灵"）

## [P2-Widget] 桌面 widget 候选库（未来选做）

> 这些是讨论过但当前不做的桌面 widget 想法，按价值/打扰度排序。等三件套上线后再评估哪些值得做。

- [ ] **侧栏对话预览** —— 屏幕最右侧 hover 5pt 边缘 → 滑出 280pt 窄面板，列最近 3 个对话标题 + 最后一条预览，点击切对话
- [ ] **Codex 画廊** —— 独立小窗口（菜单栏可呼出）2 列网格展示最近生成图片，hover 放大，点击进入对应对话
- [ ] **每日总结 banner** —— 22:00 桌面右下角滑出"今天 X 次对话 / Y 个文件修改 / Z 张图"，配 mode 主色光晕，10s 自动淡出
- [ ] **屏幕边缘 mode 主题色光带** —— 极细呼吸光带（Hermes 绿 / Claude 橙 / Codex 青），始终显示当前 mode
- [ ] **角色生日 / 满 N 次对话彩蛋** —— Clawd 戴生日帽 / 满 100 次对话从灵动岛跳出庆祝
- [ ] **任务完成成就 banner** —— AI 完成长任务（如改 ≥10 个文件）时屏幕角落滑出"成就解锁"

## [P0-AI 自感知] ActivityRecorder + 每日早报（2026-05-14 v1 上线）

> 目标：让 AI 不只是"听用户说"，还能"看见用户做了什么"。本地持续采集 app 使用 / 窗口 / 键鼠节奏 / 跟 AI 的问题，每天早晨 AI 自动生成一份"早报"汇总昨日活动 + 今日建议。
>
> 设计原则：① 数据全本地（不上云）② 早报后端用户显式选（明确隐私边界）③ 敏感 app 自动黑名单 ④ 用户可随时暂停 / 清空 ⑤ 只记用户那一侧（AI 回答不入分析库，避免重复）

### 1. 数据层 (`Sources/ActivityStore.swift`)
- [x] **SQLite 三表 schema** —— `activity_events` (raw, 48h 自动 prune) / `activity_sessions` (会话块, 30 天) / `app_usage_stats` (每日聚合, 永久)；都加索引；WAL 模式 + synchronous=NORMAL 性能优化
- [x] **`user_questions` 表 + FTS5 全文索引** —— 只记用户那一侧消息（不记 AI 回答），fields: id / conversation_id / mode / content / timestamp / char_count / has_images / has_documents；外部 content 模式 FTS5 + INSERT/DELETE triggers 自动 sync 倒排索引
- [x] **写入接口** —— `insertEvent` / `insertSession` (sync 落盘) / `insertUserQuestion` / `aggregateDailyStats` (按 SQL GROUP BY 卷统计)
- [x] **查询接口** —— `recentSessions(withinMinutes:)` / `dailyStats(for:)` / `topApps(days:limit:)` / `recentUserQuestions(withinMinutes:)` / `searchUserQuestions(matching:)` (FTS5 MATCH 关键词检索) / `userQuestionCount(for:)`
- [x] **清理接口** —— `pruneEvents(olderThan: 48h)` / `pruneSessions(olderThan: 30d)` / `clearAll()`
- [x] **线程安全** —— 串行 DispatchQueue 包所有 SQLite 操作；`@unchecked Sendable`；写用 async（不阻塞调用方），关键写入和查询用 sync（保证顺序 + 立即返回结果）；`SQLITE_TRANSIENT` 静态常量解决 Swift String 生命周期 vs C API 的指针坑

### 2. 采集层 (`Sources/ActivityRecorder.swift`)
- [x] **NSWorkspace 监听** —— `didActivateApplicationNotification` / `didLaunchApplicationNotification` / `didTerminateApplicationNotification`，用经典 `@objc selector` 模式（block 模式在 Swift 6 严格并发下会触发 `SendingRisksDataRace` 报错把 Notification 跨 actor 传过来）
- [x] **全局键盘/鼠标计数** —— `NSEvent.addGlobalMonitorForEvents(.keyDown / .leftMouseDown / .rightMouseDown)`，**只数次数不读 keyCode/字符**；callback 在 main thread
- [x] **窗口标题轮询** —— 每秒用 AX API (`AXUIElementCreateApplication` + `kAXFocusedWindowAttribute` + `kAXTitleAttribute`) 读 active app 的 focused window title；变化时切会话
- [x] **剪贴板变化检测** —— 每秒比 `NSPasteboard.general.changeCount`，只数次数不读内容
- [x] **会话切分逻辑** —— 三个触发点：① active app 变化 ② 同 app 内 window title 变化 ③ 30 秒无任何活动（键鼠/app/window 都没动）；切换时 `closeCurrentSession()` 落盘 + 开新 session；duration < 1s 的丢掉避免快切窗噪声
- [x] **黑名单（隐私保护）** —— 默认 `defaultExcludedBundleIDs` 含 1Password / Bitwarden / LastPass / Dashlane / 钥匙串等；UserDefaults `activityExcludedBundleIDs` 合并用户自定义；黑名单 app 的 session 仅记 duration 占位，**不记** windowTitle / keyboardCount / pasteboardCount
- [x] **每 5 分钟节流聚合** —— `aggregateDailyStats(for: today)` 让查询能拿到准实时统计，不用等到第二天
- [x] **生命周期** —— `start()` / `stop()` / `setRunning(_:)` / `clearAll()`；AppDelegate.applicationWillTerminate 调 stop 让 current session 落盘

### 3. 权限处理（macOS 双权限不容易）
- [x] **Accessibility 权限** —— `AXIsProcessTrustedWithOptions({"AXTrustedCheckOptionPrompt": true})` 第一次启动主动弹系统对话框，给 window title 读取用
- [x] **Input Monitoring 权限** —— **关键坑**：`NSEvent.addGlobalMonitorForEvents` for keyDown 在 macOS 10.15+ 必须有 Input Monitoring 权限，否则系统**静默忽略**所有事件（不报错也不提示，键盘 count 永远 0）。修法：调 `IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)` 主动请求 → 第一次会弹系统对话框；Info.plist 加 `NSInputMonitoringUsageDescription` 描述；user 必须手动去 系统设置 → 隐私与安全性 → 输入监控 把 HermesPet 打开

### 4. 启动 + 退出接入 (`HermesPetApp.swift`)
- [x] **applicationDidFinishLaunching** 检查 UserDefaults `activityRecordingEnabled`（默认 true），开了就 `ActivityRecorder.shared.start()`
- [x] **applicationWillTerminate** 调 `ActivityRecorder.shared.stop()` 落盘 current session
- [x] **菜单栏 (右键灵动岛/状态栏)** 加菜单项 "📰 立即生成今日早报"，方便手动触发测试，不用等到第二天

### 5. UI (`SettingsView.swift`)
- [x] **新增 `.privacy` 分类** —— icon `lock.shield.fill`，indigo 配色
- [x] **隐私 section 内容**：① "记录我的活动" 主 toggle（绑定 `viewModel.activityRecordingEnabled`，didSet 调 setRunning）② 隐私保障说明卡片（5 条要点：本地存储 / 不读键盘内容 / 只记用户问题不记 AI 回答 / 黑名单自动跳过 / 一键清空）③ "早报由谁生成" Picker（Hermes / Claude Code / Codex 三选一）④ 今日活动实时统计（top 5 app + 时长）⑤ 清空按钮（带 confirmationDialog 二次确认）

### 6. ChatViewModel hook + 早报后端 setting
- [x] **`activityRecordingEnabled` property** —— didSet 调 ActivityRecorder.setRunning
- [x] **`morningBriefingBackend: AgentMode` property** —— UserDefaults 持久化，默认 .hermes（用户在设置里显式选，不跟随当前对话 mode，因为早报数据敏感需明确隐私边界）
- [x] **`sendMessage` hook** —— 在 `messages.append(userMessage)` 之后调 `ActivityRecorder.shared.queryStore.insertUserQuestion(...)` 写入 SQLite
- [x] **`streamOneShotAsk` 升级** —— 加 `modeOverride: AgentMode?` 和 `recordToActivity: Bool = true` 参数；早报内部 prompt 用 `modeOverride` 走早报后端 + `recordToActivity: false` 不污染 user_questions 表
- [x] **`createBriefingConversation(content:)` 方法** —— 创建特殊 "📰 今日早报 YYYY-MM-DD" 对话，已满 `kMaxConversations` 时挤掉最旧的非 streaming 对话；自动切到该对话 + post 通知打开聊天窗

### 7. 早报服务 (`Sources/MorningBriefingService.swift`)
- [x] **`generateIfNeeded(viewModel:)` 自动模式** —— 启动时调，比对 UserDefaults `morningBriefingLastDate`，今天没生成过就 3s 延迟后跑（避免 app 启动时突兀弹窗，也让 ActivityRecorder 先聚合一下）
- [x] **`generateNow(viewModel:)` 手动模式** —— 用户从菜单栏触发，无视 lastBriefingDate，立即生成
- [x] **数据收集** —— `collectData(forYesterday:)` 拉指定日期的 `dailyStats` + `user_questions`（filter 时间窗）+ 最近 7 天 topApps；自动模式优先昨天，昨天空就回退今天到目前为止（解决"刚装/周末没用"的 cold start）
- [x] **Prompt 构造** —— 给 AI 一份结构化 markdown 数据 + 风格要求（第二人称"你"、亲切而非冷数字、300-500 字、5 段结构：早安问候 / 昨日概览 / 关键观察 / 今天建议 / 祝你愉快），明确"不要照搬数据要提炼主题"
- [x] **AI 调用** —— 走 `viewModel.streamOneShotAsk(modeOverride: morningBriefingBackend, recordToActivity: false)` 拿到完整流式输出，错误情况 set errorMessage（仅 manual 模式提示，自动模式静默）
- [x] **重入保护** —— `isGenerating` flag 避免用户连点菜单 / 跟自动启动撞车
- [x] **空数据兜底** —— 完全没数据时不生成早报，manual 模式提示"还没有任何活动数据"

### 8. 待做（v2，下一批）
- [ ] **AI 自动感知用户活动** —— 每次发消息前在 system prompt 末尾自动注入"用户最近 30min 活动摘要"（每 30min throttle 一次刷新），让 AI 不用调 tool 也能知道你在做什么；做之前要解决三个 client 各自的 system prompt 注入方式不同问题
- [ ] **Function calling tool 给 AI** —— 让支持 tool calling 的后端能主动调 `get_recent_activity / search_conversations / get_top_apps`，按需查询不必每次注入摘要
- [ ] **早报放灵动岛右耳** —— 早报已生成且未读时，灵动岛右耳变成小太阳/报纸图标，点击重新打开早报对话；读过自动消失
- [ ] **早报历史归档** —— 不要每天覆盖，保留过去 N 天的早报对话或单独的 `briefings/` JSON
- [ ] **周报 / 月报** —— 每周一早晨额外生成"过去一周"汇总，每月 1 号生成"过去一月"汇总
- [ ] **O 方案 (Clawd 的耳朵)** —— 灵动岛右耳订阅 ActivityRecorder 的实时 keyboardCount 数据，每秒看一下"最近 5s 按键数"，>10 就竖耳朵，<2 慢慢放下；让 Clawd 在视觉上"在听你"
- [ ] **黑名单自定义 UI** —— Settings 隐私分类加个"敏感 app"列表，让用户能加 / 删（目前只能改 UserDefaults `activityExcludedBundleIDs`）
- [ ] **数据导出** —— Settings 加"导出活动数据"按钮，把 SQLite dump 成 CSV / JSON 给用户带走

---

## [P3-暂不做] 低价值或高成本
- [ ] 跨设备同步 / iCloud
- [ ] 自动更新机制（Sparkle 集成）
- [ ] 暗 / 亮色模式深度审查
- [ ] TestFlight / App Store 上架
- [ ] 迷你浮动模式（类似歌词显示）
- [ ] **常驻大窗口 widget**（违反 LSUIElement 极简哲学）
- [ ] **剪贴板自动监听 → 弹 AI 气泡**（隐私敏感 + 用户没明确要求别主动出来）
- [ ] **Dock 一体化**（macOS 没有官方 API，hacky）

---

> **图例:** [x] 已完成 · [ ] 待实现
> 优先级按用户体验影响排序
> 最后更新：2026-05-14（① Pin 三个致命 bug 修齐 ② App 图标换成米白底猫咪线条风 ③ install.sh pkill 路径 bug 修复 ④ ActivityRecorder MVP v1 上线：本地采集 app/window/键鼠/对话 → SQLite + FTS5 ⑤ 每日早报 v1 上线：菜单栏可手动触发，启动时按 lastBriefingDate 自动跑，用户在隐私设置选早报后端）
