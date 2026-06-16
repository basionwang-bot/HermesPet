import Foundation

/// 新用户首次引导（OnboardingView）的双语文案。
/// key 命名：前缀 `onboarding.`，二级按步骤/区域（nav / brand / welcome / provider / capabilities / shortcuts）。
/// 在 `LocaleManager.zhTable` / `enTable` 数组里登记后生效。
enum L10nOnboarding {
    static let zh: [String: String] = [
        // —— 通用导航 ——
        "onboarding.nav.skip": "跳过",
        "onboarding.nav.prev": "上一步",
        "onboarding.nav.next": "下一步",
        "onboarding.nav.start": "开始使用",

        // —— 品牌头 ——
        "onboarding.brand.tagline": "桌面 AI 伙伴",

        // —— ① 欢迎 ——
        "onboarding.welcome.greeting": "你好，我是你的桌面小伙伴",
        "onboarding.welcome.body.prefix": "点屏幕顶部中间那个小胶囊（刘海那块），或随时按 ",
        "onboarding.welcome.body.suffix": " 把我叫出来。我有好几只分身，帮你干不同的活儿。",
        "onboarding.welcome.hint": "花一分钟配置一下，配好就能用啦。",

        // —— ② 选 AI 配 Key ——
        "onboarding.provider.title": "先选一个 AI，配好就能聊",
        "onboarding.provider.intro": "选一家服务商、粘上它的 API Key 就行。不知道选哪个？DeepSeek / 智谱性价比高、好上手。",
        "onboarding.provider.label": "服务商",
        "onboarding.provider.applyKey": "去 %@ 申请 API Key",
        "onboarding.provider.keyPlaceholder": "粘贴 API Key（sk-...）",
        "onboarding.provider.saved": "已保存",
        "onboarding.provider.save": "保存",
        "onboarding.provider.savedHint": "配好啦，下一步",
        "onboarding.provider.footnote": "Key 只存你本机；之后随时能在设置里换服务商或改 Key。",

        // —— ③ 懂你能力 ——
        "onboarding.capabilities.title": "我会越用越懂你",
        "onboarding.capabilities.intro": "下面这些开了，我才能真懂你、帮你减负。全部本地存储；不想要随时能在设置关。",
        "onboarding.capabilities.activity.title": "记录我的活动",
        "onboarding.capabilities.activity.desc": "记下你在用什么 app / 窗口（不记键盘内容），是「昨日回顾」的地基。需辅助功能权限。",
        "onboarding.capabilities.intent.title": "意图感知",
        "onboarding.capabilities.intent.desc": "静默看一眼屏幕在忙什么（本地 OCR，不上传），让我更懂你的处境。",
        "onboarding.capabilities.memory.title": "共享记忆",
        "onboarding.capabilities.memory.desc": "一份所有 AI 共享的「你的记忆」，换哪只桌宠都接着懂你。",
        "onboarding.capabilities.launch.title": "开机自动启动",
        "onboarding.capabilities.launch.desc": "登录后自动常驻菜单栏，随用随到。",

        // —— ④ 快捷键 ——
        "onboarding.shortcuts.title": "几个顺手的快捷键",
        "onboarding.shortcuts.toggleChat": "呼出 / 隐藏聊天",
        "onboarding.shortcuts.voice": "按住说话，松开自动发送",
        "onboarding.shortcuts.quickAsk": "Spotlight 风快问浮窗",
        "onboarding.shortcuts.capture": "截屏并附加到对话",
        "onboarding.shortcuts.footnote": "都能在设置里改。准备好了就开始吧！",

        // —— 作者署名 ——
        "onboarding.credit.prefix": "by basion wang · ",
    ]

    static let en: [String: String] = [
        "onboarding.nav.skip": "Skip",
        "onboarding.nav.prev": "Back",
        "onboarding.nav.next": "Next",
        "onboarding.nav.start": "Get Started",

        "onboarding.brand.tagline": "Your desktop AI companion",

        "onboarding.welcome.greeting": "Hi, I'm your desktop companion",
        "onboarding.welcome.body.prefix": "Click the little capsule at the top center of your screen (around the notch), or press ",
        "onboarding.welcome.body.suffix": " anytime to call me up. I have several alter egos that help with different tasks.",
        "onboarding.welcome.hint": "Take a minute to set things up—you'll be ready to go.",

        "onboarding.provider.title": "Pick an AI to start chatting",
        "onboarding.provider.intro": "Choose a provider and paste in its API key. Not sure which? DeepSeek / Zhipu are affordable and easy to start with.",
        "onboarding.provider.label": "Provider",
        "onboarding.provider.applyKey": "Get an API key from %@",
        "onboarding.provider.keyPlaceholder": "Paste API key (sk-...)",
        "onboarding.provider.saved": "Saved",
        "onboarding.provider.save": "Save",
        "onboarding.provider.savedHint": "All set—next step",
        "onboarding.provider.footnote": "The key stays on your Mac; you can switch providers or change the key in Settings anytime.",

        "onboarding.capabilities.title": "I get to know you better over time",
        "onboarding.capabilities.intro": "Turn these on so I can truly understand you and lighten your load. Everything is stored locally; turn it off anytime in Settings.",
        "onboarding.capabilities.activity.title": "Record my activity",
        "onboarding.capabilities.activity.desc": "Notes which apps / windows you use (not your keystrokes)—the foundation for the Daily Recap. Requires Accessibility permission.",
        "onboarding.capabilities.intent.title": "Intent awareness",
        "onboarding.capabilities.intent.desc": "Quietly glances at what's on screen (local OCR, never uploaded) to better understand your context.",
        "onboarding.capabilities.memory.title": "Shared memory",
        "onboarding.capabilities.memory.desc": "One \"memory of you\" shared by all AIs—whichever pet you switch to keeps knowing you.",
        "onboarding.capabilities.launch.title": "Launch at login",
        "onboarding.capabilities.launch.desc": "Stays in the menu bar after login, ready whenever you need it.",

        "onboarding.shortcuts.title": "A few handy shortcuts",
        "onboarding.shortcuts.toggleChat": "Show / hide chat",
        "onboarding.shortcuts.voice": "Hold to talk, release to send",
        "onboarding.shortcuts.quickAsk": "Spotlight-style quick ask",
        "onboarding.shortcuts.capture": "Capture screen and attach to chat",
        "onboarding.shortcuts.footnote": "All adjustable in Settings. Ready? Let's go!",

        "onboarding.credit.prefix": "by basion wang · ",
    ]
}
