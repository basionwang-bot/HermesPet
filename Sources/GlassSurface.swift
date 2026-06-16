import SwiftUI

/// 玻璃质感（半透明材质）可读性增强。
///
/// 痛点：`.ultraThinMaterial` 是最透的一档，背后一旦是亮壁纸 / 白窗口，材质被"染白"，
/// 文字（尤其浅色 / secondary）对比度崩掉，用户反映"看不清"。
///
/// 方案：在材质和文字之间垫一层"对比兜底" scrim —— 用 `windowBackgroundColor`
/// （浅色模式≈白、深色模式≈黑，自动跟随外观），保证文字始终有一个对比度下限，
/// **但卡片整体仍透**（scrim 越轻越透）。
///
/// 同时尊重系统辅助功能「减弱透明度」：开启时直接换近实色背景（Apple 官方可读性方案）。
///
/// 用法：替换原来的 `.background(.ultraThinMaterial)`，圆角由调用点已有的 `.clipShape` 负责。
extension View {
    /// - Parameter scrim: 平时（未开减弱透明度）scrim 不透明度。
    ///   越大越清楚越不透。聊天窗 ~0.5、快问 ~0.42、桌面 Pin ~0.28（保通透）。
    func legibleGlass(scrim: Double) -> some View {
        modifier(LegibleGlassModifier(scrim: scrim))
    }
}

private struct LegibleGlassModifier: ViewModifier {
    let scrim: Double
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        content.background {
            if reduceTransparency {
                // 辅助功能：用户主动选"看清优先" → 近实色背景，不再透
                Color(nsColor: .windowBackgroundColor)
            } else {
                ZStack {
                    Rectangle().fill(.ultraThinMaterial)
                    // 对比兜底层：自动跟随亮/暗模式（浅色垫白、深色垫黑）
                    Rectangle().fill(Color(nsColor: .windowBackgroundColor).opacity(scrim))
                }
            }
        }
    }
}

// MARK: - 液态玻璃卡（iOS 27 Liquid Glass）：真 behind-window 通透 + 暗色渐变 + 顶部光泽 + 主色描边

/// 真·behind-window 玻璃模糊：透出并模糊窗口「背后」的桌面/窗口——iOS 27 那种通透液态玻璃质感。
/// ⚠️ SwiftUI 的 `.ultraThinMaterial` 在透明 borderless 窗里多走 within-window 混合（窗内没东西可糊→
///   几乎不透，这是「不够通透」的根因）；只有 `NSVisualEffectView` + `.behindWindow` 才真透出桌面。
/// ⚠️ 不能塞进 `.compositingGroup()`/离屏渲染——behind-window 是窗口服务器级效果，离屏后会失效变黑。
/// 宿主窗口必须 `isOpaque=false` + `backgroundColor=.clear`，否则糊不出来。
struct BehindWindowGlass: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow   // 透出窗口「背后」的桌面（通透关键）
        v.state = .active                // 始终激活，不随窗口失焦变实
        v.isEmphasized = true
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .active
    }
}

extension View {
    /// 给一张「自由浮在桌面/内容上方」的卡片套上 **iOS 26 原生液态玻璃**（真通透 + 边缘折射 + 高光）。
    /// macOS 26+ 走系统 `.glassEffect()`（Apple 自己算的 Liquid Glass，不是磨砂）；老系统退回 behind-window 磨砂兜底。
    /// **仅用于 `isOpaque=false`+`.clear` 背景的独立窗口**；贴刘海的纯黑面板别用。
    /// - tint：仅老系统兜底的边缘高光主色（原生 Liquid Glass 不染色，保持通透）。
    func liquidGlassCard(cornerRadius: CGFloat,
                         tint: Color = Color(red: 0.431, green: 0.431, blue: 0.969)) -> some View {
        modifier(LiquidGlassCardModifier(cornerRadius: cornerRadius, tint: tint))
    }
}

private struct LiquidGlassCardModifier: ViewModifier {
    let cornerRadius: CGFloat
    let tint: Color
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        // 辅助功能「减弱透明度」：近实色深底 + 细描边，不再通透（Apple 官方可读性方案）
        if reduceTransparency {
            return AnyView(content.background(
                shape.fill(Color.black.opacity(0.92))
                    .overlay(shape.stroke(Color.white.opacity(0.12), lineWidth: 0.8))
            ))
        }

        // ⭐ macOS 26 (Tahoe) 原生 Liquid Glass —— iOS 26 那种「真通透 + 边缘折射 + 高光」，
        //   Apple 自己算的玻璃，不是 NSVisualEffectView 的磨砂质感。窗口须 isOpaque=false/.clear。
        //   用更通透的 `.clear` 档（`.regular` 偏实）+ 在系统折射之上再叠一道高光描边让边缘更有玻璃味。
        if #available(macOS 26.0, *) {
            // ✅ 通透版（用户认可的那版）：玻璃放背景层 + 降不透明度 → 通透；外加一道斜向高光描边收边。
            //   （`.regular` 折射太实、`.clear.interactive()` 又不如这版好，已回退到此版。）
            return AnyView(
                content
                    .background {
                        Color.clear
                            .glassEffect(.clear, in: shape)
                            .opacity(0.72)
                    }
                    .overlay(
                        shape.strokeBorder(
                            LinearGradient(
                                colors: [Color.white.opacity(0.55),
                                         Color.white.opacity(0.06),
                                         Color.white.opacity(0.22)],
                                startPoint: .topLeading, endPoint: .bottomTrailing),
                            lineWidth: 1)
                    )
            )
        }

        // 老系统(<26)兜底：behind-window 磨砂模糊（达不到原生 Liquid Glass，尽量通透）
        return AnyView(content.background(
            BehindWindowGlass()
                .clipShape(shape)
                .overlay(shape.fill(LinearGradient(
                    colors: [Color.black.opacity(0.10), Color.black.opacity(0.28)],
                    startPoint: .top, endPoint: .bottom)))
                .overlay(shape.fill(LinearGradient(
                    colors: [Color.white.opacity(0.20), .clear],
                    startPoint: .top, endPoint: .center)))
                .overlay(shape.stroke(LinearGradient(
                    colors: [Color.white.opacity(0.42), tint.opacity(0.22), Color.white.opacity(0.06)],
                    startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.9))
        ))
    }
}
