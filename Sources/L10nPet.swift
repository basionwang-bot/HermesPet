import Foundation

/// 桌宠"软台词"双语文案（i18n Phase 5-2）。
/// 这批是桌宠**本地**说的固定台词 —— 短、俏皮、口语、有人格。英文不死译，同样俏皮传神。
///
/// key 命名：前缀 `pet.`，二级按区域：
///   - `pet.quote.*`   —— Clawd 心情台词池（漫步 idle / morning / lateNight / 招呼 / 撞墙 / 累了 / 睡饱）
///   - `pet.sniff.*`   —— 桌面巡视嗅文件兜底文案池（按 5 种桌宠形象 × 文件夹/文件）
///   - `pet.bubble.*`  —— 吃文件 / 兜底气泡
///   - `pet.tool.*`    —— 灵动岛展开里的工具动词（ToolKind.verb）
///   - `pet.intent.*`  —— 桌宠对用户意图的短评模板池（IntentCopyWriter）
///   - `pet.channel.*` —— 反馈通道偏好选择器名（IntentInstantFeedback）
///   - `pet.suggest.*` —— 意图建议卡片按钮（IntentSuggestionWindowController）
/// 在 `LocaleManager.zhTable` / `enTable` 数组里登记后生效。
///
/// ⚠️ **台词池方案**：每个池一个 key，多句用竖线 `|` 分隔存进 value，
/// 代码读出后 `split(separator: "|")` 再随机选一句。带名词的模板池用 `%@` 占位，
/// 选中那句再 `String(format:)` 插值。
///
/// ⚠️ pet 名（Clawd / 云朵 / fomo / 小马 / coco）作为桌宠专名不翻译。
/// ⚠️ 终端桌宠保留命令行梗（ls / cd / cat / scan / $ stat）。
enum L10nPet {
    static let zh: [String: String] = [
        // —— Clawd 心情台词池（ClawdQuotes，按情境分组）——
        "pet.quote.idle": "在散步~|悠闲~|👀|看屏幕外|今天怎么样?|好像很闲?|嗯哼~",
        "pet.quote.morning": "早安~|新的一天 ☀️|起这么早?|咖啡了吗?",
        "pet.quote.lateNight": "该睡啦~|夜猫子 🌙|再不睡眼睛会肿…|明天还要早起呢",
        "pet.quote.greetings": "嗨~|找我吗?|诶?|👋|回来啦?|在这呢",
        "pet.quote.bumps": "哎呀|...|走错了|啊",
        "pet.quote.tired": "好累呀…歇会儿 😮‍💨|不跑啦，趴一会儿|腿酸了…|休息一下下~|喘口气 🫠",
        "pet.quote.refreshed": "睡饱啦！|满血复活 ✨|再逛逛~|精神了！|走起 🐾",

        // —— 桌面巡视嗅文件兜底文案池（localFallbackQuote）——
        // Clawd 螃蟹 / 嗅嗅腔
        "pet.sniff.clawd.folder": "翻翻这个~|里面装啥?|嗯…文件夹|看着挺鼓|藏宝盒?",
        "pet.sniff.clawd.file": "这名字有意思|什么文件呢?|嗅嗅~|瞄一眼|看着挺新",
        // 云朵 / 轻飘
        "pet.sniff.cloud.folder": "飘过看看~|里面有啥?|云遮着了|好奇好奇|藏着什么?",
        "pet.sniff.cloud.file": "飘着瞧瞧~|新东西?|嗯～|看看名字|挺有意思",
        // 小怪兽 / 好奇专注
        "pet.sniff.monster.folder": "瞪瞪它~|里面装啥?|嗯…文件夹|盯上了|有点东西",
        "pet.sniff.monster.file": "瞄一眼~|这是啥?|嗯～|盯着看|新东西!",
        // 九尾狐 fomo / 月光九尾
        "pet.sniff.fox.folder": "嗯…有点东西|里面藏什么|嗅嗅~|月光照过|九尾扫过~",
        "pet.sniff.fox.file": "这名字…|好奇好奇|嗯～看看|瞄一眼|新的耶",
        // 金黄小马 / 哒哒
        "pet.sniff.horse.folder": "哒哒~ 这个|里面装啥?|嗅一嗅~|挺有趣|进去看看?",
        "pet.sniff.horse.file": "哒哒哒~|新东西!|嗅嗅看|瞄一眼|听过这名",
        // 终端 coco / 命令行梗
        "pet.sniff.terminal.folder": "ls 一下?|cd 进去看|scan 中…|$ stat .|目录树呢",
        "pet.sniff.terminal.file": "cat 试试?|$ file .|扫描中…|新文件!|看看 metadata",
        // 布尔熊 / 聪明好奇 + 编程启蒙
        "pet.sniff.bear.folder": "里面有什么?|翻一翻~|装了好多?|藏宝箱?|瞧瞧这个",
        "pet.sniff.bear.file": "这是啥呀?|瞄一眼~|新东西!|什么名字?|好奇好奇",
        // 嗅文件兜底的兜底（pool 为空时）
        "pet.sniff.default": "嗅嗅~",

        // —— 吃文件 / 兜底气泡 ——
        "pet.bubble.feedMe": "嗯？给我吃的？",
        "pet.bubble.chewing": "嚼嚼… %@",
        "pet.bubble.fallback": "👀",
        // 桌宠 walk 视图的 help tooltip
        "pet.walk.help": "Clawd 在散步 · 单击=打开聊天 · 双击=切到 Claude · 拖到桌面图标上=让它嗅一下",

        // —— 灵动岛展开里的工具动词（ToolKind.verb）——
        "pet.tool.read": "正在读",
        "pet.tool.write": "正在写",
        "pet.tool.bash": "正在执行",
        "pet.tool.search": "正在搜索",
        "pet.tool.web": "正在浏览",
        "pet.tool.todo": "更新清单",
        "pet.tool.task": "派遣 subagent",
        "pet.tool.thinking": "正在思考",
        "pet.tool.other": "正在调用",

        // —— 桌宠对用户意图的短评模板池（IntentCopyWriter，%@ = 提取出的名词）——
        // copiedError：复制了报错文本
        "pet.intent.copiedError.hermes": "注意到 %@|你复制了 %@|嗯，%@",
        "pet.intent.copiedError.cloud": "咦，%@？|%@ 这个…|看到 %@ 了",
        "pet.intent.copiedError.claude": "横眼看 %@|嗯？%@|%@ 哦",
        "pet.intent.copiedError.codex": "→ %@|%@ ←|err: %@",
        "pet.intent.copiedError.fallback": "看到报错了",
        // windowTitleDebug：在调试
        "pet.intent.debug.hermes": "你在调试|调试模式？|在 debug",
        "pet.intent.debug.cloud": "调试呢～|在 debug？|调试模式",
        "pet.intent.debug.claude": "调 bug 呢|debug 中|在抓虫",
        "pet.intent.debug.codex": "→ debug|断点中|debug…",
        // windowTitleStackOverflow：查 Stack Overflow
        "pet.intent.so.hermes": "查 SO 呢|Stack Overflow？|去 SO 找答案",
        "pet.intent.so.cloud": "SO 走起|查 SO 呢|翻 SO？",
        "pet.intent.so.claude": "上 SO 啦|SO 翻翻|横着翻 SO",
        "pet.intent.so.codex": "→ SO|SO 查询|stackoverflow",
        // windowTitleDoc：翻文档
        "pet.intent.doc.hermes": "在翻文档|查文档呢？|看文档？",
        "pet.intent.doc.cloud": "翻文档哎|看文档？|查文档呢",
        "pet.intent.doc.claude": "翻翻文档|横着翻文档|查文档",
        "pet.intent.doc.codex": "→ docs|docs?|→ 文档",
        // screenKeyword：屏幕上看到名词
        "pet.intent.screen.hermes": "屏幕上 %@|看到 %@|注意到 %@",
        "pet.intent.screen.cloud": "%@ 这个…|咦，%@|我看到 %@",
        "pet.intent.screen.claude": "横看 %@|嗯？%@|%@ 哦",
        "pet.intent.screen.codex": "→ %@|%@?|屏: %@",
        "pet.intent.screen.fallback": "屏幕有报错",
        // 模板池整体兜底
        "pet.intent.fallback": "看到了",

        // —— 反馈通道偏好选择器名（IntentChannelPreference.displayName）——
        "pet.channel.auto": "自动",
        "pet.channel.pet": "桌宠优先",
        "pet.channel.island": "灵动岛优先",

        // —— 意图建议卡片按钮（IntentSuggestionWindowController）——
        "pet.suggest.dismiss": "知道了",
        "pet.suggest.accept": "看看吧",

        // —— 养成系统：心情名（PetMood.displayNameKey）——
        "pet.mood.happy": "开心",
        "pet.mood.content": "满足",
        "pet.mood.neutral": "平静",
        "pet.mood.tired": "累了",
        "pet.mood.lonely": "想你",

        // —— 养成系统：形象名（PetForm.displayNameKey，专名中英一致不译）——
        "pet.form.clawd": "Clawd",
        "pet.form.fomo": "fomo",
        "pet.form.horse": "小马",
        "pet.form.monster": "小怪兽",
        "pet.form.terminal": "coco",

        // —— 养成系统：成长阶段（PetGrowthStage.titleKey）——
        "pet.stage.egg": "蛋",
        "pet.stage.baby": "幼年期",
        "pet.stage.prime": "壮年期",
        "pet.stage.adult": "成年期",

        // —— 宠物乐园 ——
        "pet.park.power": "战斗力",
        "pet.park.nextStage": "再升 %d 级 → %@",
        "pet.park.maxStage": "已成年 · 圆满",
        "pet.park.preview": "预览",
        "pet.park.switchRole": "换角色",
    ]

