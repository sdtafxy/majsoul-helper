import Foundation
import CoreGraphics
import ImageIO

/// 纯像素的牌面计数。**不调模型**，用来给模型的结果做交叉校验 / 纠错。
///
/// 目前只做**索子的竹节根数**，因为它在真实截图上被验证过。
///
/// 实测数据（雀魂真实截图，两张图共 27 张手牌，2× 导出图）：
///
/// | 牌 | 墨块的高宽比 ar | 判定 |
/// |---|---|---|
/// | 万子（伍萬/六萬/八萬/九萬/…) | 0.24 ~ 0.74（汉字笔画是方块状） | 0 个细长块 |
/// | 筒子（1/2/3/4/6/6/8 筒） | 0.33 ~ 1.67（圆圈也是团块） | 0 个细长块 |
/// | 索子 5 索（「理和鳴切」主题，全红） | 2.00 ~ 2.35 | **5** 个（另有 1 个 ar 0.96 的装饰点） |
/// | 索子 6 索（同上） | 2.00 ~ 2.30 | **6** 个 |
/// | 索子 7 索（默认主题，矮胖画法） | 1.29 ~ 1.72 | **7** 个 |
///
/// 关键：**竹节的高宽比在同一条牌里永远大于圆圈和汉字笔画**，所以
/// 「ar ≥ 1.2 的墨块个数」就是竹节根数。5 索那个装饰小圆点 ar 只有 0.96，
/// 会被自动排除，不会多数成 6 根。
///
/// 为什么筒子不能这样数：圆圈彼此紧贴会连成一整块 —— 实测 6 筒的 6 个圆只连成
/// 2 块、8 筒的 8 个圆连成 1 块，块数不等于圆圈数。索子的竹节之间是分开的，才可以这么数。
///
/// 实测覆盖：两张真实截图 27 张牌（含 5索/6索/7索）**全部判对，且对万子/筒子零误报**。
enum LocalTileReader {

    struct Blob {
        var area: Int
        var height: Int
        var width: Int
        var aspect: Double { Double(height) / Double(max(width, 1)) }
    }

    /// 估算一张索子牌的番数（竹节根数）。判断不了时返回 `nil`（宁可不给结论）。
    ///
    /// - Parameter data: 单张牌的 JPEG（和送给模型的是同一张）
    static func souzuRank(ofTileJPEG data: Data) -> Int? {
        guard let (w, h, rgb) = rgbaPixels(data), w > 40, h > 40 else { return nil }

        // 裁掉牌面上缘的绿色倒角、圆角与阴影 —— 它们的形状不规则，会污染墨块统计。
        let x0 = Int(Double(w) * 0.075), x1 = w - x0
        let y0 = Int(Double(h) * 0.19), y1 = h - Int(Double(h) * 0.04)
        guard x1 - x0 > 20, y1 - y0 > 20 else { return nil }
        let cropW = x1 - x0, cropH = y1 - y0
        let cropArea = Double(cropW * cropH)

        // 墨 = 不是牌面底色（底色接近纯白，R/G/B 都 > 185）
        var ink = [Bool](repeating: false, count: cropW * cropH)
        for y in 0..<cropH {
            for x in 0..<cropW {
                let p = ((y + y0) * w + (x + x0)) * 4
                let r = Int(rgb[p]), g = Int(rgb[p + 1]), b = Int(rgb[p + 2])
                ink[y * cropW + x] = !(r > 185 && g > 185 && b > 180)
            }
        }

        let blobs = labelBlobs(ink, width: cropW, height: cropH)
        // 面积阈值按裁剪面积缩放，这样换导出倍率也不用改常数
        let minTallArea = max(120, Int(cropArea * 0.025))
        let tall = blobs.filter { $0.aspect >= 1.2 && $0.area >= minTallArea }

        // 竹节之间互不相连 → 个数应当在 2~9；1 索是一只鸟，不走这条路
        guard (2...9).contains(tall.count) else { return nil }
        // 同一张牌的竹节大小应当接近；差太多说明有块把两根粘一起了，不可信
        let areas = tall.map(\.area)
        guard let lo = areas.min(), let hi = areas.max(), lo > 0,
              Double(hi) / Double(lo) <= 1.8 else { return nil }

        return tall.count
    }

    // MARK: - 像素与连通块

    private static func rgbaPixels(_ data: Data) -> (Int, Int, [UInt8])? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let w = cg.width, h = cg.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return (w, h, buf)
    }

    /// 四连通标记，返回面积 > 阈值的块。
    private static func labelBlobs(_ ink: [Bool], width: Int, height: Int) -> [Blob] {
        var seen = [Bool](repeating: false, count: ink.count)
        var out: [Blob] = []
        var stack: [Int] = []
        for start in 0..<ink.count where ink[start] && !seen[start] {
            seen[start] = true
            stack.removeAll(keepingCapacity: true)
            stack.append(start)
            var area = 0
            var minY = height, maxY = 0, minX = width, maxX = 0
            while let idx = stack.popLast() {
                let y = idx / width, x = idx % width
                area += 1
                if y < minY { minY = y }
                if y > maxY { maxY = y }
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if x > 0, ink[idx - 1], !seen[idx - 1] { seen[idx - 1] = true; stack.append(idx - 1) }
                if x < width - 1, ink[idx + 1], !seen[idx + 1] { seen[idx + 1] = true; stack.append(idx + 1) }
                if y > 0, ink[idx - width], !seen[idx - width] { seen[idx - width] = true; stack.append(idx - width) }
                if y < height - 1, ink[idx + width], !seen[idx + width] { seen[idx + width] = true; stack.append(idx + width) }
            }
            if area > 40 {
                out.append(Blob(area: area, height: maxY - minY + 1, width: maxX - minX + 1))
            }
        }
        return out
    }

    // MARK: - 与模型结果合并

    /// 用本地竹节计数校正模型给出的索子。
    ///
    /// 只在**模型也认为是索子**（`Ns` 或 `0s`）但**根数不符**时才改 ——
    /// 这样万一像素法的适用条件在别的主题上不成立，也不会把万子/筒子改坏。
    /// `0s`（赤五索）保持不动：颜色由模型看，根数一致就不动它。
    static func reconcileWithModel(names: [String], tiles: [Data]) -> (names: [String], fixes: [String]) {
        var out = names
        var fixes: [String] = []
        for i in out.indices where i < tiles.count {
            guard let localRank = souzuRank(ofTileJPEG: tiles[i]) else { continue }
            let raw = out[i].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard raw.hasSuffix("s"), let modelRank = Int(raw.dropLast()) else { continue }
            if modelRank == 0 && localRank == 5 { continue }   // 赤 5 索：颜色归模型，根数没矛盾
            guard modelRank != localRank else { continue }
            out[i] = "\(localRank)s"
            fixes.append("#\(i + 1) \(raw)→\(localRank)s（竹节 \(localRank) 根）")
        }
        return (out, fixes)
    }
}
