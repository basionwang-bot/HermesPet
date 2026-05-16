import Foundation

/// 画布模板 —— 预定义一组 slot（卡片占位），告诉 AI "这个画布应该长成什么样"。
///
/// 用户选模板 + 填主题（如"可口可乐"）→ CanvasService 用模板的 systemPrompt + 用户主题
/// 让 AI 给每个 slot 生成具体内容（图的 prompt / 文字的内容）
struct CanvasTemplate: Identifiable, Codable, Hashable {
    let id: String              // "ecommerce" / "courseware" / "story" / "custom"
    let name: String            // "电商产品介绍"
    let icon: String            // SF Symbol 名
    let summary: String         // 一句话说明，UI 上下拉时显示
    let slots: [CanvasSlot]     // 卡片占位定义
}

/// 模板里的一个 slot 定义 —— 决定该卡片的类型、小标题、给 AI 的提示
struct CanvasSlot: Codable, Hashable {
    let kind: CanvasElementKind
    let caption: String         // 显示在卡片左上角的小标题（"产品主图" / "卖点 ①"）
    let promptHint: String      // 给 AI 的 hint："为<topic>生成产品主图，要红色为主色调"
}

/// 内置画布模板库 —— 添加新模板时在这里追加一项即可，UI 自动列出来
enum CanvasTemplates {

    /// 全部模板，UI 下拉用
    static let all: [CanvasTemplate] = [
        ecommerce,
        courseware,
        storyboard,
        custom,
    ]

    /// 按 id 查模板。找不到 fallback 到 custom
    static func find(id: String) -> CanvasTemplate {
        all.first(where: { $0.id == id }) ?? custom
    }

