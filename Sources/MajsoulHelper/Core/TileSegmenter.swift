import Foundation
import CoreGraphics
import ImageIO
import AppKit

/// 把手牌区切成「一张牌一个图」，并顺带定位副露区。
///
/// ## 为什么必须切
/// 模型对图片有固定的降采样预算。整屏时一张牌只剩很少的像素；单独一张牌时，
/// 同一份预算全花在这一张上 —— 实测整屏读手牌只能对 1~4 张，逐张才能到 14/14。
/// （不过现在主路径已经换成 `TileTemplateMatcher` 的本地模板匹配，比模型更准更快；
/// 这里切出来的单张图仍然要用来做模板匹配。）
///
/// ## ⚠️ 手牌张数**不是**固定 14 张
///
/// 这是最容易踩的坑，而且它是**确定性**会发生的：
///
/// | 情形 | 暗牌 | 摸牌 | 一行里的牌 |
/// |---|---|---|---|
/// | 刚摸牌（13 张 + ツモ） | 13 | 1 | 14 |
/// | 刚打完（没有ツモ） | 13 | 0 | 13 |
/// | 碰/吃 1 组后刚摸牌 | 10 | 1 | 11 |
/// | 碰/吃 1 组后马上出牌（**没有进张**） | 10 | 0 | 10 |
/// | 2 组副露 + 刚摸牌 | 7 | 1 | 8 |
/// | 2 组副露 + 没有进张 | 7 | 0 | 7 |
///
/// 旧的实现硬按「14 张」去等分，于是：
/// - 有副露时右侧的**副露牌被一起切进来**，张数变成 8 张、位置全错；
/// - 碰完轮到自己出牌（**没有进张**）时干脆推不出合理的张数，直接判失败。
///
/// 现在的做法是**先分块，再数张**：
///
/// 1. 在手牌行里按列算「牌面度」，切出若干**牌块**（同一块内牌与牌只是挨着，
///    缝隙很窄；块与块之间是明显的空隙）。
/// 2. 最右边、宽度达到 2 张以上的块 = **副露区**（摆在桌面上，另有透视，不作识别）。
/// 3. 副露区左边，若有一块**只有一张宽、且与前一块有明显空隙** → 那就是**摸牌**；
///    没有这样一块，就说明这一轮**没有进张**（刚碰/吃之后直接出牌）。
/// 4. 剩下的就是暗牌，张数 = `块宽 ÷ 牌宽`。
///
/// ## 牌宽从哪来
///
/// 不再靠自相关"猜"：canvas 是按宽度受限缩放的（见 `CanvasMapper`），
/// 所以牌宽 = 图宽 × 126/2560 ≈ 图宽 × 0.0492（实测 2048 宽截图 → 100.8px，
/// 而牌缝实测 100px、逐张切分实测 101~101.25px）。自相关只在它附近做细调。
enum TileSegmenter {

    struct Result {
        /// 暗牌（不含摸的那张）
        var concealedRects: [CGRect]
        /// 刚摸进来的那张 —— **为空表示这一轮没有进张**（碰/吃之后直接出牌）
        var drawnRect: CGRect?
        /// 副露区的整体矩形（摆在桌面上、带透视压缩，目前只用来告知"有副露"）
        var meldBlock: CGRect?
        /// 副露单张牌的估算宽（副露的间距比手牌窄）
        var meldTileWidth: Double
        /// 副露单张牌在屏幕上的实际高度。**明显小于按 80:129 应有的高度** ——
        /// 因为副露是平放在桌面上画的，纵向被透视压扁了。
        /// 送模型之前要按这个把它拉回来（见 `meldCrop`）。
        var meldTileHeight: Double = 0
        /// 手牌行边界（像素）
        var band: CGRect
        /// 牌宽（像素）
        var pitch: Double
        /// 自相关峰值，越高越可信
        var correlation: Double
        /// 认出来的画布（供上层把像素坐标换算成虚拟坐标）
        var canvas: CanvasFrame?

