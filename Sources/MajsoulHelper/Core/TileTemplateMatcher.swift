import Foundation
import CoreGraphics
import ImageIO

/// 用**雀魂自己的牌面素材**（`ui.png` + `ui.atlas`）做模板匹配来识别手牌。
///
/// ## 为什么换掉模型
///
/// 实测同一批真实截图，模型逐张识牌的准确率只有 74~85%，
/// 而且每张牌都要发一次带图请求（十几秒）。模板匹配是**确定性**的：
///
/// | 测试 | 结果 |
/// |---|---|
/// | 自检：素材图 37 个 sprite 自己认自己 | **37/37** |
/// | 真机截图 A（「理和鳴切」主题，14 张，含赤五索与白板） | **14/14** |
/// | 真机截图 B（默认主题，14 张） | **14/14** |
///
/// 纯本地计算，不花 token。
///
/// ## 四个关键点（少一个就做不成）
///
/// 1. **必须用整张牌**，不能只切牌面。实测手牌那一张的纵向真实范围是 164px
///    （`101 × 129/80`，比例来自 atlas 里 sprite 的 80×129），而按"亮牌面"检测出来的
///    只有 136px —— 上下各少了 14px。裁少了就对不上模板，分数会掉到 0.3 上下、次选只差 0.01。
/// 2. **切分与裁牌必须是同一份像素**。切分跑 JPEG、裁牌用编码前的位图，
///    边界会差几像素 → 赤五索被判成普通五索、白板认不出。见 `TileSegmenter.segment(cg:)`。
/// 3. **要遮掉素材图右上角的编号**。素材图上每格右上角印了 `1`~`9` / `E S W N Wh G R`
///    之类的编号，真机上没有 —— 不遮就成了"模板有、实拍没有"的固定差异。
/// 4. **比的是"墨迹强度图" + 软 IoU**，不是原图、也不是二值图。
///    - 用原图：素材底色 `(223,223,220)` 与实拍底色 `(247,245,238)` 不同，会被底色主导。
///    - 用二值图（IoU）：对墨迹粗细太敏感，实拍有 JPEG 噪声 + 阴影，分数全挤在 0.35~0.6。
///    - 软 IoU（`Σmin / Σmax`）只在有墨迹的地方比，白板对白板 ≈ 1、白板对有图案的牌 ≈ 0。
///
/// ## 性能
///
/// 朴素写法一张牌要跑 `25 平移 × 37 模板 × 10320 像素 ≈ 950 万次比较`，实测 **2.4 秒/张**
/// （14 张 34 秒，比调模型还慢）。三处优化后降到毫秒级：
/// 1. 用恒等式 `Σmin/Σmax = (S−D)/(S+D)`（`S=Σ(a+b)`、`D=Σ|a−b|`），
///    内循环只剩「一次减法求绝对值」，去掉了逐像素的 min/max 分支。
/// 2. `S` 用**二维前缀和**，O(1) 取值，不用再遍历一遍。
/// 3. 先按「不平移的分数」给 37 张模板粗排，只对前 8 名做完整平移搜索。
/// 4. 上层再按牌并行（`DispatchQueue.concurrentPerform`），多核再快几倍。
enum TileTemplateMatcher {

    struct Match {
        var name: String          // 牌名记号，如 "5m" / "0s" / "5z"
        var score: Double         // 软 IoU，0~1
        var runnerUp: String
        var runnerUpScore: Double
        /// 墨迹里的红色占比（区分赤五与普通五的依据，自测里会打出来）
        var redRatio: Double = 0
        var margin: Double { score - runnerUpScore }
    }

    /// atlas 里每个 sprite 的尺寸（`ui.atlas` 里 40 个 frame 全是 80×129）
    static let tileW = 80
    static let tileH = 129
    private static let planeW = tileW
    private static let planeH = tileH

