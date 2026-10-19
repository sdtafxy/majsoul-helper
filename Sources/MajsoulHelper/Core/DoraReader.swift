import Foundation
import CoreGraphics

/// 读画面**左上角**那排**宝牌指示牌**。
///
/// ## 面板结构（实测这张真实截图）
///
/// ```
/// ┌──────────────────────────────────────────────┐
/// │ [八索] [  ][  ][  ][  ]   ← 5 个槽位          │
/// │  ↑真牌    ↑后面几格是空的绿槽                 │
/// │  屯 ×0                屯 ×0                   │
/// └──────────────────────────────────────────────┘
/// ```
///
/// 槽宽 55px、间距 59.5px、高 77px（整图 2048 宽时）；牌**正立**，不需要旋转 ——
/// 实测同一张格子分别按 0°/90°/180°/270° 去匹配：只有 0° 能对上
/// （`8s` 0.52，其它朝向最高才 0.37）。
///
/// ## 为什么不用硬编码坐标
///
/// **空槽的绿色本身就能定位整个格子阵列**：
///
/// - 每格宽 = 绿槽的宽；高 ≈ 1.4 × 宽；间距 ≈ 1.08 × 宽（都由绿槽自身量出来）
/// - 宝牌张数 = 5 − 绿槽个数，占最左边那几格
///
/// 这样窗口大小、缩放怎么变都不用改常数。实测本图：1 张宝牌 + 4 个绿槽 → 认出 `8s`。
enum DoraReader {

    struct Reading {
        var indicators: [String] = []
        var note: String?
        var debug: [String] = []
    }

    /// 槽位总数固定是 5（四麻最多 5 张宝牌指示牌）
    private static let slotCount = 5

    /// - Parameter tileWidth: 手牌一张的宽度（像素），用来给"绿槽该多宽"设范围。
    ///   传 0 时按画面宽度的 4.9% 估（实测 2048 宽的截图里手牌宽 101px）。
    static func read(from cg: CGImage, tileWidth: Double = 0) -> Reading {
        var out = Reading()
        let w = cg.width, h = cg.height
        guard let px = rgbPixels(cg) else {
            out.note = "宝牌面板：取不到像素"
            return out
        }
        let expectTile = tileWidth > 4 ? tileWidth : Double(w) * 0.049

        // ---------- 1. 找空槽的绿色 ----------
        //
        // 空槽实测 RGB ≈ (114,195,116)。搜索范围限制在左上角，
        // 免得把牌墙的绿背也扫进来（那些在画面中部/右侧）。
        let x0 = 0, x1 = Int(Double(w) * 0.22)
        let y0 = Int(Double(h) * 0.15), y1 = Int(Double(h) * 0.35)
        guard x1 > x0, y1 > y0 else { out.note = "宝牌面板：搜索区非法"; return out }

        var mask = [Bool](repeating: false, count: (x1 - x0) * (y1 - y0))
        let mw = x1 - x0
        for y in y0..<y1 {
            for x in x0..<x1 {
                let p = (y * w + x) * 4
                let r = Int(px[p]), g = Int(px[p + 1]), b = Int(px[p + 2])
                // 空槽绿：绿明显高于红蓝，且整体够亮（暗绿背景不算）
                mask[(y - y0) * mw + (x - x0)] = (g > 150 && g - r > 35 && g - b > 30 && r > 60)
            }
        }
        let blobs = components(mask, width: mw, height: mh(y1 - y0), minArea: Int(expectTile * expectTile * 0.15))

        // 只要"竖长条"的块，且宽度在手牌宽的 0.3~0.8 之间（牌墙的绿背会宽得多，被滤掉）
        let slots = blobs.compactMap { b -> (CGRect, Int)? in
            let bw = Double(b.w), bh = Double(b.h)
            let ar = bh / max(bw, 1)
            guard bw >= expectTile * 0.30, bw <= expectTile * 0.85,
                  ar >= 1.0, ar <= 1.9 else { return nil }
            return (CGRect(x: Double(b.minX + x0), y: Double(b.minY + y0), width: bw, height: bh), b.area)
        }.map(\.0)
        guard !slots.isEmpty else {
            out.note = "宝牌面板：没找到空槽（可能 5 张宝牌全亮，或窗口布局不同）"
            return out
        }

        let sorted = slots.sorted { $0.minX < $1.minX }
        let slotW = median(sorted.map { Double($0.width) })
        let slotH = median(sorted.map { Double($0.height) })
        // 间距：有 2 个以上绿槽就实测；只有 1 个就按实测比例 1.08
        var pitch = slotW * 1.08
        if sorted.count >= 2 {
            var gaps: [Double] = []
            for i in 1..<sorted.count { gaps.append(Double(sorted[i].minX - sorted[i - 1].minX)) }
            pitch = median(gaps)
        }
        let leftmostGreen = Double(sorted[0].minX)
        let topY = median(sorted.map { Double($0.minY) })
        let nDora = slotCount - sorted.count
        guard nDora >= 1 else {
            out.note = "宝牌面板：绿槽占满，读不到宝牌"
            return out
        }

        out.debug.append(String(format: "宝牌面板：槽宽 %.0f 高 %.0f 间距 %.0f，绿槽 %d 个 → 宝牌 %d 张",
                                slotW, slotH, pitch, sorted.count, nDora))

        // ---------- 2. 最左边那 nDora 格就是宝牌指示牌 ----------
        for k in 1...nDora {
            let left = leftmostGreen - Double(nDora + 1 - k) * pitch
            let rect = CGRect(x: left, y: topY, width: slotW, height: slotH)
            guard let sub = cg.cropping(to: rect) else { continue }
            guard let m = TileTemplateMatcher.identify(sub) else {
                out.debug.append("  槽 \(k) @x\(Int(left))：认不出")
                continue
            }
            out.debug.append(String(format: "  槽 %d @x%3d → %@ (%.2f，次选 %@ %.2f)",
                                    k, Int(left), m.name, m.score, m.runnerUp, m.runnerUpScore))
            if m.score >= TileTemplateMatcher.minAcceptableScore {
                out.indicators.append(m.name)
            } else {
                out.note = "宝牌第 \(k) 张认不准（最高才 \(String(format: "%.2f", m.score))），已忽略"
            }
        }
        return out
    }

