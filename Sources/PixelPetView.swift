import SwiftUI

// MARK: - 像素宠物渲染器（把基因画成会动的像素宠物）

/// 固定的「画师」：拿一份 `PetGenome`，合成 13×13 像素网格，按配色画出来，
/// 再加轻微浮动（呼吸）+ 偶尔眨眼。纯代码渲染（守决策2）、数据驱动（基因是纯数据）。
struct PixelPetView: View {
    let genome: PetGenome
    var size: CGFloat = 110

    @State private var bob = false
    @State private var blink = false

    private var palette: PixelPalette {
        PixelPalettes.all[min(genome.palette, PixelPalettes.all.count - 1)]
    }

    var body: some View {
        let n = PetGenomeRenderer.canvas
        let grid = PetGenomeRenderer.grid(for: genome, blink: blink)
        let cell = size / CGFloat(n)

        Canvas { ctx, _ in
            for r in 0..<n {
                for c in 0..<n {
                    guard let color = palette.color(for: grid[r][c]) else { continue }
                    let rect = CGRect(x: CGFloat(c) * cell, y: CGFloat(r) * cell,
                                      width: cell + 0.6, height: cell + 0.6)  // +0.6 消除像素缝
                    ctx.fill(Path(rect), with: .color(color))
                }
            }
        }
        .frame(width: size, height: size)
        .offset(y: bob ? -3 : 1)                          // 呼吸式上下浮动（offset 不重绘 Canvas）
        .shadow(color: .black.opacity(0.25), radius: 5, y: 4)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) { bob = true }
        }
        .task(id: genome) { await blinkLoop() }            // 换宠物时重启眨眼循环
    }

    /// 每隔 2.5~4.5s 眨一下眼（120ms）。只在眨眼瞬间重绘 Canvas，开销极小。
    private func blinkLoop() async {
        while !Task.isCancelled {
            let gap = UInt64.random(in: 2_500_000_000...4_500_000_000)
            try? await Task.sleep(nanoseconds: gap)
            if Task.isCancelled { return }
            blink = true
            try? await Task.sleep(nanoseconds: 130_000_000)
            blink = false
        }
    }
}

// MARK: - 图片宠物（AI 生成的 PNG + 程序化"活"起来）

/// 把一张透明 PNG 显示成"活着的宠物"：呼吸缩放 + 上下浮动。
/// **关键 `.interpolation(.none)`**：像素图放大保持清晰、绝不糊。
struct ImagePetView: View {
    let image: NSImage
    var size: CGFloat = 170

    @State private var bob = false
    @State private var breathe = false

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .interpolation(.none)                 // 像素图：最近邻缩放，保持清晰不糊
            .scaledToFit()
            .frame(width: size, height: size)
            .scaleEffect(breathe ? 1.035 : 1.0)   // 呼吸
            .offset(y: bob ? -4 : 2)              // 浮动
            .shadow(color: .black.opacity(0.30), radius: 7, y: 7)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.7).repeatForever(autoreverses: true)) { bob = true }
                withAnimation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true)) { breathe = true }
            }
    }
}

// MARK: - 宠物乐园（控制中心「乐园」标签里的内容）

/// 乐园：用户用 AI 生成的原创精灵图（`PetSpeciesStore`，切片在 ~/.hermespet/species/）。
/// 每个物种一条进化线，当前阶段由养成等级推算；底部「换角色」可切不同物种。
/// 缺图时回退到纯代码自绘的 `PetSpriteView`。
struct PetParkView: View {
    @State private var progress = PetProgressStore.shared
    @State private var species = PetSpeciesStore.shared
    /// 点缩略图临时预览某阶段（nil = 跟随当前真实阶段）。
    @State private var previewStage: PetGrowthStage?

    private var current: PetGrowthStage { progress.progress.growthStage }
    private var shown: PetGrowthStage { previewStage ?? current }
    private var sel: PetSpecies { species.selected }

