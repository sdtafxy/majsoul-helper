import Foundation
import CoreGraphics
import ImageIO

/// 用雀魂自己的牌面素材做**牌面级**匹配 —— 专门用来认**平放在桌面上**的牌
/// （牌河、副露）。
///
/// ## 为什么不复用 `TileTemplateMatcher`
///
/// 手牌是**立着正对镜头**的，整张牌的模板匹配就有 14/14。牌河/副露是
/// **平放在桌面上**画的，纵向被透视压扁、还带一点错切，整张牌去比会全线错位
/// （实测只有 1~4/14，分数全塌到 0.3 上下）。
///
/// 换成牌面级之后还要解决三个坑，都是实测出来的：
///
/// 1. **只比"白纸牌面"**。sprite 里上下左右还带着牌边（顶部一条琥珀色、底部一条），
///    实拍的牌边是绿色的、位置也对不上 —— 这一圈边框的墨量比牌面图案还大，
///    不裁掉的话 soft IoU 会被边框主导。裁到 `[10..127, 2..76]`（75×118）。
///
/// 2. **必须按实测的压缩比缩放模板**。牌面的真实投影尺寸（虚拟坐标）约
///    `71 × 77`，而 sprite 的牌面是 `75 × 118` —— 横向几乎 1:1、纵向压到 **0.65~0.70**。
///    一开始按"整张牌 80:129"等比缩放，全部认错；用配准法（网格搜索缩放 + 平移
///    最大化 NCC）量出来才是 `1.00 × 0.70`（对自家牌河）。
///
/// 3. **度量用 NCC，不能用软 IoU**。实拍牌面只有 ~60px 宽、还过了 JPEG，
///    笔画会明显变粗（墨迹占比 36% vs 模板 22%）。软 IoU 会系统性偏向"墨多"的模板
///    —— 实测稳定把 `6s` 认成 `7s`、`4s` 认成 `2s`、`6p` 认成 `8p`。
///    NCC（零均值归一化互相关）对整体亮度/对比度缩放不敏感，这些错就没了。
///
/// ## 性能
///
/// 每张牌 ≈ `37 模板 × 搜索窗 9×9 × 3500 像素 ≈ 1000 万次乘加`，release 下
/// 单张 ~10ms；一副手牌带四家牌河也就 0.3 秒。模板缩放结果按目标尺寸缓存。
enum TileFaceMatcher {

    struct Match {
        var name: String
        var score: Double          // NCC，-1~1
        var runnerUp: String
        var runnerUpScore: Double
        /// 牌面里"红色墨迹"的占比（赤五 / 一索这类要靠颜色区分的牌）
        var redRatio: Double = 0
        var margin: Double { score - runnerUpScore }
    }

    /// sprite 里"白纸牌面"的裁剪框（`ui.png` 每个 frame 都是 80×129）
    private static let faceTop = 10
    private static let faceBottom = 1
    private static let faceLeft = 2
    private static let faceRight = 3

    /// 牌面模板尺寸
    static let faceW = 80 - faceLeft - faceRight      // 75
    static let faceH = 129 - faceTop - faceBottom     // 118

    /// 实拍牌面里墨迹的中位灰度为底、除以这个增益截到 0~1
    private static let inkGain = 70.0
    /// 低于这个 NCC 认为"这不是一张牌"（空槽/严重错位）
    static let minAcceptableScore = 0.42

    // MARK: - 内部表示

    private struct Plane {
        var name: String
        var ink: [Float]
        var w: Int
        var h: Int
        var sum: Float
        var sumSq: Float
        var redRatio: Double
    }

    private static let templates: [Plane] = loadTemplates()

    static var isAvailable: Bool { !templates.isEmpty }
    static var count: Int { templates.count }
    static var names: [String] { templates.map(\.name) }

    /// 某张模板的"牌面红色占比"。用来裁决赤五 / 普通五（两者图案完全一样）。
    static func redRatio(_ name: String) -> Double? {
        templates.first { $0.name == name }?.redRatio
    }

    private static let lock = NSLock()
    private static var scaledCache: [String: [Plane]] = [:]

    // MARK: - 对外接口