    // MARK: - 像素 / 连通块

    private static func mh(_ v: Int) -> Int { v }

    private struct Blob { var minX: Int; var minY: Int; var w: Int; var h: Int; var area: Int }

    private static func components(_ mask: [Bool], width: Int, height: Int, minArea: Int) -> [Blob] {
        var seen = [Bool](repeating: false, count: mask.count)
        var out: [Blob] = []
        var stack: [Int] = []
        for start in 0..<mask.count where mask[start] && !seen[start] {
            seen[start] = true
            stack.removeAll(keepingCapacity: true)
            stack.append(start)
            var area = 0, minX = width, maxX = 0, minY = height, maxY = 0
            while let i = stack.popLast() {
                let y = i / width, x = i % width
                area += 1
                if x < minX { minX = x }; if x > maxX { maxX = x }
                if y < minY { minY = y }; if y > maxY { maxY = y }
                if x > 0, mask[i - 1], !seen[i - 1] { seen[i - 1] = true; stack.append(i - 1) }
                if x < width - 1, mask[i + 1], !seen[i + 1] { seen[i + 1] = true; stack.append(i + 1) }
                if y > 0, mask[i - width], !seen[i - width] { seen[i - width] = true; stack.append(i - width) }
                if y < height - 1, mask[i + width], !seen[i + width] { seen[i + width] = true; stack.append(i + width) }
            }
            if area >= minArea {
                out.append(Blob(minX: minX, minY: minY, w: maxX - minX + 1, h: maxY - minY + 1, area: area))
            }
        }
        return out
    }

    private static func rgbPixels(_ cg: CGImage) -> [UInt8]? {
        let w = cg.width, h = cg.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return buf
    }

    private static func median(_ v: [Double]) -> Double {
        guard !v.isEmpty else { return 0 }
        let s = v.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }
}
