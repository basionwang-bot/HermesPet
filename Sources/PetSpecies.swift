import SwiftUI

// MARK: - 宠物物种（用户用 AI 生成的原创精灵图，切片放在 ~/.hermespet/species/）
//
// 每个物种一条进化线：egg / baby / juv / adult（对应养成阶段 蛋/幼年/壮年/成年）。
// 图片由用户拥有版权（自己生成的原创元素生物），切片文件名 = `<species>_<filestage>.png`。

enum PetSpecies: String, CaseIterable, Identifiable {
    case flame, frost, moss, storm, leaf, magma
    var id: String { rawValue }

    /// 显示名（专名，中英一致；后续可接 i18n）
    var displayName: String {
        switch self {
        case .flame: return "炎龙"
        case .frost: return "霜狐"
        case .moss:  return "苔龟"
        case .storm: return "雷鹰"
        case .leaf:  return "叶精"
        case .magma: return "熔岩"
        }
    }
}

// MARK: - 物种素材仓库（@Observable 单例：选哪只 + 加载/缓存切片图）

@MainActor
@Observable
final class PetSpeciesStore {
    static let shared = PetSpeciesStore()

    /// 当前选中的物种（持久化）。
    private(set) var selected: PetSpecies

    @ObservationIgnored private var cache: [String: NSImage] = [:]
    @ObservationIgnored private var frameCache: [String: [NSImage]] = [:]
    private static let storageKey = "petSpecies.v1"

    private init() {
        let raw = UserDefaults.standard.string(forKey: Self.storageKey) ?? PetSpecies.flame.rawValue
        selected = PetSpecies(rawValue: raw) ?? .flame
    }

    func select(_ s: PetSpecies) {
        selected = s
        UserDefaults.standard.set(s.rawValue, forKey: Self.storageKey)
    }

    static var dir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".hermespet/species")
    }

    /// 养成阶段 → 切片文件里的阶段名（prime → juv）。
    private static let fileStage = ["egg", "baby", "juv", "adult"]

    func image(_ species: PetSpecies, _ stage: PetGrowthStage) -> NSImage? {
        let fs = Self.fileStage[max(0, min(3, stage.rawValue))]
        let name = "\(species.rawValue)_\(fs)"
        if let c = cache[name] { return c }
        let url = Self.dir.appendingPathComponent("\(name).png")
        guard let img = NSImage(contentsOf: url) else { return nil }
        cache[name] = img
        return img
    }

    /// 走路循环帧（anim/<species>_<filestage>_walk_<i>.png，从 0 连续加载）。空 = 没有动画素材。
    func walkFrames(_ species: PetSpecies, _ stage: PetGrowthStage) -> [NSImage] {
        let fs = Self.fileStage[max(0, min(3, stage.rawValue))]
        let key = "\(species.rawValue)_\(fs)"
        if let c = frameCache[key] { return c }
        let animDir = Self.dir.appendingPathComponent("anim")
        var frames: [NSImage] = []
        var i = 0
        while i < 48 {
            let url = animDir.appendingPathComponent("\(key)_walk_\(i).png")
            guard let img = NSImage(contentsOf: url) else { break }
            frames.append(img); i += 1
        }
        frameCache[key] = frames
        return frames
    }

    /// 是否已经导入了素材（用 flame_adult 当探针）。
    var hasArt: Bool {
        FileManager.default.fileExists(atPath: Self.dir.appendingPathComponent("flame_adult.png").path)
    }
}

// MARK: - 图片宠物视图（呼吸浮动；守 [[feedback_pixel_art_swiftui]]：只用 offset，不挂 scaleEffect）

struct SpeciesPetView: View {
    let image: NSImage
    var size: CGFloat = 120
    var animated: Bool = true

    @State private var bobUp = false

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)        // 这套是较高分辨率的精细像素画，缩放用高质量更顺
            .scaledToFit()
            .frame(width: size, height: size)
            .offset(y: animated ? (bobUp ? -5 : 1) : 0)
            .shadow(color: .black.opacity(0.3), radius: 7, y: 6)
            .onAppear {
                guard animated else { return }
                withAnimation(.easeInOut(duration: 1.7).repeatForever(autoreverses: true)) { bobUp = true }
            }
    }
}

// MARK: - 帧动画播放器（逐帧循环 = 真·走起来）

/// 把一组连续帧按 fps 循环播放。守 [[feedback_pixel_art_swiftui]]：不挂 scaleEffect。
struct FrameAnimatedView: View {
    let frames: [NSImage]
    var fps: Double = 8
    var size: CGFloat = 116

    @State private var idx = 0

    var body: some View {
        Group {
            if frames.indices.contains(idx) {
                Image(nsImage: frames[idx]).resizable().interpolation(.high).scaledToFit()
            } else if let first = frames.first {
                Image(nsImage: first).resizable().interpolation(.high).scaledToFit()
            } else {
                Color.clear
            }
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.3), radius: 7, y: 6)
        .task(id: frames.count) {
            guard frames.count > 1 else { return }
            let ns = UInt64(1_000_000_000.0 / max(1, fps))
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: ns)
                if Task.isCancelled { return }
                idx = (idx + 1) % frames.count
            }
        }
    }
}
