import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 像素角色（一个像素格扮演什么颜色）

/// 一个像素格的「颜色角色」—— 基因只记角色，真正的颜色由 `PixelPalette` 决定（换配色不动形状）。
enum PixelRole: UInt8 {
    case empty       // 透明
    case primary     // 身体主色
    case secondary   // 肚皮副色
    case accent      // 点缀/签名色（耳朵尖、花纹）
    case outline     // 描边（自动生成）
    case eyeWhite    // 眼白
    case pupil       // 瞳孔
}

// MARK: - 配色（一套调色板把角色映射成真实颜色）

struct PixelPalette {
    let primary, secondary, accent, outline, eyeWhite, pupil: Color

    func color(for role: PixelRole) -> Color? {
        switch role {
        case .empty:     return nil
        case .primary:   return primary
        case .secondary: return secondary
        case .accent:    return accent
        case .outline:   return outline
        case .eyeWhite:  return eyeWhite
        case .pupil:     return pupil
        }
    }
}

enum PixelPalettes {
    static let all: [PixelPalette] = [
        // 薄荷
        PixelPalette(primary: Color(red: 0.56, green: 0.86, blue: 0.74), secondary: Color(red: 0.86, green: 0.97, blue: 0.91),
                   accent: Color(red: 0.27, green: 0.72, blue: 0.62), outline: Color(red: 0.10, green: 0.26, blue: 0.23),
                   eyeWhite: .white, pupil: Color(red: 0.10, green: 0.20, blue: 0.20)),
        // 桃粉
        PixelPalette(primary: Color(red: 0.99, green: 0.71, blue: 0.78), secondary: Color(red: 1.00, green: 0.90, blue: 0.92),
                   accent: Color(red: 0.95, green: 0.45, blue: 0.62), outline: Color(red: 0.42, green: 0.14, blue: 0.24),
                   eyeWhite: .white, pupil: Color(red: 0.30, green: 0.12, blue: 0.18)),
        // 天蓝
        PixelPalette(primary: Color(red: 0.55, green: 0.78, blue: 0.98), secondary: Color(red: 0.88, green: 0.95, blue: 1.00),
                   accent: Color(red: 0.32, green: 0.55, blue: 0.95), outline: Color(red: 0.10, green: 0.22, blue: 0.42),
                   eyeWhite: .white, pupil: Color(red: 0.10, green: 0.18, blue: 0.34)),
        // 暖橙
        PixelPalette(primary: Color(red: 0.99, green: 0.74, blue: 0.42), secondary: Color(red: 1.00, green: 0.92, blue: 0.78),
                   accent: Color(red: 0.95, green: 0.50, blue: 0.20), outline: Color(red: 0.40, green: 0.20, blue: 0.06),
                   eyeWhite: .white, pupil: Color(red: 0.32, green: 0.16, blue: 0.06)),
        // 紫晶
        PixelPalette(primary: Color(red: 0.75, green: 0.66, blue: 0.96), secondary: Color(red: 0.92, green: 0.88, blue: 1.00),
                   accent: Color(red: 0.55, green: 0.42, blue: 0.92), outline: Color(red: 0.22, green: 0.14, blue: 0.40),
                   eyeWhite: .white, pupil: Color(red: 0.18, green: 0.12, blue: 0.32)),
    ]
    static let names = ["薄荷", "桃粉", "天蓝", "暖橙", "紫晶"]
}

// MARK: - 积木：身体（含耳朵，画成完整轮廓更可爱）

/// 一个身体模板：ASCII 像素图（B=主色 b=副色 A=点缀 .=空）+ 眼睛锚点。
/// 全部在 13×13 的画布坐标系里，最多 13 行。
struct PetBody {
    let art: [String]
    let eyeRow: Int
    let eyeColL: Int
    let eyeColR: Int
}

enum PetBodies {
    /// 圆滚滚 + 圆耳朵
    static let round = PetBody(art: [
        "..BB.....BB..",
        "..BBBBBBBBB..",
        "...BBBBBBB...",
        ".BBBBBBBBBBB.",
        ".BBBBBBBBBBB.",
        "BBBBBBBBBBBBB",
        "BBBBBBBBBBBBB",
        "BBBBbbbbbBBBB",
        "BBBBbbbbbBBBB",
        ".BBBBbbbBBBB.",
        "..BBBBBBBBB..",
        "...BB...BB...",
    ], eyeRow: 5, eyeColL: 3, eyeColR: 8)