    var body: some View {
        VStack(spacing: 7) {
            // 顶部：物种名 · 阶段名（+ 预览标）+ 心情
            HStack(spacing: 5) {
                Text(sel.displayName)
                    .font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                Text("· " + L(shown.titleKey))
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.7))
                if previewStage != nil, previewStage != current {
                    Text(L("pet.park.preview"))
                        .font(.system(size: 9, weight: .semibold)).foregroundStyle(.white.opacity(0.65))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Color.white.opacity(0.14)))
                }
                Spacer(minLength: 0)
                HStack(spacing: 3) {
                    Image(systemName: progress.progress.mood.symbolName)
                    Text(L(progress.progress.mood.displayNameKey))
                }
                .font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.6))
            }

            // 大宠物（图片优先，缺图回退代码自绘；点空白回当前阶段）
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(RadialGradient(colors: [.white.opacity(0.10), .white.opacity(0.02)],
                                         center: .center, startRadius: 4, endRadius: 120))
                if case let frames = species.walkFrames(sel, shown), frames.count > 1 {
                    FrameAnimatedView(frames: frames, fps: 8, size: 118)   // 有逐帧动画 → 真走起来
                } else if let img = species.image(sel, shown) {
                    SpeciesPetView(image: img, size: 116)
                } else {
                    PetSpriteView(stage: shown, mood: progress.progress.mood, size: 116)
                }
            }
            .frame(height: 130)
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.easeOut(duration: 0.2)) { previewStage = nil } }

            // 战斗力
            HStack(spacing: 5) {
                Image(systemName: "bolt.fill").font(.system(size: 11)).foregroundStyle(Color(red: 1, green: 0.82, blue: 0.36))
                Text("\(progress.progress.battlePower)")
                    .font(.system(size: 18, weight: .heavy, design: .rounded)).foregroundStyle(.white)
                    .contentTransition(.numericText())
                Text(L("pet.park.power")).font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.5))
            }

            // 经验条 + 等级 + 下一阶段提示
            VStack(spacing: 4) {
                HStack {
                    Text("Lv \(progress.progress.level)")
                        .font(.system(size: 10, weight: .bold)).foregroundStyle(.white.opacity(0.85))
                    Spacer(minLength: 0)
                    Text(nextStageHint).font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.5))
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.12))
                        Capsule().fill(Color(red: 0.45, green: 0.86, blue: 0.78))
                            .frame(width: max(3, geo.size.width * progress.levelProgressFraction))
                    }
                }
                .frame(height: 6)
            }

            // 当前物种进化线（点击预览）
            HStack(spacing: 7) {
                ForEach(PetGrowthStage.allCases, id: \.rawValue) { stageThumb($0) }
            }

            Spacer(minLength: 0)

            // 换角色（切不同物种）
            HStack(spacing: 0) {
                Text(L("pet.park.switchRole"))
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.5))
                Spacer(minLength: 0)
            }
            HStack(spacing: 5) {
                ForEach(PetSpecies.allCases) { speciesThumb($0) }
            }
        }
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var nextStageHint: String {
        if let nx = current.next {
            let remain = max(1, nx.minLevel - progress.progress.level)
            return L("pet.park.nextStage", remain, L(nx.titleKey))
        }
        return L("pet.park.maxStage")
    }

    @ViewBuilder
    private func stageThumb(_ stage: PetGrowthStage) -> some View {
        let locked = stage.rawValue > current.rawValue
        let isShown = stage == shown
        Button {
            withAnimation(.easeOut(duration: 0.2)) { previewStage = (stage == current) ? nil : stage }
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(isShown ? 0.16 : 0.06))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.white.opacity(isShown ? 0.55 : 0), lineWidth: 1.5))
                Group {
                    if let img = species.image(sel, stage) {
                        Image(nsImage: img).resizable().interpolation(.high).scaledToFit().padding(4)
                    } else {
                        PetSpriteView(stage: stage, size: 38, animated: false)
                    }
                }
                .opacity(locked ? 0.4 : 1)
                if locked {
                    Image(systemName: "lock.fill").font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.7)).padding(3)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                }
            }
            .frame(width: 54, height: 50)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func speciesThumb(_ s: PetSpecies) -> some View {
        let isSel = s == sel
        Button {
            withAnimation(.easeOut(duration: 0.2)) { species.select(s); previewStage = nil }
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.white.opacity(isSel ? 0.18 : 0.06))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Color(red: 1, green: 0.82, blue: 0.36).opacity(isSel ? 0.9 : 0), lineWidth: 1.5))
                if let img = species.image(s, .adult) {
                    Image(nsImage: img).resizable().interpolation(.high).scaledToFit().padding(3)
                }
            }
            .frame(width: 48, height: 44)
        }
        .buttonStyle(.plain)
    }
}