    // MARK: - 电商产品介绍（MVP 主推）
    //
    // 一个产品主图（大）+ 标题文案 + 3 个卖点 + 2 个使用场景图 + 行动号召 = 8 张卡片
    // 主图大、卖点小、场景图中等 —— 网格 LazyVGrid 会按 slot 顺序展开
    /// 电商主图模板 —— v4（"成品参考"思路 + GPT Image 2 99% 中文渲染）
    ///
    /// **v4 vs v3 的根本差异**：
    /// - v3 给的是抽象描述（"layout: left product, right text"），LLM 自由发挥空间太大
    /// - v4 给的是**具体成品参考**：明确告诉 image-2 "成品长成 XX 样的图"（参考真实淘宝爆款）
    ///   + 精确分区比例（50/50、70/30）+ 文字精确位置（top-left 30% area）+ 字体精确风格
    ///   （思源黑体 Heavy / 阿里巴巴普惠体）+ 配色 anchor（brand 主色 / 中国红 / 高端金）
    ///   + 风格 anchor（Tmall 旗舰店 / Apple product page / Pinterest infographic）
    /// - 大幅减少负面 NOT 指令（image-2 对正向描述响应更好），用具体正向词替代
    /// - LLM 不再"创作整体 prompt"，只负责填具体字段（中文文字内容 / 配色提示），框架不动
    ///
    /// 按淘宝五图规范：5 张 1:1，第 5 张强制纯白底
    static let ecommerce = CanvasTemplate(
        id: "ecommerce",
        name: "电商主图 5 张套图",
        icon: "cart.fill",
        summary: "淘宝/天猫规范的 5 张 800×800 主图，每张都带精确排版的中文文案",
        slots: [
            CanvasSlot(
                kind: .heroImage,
                caption: "主图 ① · 核心卖点海报（替代详情页）",
                promptHint: """
                A bestseller Tmall flagship store main image (主图) for [TOPIC], 1:1 square aspect ratio, photorealistic commercial product photography blended with bold Chinese typography poster design — the kind of hero image you see on top-selling Tmall pages.

                EXACT COMPOSITION (50/50 split, vertical division at center):
                • LEFT 50% panel: pure soft-lit product shot. The product is large, centered vertically, dramatic three-point studio lighting with softbox glow. Pure clean background (white or subtle brand-color gradient). All packaging labels and brand marks are tack-sharp and 100% readable. NO clutter, NO props.
                • RIGHT 50% panel: solid color background using the brand's signature color, divided into TWO text zones:
                  - TOP 60% of right panel: massive Chinese headline "[CHINESE_HEADLINE_4_TO_6_CHARS]" in heavy weight bold sans-serif (思源黑体 Heavy / 阿里巴巴普惠体 Bold), color: high-contrast white or brand-accent. Character size: VERY large, fills the zone, perfectly centered horizontally.
                  - BOTTOM 40% of right panel: Chinese subtitle "[CHINESE_SUBTITLE_8_TO_14_CHARS]" with concrete product data, in medium weight sans-serif, slightly smaller, supporting the headline.
                • BOTTOM-RIGHT corner of full image: small circular price/promo badge with Chinese text "[BADGE_TEXT_E.G._限时优惠_OR_新品上市]", brand-accent color circle with white text.

                Style anchors: 2025 Tmall flagship store hero aesthetic / Apple product hero composition / clean modern Chinese e-commerce poster. High contrast, premium, confident, zero clutter.
                """
            ),
            CanvasSlot(
                kind: .heroImage,
                caption: "主图 ② · 工艺细节图（带标签注解）",
                promptHint: """
                A premium product detail close-up image for [TOPIC], 1:1 square, photorealistic macro-style commercial photography with Chinese annotation labels overlaid — the kind of detail callout image used on Tmall flagship product pages.

                EXACT COMPOSITION:
                • Center 70% area: extremely tight close-up of the product showing material texture, craftsmanship, label print quality. Sharp focus on the most premium-looking detail. Soft fade gradient background (cream / off-white).
                • THREE Chinese annotation labels positioned at top-left, middle-right, bottom-left (triangulating around the product):
                  - Each label = a small rounded white pill (12px radius) with thin connecting line pointing to the relevant product detail spot
                  - Label format: small icon + 4 Chinese characters (e.g., "[FEATURE_1_LABEL]", "[FEATURE_2_LABEL]", "[FEATURE_3_LABEL]")
                  - Chinese text in medium weight sans-serif, black color, perfectly crisp and readable

                Style anchors: Apple product page detail callout / Dyson product spec illustration / high-end Tmall craft showcase. Refined, premium, technical.
                """
            ),
            CanvasSlot(
                kind: .heroImage,
                caption: "主图 ③ · 真实生活场景 + 大字主题",
                promptHint: """
                A lifestyle scene image for [TOPIC], 1:1 square, photorealistic instagram-style real-life photography with a Chinese banner overlay — the kind of warm authentic scene image used on Tmall lifestyle product listings.

                EXACT COMPOSITION:
                • Full frame: photorealistic real-world scene with a natural-looking person using/enjoying the product in daily life context [SCENE_CONTEXT_E.G._家庭餐桌_OR_朋友聚会_OR_户外露营]. Soft natural daylight, candid feel, slight depth of field. The product is prominently visible but feels organic to the scene.
                • TOP BANNER strip (occupying top 18% of image, semi-transparent dark gradient or solid brand-color band): a single bold Chinese headline "[CHINESE_LIFESTYLE_HEADLINE_6_TO_10_CHARS]" in heavy weight bold sans-serif, white color, perfectly centered horizontally, with subtle drop shadow for readability against varied scene.
                • Optional small subtitle in the banner, 8-12 Chinese characters, lighter weight.

                Style anchors: Instagram lifestyle / 小红书 brand collaboration / Tmall lifestyle hero. Warm, authentic, aspirational.
                """
            ),
            CanvasSlot(
                kind: .heroImage,
                caption: "主图 ④ · 3 卖点信息图",
                promptHint: """
                A 3-point benefit infographic for [TOPIC], 1:1 square, modern flat-design Chinese e-commerce infographic style — the kind of "三大卖点" image used on every Tmall product detail page.

                EXACT COMPOSITION (vertical thirds layout):
                • TOP 30%: photorealistic small product shot centered on cream/off-white background, with a thin horizontal divider line below it.
                • BOTTOM 70%: divided into THREE equal vertical columns (33% width each), each column contains stacked vertically:
                  - Top: a clean flat-design colored icon (about 80px), brand-accent color
                  - Middle: bold Chinese title "[POINT_N_TITLE_2_TO_4_CHARS]" in heavy weight sans-serif (e.g., "0 添加" / "百年品牌" / "全球认证")
                  - Bottom: light-weight Chinese description "[POINT_N_DESC_10_TO_15_CHARS]" with concrete data

                Background: clean cream/off-white, NO clutter, ample white space between columns. All Chinese text perfectly aligned, balanced, identical size across columns.

                Style anchors: modern flat-design Chinese infographic / 知乎专栏头图 / Tmall "三大优势" panel. Clean, professional, scannable in 2 seconds.
                """
            ),
            CanvasSlot(
                kind: .heroImage,
                caption: "主图 ⑤ · 标准白底图（搜索结果展示）",
                promptHint: """
                Pure white background commercial product shot for [TOPIC], 1:1 square aspect ratio — the Taobao-mandated standard for search results.

                EXACT REQUIREMENTS (Taobao strictly enforces this format):
                • Background: 100% pure white (#FFFFFF), no gradients, no patterns, no decorative elements
                • Subtle soft floor shadow directly under the product is permitted
                • Product centered both horizontally and vertically, occupying ~70% of frame height
                • Three-point studio softbox lighting, no harsh shadows, complete packaging visible with crisp label readability
                • ZERO text overlays, ZERO badges, ZERO decorations — must be a pure clean product shot

                Style anchors: Taobao search-result thumbnail / Tmall white-background spec / Amazon main image standard. Pristine, neutral, accurate.
                """
            ),
        ]
    )