    /// 高个 + 触角
    static let tall = PetBody(art: [
        "....A...A....",
        "....B...B....",
        "....BBBBB....",
        "...BBBBBBB...",
        "...BBBBBBB...",
        "...BBBBBBB...",
        "...BBbbbBB...",
        "...BBbbbBB...",
        "...BBBBBBB...",
        "...BBBBBBB...",
        "....B...B....",
        "...BB...BB...",
    ], eyeRow: 4, eyeColL: 4, eyeColR: 8)

    /// 宽墩墩 + 小尖耳
    static let wide = PetBody(art: [
        ".A.........A.",
        ".BB.......BB.",
        ".BBBBBBBBBBB.",
        "BBBBBBBBBBBBB",
        "BBBBBBBBBBBBB",
        "BBBBBBBBBBBBB",
        "BBBBbbbbbBBBB",
        "BBBBbbbbbBBBB",
        "BBBBbbbbbBBBB",
        "BBBBBBBBBBBBB",
        ".BBBBBBBBBBB.",
        "..BB.....BB..",
    ], eyeRow: 4, eyeColL: 3, eyeColR: 8)

    static let all: [PetBody] = [round, tall, wide]
}

// MARK: - 积木：眼睛（小图章，贴在身体的眼睛锚点）

enum PetEyes {
    /// 每种眼睛是一个小 ASCII 图章，左右各贴一次
    static let all: [[String]] = [
        ["WW", "WP"],   // 圆眼（眼白 + 右下瞳）
        ["WW", "PP"],   // 大眼（看下方，萌）
        ["PP"],         // 豆豆眼（一条小线）
    ]
    /// 眨眼时用的闭眼（一条描边色横线）
    static let closed: [String] = ["OO"]
}

// MARK: - 阶段

enum PetStage: String, Codable, CaseIterable {
    case egg, baby, child, teen, adult

    var title: String {
        switch self {
        case .egg:   return "蛋"
        case .baby:  return "幼年"
        case .child: return "成长"
        case .teen:  return "成熟"
        case .adult: return "究极"
        }
    }
}

// MARK: - 基因（纯数据：零件 id + 配色 + 签名 + 阶段 + 种子）

/// 一只像素宠物的「基因」。AI 生成时只产这份数据（安全、可存、随处渲染）；
/// 固定的 `PixelPetView` 照着画。本原型先用本地随机当"AI 选件"占位。
struct PetGenome: Codable, Equatable {
    var body: Int          // PetBodies.all 索引
    var eyes: Int          // PetEyes.all 索引
    var palette: Int       // PixelPalettes.all 索引
    var signature: Int     // 0/1/2 签名件位置
    var stage: PetStage
    var seed: Int

    /// 由种子确定性生成一只（同种子永远同一只 → 可复现）
    static func random(seed: Int) -> PetGenome {
        var rng = SeededRNG(seed: UInt64(bitPattern: Int64(seed)))
        func pick(_ n: Int) -> Int { Int(rng.next() % UInt64(max(1, n))) }
        return PetGenome(
            body: pick(PetBodies.all.count),
            eyes: pick(PetEyes.all.count),
            palette: pick(PixelPalettes.all.count),
            signature: pick(3),
            stage: .baby,
            seed: seed
        )
    }

    var paletteName: String { PixelPalettes.names[min(palette, PixelPalettes.names.count - 1)] }
}

/// 极简确定性随机（xorshift64）—— 同种子出同一只宠物。
struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}

// MARK: - 基因 → 像素网格（合成 + 自动描边）

enum PetGenomeRenderer {
    static let canvas = 13   // 13×13 像素画布

    /// 把基因合成成一张 13×13 的「角色网格」。blink=true 时画闭眼。
    static func grid(for g: PetGenome, blink: Bool) -> [[PixelRole]] {
        let n = canvas
        var grid = Array(repeating: Array(repeating: PixelRole.empty, count: n), count: n)

        // 1) 身体
        let body = PetBodies.all[min(g.body, PetBodies.all.count - 1)]
        for (r, line) in body.art.enumerated() where r < n {
            for (c, ch) in line.enumerated() where c < n {
                if let role = role(for: ch) { grid[r][c] = role }
            }
        }

        // 2) 眼睛（左右各贴一次；眨眼用闭眼）
        let eyeArt = blink ? PetEyes.closed : PetEyes.all[min(g.eyes, PetEyes.all.count - 1)]
        stamp(&grid, eyeArt, row: body.eyeRow, col: body.eyeColL)
        stamp(&grid, eyeArt, row: body.eyeRow, col: body.eyeColR)

        // 3) 签名件（AI 自由发挥那一点 —— 本原型按 signature 放在固定几个位置）
        for (r, c) in signatureCells(g.signature, body: body) where r >= 0 && r < n && c >= 0 && c < n {
            if grid[r][c] == .primary || grid[r][c] == .secondary { grid[r][c] = .accent }
        }

        // 4) 自动描边（轮廓外缘一圈 → 干净的像素描边）
        addOutline(&grid)
        return grid
    }