        /// 暗牌 + 摸牌（模板匹配要吃的就是这些）
        var tileRects: [CGRect] {
            var r = concealedRects
            if let d = drawnRect { r.append(d) }
            return r
        }
        var count: Int { concealedRects.count + (drawnRect == nil ? 0 : 1) }
        /// 副露占掉的牌数（每组 3 张，杠另有 4 张的情形，这里按 3 计）
        var meldTiles: Int {
            guard let m = meldBlock, meldTileWidth > 1 else { return 0 }
            return max(0, Int((m.width / meldTileWidth).rounded()))
        }
        var meldGroups: Int { meldTiles / 3 }
    }

    enum Failure: LocalizedError {
        case noBand
        case spanTooSmall
        case weakPeriodicity(Double)
        case implausibleCount(Int)

        var errorDescription: String? {
            switch self {
            case .noBand: return "没找到手牌行"
            case .spanTooSmall: return "手牌行太窄"
            case .weakPeriodicity(let c): return String(format: "牌宽周期性太弱（%.2f）", c)
            case .implausibleCount(let n): return "推出来的张数不合理（\(n)）"
            }
        }
    }

    // MARK: - 主流程

    static func analyze(gray: [UInt8], saturated: [Bool], w: Int, h: Int,
                     rgba: [UInt8]? = nil) -> Swift.Result<Result, Failure> {
        let canvas = CanvasMapper.locate(gray: gray, w: w, h: h, rgba: rgba)

        // ---------- 1. 找手牌行 ----------
        // 有画布就只在画布底部 20% 里找；没有就退回"画面下半部分"。
        let searchTop: Int
        if let c = canvas {
            searchTop = max(0, Int(c.y + c.height * 0.80))
        } else {
            searchTop = Int(Double(h) * 0.55)
        }
        var lightFrac = [Double](repeating: 0, count: h)
        for y in searchTop..<h {
            var n = 0
            let base = y * w
            for x in 0..<w where gray[base + x] > 150 && !saturated[base + x] { n += 1 }
            lightFrac[y] = Double(n) / Double(w)
        }
        var bestLen = 0, bestStart = 0, curStart = -1
        for y in searchTop..<h {
            if lightFrac[y] > 0.12 {
                if curStart < 0 { curStart = y }
            } else if curStart >= 0 {
                if y - curStart > bestLen { bestLen = y - curStart; bestStart = curStart }
                curStart = -1
            }
        }
        if curStart >= 0, h - curStart > bestLen { bestLen = h - curStart; bestStart = curStart }
        guard bestLen > 20 else { return .failure(.noBand) }

        let inset = max(2, Int(Double(bestLen) * 0.06))
        let y0 = bestStart + inset, y1 = bestStart + bestLen - inset
        guard y1 - y0 > 15 else { return .failure(.noBand) }
        let rows = y1 - y0

        // ---------- 2. 牌宽初值 ----------
        // 画布按宽度受限 → 牌宽只跟图宽有关。这也顺便让"画布没认出来"时仍能工作。
        let pitchEst = Double(w) * CanvasMapper.handPitchVirtual / CanvasFrame.virtualWidth

        // ---------- 3. 按列算「牌面度」，切牌块 ----------
        var colFrac = [Double](repeating: 0, count: w)
        for x in 0..<w {
            var n = 0
            for y in y0..<y1 where gray[y * w + x] > 150 && !saturated[y * w + x] { n += 1 }
            colFrac[x] = Double(n) / Double(rows)
        }
        let blocks = merge(runs: runs(of: colFrac, threshold: 0.35, minLength: 8),
                           tolerance: pitchEst * 0.20)
        guard !blocks.isEmpty else { return .failure(.spanTooSmall) }

        // ---------- 4. 分出「暗牌 / 摸牌 / 副露区」 ----------
        //
        // 手牌区永远是**左对齐**的（实测 5 张截图都从虚拟 x≈300 开始；
        // 暗牌只剩 7 张时也不会居中），所以最左边那一块就是暗牌。
        // 紧跟着的小块是摸牌；**剩下的一律是副露区**。
        //
        // 为什么不能"从右边找最宽的一块当副露"：副露的**组与组之间有空隙**
        // （实测那 6 张牌被切成了 1428..1526 / 1562..1633 / 1673..1933 三段），
        // 只挑最宽的一段会把另外两段漏在手牌里，暗牌张数就变成 14 张。
        guard let handBlock = blocks.first else { return .failure(.spanTooSmall) }
        let concealedSpan = CGRect(x: handBlock.minX, y: Double(y0),
                                   width: handBlock.width, height: Double(rows))
        var rest = Array(blocks.dropFirst())

        // 摸牌：只有一张宽，且与暗牌之间的空隙**很小**。
        //
        // 「空隙 ≤ 0.8 张」这个上界是必须的：**没有进张**时（碰/吃之后直接出牌），
        // 紧跟其后的会是副露区的第一小块，它也可能"只有一张宽"，
        // 但中间隔着 4~5 张牌的空隙 —— 用这个上界正好区分开。
        var drawn: CGRect?
        if let cand = rest.first {
            let gap = Double(cand.minX - handBlock.maxX)
            if Double(cand.width) <= pitchEst * 1.35,
               gap >= pitchEst * 0.25, gap <= pitchEst * 0.8 {
                drawn = cand
                rest.removeFirst()
            }
        }

        // 副露区 = 右边剩下的所有块（跨度取第一块的左边界到最后一块的右边界）
        var meldBlock: CGRect?
        if let f = rest.first, let l = rest.last {
            meldBlock = CGRect(x: f.minX, y: Double(y0),
                               width: l.maxX - f.minX, height: Double(rows))
        }

        // 副露牌在纵向上被透视压扁了多少：量出它在手牌行里实际占的高度
        var meldTileHeight = 0.0
        if let m = meldBlock {
            let xa = max(0, Int(m.minX)), xb = min(w, Int(m.maxX))
            if xb > xa {
                var rowFrac = [Bool](repeating: false, count: y1 - y0)
                for (ri, y) in (y0..<y1).enumerated() {
                    var n = 0
                    let base = y * w
                    for x in xa..<xb where gray[base + x] > 150 && !saturated[base + x] { n += 1 }
                    rowFrac[ri] = Double(n) / Double(xb - xa) > 0.25
                }
                var best = 0, cur = -1
                for (i, on) in rowFrac.enumerated() {
                    if on { if cur < 0 { cur = i } }
                    else if cur >= 0 { best = max(best, i - cur); cur = -1 }
                }
                if cur >= 0 { best = max(best, rowFrac.count - cur) }
                meldTileHeight = Double(best)
            }
        }

        // ---------- 5. 自相关在初值附近细调牌宽 ----------
        let (pitch, corr) = refinePitch(gray: gray, w: w, y0: y0, y1: y1,
                                        x0: Int(concealedSpan.minX),
                                        x1: Int(concealedSpan.maxX),
                                        estimate: pitchEst)

        // ---------- 6. 摆位置 ----------
        let concealedCount = max(1, Int((Double(concealedSpan.width) / pitch).rounded()))
        guard concealedCount <= 14 else { return .failure(.implausibleCount(concealedCount)) }

        // 切**整张牌**（含上下那条边）。比例 80:129 来自 ui.atlas；
        // 只切"亮牌面"会上下各少 14px，模板匹配的分数会整体塌到 0.3。
        let tileH = pitch * Double(TileTemplateMatcher.tileH) / Double(TileTemplateMatcher.tileW)
        let topY = Double(y0 + y1) / 2 - tileH / 2

        var concealed: [CGRect] = []
        for i in 0..<concealedCount {
            concealed.append(CGRect(x: Double(concealedSpan.minX) + Double(i) * pitch,
                                    y: topY, width: pitch, height: tileH))
        }

        var drawnRect: CGRect?
        if let d = drawn {
            // 摸牌那张也在同一行，用同样的纵向范围（横向按它自己的块定位）
            drawnRect = CGRect(x: d.minX + (d.width - pitch) / 2, y: topY,
                               width: pitch, height: tileH)
        }

        return .success(Result(concealedRects: concealed,
                               drawnRect: drawnRect,
                               meldBlock: meldBlock,
                               meldTileWidth: (meldBlock?.width ?? 0) / max(1.0, Double(meldTilesEstimate(meldBlock, pitch))),
                               meldTileHeight: meldTileHeight,
                               band: CGRect(x: concealedSpan.minX, y: Double(y0),
                                            width: concealedSpan.width, height: Double(rows)),
                               pitch: pitch,
                               correlation: corr,
                               canvas: canvas))
    }

