import SwiftUI

// MARK: - 通用配色（程度 → 颜色）

private enum StatColor {
    /// 占用/负载类（0~1）：低=绿、偏高=橙、很高=红
    static func load(_ frac: Double) -> Color {
        if frac >= 0.88 { return .red }
        if frac >= 0.70 { return .orange }
        return .green
    }
    /// 温度（°C）：<60 绿、<80 橙、否则红
    static func temp(_ celsius: Double) -> Color {
        if celsius >= 80 { return .red }
        if celsius >= 60 { return .orange }
        return .green
    }
}

// MARK: - 迷你环形仪表

/// Apple Watch 风格的小圆环：底色淡灰轨道 + 彩色填充弧（填充比例 = 程度，颜色 = 要紧否）。
struct MiniRing: View {
    let fraction: Double     // 0...1，环的填充比例
    let color: Color
    var size: CGFloat = 12
    var lineWidth: CGFloat = 2.4

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.16), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.03, min(1, fraction)))   // 至少留一点弧，别全空
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))                     // 从 12 点方向起笔
                .shadow(color: color.opacity(0.80), radius: 3)     // 彩色发散光（近，亮）
                .shadow(color: color.opacity(0.45), radius: 8)     // 彩色发散光（远，弥散开）
        }
        .frame(width: size, height: size)
        .animation(.easeOut(duration: 0.45), value: fraction)
        .animation(.easeOut(duration: 0.45), value: color)
    }
}

// MARK: - 指标定义（环 + 数值 + 颜色 + 图标 + 标签的统一来源）

enum StatMetric: CaseIterable {
    case cpu, mem, net, temp

    var icon: String {
        switch self {
        case .cpu:  return "cpu"
        case .mem:  return "memorychip"
        case .net:  return "wifi"
        case .temp: return "thermometer.medium"
        }
    }
    var labelKey: String {
        switch self {
        case .cpu:  return "island.stats.cpu"
        case .mem:  return "island.stats.mem"
        case .net:  return "island.stats.net"
        case .temp: return "island.stats.temp"
        }
    }
    /// 右耳轮询时的单字母标识（C=CPU / M=内存 / T=温度 / N=网络），省空间又能区分
    var letter: String {
        switch self {
        case .cpu:  return "C"
        case .mem:  return "M"
        case .net:  return "N"
        case .temp: return "T"
        }
    }

    /// 环的填充比例
    @MainActor func fraction(_ m: SystemMonitor) -> Double {
        switch self {
        case .cpu:  return m.cpuUsage
        case .mem:  return m.memUsedFraction
        case .net:  // 网速跨度大，用对数刻度（否则几 K 的速率环永远空着）：~8MB/s 满环
            let d = m.netDownBytesPerSec
            return d > 0 ? min(1, log10(d + 1) / log10(8_000_000)) : 0
        case .temp: return min(1, max(0, ((m.cpuTempCelsius ?? 30) - 30) / 65)) // 30→95°C 映射 0→1
        }
    }

    /// 环 / 数值颜色
    @MainActor func color(_ m: SystemMonitor) -> Color {
        switch self {
        case .cpu:  return StatColor.load(m.cpuUsage)
        case .mem:  return StatColor.load(m.memUsedFraction)
        case .net:  return .cyan                                  // 网速无"危险"概念，固定青色
        case .temp: return StatColor.temp(m.cpuTempCelsius ?? 0)
        }
    }

    /// 右耳精简数值（单位各不相同 → 一眼区分是哪项）
    @MainActor func earValue(_ m: SystemMonitor) -> String {
        switch self {
        case .cpu:  return String(format: "%.0f%%", m.cpuUsage * 100)
        case .mem:  return String(format: "%.0fG", m.memUsedGB)
        case .net:  return SystemMonitor.formatRate(m.netDownBytesPerSec)
        case .temp: return m.cpuTempCelsius.map { String(format: "%.0f°", $0) } ?? "—"
        }
    }