    private static func role(for ch: Character) -> PixelRole? {
        switch ch {
        case "B": return .primary
        case "b": return .secondary
        case "A": return .accent
        case "W": return .eyeWhite
        case "P": return .pupil
        case "O": return .outline
        default:  return nil
        }
    }

    private static func stamp(_ grid: inout [[PixelRole]], _ art: [String], row: Int, col: Int) {
        for (dr, line) in art.enumerated() {
            for (dc, ch) in line.enumerated() {
                let r = row + dr, c = col + dc
                guard r >= 0, r < grid.count, c >= 0, c < grid[0].count else { continue }
                if let role = role(for: ch) { grid[r][c] = role }
            }
        }
    }

    /// 签名件落点（0=额心 1=肚皮 2=腮红）
    private static func signatureCells(_ sig: Int, body: PetBody) -> [(Int, Int)] {
        let cx = 6
        switch sig {
        case 0:  return [(body.eyeRow - 1, cx)]                                   // 额心一点
        case 1:  return [(body.eyeRow + 3, cx), (body.eyeRow + 3, cx - 1)]        // 肚皮小花纹
        default: return [(body.eyeRow + 1, body.eyeColL - 1), (body.eyeRow + 1, body.eyeColR + 2)]  // 腮红
        }
    }

    /// 给轮廓加一圈描边：空格但 4 邻有实体（非空非描边）→ 设为描边。
    private static func addOutline(_ grid: inout [[PixelRole]]) {
        let n = grid.count
        let solid: (PixelRole) -> Bool = { $0 != .empty && $0 != .outline }
        var outlineCells: [(Int, Int)] = []
        for r in 0..<n {
            for c in 0..<n where grid[r][c] == .empty {
                let neighbors = [(r-1, c), (r+1, c), (r, c-1), (r, c+1)]
                if neighbors.contains(where: { (nr, nc) in
                    nr >= 0 && nr < n && nc >= 0 && nc < n && solid(grid[nr][nc])
                }) {
                    outlineCells.append((r, c))
                }
            }
        }
        for (r, c) in outlineCells { grid[r][c] = .outline }
    }
}

// MARK: - 基因存档（@Observable 单例，持久化 + 再孵）

/// 当前这只宠物的基因 —— 存 UserDefaults，乐园直接读。本原型用 `reroll()` 本地随机换一只看效果。
@MainActor
@Observable
final class PetGenomeStore {
    static let shared = PetGenomeStore()

    private(set) var current: PetGenome

    private static let key = "petGenome.v1"

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let g = try? JSONDecoder().decode(PetGenome.self, from: data) {
            current = g
        } else {
            current = PetGenome.random(seed: 20260606)
            save()
        }
    }

    /// 再孵一只（换个随机种子）—— 演示盲盒变化。后续这步换成"AI 按问答选件"。
    func reroll() {
        current = PetGenome.random(seed: Int.random(in: 0..<1_000_000))
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(current) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}

// MARK: - 宠物形象图（AI 生成的 PNG，先手动放进来，后续接自动生成）

/// 当前这只宠物的「形象图」—— 一张透明 PNG（AI 生成）。先支持手动选图放进来看效果，
/// 之后这步换成"问答 → 调出图模型自动生成"。图存到 `~/.hermespet/pet.png`。
@MainActor
@Observable
final class PetImageStore {
    static let shared = PetImageStore()

    /// 当前宠物图（nil = 还没设）
    private(set) var image: NSImage?

    private init() {
        image = NSImage(contentsOf: Self.imageURL)
    }

    private static var dir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".hermespet")
    }
    private static var imageURL: URL { dir.appendingPathComponent("pet.png") }

    /// 弹出系统选图框，挑一张 PNG/图片当宠物形象。
    func pickImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "选作宠物"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importImage(from: url)
    }

    /// 把选中的图标准化成 PNG 存到 ~/.hermespet/pet.png，并刷新当前形象。
    func importImage(from url: URL) {
        guard let img = NSImage(contentsOf: url) else { return }
        try? FileManager.default.createDirectory(at: Self.dir, withIntermediateDirectories: true)
        // 统一转成 PNG 落盘（保留透明）
        if let tiff = img.tiffRepresentation,
           let bmp = NSBitmapImageRep(data: tiff),
           let png = bmp.representation(using: .png, properties: [:]) {
            try? png.write(to: Self.imageURL)
        }
        image = NSImage(contentsOf: Self.imageURL) ?? img
    }
}