    /// 副露块里大概有几张牌。
    ///
    /// 副露的间距比手牌窄 —— 实测手牌 101px 时副露只有 **85px**（牌与牌在视觉上略微重叠），
    /// 所以按 **0.84 倍**手牌宽去数。实测那段 505px 的副露区 → 505/(101×0.84) = 5.95 → 6 张 ✓
    /// （确实就是两个碰：6筒×3 + 中×3）。
    ///
    /// ⚠️ 这里只是**估算**，只用于"告诉模型有几组副露"和换算单张宽。
    /// 副露的牌面是摆在桌面上、带透视压缩的（纵向只有手牌的 55%），
    /// 模板匹配吃不动，所以**副露的牌名不在这里认**。
    private static func meldTilesEstimate(_ block: CGRect?, _ handPitch: Double) -> Int {
        guard let b = block, handPitch > 1, b.width > 1 else { return 0 }
        let unit = handPitch * 0.84
        return max(1, Int((Double(b.width) / unit).rounded()))
    }

    // MARK: - 小工具

    /// 二值化找连续段
    static func runs(of v: [Double], threshold: Double, minLength: Int) -> [CGRect] {
        var out: [CGRect] = []
        var start = -1
        for i in 0..<v.count {
            if v[i] > threshold {
                if start < 0 { start = i }
            } else if start >= 0 {
                if i - start >= minLength { out.append(CGRect(x: start, y: 0, width: i - start, height: 0)) }
                start = -1
            }
        }
        if start >= 0, v.count - start >= minLength {
            out.append(CGRect(x: start, y: 0, width: v.count - start, height: 0))
        }
        return out
    }