    /// 右耳小环里居中的数值（空间极小，去掉单位/小数：CPU/内存=整数百分比、温度=整数°、网速=速率）
    @MainActor func ringEarInner(_ m: SystemMonitor) -> String {
        switch self {
        case .cpu:  return String(format: "%.0f", m.cpuUsage * 100)
        case .mem:  return String(format: "%.0f", m.memUsedFraction * 100)
        case .net:  return SystemMonitor.formatRate(m.netDownBytesPerSec)
        case .temp: return m.cpuTempCelsius.map { String(format: "%.0f°", $0) } ?? "—"
        }
    }

    /// 仪表盘环内居中数值（CPU/内存用占用百分比配合环填充，温度用°C，网络用 ↓下行速率）
    @MainActor func ringCenterValue(_ m: SystemMonitor) -> String {
        switch self {
        case .cpu:  return String(format: "%.0f%%", m.cpuUsage * 100)
        case .mem:  return String(format: "%.0f%%", m.memUsedFraction * 100)
        case .net:  return "↓" + SystemMonitor.formatRate(m.netDownBytesPerSec)
        case .temp: return m.cpuTempCelsius.map { String(format: "%.0f°", $0) } ?? "—"
        }
    }

    /// 仪表盘标签下的副信息（内存显示绝对 GB；网络显示上行速率；其余无）
    @MainActor func detail(_ m: SystemMonitor) -> String? {
        switch self {
        case .mem:  return String(format: "%.1fG", m.memUsedGB)
        case .net:  return "↑" + SystemMonitor.formatRate(m.netUpBytesPerSec)
        default:    return nil
        }
    }
}

// MARK: - 右耳：轮询单指标（字母 + 数值），tick 驱动不卡

/// 「字母 + 小环数值」单元 —— 右耳轮播 / 悬浮胶囊三连排 共用。
struct EarMetricCell: View {
    let metric: StatMetric
    let monitor: SystemMonitor
    var ringSize: CGFloat = 17
    var lineWidth: CGFloat = 2.6
    var valueFont: CGFloat = 7