    /// 实测：正确匹配最低 0.62（白板，最容易混的一张），错误匹配最高约 0.5。
    /// 取 0.45 当"认出来了"的门槛；低于它的基本是空槽或严重错位。
    static let minAcceptableScore = 0.45

    // MARK: - 内部数据结构

    private struct Plane {
        var ink: [Float]
        var prefix: [Float]       // (w+1)×(h+1) 的二维前缀和
        var redRatio: Double
    }

    private struct Template {
        var name: String
        var ink: [Float]
        var prefix: [Float]
        var redRatio: Double
    }

    private static let templates: [Template] = loadTemplates()
    private static let redRatios: [String: Double] = {
        var d: [String: Double] = [:]
        for t in templates { d[t.name] = t.redRatio }
        return d
    }()

    static var isAvailable: Bool { !templates.isEmpty }
    static var templateNames: [String] { templates.map(\.name).sorted() }

    // MARK: - 识别

    /// 认一张牌。`cg` 应当是**整张牌**（宽高比 80:129，即 `pitch × pitch*129/80`），
    /// 不是只裁牌面。
    static func identify(_ cg: CGImage) -> Match? {
        guard !templates.isEmpty, let q = planes(from: cg) else { return nil }

        // 粗排：不平移，先给 37 张模板打个分
        let coarse = templates.map { (t: Template) -> (Double, Template) in
            (bestSoftIoU(q.ink, q.prefix, t.ink, t.prefix, radius: 0), t)
        }.sorted { $0.0 > $1.0 }

        // 只对前 8 名做完整平移搜索；同时保证 5X/0X 成对进入决赛
        var finalists = Array(coarse.prefix(8).map(\.1))
        var seen = Set(finalists.map(\.name))
        for (_, t) in coarse.prefix(8) where t.name == "5m" || t.name == "5p" || t.name == "5s" {
            let partner = "0" + t.name.suffix(1)
            if let p = templates.first(where: { $0.name == partner }), !seen.contains(p.name) {
                finalists.append(p)
                seen.insert(p.name)
            }
        }

        var best = ("", 0.0), second = ("", 0.0)
        for t in finalists {
            let s = bestSoftIoU(q.ink, q.prefix, t.ink, t.prefix)
            if s > best.1 {
                second = best
                best = (t.name, s)
            } else if s > second.1 {
                second = (t.name, s)
            }
        }
        guard !best.0.isEmpty else { return nil }

        // ★ 赤五（0X）与普通五（5X）**形状完全一样、只有颜色不同**，
        //   光比墨迹形状只差 0.01（实测 0s 0.83 vs 5s 0.82），等于在掷硬币。
        //   用「红色占比」裁决：拿两张模板占比的**中点**当阈值。
        //   实测：模板 5m 0.49 / 0m 0.69、5p 0.20 / 0p 0.76、5s 0.26 / 0s 0.74；
        //   真机 5m 0.39~0.40、0s 0.81 —— 都落在正确一侧，且离中点很远。
        if best.0.count == 2, let rank = best.0.first, rank == "5" || rank == "0" {
            let suit = String(best.0.suffix(1))
            if let r5 = redRatios["5" + suit], let r0 = redRatios["0" + suit] {
                best.0 = q.redRatio >= (r5 + r0) / 2 ? ("0" + suit) : ("5" + suit)
            }
        }

        return Match(name: best.0, score: best.1, runnerUp: second.0,
                     runnerUpScore: second.1, redRatio: q.redRatio)
    }

    /// 一次认多张牌。内部按牌并行 —— 单张毫秒级，14 张在多核上更快。
    static func identifyAll(_ cgs: [CGImage]) -> [Match?] {
        var out = [Match?](repeating: nil, count: cgs.count)
        DispatchQueue.concurrentPerform(iterations: cgs.count) { i in
            out[i] = identify(cgs[i])
        }
        return out
    }

    static func identify(jpeg: Data) -> Match? {
        guard let cg = decodeFirstImage(jpeg) else { return nil }
        return identify(cg)
    }

    // MARK: - 墨迹强度图