    /// 把挨得很近的段合并（牌与牌之间的窄缝要被吞掉，真正的空隙要保留）
    static func merge(runs: [CGRect], tolerance: Double) -> [CGRect] {
        var out: [CGRect] = []
        for r in runs {
            if let last = out.last, Double(r.minX - last.maxX) <= tolerance {
                out[out.count - 1] = CGRect(x: last.minX, y: 0,
                                            width: r.maxX - last.minX, height: 0)
            } else {
                out.append(r)
            }
        }
        return out
    }

    /// 自相关细调牌宽。找不到可信的峰就返回初值。
    private static func refinePitch(gray: [UInt8], w: Int, y0: Int, y1: Int,
                                    x0: Int, x1: Int, estimate: Double) -> (Double, Double) {
        let span = x1 - x0
        guard span > 40 else { return (estimate, 0) }
        var prof = [Double](repeating: 0, count: span)
        let rows = y1 - y0
        for (i, x) in (x0..<x1).enumerated() {
            var s = 0
            for y in y0..<y1 { s += Int(gray[y * w + x]) }
            prof[i] = Double(s) / Double(rows)
        }
        let mean = prof.reduce(0, +) / Double(prof.count)
        for i in prof.indices { prof[i] -= mean }
        let norm = prof.reduce(0) { $0 + $1 * $1 }
        guard norm > 0 else { return (estimate, 0) }

        let loLag = max(8, Int(estimate * 0.82))
        let hiLag = max(loLag + 2, Int(estimate * 1.18))
        guard hiLag < prof.count - 2 else { return (estimate, 0) }
        var bestLag = 0
        var bestCorr = -2.0
        for lag in loLag...hiLag {
            var acc = 0.0
            for i in 0..<(prof.count - lag) { acc += prof[i] * prof[i + lag] }
            let corr = acc / norm
            if corr > bestCorr { bestCorr = corr; bestLag = lag }
        }
        guard bestLag > 0, bestCorr > 0.22 else { return (estimate, bestCorr) }
        return (Double(bestLag), bestCorr)
    }