    var body: some View {
        HStack(spacing: 3) {
            // 字母给"是哪项"的身份（按程度变色）
            Text(metric.letter)
                .font(.system(size: 8.5, weight: .bold, design: .rounded))
                .foregroundStyle(metric.color(monitor))
                .shadow(color: metric.color(monitor).opacity(0.6), radius: 3)   // 同色微光
            // 小环给"程度"感知（填充 + 颜色），环里放数字给精确值
            ZStack {
                MiniRing(fraction: metric.fraction(monitor), color: metric.color(monitor), size: ringSize, lineWidth: lineWidth)
                Text(metric.ringEarInner(monitor))
                    .font(.system(size: valueFont, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .monospacedDigit()
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
            }
        }
    }
}

/// 右耳轮播指标列表：CPU / 内存（/ 温度，读得到才进）。**网络不进右耳**（只在 hover 面板里看）。
@MainActor
private func earRotationMetrics(_ monitor: SystemMonitor) -> [StatMetric] {
    var m: [StatMetric] = [.cpu, .mem]
    if monitor.cpuTempCelsius != nil { m.append(.temp) }
    return m
}

/// 悬浮胶囊「三连排」：CPU / 内存 / 温度**同时**展示（不轮播）。胶囊那条够长，一次看全。
struct SystemEarTriple: View {
    @State private var monitor = SystemMonitor.shared

    var body: some View {
        HStack(spacing: 8) {
            ForEach(earRotationMetrics(monitor), id: \.self) { m in
                EarMetricCell(metric: m, monitor: monitor, ringSize: 16, lineWidth: 2.4, valueFont: 6.5)
            }
        }
        .onAppear { SystemMonitor.shared.start() }
    }
}

/// 灵动岛右耳（**刘海屏**，空间窄只能一次显一个）：每次采样（~2s）轮播一个指标。
/// **轮播靠 `SystemMonitor.sampleTick` 驱动**（而非内联 Timer —— 那个会被每次重绘重置导致永不触发，
/// 是上一版"看不到轮播效果"的根因）。**只轮 CPU/内存/温度，网络去掉**（网络在 hover 面板里看）。
struct SystemEarStat: View {
    @State private var monitor = SystemMonitor.shared

    /// 温度读不到（Intel / 未来系统）就不进轮播
    private var metrics: [StatMetric] { earRotationMetrics(monitor) }

    var body: some View {
        let active = metrics
        let cur = active[monitor.sampleTick % active.count]   // tick 一变就换下一个
        EarMetricCell(metric: cur, monitor: monitor)
            .frame(maxWidth: 40, alignment: .trailing)
            .id(cur)                                          // 切指标时重建 → 配合下面 animation 做淡入淡出
            .transition(.opacity)
            .animation(.easeInOut(duration: 0.3), value: monitor.sampleTick)
            .onAppear { SystemMonitor.shared.start() }
    }
}

// MARK: - 横排四指标（hover 仪表盘 + 钉住卡片共用）

/// 系统信息核心内容：CPU / 内存 / 温度用**圆环**（占用%、温度有"程度"概念，环最直观），
/// 网络是**速率**（没有满格概念，圆环反而别扭）→ 单独用**上传 ↑ / 下载 ↓ 两行文字**展示，
/// 箭头在左、速率在右，中间一条分割线隔开；并用一条竖分割线把它跟左侧三个圆环隔开。
/// **横排一行** 配合宽幅面板，一眼平铺看全。不含外层背景 —— 由调用方套壳。
struct SystemStatsGrid: View {
    @State private var monitor = SystemMonitor.shared

    var body: some View {
        HStack(spacing: 0) {
            gaugeCell(.cpu)
            gaugeCell(.mem)
            gaugeCell(.temp)
            // 竖分割线：把"圆环类指标"和"网络速率"在视觉上分开
            Rectangle()
                .fill(Color.white.opacity(0.12))
                .frame(width: 1, height: 56)
                .padding(.horizontal, 4)
            networkCell(monitor)
        }
        .onAppear { SystemMonitor.shared.start() }
    }

    /// 环形仪表单元（结构跟网络格对齐）：环内居中数值 + 图标+中文标签 + 副值行(始终预留一行高，无副值则占位)
    private func gaugeCell(_ m: StatMetric) -> some View {
        VStack(spacing: 6) {
            ZStack {
                MiniRing(fraction: m.fraction(monitor), color: m.color(monitor), size: 46, lineWidth: 5)
                Text(m.ringCenterValue(monitor))
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .monospacedDigit()
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                    .shadow(color: .white.opacity(0.45), radius: 4)   // 文字发散光晕
            }
            VStack(spacing: 1) {
                HStack(spacing: 4) {
                    Image(systemName: m.icon)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(m.color(monitor))
                        .shadow(color: m.color(monitor).opacity(0.6), radius: 4)   // 同色微光
                    Text(L(m.labelKey))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                        .shadow(color: .white.opacity(0.22), radius: 2)   // 文字微辉光
                }
                // 副值始终占一行（CPU/温度无副值就放空格占位，保证各格等高对齐）
                Text(m.detail(monitor) ?? " ")
                    .font(.system(size: 8.5, weight: .regular))
                    .foregroundStyle(.white.opacity(0.45))
                    .monospacedDigit()
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// 网络速率格：上传 ↑ / 下载 ↓ 两行（箭头左、速率右，中间分割线隔开），跟圆环格等高对齐。
    private func networkCell(_ m: SystemMonitor) -> some View {
        VStack(spacing: 6) {
            // 上/下两行 + 中间分割线（替代圆环，占 46pt 跟圆环等高）
            VStack(spacing: 0) {
                netRow("arrow.up", SystemMonitor.formatRate(m.netUpBytesPerSec))
                Rectangle()
                    .fill(Color.white.opacity(0.14))
                    .frame(height: 1)
                    .padding(.vertical, 5)
                netRow("arrow.down", SystemMonitor.formatRate(m.netDownBytesPerSec))
            }
            .frame(height: 46)
            .padding(.horizontal, 6)
            VStack(spacing: 1) {
                HStack(spacing: 4) {
                    Image(systemName: "wifi")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.cyan)
                    Text(L("island.stats.net"))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                        .shadow(color: .white.opacity(0.22), radius: 2)   // 文字微辉光
                }
                Text(" ")   // 预留副值行，跟圆环格等高
                    .font(.system(size: 8.5, weight: .regular))
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// 单行：方向箭头(左) + 速率(右)
    private func netRow(_ arrow: String, _ value: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: arrow)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.cyan)
                .shadow(color: .cyan.opacity(0.6), radius: 4)   // 青色微光
            Spacer(minLength: 2)
            Text(value)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.55)
                .shadow(color: .white.opacity(0.45), radius: 4)   // 文字发散光晕
        }
    }
}

// MARK: - 标题头部（标题身份 + 右侧操作按钮，hover/钉住共用）

/// 仪表盘头部：左侧「系统状态」标题给身份，右侧放一个操作按钮（hover=📌 钉住 / 钉住卡=× 关闭）。
private struct StatsHeader<Trailing: View>: View {
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "gauge.medium")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
            Text(L("island.stats.title"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.62))
            Spacer(minLength: 4)
            trailing
        }
    }
}