    // MARK: - 课件 / PPT 大纲

    static let courseware = CanvasTemplate(
        id: "courseware",
        name: "课件大纲",
        icon: "book.fill",
        summary: "封面图 + 课程标题 + 5 个章节要点 + 总结",
        slots: [
            CanvasSlot(
                kind: .heroImage, caption: "封面图",
                promptHint: "为课程 <topic> 生成封面图，符合主题氛围，留出顶部标题区域"
            ),
            CanvasSlot(
                kind: .title, caption: "课程标题",
                promptHint: "为 <topic> 写课程主标题（10-14 字）和副标题（≤20 字）"
            ),
            CanvasSlot(
                kind: .sellingPoint, caption: "章节 ①",
                promptHint: "<topic> 的第 1 个章节标题 + 该章核心要点（一行）"
            ),
            CanvasSlot(
                kind: .sellingPoint, caption: "章节 ②",
                promptHint: "<topic> 的第 2 个章节标题 + 要点"
            ),
            CanvasSlot(
                kind: .sellingPoint, caption: "章节 ③",
                promptHint: "<topic> 的第 3 个章节标题 + 要点"
            ),
            CanvasSlot(
                kind: .sellingPoint, caption: "章节 ④",
                promptHint: "<topic> 的第 4 个章节标题 + 要点"
            ),
            CanvasSlot(
                kind: .sellingPoint, caption: "章节 ⑤",
                promptHint: "<topic> 的第 5 个章节标题 + 要点"
            ),
            CanvasSlot(
                kind: .text, caption: "课程总结",
                promptHint: "为 <topic> 写一段 50-80 字的总结，概括学完后能掌握什么"
            ),
        ]
    )

    // MARK: - 故事板 / 插画连环

    static let storyboard = CanvasTemplate(
        id: "storyboard",
        name: "故事板",
        icon: "books.vertical.fill",
        summary: "主题描述 + 4 格叙事插画 + 一句话报题",
        slots: [
            CanvasSlot(
                kind: .text, caption: "故事简介",
                promptHint: "为故事 <topic> 写一段 30-60 字的简介，交代背景和主线"
            ),
            CanvasSlot(
                kind: .sceneImage, caption: "第 1 幕",
                promptHint: "为 <topic> 画第 1 幕：故事开端，介绍主角或场景"
            ),
            CanvasSlot(
                kind: .sceneImage, caption: "第 2 幕",
                promptHint: "为 <topic> 画第 2 幕：冲突或转折"
            ),
            CanvasSlot(
                kind: .sceneImage, caption: "第 3 幕",
                promptHint: "为 <topic> 画第 3 幕：高潮"
            ),
            CanvasSlot(
                kind: .sceneImage, caption: "第 4 幕",
                promptHint: "为 <topic> 画第 4 幕：结局"
            ),
            CanvasSlot(
                kind: .title, caption: "故事标题",
                promptHint: "为 <topic> 起一个有诗意的故事标题（6-12 字）"
            ),
        ]
    )

    // MARK: - 自由规划（AI 自决）

    /// "自定义"模板没有预设 slot —— CanvasService 会先让 AI 看主题
    /// 自己规划应该生成哪些 slot（图 / 文 / 数量），更灵活但不可控
    static let custom = CanvasTemplate(
        id: "custom",
        name: "AI 自由规划",
        icon: "wand.and.stars",
        summary: "不预设结构，让 AI 看主题自己决定生成什么",
        slots: []   // 空 = 让 AI 在规划阶段自决
    )
}