    // MARK: - 取图

    /// 切出每张手牌（暗牌 + 摸牌，**整张**原尺寸）。模板匹配直接吃这个。
    static func tileCGImages(from cg: CGImage, result: Result) -> [CGImage] {
        result.tileRects.compactMap { cg.cropping(to: $0) }
    }

    /// 切出每张手牌并放大 `upscale` 倍、编码成 JPEG（留给需要送模型的兜底路径）。
    static func tileJPEGs(from cg: CGImage,
                          result: Result,
                          upscale: Int = 2,
                          quality: Double = 0.9) -> [Data] {
        var out: [Data] = []
        for sub in tileCGImages(from: cg, result: result) {
            let w = sub.width * upscale, h = sub.height * upscale
            guard w > 8, h > 8,
                  let ctx = CGContext(data: nil, width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { continue }
            ctx.interpolationQuality = .high
            ctx.draw(sub, in: CGRect(x: 0, y: 0, width: w, height: h))
            guard let scaled = ctx.makeImage() else { continue }
            let rep = NSBitmapImageRep(cgImage: scaled)
            if let d = rep.representation(using: .jpeg, properties: [.compressionFactor: quality]) {
                out.append(d)
            }
        }
        return out
    }

    /// 把一张 CGImage 直接编码成 JPEG（用于"整块区域"送模型）
    static func jpeg(from cg: CGImage, quality: Double = 0.92) -> Data? {
        NSBitmapImageRep(cgImage: cg)
            .representation(using: .jpeg, properties: [.compressionFactor: quality])
    }

    /// 从 CGImage 里裁一块、放大 `upscale` 倍、编码成 JPEG。
    /// 用于把「副露区」单独裁出来送模型（见 `DeepSeekClient.stream` 的说明）。
    static func jpeg(from cg: CGImage, rect: CGRect, upscale: Int = 2, quality: Double = 0.92) -> Data? {
        var r = rect.intersection(CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        guard !r.isNull, r.width > 8, r.height > 8 else { return nil }
        r = CGRect(x: r.minX.rounded(), y: r.minY.rounded(),
                   width: r.width.rounded(), height: r.height.rounded())
        guard let sub = cg.cropping(to: r) else { return nil }
        let w = sub.width * upscale, h = sub.height * upscale
        guard let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(sub, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let scaled = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: scaled)
            .representation(using: .jpeg, properties: [.compressionFactor: quality])
    }

    /// 把「玩家自己的副露区」裁出来，并**把纵向透视压缩还原**，编码成 JPEG 送模型。
    ///
    /// 两个问题都是实测出来的：
    ///
    /// 1. **整屏下发时模型会整个漏看副露** —— 它回答过"全场均未副露"，而玩家明明有两个碰。
    ///    所以副露必须单独裁一块出来送。
    /// 2. **裁出来还得把纵向拉回来**。副露是平放在桌面上画的，纵向只有手牌的 ~55%，
    ///    于是在图里 6 筒（2列×3行 6 个圆）会被读成 5 筒（四角+中心 5 个圆）。
    ///    实测同一块副露区（真值 `6p×3 + 7z×3`）：
    ///
    ///    | 送法 | 结果 |
    ///    |---|---|
    ///    | 原比例 2× | `6p 6p 6p 7z 6z 7z`（把中读成發） |
    ///    | 原比例 4× | 同上，还有一次把中读成發 |
    ///    | **纵向还原到 80:129** | **`6p 6p 6p 7z 7z 7z` 两次全对** |
    ///
    ///    道理和手牌一样：牌面是按 80×129 画的，形状被压扁就走样了。
    static func meldCrop(from cg: CGImage, result: Result, pad: Double = 0.25) -> Data? {
        guard let m = result.meldBlock else { return nil }
        let p = result.pitch * pad
        let rect = CGRect(x: m.minX - p, y: m.minY - p,
                          width: m.width + p * 2, height: m.height + p * 2)
        guard let sub = crop(cg, rect) else { return nil }

        // 目标高度：按 atlas 的 80:129 算，一张副露牌"本该"有多高
        let tileW = result.meldTileWidth > 1 ? result.meldTileWidth : result.pitch * 0.84
        let targetTileH = tileW * Double(TileTemplateMatcher.tileH) / Double(TileTemplateMatcher.tileW)
        var stretch = 1.0
        if result.meldTileHeight > 4 {
            stretch = min(2.6, max(1.0, targetTileH / result.meldTileHeight))
        }

        let up = 2.0
        let w = Int(Double(sub.width) * up)
        let h = Int(Double(sub.height) * up * stretch)
        guard w > 16, h > 16,
              let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(sub, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let out = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: out)
            .representation(using: .jpeg, properties: [.compressionFactor: 0.92])
    }

    private static func crop(_ cg: CGImage, _ rect: CGRect) -> CGImage? {
        var r = rect.intersection(CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        guard !r.isNull, r.width > 8, r.height > 8 else { return nil }
        r = CGRect(x: r.minX.rounded(), y: r.minY.rounded(),
                   width: r.width.rounded(), height: r.height.rounded())
        return cg.cropping(to: r)
    }

    /// 从 CGImage 跑一遍切分。
    ///
    /// ⚠️ **必须和裁牌用的是同一张图**。踩过这个坑：切分跑在 JPEG 上、裁牌用编码前的
    /// 干净位图 —— 两张图不是同一份像素，边界差几像素，结果赤五索被判成普通五索、
    /// 白板直接认不出。
    static func segment(cg: CGImage) -> Swift.Result<Result, Failure> {
        guard let b = buffers(of: cg) else { return .failure(.noBand) }
        return analyze(gray: b.gray, saturated: b.sat, w: b.w, h: b.h, rgba: b.rgba)
    }

    /// 从 JPEG/PNG 数据跑一遍切分（自测用）
    static func segment(jpegData: Data) -> Swift.Result<Result, Failure> {
        guard let src = CGImageSourceCreateWithData(jpegData as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            return .failure(.noBand)
        }
        return segment(cg: cg)
    }

    /// 取亮度 + 饱和度判定（牌面 = 低饱和且亮；牌桌 = 高饱和绿）
    static func luminance(of cg: CGImage) -> ([UInt8], [Bool], Int, Int)? {
        guard let v = buffers(of: cg) else { return nil }
        return (v.gray, v.sat, v.w, v.h)
    }

    /// 连同 RGBA 原图一起返回（画布定位在"高度受限"时需要颜色分桌面）。
    static func buffers(of cg: CGImage) -> (rgba: [UInt8], gray: [UInt8], sat: [Bool], w: Int, h: Int)? {
        let w = cg.width, h = cg.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &buf, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var gray = [UInt8](repeating: 0, count: w * h)
        var sat = [Bool](repeating: false, count: w * h)
        for i in 0..<(w * h) {
            let r = Int(buf[i * 4]), g = Int(buf[i * 4 + 1]), b = Int(buf[i * 4 + 2])
            gray[i] = UInt8((r * 299 + g * 587 + b * 114) / 1000)
            let mx = max(r, max(g, b)), mn = min(r, min(g, b))
            sat[i] = (mx - mn) > 45
        }
        return (buf, gray, sat, w, h)
    }
}