// MARK: - 灵动岛控制中心（多功能 hub：系统状态 / 应用启动器 / 宠物乐园）

/// 控制中心的功能分区。设置里可选启用哪几个；面板顶部一排图标标签切换。
enum IslandPanelSection: String, CaseIterable, Sendable {
    case system   // 系统状态（紧凑，hover 即弹）
    case apps     // 应用启动器（点开放大、可交互）
    case tokens   // Token 消耗（计费 + 省钱，点开放大）
    case pets     // 宠物乐园（占位，后续做）
    case workspace // AI 工作台（全屏，菜单触发；不进常规 tab bar，body 顶层单独分支渲染）

    var icon: String {
        switch self {
        case .system: return "gauge.medium"
        case .apps:   return "square.grid.2x2.fill"
        case .tokens: return "dollarsign.circle.fill"
        case .pets:   return "pawprint.fill"
        case .workspace: return "rectangle.3.group.fill"
        }
    }
    var titleKey: String {
        switch self {
        case .system: return "island.hub.system"
        case .apps:   return "island.hub.apps"
        case .tokens: return "island.hub.tokens"
        case .pets:   return "island.hub.pets"
        case .workspace: return "island.hub.workspace"
        }
    }
}

/// 鼠标悬停灵动岛时，刘海正下方「整体放大」弹出的**控制中心**面板。
///
/// **视觉=灵动岛长大**（用户要求「一体」）：顶部直角 + 底部圆角、纯黑无描边无阴影、顶满屏幕物理顶
/// → 黑色跟刘海/悬浮胶囊连成一片，像「刘海整体放大成一块面板」（受决策 #1 约束：灵动岛本体 NSWindow
/// 永不 setFrame，长大全靠这张独立窗口伪装；窗口大小变化由 controller 走 AppKit animator）。
///
/// **多功能**：顶部一排图标标签（系统 / 应用 / 乐园），点哪个 controller 把窗口形变到对应大小 + 切内容。
/// 系统区紧凑、hover 即弹即收；应用/乐园区点开后「粘住」可交互，× 或点空白处关闭。
///
/// `topInset` = 刘海高：内容靠它下移到刘海下方可见区，顶部那条黑色补在刘海左右、跟刘海黑融为一体。
struct IslandHubView: View {
    @Bindable var state: SystemStatsPanelState
    var topInset: CGFloat = 0