    /// 认一张牌。
    ///
    /// - Parameters:
    ///   - rgba: 已按截图尺度采样好的牌面块（**整块**，比牌面本身大一圈）
    ///   - w, h: 上面那块图的像素尺寸
    ///   - scaleX, scaleY: 模板要缩放到的尺寸比例（模板原始 75×118 乘以它）
    ///   - anchorX, anchorY: 模板默认摆放的左上角（块内像素坐标）。**必须给准** ——
    ///     查询块里除了牌面还有四周的桌面（桌面是暗的，墨迹会被算成 1），
    ///     模板摆偏了就会拿桌面去比牌面，分数直接塌掉。调用方按"牌面在块里的位置"
    ///     算出来即可。
    ///   - extraShift: 在默认位置之外再允许平移的像素数，用来吸收"摆得不整齐"的抖动
    static func identify(_ rgba: [UInt8], w: Int, h: Int,
                         scaleX: Double, scaleY: Double,
                         anchorX: Int, anchorY: Int,
                         extraShift: Int = 6) -> Match? {
        guard !templates.isEmpty, w > 8, h > 8 else { return nil }
        let tw = Int((Double(faceW) * scaleX).rounded())
        let th = Int((Double(faceH) * scaleY).rounded())
        guard tw > 6, th > 6, tw <= w, th <= h else { return nil }

        let query = ink(of: rgba, w: w, h: h)
        if ProcessInfo.processInfo.environment["MJ_MATCHDBG"] != nil {
            var s0: Float = 0, s1: Float = 0
            for v in query { s0 += v; s1 += v * v }
            let mn = query.min() ?? 0, mx = query.max() ?? 0
            print(String(format: "  [match] q %dx%d inkΣ=%.1f Σ²=%.1f min=%.3f max=%.3f 模板%dx%d",
                         w, h, s0, s1, mn, mx, tw, th))
        }
        let pref = prefix(query, w: w, h: h)          // Σq
        let prefSq = prefixSq(query, w: w, h: h)      // Σq²
        let tpls = scaledTemplates(tw: tw, th: th)

        var best = ("", -2.0), second = ("", -2.0)
        var firstScore: [String: Double] = [:]
        for t in tpls {
            let s = bestNCC(query: query, pref: pref, prefSq: prefSq, w: w, h: h,
                            t: t, anchorX: anchorX, anchorY: anchorY, extraShift: extraShift)
            firstScore[t.name] = s
            if s > best.1 {
                second = best
                best = (t.name, s)
            } else if s > second.1 {
                second = (t.name, s)
            }
        }
        guard !best.0.isEmpty else { return nil }
        return Match(name: best.0, score: best.1, runnerUp: second.0, runnerUpScore: second.1,
                     redRatio: redRatio(of: rgba, w: w, h: h))
    }

    /// 牌面里"红墨"的占比（赤五 / 普通五的裁决依据）。
    private static func redRatio(of rgba: [UInt8], w: Int, h: Int) -> Double {
        var gray = [Float](repeating: 0, count: w * h)
        var red = [Float](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            let p = i * 4
            let r = Float(rgba[p]), g = Float(rgba[p + 1]), b = Float(rgba[p + 2])
            gray[i] = 0.299 * r + 0.587 * g + 0.114 * b
            red[i] = max(0, min(1, (r - max(g, b)) / 60.0))
        }
        let inkPlane = ink(fromGray: gray, red: red, w: w, h: h)
        var sum: Float = 0, redSum: Float = 0
        for i in 0..<inkPlane.count {
            sum += inkPlane[i]
            redSum += inkPlane[i] * red[i]
        }
        return sum < 1 ? 0 : Double(redSum / sum)
    }

    // MARK: - NCC

    /// 在 `anchor` 附近 ±extraShift 里取最大的 NCC。
    ///
    /// `Σq`、`Σq²` 用二维前缀和 O(1) 取；只有 `Σqt` 需要遍历窗口。
    private static func bestNCC(query: [Float], pref: [Float], prefSq: [Float],
                                w: Int, h: Int, t: Plane,
                                anchorX: Int, anchorY: Int, extraShift: Int) -> Double {
        let tw = t.w, th = t.h
        let maxDy = h - th, maxDx = w - tw
        guard maxDy >= 0, maxDx >= 0 else { return -2 }
        // 默认位置由调用方给（对齐到牌面），只在它附近滑一点点
        let cx = min(max(0, anchorX), maxDx)
        let cy = min(max(0, anchorY), maxDy)
        let y0 = max(0, cy - extraShift), y1 = min(maxDy, cy + extraShift)
        let x0 = max(0, cx - extraShift), x1 = min(maxDx, cx + extraShift)

        let n = Float(tw * th)
        var best = -2.0
        for dy in y0...y1 {
            for dx in x0...x1 {
                var dot: Float = 0
                for y in 0..<th {
                    let qb = (dy + y) * w + dx
                    let tb = y * tw
                    for x in 0..<tw {
                        dot += query[qb + x] * t.ink[tb + x]
                    }
                }
                let sq = rectSum(pref, w, dy, dy + th, dx, dx + tw)
                let sqq = rectSum(prefSq, w, dy, dy + th, dx, dx + tw)
                let vq = sqq - sq * sq / n
                let vt = t.sumSq - t.sum * t.sum / n
                guard vq > 1e-6, vt > 1e-6 else { continue }
                let cov = dot - sq * t.sum / n
                let v = Double(cov / (vq * vt).squareRoot())
                if v > best { best = v }
            }
        }
        return best
    }