    /// 把一张图归一化成 `tileW × tileH` 的「墨迹强度图」+ 红色占比。
    ///
    /// 墨迹强度：以该图自身的**中位灰度为底色**，`(底色 - 灰度) / 90` 截到 0~1。
    /// 这样素材图（底色 223）与实拍图（底色 247）能落在同一尺度上。
    ///
    /// 红色强度：`(R - max(G,B)) / 60` 截到 0~1，按墨迹强度加权求和，
    /// 得到「墨迹里有多少是红的」—— 区分赤五与普通五（两者形状完全一样）。
    private static func planes(from cg: CGImage) -> Plane? {
        guard let (gray, red) = samplePlanes(cg, w: planeW, h: planeH) else { return nil }
        var sorted = gray
        sorted.sort()
        let median = sorted[sorted.count / 2]
        var ink = [Float](repeating: 0, count: gray.count)
        for i in 0..<gray.count {
            let d = (median - gray[i]) / 90.0
            ink[i] = d <= 0 ? 0 : (d >= 1 ? 1 : d)
        }
        // 标签区在 ink 里清零，红色统计乘的是 ink，于是口径自动一致
        maskLabel(&ink, w: planeW, h: planeH)
        var inkSum = 0.0, redSum = 0.0
        for i in 0..<ink.count {
            let m = Double(ink[i])
            inkSum += m
            redSum += m * Double(red[i])
        }
        return Plane(ink: ink, prefix: prefixSum(ink, w: planeW, h: planeH),
                     redRatio: inkSum < 1 ? 0 : redSum / inkSum)
    }

    /// 遮掉素材图右上角的编号区（实拍图那块是空的，不遮就是固定差异）。
    private static func maskLabel(_ v: inout [Float], w: Int, h: Int) {
        let x0 = Int(Double(w) * 0.68), y1 = Int(Double(h) * 0.24)
        guard x0 < w, y1 > 0 else { return }
        for y in 0..<y1 {
            for x in x0..<w { v[y * w + x] = 0 }
        }
    }

    private static func samplePlanes(_ cg: CGImage, w: Int, h: Int) -> ([Float], [Float])? {
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &buf, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var gray = [Float](repeating: 0, count: w * h)
        var red = [Float](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            let p = i * 4
            let r = Float(buf[p]), g = Float(buf[p + 1]), b = Float(buf[p + 2])
            // 亮度权重要与 PIL 的 convert("L") 接近，才能跟标定时的数据一致
            gray[i] = 0.299 * r + 0.587 * g + 0.114 * b
            let d = (r - max(g, b)) / 60.0
            red[i] = d <= 0 ? 0 : (d >= 1 ? 1 : d)
        }
        return (gray, red)
    }

    // MARK: - 前缀和 / 软 IoU

    /// (w+1)×(h+1) 的二维前缀和，任取矩形的和都是 O(1)
    private static func prefixSum(_ v: [Float], w: Int, h: Int) -> [Float] {
        var p = [Float](repeating: 0, count: (w + 1) * (h + 1))
        for y in 0..<h {
            var rowSum: Float = 0
            for x in 0..<w {
                rowSum += v[y * w + x]
                p[(y + 1) * (w + 1) + (x + 1)] = p[y * (w + 1) + (x + 1)] + rowSum
            }
        }
        return p
    }

    @inline(__always)
    private static func rectSum(_ p: [Float], _ w: Int, _ y0: Int, _ y1: Int, _ x0: Int, _ x1: Int) -> Float {
        let st = w + 1
        return p[y1 * st + x1] - p[y0 * st + x1] - p[y1 * st + x0] + p[y0 * st + x0]
    }