    static let en: [String: String] = [
        // —— Clawd mood quotes (pools, contextual) ——
        "pet.quote.idle": "just strolling~|chillin'~|👀|gazing off|how's it going?|kinda quiet?|mhm~",
        "pet.quote.morning": "morning~|new day ☀️|up early?|coffee yet?",
        "pet.quote.lateNight": "bedtime~|night owl 🌙|sleep or puffy eyes…|early start tomorrow",
        "pet.quote.greetings": "hi~|need me?|huh?|👋|you're back?|right here",
        "pet.quote.bumps": "oops|...|wrong way|ack",
        "pet.quote.tired": "so tired… break time 😮‍💨|done running, flopping|legs ache…|quick rest~|catching my breath 🫠",
        "pet.quote.refreshed": "all rested!|full HP ✨|let's wander~|feeling fresh!|off we go 🐾",

        // —— Desktop-patrol sniff fallback pools ——
        "pet.sniff.clawd.folder": "ooh, this one~|what's inside?|hmm, a folder|looks stuffed|treasure box?",
        "pet.sniff.clawd.file": "fun name|what file is this?|*sniff sniff*|just a peek|looks new",
        "pet.sniff.cloud.folder": "drifting by~|what's in here?|cloud's in the way|curious curious|hiding what?",
        "pet.sniff.cloud.file": "drifting for a look~|new thing?|hmm~|reading the name|kinda neat",
        "pet.sniff.monster.folder": "staring at it~|what's inside?|hmm, a folder|got my eyes on it|something here",
        "pet.sniff.monster.file": "a quick peek~|what's this?|hmm~|eyeing it|new thing!",
        "pet.sniff.fox.folder": "hmm, something here|what's it hiding|*sniff sniff*|moonlit~|nine tails brush by~",
        "pet.sniff.fox.file": "this name…|curious curious|hmm~ a look|just a peek|oh, new",
        "pet.sniff.horse.folder": "clip-clop~ this one|what's inside?|sniff sniff~|kinda fun|trot in?",
        "pet.sniff.horse.file": "clip-clop-clop~|new thing!|sniff and see|just a peek|heard this name",
        "pet.sniff.terminal.folder": "ls this?|cd in?|scanning…|$ stat .|dir tree?",
        "pet.sniff.terminal.file": "cat it?|$ file .|scanning…|new file!|check metadata",
        // BoolBear / clever + curious
        "pet.sniff.bear.folder": "what's inside?|let's peek~|so much stuff?|treasure box?|ooh this one",
        "pet.sniff.bear.file": "what's this?|a peek~|new thing!|what's the name?|curious curious",
        "pet.sniff.default": "*sniff sniff*",

        // —— Eating / fallback bubbles ——
        "pet.bubble.feedMe": "huh? a snack for me?",
        "pet.bubble.chewing": "nom nom… %@",
        "pet.bubble.fallback": "👀",
        "pet.walk.help": "Clawd is strolling · click = open chat · double-click = switch to Claude · drag onto a desktop icon = let it sniff",

        // —— Tool verbs in the expanded island (ToolKind.verb) ——
        "pet.tool.read": "reading",
        "pet.tool.write": "writing",
        "pet.tool.bash": "running",
        "pet.tool.search": "searching",
        "pet.tool.web": "browsing",
        "pet.tool.todo": "updating list",
        "pet.tool.task": "dispatching subagent",
        "pet.tool.thinking": "thinking",
        "pet.tool.other": "calling tool",

        // —— Intent quip template pools (%@ = extracted noun) ——
        "pet.intent.copiedError.hermes": "noticed %@|you copied %@|hmm, %@",
        "pet.intent.copiedError.cloud": "ooh, %@?|%@ huh…|spotted %@",
        "pet.intent.copiedError.claude": "side-eyeing %@|huh? %@|%@, eh",
        "pet.intent.copiedError.codex": "→ %@|%@ ←|err: %@",
        "pet.intent.copiedError.fallback": "saw an error",
        "pet.intent.debug.hermes": "debugging?|debug mode?|on a bug",
        "pet.intent.debug.cloud": "debugging~|in debug?|debug mode",
        "pet.intent.debug.claude": "squashing bugs|in debug|bug hunting",
        "pet.intent.debug.codex": "→ debug|breakpoint|debug…",
        "pet.intent.so.hermes": "on SO?|Stack Overflow?|hunting SO",
        "pet.intent.so.cloud": "SO time|on SO?|SO dive?",
        "pet.intent.so.claude": "hit SO|SO crawl|crab-walk SO",
        "pet.intent.so.codex": "→ SO|SO query|stackoverflow",
        "pet.intent.doc.hermes": "reading docs|on the docs?|docs?",
        "pet.intent.doc.cloud": "in the docs~|docs?|reading docs",
        "pet.intent.doc.claude": "flipping docs|sideways through docs|docs",
        "pet.intent.doc.codex": "→ docs|docs?|→ docs",
        "pet.intent.screen.hermes": "%@ on screen|saw %@|noticed %@",
        "pet.intent.screen.cloud": "%@ huh…|ooh, %@|I see %@",
        "pet.intent.screen.claude": "eyeing %@|huh? %@|%@, eh",
        "pet.intent.screen.codex": "→ %@|%@?|scr: %@",
        "pet.intent.screen.fallback": "error on screen",
        "pet.intent.fallback": "saw it",

        // —— Feedback channel preference picker names ——
        "pet.channel.auto": "Auto",
        "pet.channel.pet": "Pet first",
        "pet.channel.island": "Island first",

        // —— Intent suggestion card buttons ——
        "pet.suggest.dismiss": "Got it",
        "pet.suggest.accept": "Take a look",

        // —— Growth system: mood names (PetMood.displayNameKey) ——
        "pet.mood.happy": "Happy",
        "pet.mood.content": "Content",
        "pet.mood.neutral": "Calm",
        "pet.mood.tired": "Tired",
        "pet.mood.lonely": "Missing you",

        // —— Growth system: form names (PetForm.displayNameKey, proper nouns kept) ——
        "pet.form.clawd": "Clawd",
        "pet.form.fomo": "fomo",
        "pet.form.horse": "Pony",
        "pet.form.monster": "Monster",
        "pet.form.terminal": "coco",

        // —— Growth system: growth stages (PetGrowthStage.titleKey) ——
        "pet.stage.egg": "Egg",
        "pet.stage.baby": "Baby",
        "pet.stage.prime": "Prime",
        "pet.stage.adult": "Adult",

        // —— Pet park ——
        "pet.park.power": "Power",
        "pet.park.nextStage": "%d lv → %@",
        "pet.park.maxStage": "Adult · complete",
        "pet.park.preview": "Preview",
        "pet.park.switchRole": "Switch",
    ]
}