    // MARK: - 墨迹平面

    private static func ink(of rgba: [UInt8], w: Int, h: Int) -> [Float] {
        var gray = [Float](repeating: 0, count: w * h)
        var red = [Float](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            let p = i * 4
            let r = Float(rgba[p]), g = Float(rgba[p + 1]), b = Float(rgba[p + 2])
            gray[i] = 0.299 * r + 0.587 * g + 0.114 * b
            red[i] = max(0, min(1, (r - max(g, b)) / 60.0))
        }
        return ink(fromGray: gray, red: red, w: w, h: h)
    }

    private static func ink(fromGray gray: [Float], red: [Float], w: Int, h: Int) -> [Float] {
        var sorted = gray
        sorted.sort()
        let median = sorted[sorted.count / 2]
        var out = [Float](repeating: 0, count: gray.count)
        for i in 0..<gray.count {
            let d = (median - gray[i]) / Float(inkGain)
            out[i] = d <= 0 ? 0 : (d >= 1 ? 1 : d)
        }
        return out
    }

    private static func prefix(_ v: [Float], w: Int, h: Int) -> [Float] {
        var p = [Float](repeating: 0, count: (w + 1) * (h + 1))
        for y in 0..<h {
            var row: Float = 0
            for x in 0..<w {
                row += v[y * w + x]
                p[(y + 1) * (w + 1) + (x + 1)] = p[y * (w + 1) + (x + 1)] + row
            }
        }
        return p
    }

    private static func prefixSq(_ v: [Float], w: Int, h: Int) -> [Float] {
        var p = [Float](repeating: 0, count: (w + 1) * (h + 1))
        for y in 0..<h {
            var row: Float = 0
            for x in 0..<w {
                row += v[y * w + x] * v[y * w + x]
                p[(y + 1) * (w + 1) + (x + 1)] = p[y * (w + 1) + (x + 1)] + row
            }
        }
        return p
    }

    @inline(__always)
    private static func rectSum(_ p: [Float], _ w: Int, _ y0: Int, _ y1: Int, _ x0: Int, _ x1: Int) -> Float {
        let st = w + 1
        return p[y1 * st + x1] - p[y0 * st + x1] - p[y1 * st + x0] + p[y0 * st + x0]
    }

    // MARK: - 模板

    /// 把模板缩放（盒式降采样）到目标尺寸，按尺寸缓存。
    ///
    /// ⚠️ **缩放之后必须再模糊一下**。实拍牌面是"游戏画在 2560 的画布上、浏览器又缩到
    /// 1638、再过一遍 JPEG"——笔画边缘被糊开了。模板是矢量渲染的、边缘极硬，
    /// 不糊的话两边对不上，NCC 会掉一大截（实测这个改动直接决定成不成）。
    /// 模糊核取 `[1,2,1]/4` 走两遍，约等于 sigma 0.8。
    private static func scaledTemplates(tw: Int, th: Int) -> [Plane] {
        let key = "\(tw)x\(th)"
        lock.lock()
        if let c = scaledCache[key] { lock.unlock(); return c }
        lock.unlock()

        var out: [Plane] = []
        out.reserveCapacity(templates.count)
        for t in templates {
            var ink = [Float](repeating: 0, count: tw * th)
            let sx = Double(t.w) / Double(tw), sy = Double(t.h) / Double(th)
            for y in 0..<th {
                let sy0 = Int(Double(y) * sy), sy1 = max(sy0 + 1, Int(Double(y + 1) * sy))
                for x in 0..<tw {
                    let sx0 = Int(Double(x) * sx), sx1 = max(sx0 + 1, Int(Double(x + 1) * sx))
                    var acc: Float = 0
                    var cnt = 0
                    for yy in sy0..<min(sy1, t.h) {
                        let base = yy * t.w
                        for xx in sx0..<min(sx1, t.w) { acc += t.ink[base + xx]; cnt += 1 }
                    }
                    ink[y * tw + x] = cnt > 0 ? acc / Float(cnt) : 0
                }
            }
            for _ in 0..<2 { ink = blur121(ink, w: tw, h: th) }
            var sum: Float = 0, sumSq: Float = 0
            for v in ink { sum += v; sumSq += v * v }
            out.append(Plane(name: t.name, ink: ink, w: tw, h: th,
                             sum: sum, sumSq: sumSq, redRatio: t.redRatio))
        }
        lock.lock()
        scaledCache[key] = out
        lock.unlock()
        return out
    }