    /// 软 IoU = `Σmin / Σmax`，在一小片平移里取最好值。
    ///
    /// 用恒等式避开逐像素 min/max：
    ///   `Σmax − Σmin = Σ|a−b| = D`、`Σmax + Σmin = Σ(a+b) = S`
    ///   → `Σmin / Σmax = (S − D) / (S + D)`
    /// 于是内循环只剩「一次减法求绝对值」，`S` 由前缀和 O(1) 得到。
    private static func bestSoftIoU(_ a: [Float], _ prefA: [Float],
                                    _ b: [Float], _ prefB: [Float],
                                    radius: Int = 4, step: Int = 2) -> Double {
        let w = planeW, h = planeH
        return a.withUnsafeBufferPointer { ap in
            b.withUnsafeBufferPointer { bp in
                var best: Float = 0
                for dy in stride(from: -radius, through: radius, by: step) {
                    for dx in stride(from: -radius, through: radius, by: step) {
                        let y0 = max(0, dy), y1 = min(h, h + dy)
                        let x0 = max(0, dx), x1 = min(w, w + dx)
                        guard (y1 - y0) * (x1 - x0) >= w * h / 2 else { continue }
                        var d: Float = 0
                        let n = x1 - x0
                        for y in y0..<y1 {
                            var i = y * w + x0
                            var j = (y - dy) * w + (x0 - dx)
                            for _ in 0..<n {
                                let diff = ap[i] - bp[j]
                                d += diff < 0 ? -diff : diff
                                i += 1
                                j += 1
                            }
                        }
                        let s0 = rectSum(prefA, w, y0, y1, x0, x1)
                        let s1 = rectSum(prefB, w, y0 - dy, y1 - dy, x0 - dx, x1 - dx)
                        let sum = s0 + s1
                        let denom = sum + d
                        guard denom > 1e-6 else { continue }
                        let s = (sum - d) / denom
                        if s > best { best = s }
                    }
                }
                return Double(best)
            }
        }
    }

    // MARK: - 载入素材

    /// 找素材文件。会依次尝试几个位置，这样 `.app` 里和 `swift build` 出来的
    /// 裸可执行文件（`--selftest`）都能跑。
    static func assetURL(_ name: String) -> URL? {
        var roots: [URL] = []
        if let r = Bundle.main.resourceURL { roots.append(r) }
        let exeDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        roots.append(exeDir)
        var up = exeDir
        for _ in 0..<4 {          // .build/debug/xxx → 上溯到工程根
            up = up.deletingLastPathComponent()
            roots.append(up.appendingPathComponent("Resources"))
        }
        roots.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                        .appendingPathComponent("Resources"))
        for r in roots {
            let u = r.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: u.path) { return u }
        }
        return nil
    }

    private static func loadTemplates() -> [Template] {
        guard let atlasURL = assetURL("ui.atlas"),
              let pngURL = assetURL("ui.png"),
              let data = try? Data(contentsOf: atlasURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let frames = obj["frames"] as? [String: Any],
              let png = try? Data(contentsOf: pngURL),
              let sheet = decodeFirstImage(png) else {
            Log.warn("牌面素材 ui.png / ui.atlas 没找到，模板匹配不可用")
            return []
        }

        var out: [Template] = []
        for (file, value) in frames {
            let name = file.replacingOccurrences(of: ".png", with: "")
            if name == "back" { continue }                     // 牌背不参与识别
            guard let f = value as? [String: Any],
                  let fr = f["frame"] as? [String: Any],
                  let x = fr["x"] as? Int, let y = fr["y"] as? Int,
                  let w = fr["w"] as? Int, let h = fr["h"] as? Int,
                  let sub = sheet.cropping(to: CGRect(x: x, y: y, width: w, height: h)),
                  let p = planes(from: sub) else { continue }
            out.append(Template(name: name, ink: p.ink, prefix: p.prefix, redRatio: p.redRatio))
        }
        Log.info("牌面模板载入 \(out.count) 张（ui.png 共 \(frames.count) 个 sprite）")
        return out.sorted { $0.name < $1.name }
    }

    private static func decodeFirstImage(_ data: Data) -> CGImage? {
        guard !data.isEmpty, let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }
}