    @AppStorage("islandHubApps") private var appsEnabled = true
    @AppStorage("islandHubTokens") private var tokensEnabled = false   // 消耗面板发版前默认隐藏
    @AppStorage("islandHubPets") private var petsEnabled = true

    /// 启用的分区（系统恒在；应用按设置）。
    /// ⚠️ 乐园（宠物养成/形象）**暂封印**（2026-06-06）：试过纯代码自绘 / AI 静态图 / 逐帧动画
    /// 多套方案均未达满意，决定先不暴露入口、不再轻易改动。代码与素材（PetSprite / PetSpecies /
    /// PetParkView / ~/.hermespet/species/）全部保留，恢复只需放开下面这行 + SettingsView 的开关。
    private var sections: [IslandPanelSection] {
        var s: [IslandPanelSection] = [.system]
        if appsEnabled { s.append(.apps) }
        if tokensEnabled { s.append(.tokens) }
        // if petsEnabled { s.append(.pets) }   // 乐园封印中
        _ = petsEnabled
        return s
    }
    private var showsTabBar: Bool { sections.count >= 2 }

    var body: some View {
        if state.section == .workspace {
            // 全屏工作台：占满整个面板（WorkbenchView 自带顶部栏），顶部 topInset 留给刘海让位。
            // 不走下面的 hub 标签栏布局。窗口尺寸由 controller 的 .workspace contentSize 定（瞬切，守决策 #1/#6）。
            WorkbenchView(onClose: { SystemStatsPanelController.shared?.dismiss() },
                          topInset: topInset)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            hubBody
        }
    }

    private var hubBody: some View {
        let shape = UnevenRoundedRectangle(
            cornerRadii: .init(topLeading: 0, bottomLeading: 22, bottomTrailing: 22, topTrailing: 0),
            style: .continuous
        )
        return ZStack(alignment: .top) {
            // 纯黑实心、无描边、无阴影：从屏幕物理顶一直黑下来，跟刘海黑区连成一整块
            shape.fill(Color.black)

            VStack(spacing: 10) {
                hubTopBar
                sectionContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(.top, topInset + 6)   // 下移到「让位区」下方（topInset=让位区高，已含灵动岛悬停内容高度）
            .padding(.bottom, 12)
            .padding(.horizontal, 14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 顶部条（标签 + 右侧操作）

    @ViewBuilder private var hubTopBar: some View {
        HStack(spacing: 6) {
            if showsTabBar {
                ForEach(sections, id: \.self) { tabButton($0) }
            } else {
                // 只启用系统区：退回"标题"样式（跟改版前一致）
                Image(systemName: "gauge.medium").font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.5))
                Text(L("island.hub.system")).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.62))
            }
            Spacer(minLength: 4)
            workspaceEntryButton
            trailingAction
        }
    }