    /// 可分离的 `[1,2,1]/4` 模糊（边缘用夹取）。
    private static func blur121(_ v: [Float], w: Int, h: Int) -> [Float] {
        var tmp = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            let base = y * w
            for x in 0..<w {
                let l = v[base + max(0, x - 1)], c = v[base + x], r = v[base + min(w - 1, x + 1)]
                tmp[base + x] = (l + 2 * c + r) * 0.25
            }
        }
        var out = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            let up = max(0, y - 1) * w, dn = min(h - 1, y + 1) * w, base = y * w
            for x in 0..<w {
                out[base + x] = (tmp[up + x] + 2 * tmp[base + x] + tmp[dn + x]) * 0.25
            }
        }
        return out
    }

    private static func loadTemplates() -> [Plane] {
        guard let atlasURL = TileTemplateMatcher.assetURL("ui.atlas"),
              let pngURL = TileTemplateMatcher.assetURL("ui.png"),
              let atlasData = try? Data(contentsOf: atlasURL),
              let obj = try? JSONSerialization.jsonObject(with: atlasData) as? [String: Any],
              let frames = obj["frames"] as? [String: Any],
              let pngData = try? Data(contentsOf: pngURL),
              let sheet = decodeFirstImage(pngData) else {
            Log.warn("牌面素材缺失，牌面级匹配不可用（牌河/副露只能退回交给模型）")
            return []
        }
        guard let buf = rgbaBuffer(sheet) else { return [] }

        var out: [Plane] = []
        for (file, value) in frames {
            let name = file.replacingOccurrences(of: ".png", with: "")
            if name == "back" { continue }
            guard let f = value as? [String: Any],
                  let fr = f["frame"] as? [String: Any],
                  let fx = fr["x"] as? Int, let fy = fr["y"] as? Int,
                  let fw = fr["w"] as? Int, let fh = fr["h"] as? Int else { continue }
            let x0 = fx + faceLeft, y0 = fy + faceTop
            let w = fw - faceLeft - faceRight, h = fh - faceTop - faceBottom
            guard w > 4, h > 4, x0 + w <= sheet.width, y0 + h <= sheet.height else { continue }

            var gray = [Float](repeating: 0, count: w * h)
            var red = [Float](repeating: 0, count: w * h)
            for y in 0..<h {
                for x in 0..<w {
                    let p = ((y0 + y) * sheet.width + (x0 + x)) * 4
                    let r = Float(buf[p]), g = Float(buf[p + 1]), b = Float(buf[p + 2])
                    gray[y * w + x] = 0.299 * r + 0.587 * g + 0.114 * b
                    red[y * w + x] = max(0, min(1, (r - max(g, b)) / 60.0))
                }
            }
            // 素材右上角印着编号（1~9 / E S W N Wh G R），真机上没有 —— 清零，
            // 免得变成"模板有、实拍没有"的固定差异。
            let lx = Int(Double(w) * 0.62), ly = Int(Double(h) * 0.24)
            for y in 0..<ly { for x in lx..<w { gray[y * w + x] = 255; red[y * w + x] = 0 } }

            let inkPlane = ink(fromGray: gray, red: red, w: w, h: h)
            var sum: Float = 0, sumSq: Float = 0, redSum: Float = 0
            for i in 0..<inkPlane.count {
                sum += inkPlane[i]
                sumSq += inkPlane[i] * inkPlane[i]
                redSum += inkPlane[i] * red[i]
            }
            out.append(Plane(name: name, ink: inkPlane, w: w, h: h, sum: sum, sumSq: sumSq,
                             redRatio: sum < 1 ? 0 : Double(redSum / sum)))
        }
        Log.info("牌面模板载入 \(out.count) 张（牌面 \(faceW)×\(faceH)）")
        return out.sorted { $0.name < $1.name }
    }

    // MARK: - 小工具

    private static func rgbaBuffer(_ cg: CGImage) -> [UInt8]? {
        let w = cg.width, h = cg.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &buf, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return buf
    }

    private static func decodeFirstImage(_ data: Data) -> CGImage? {
        guard !data.isEmpty, let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }
}