    /// 「工作台」入口：hover 面板里点它 → 收起面板 + 打开独立的 AI 工作台窗口（标准窗口、不盖 Dock）。
    /// 任何分区（系统/应用…）的 hover 面板都带这个入口，悬停即可一步进工作台。
    private var workspaceEntryButton: some View {
        Button {
            SystemStatsPanelController.shared?.dismiss()
            WorkbenchController.shared.present()
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "rectangle.3.group.fill").font(.system(size: 9, weight: .semibold))
                Text("工作台").font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(.white.opacity(0.72))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Capsule().fill(Color.white.opacity(0.14)))
        }
        .buttonStyle(.plain)
        .help("展开成全屏 AI 工作台")
    }

    private func tabButton(_ sec: IslandPanelSection) -> some View {
        let active = state.section == sec
        return Button {
            SystemStatsPanelController.shared?.switchSection(sec)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: sec.icon).font(.system(size: 10, weight: .semibold))
                if active {
                    Text(L(sec.titleKey)).font(.system(size: 10.5, weight: .semibold)).fixedSize()
                }
            }
            .foregroundStyle(active ? Color.white : Color.white.opacity(0.5))
            .padding(.horizontal, active ? 9 : 6)
            .padding(.vertical, 5)
            .background(Capsule().fill(active ? Color.white.opacity(0.16) : Color.clear))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var trailingAction: some View {
        if state.sticky {
            // 粘住的功能区（应用/乐园）：× 关闭
            Button { SystemStatsPanelController.shared?.dismiss() } label: {
                actionIcon("xmark")
            }
            .buttonStyle(.plain)
        } else {
            // 系统区：📌 钉到桌面
            Button {
                SystemStatsPinController.shared.pin()
                NotificationCenter.default.post(name: .init("HermesPetSystemStatsForceHide"), object: nil)
            } label: {
                actionIcon("pin.fill")
            }
            .buttonStyle(.plain)
            .help(L("island.stats.pin"))
        }
    }

    private func actionIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.white.opacity(0.55))
            .frame(width: 20, height: 20)
            .background(Circle().fill(Color.white.opacity(0.08)))
    }

    // MARK: 当前分区内容

    @ViewBuilder private var sectionContent: some View {
        switch state.section {
        case .system:
            SystemStatsGrid().frame(maxWidth: 300)   // 系统区定宽居中（加宽部分当黑边盖胶囊）
        case .apps:
            AppLauncherView()
        case .tokens:
            TokenConsumptionView()
        case .pets:
            PetParkView()
        case .workspace:
            EmptyView()   // 全屏工作台在 body 顶层分支处理，不走 hubBody/sectionContent
        }
    }
}

// MARK: - 应用启动器（自动列出全部应用 + 搜索 + 点击打开）

/// 自动扫描的全部应用网格：顶部搜索框 + 自适应列宽图标网格，点图标一下打开并收起面板。
struct AppLauncherView: View {
    @Bindable private var store = AppLauncherStore.shared

    var body: some View {
        VStack(spacing: 8) {
            // 搜索框
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.4))
                TextField(L("island.hub.search"), text: $store.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.white.opacity(0.08)))

            // 应用网格
            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 66), spacing: 8)],
                    spacing: 10
                ) {
                    ForEach(store.filtered) { app in
                        appCell(app)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .onAppear { store.loadIfNeeded() }
    }

    private func appCell(_ app: InstalledApp) -> some View {
        Button {
            AppLauncherStore.shared.launch(app)
            SystemStatsPanelController.shared?.dismiss()
        } label: {
            VStack(spacing: 4) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 42, height: 42)
                Text(app.name)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(width: 66)
            .padding(.vertical, 6)
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 宠物乐园（占位，后续做）

/// 「桌宠乐园」占位 —— 后续把桌宠活动场景放这里（承接 project_pet_life_scene_card 设想）。
struct PetParkPlaceholder: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "pawprint.fill")
                .font(.system(size: 30))
                .foregroundStyle(.white.opacity(0.28))
            Text(L("island.hub.pets.soon"))
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 钉住的桌面常驻卡片

/// 钉在桌面上的独立系统监控卡片：圆角矩形 + 标题头部 + 横排四指标 + 右上角关闭按钮。
/// 离开了刘海是自由浮在桌面的卡片，所以四角全圆角（不像 hover 面板那样顶部直角贴刘海）。
/// 拖动由 NSWindow.isMovableByWindowBackground 处理，关闭走 onClose。
/// **视觉（2026-06-08）**：从「纯黑」升级成 iOS 27 液态玻璃 —— 它自由浮在桌面，最适合通透玻璃。
/// 窗口已 `isOpaque=false`+`.clear`（见 SystemStatsPinController），behind-window 模糊直接生效。
struct SystemStatsPinnedCard: View {
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            StatsHeader {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.55))
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
            }
            SystemStatsGrid()
        }
        .padding(.top, 12)
        .padding(.bottom, 14)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .liquidGlassCard(cornerRadius: 16)   // iOS 27 液态玻璃：通透磨砂 + 渐变 + 顶部光泽 + 主色描边
    }
}
