import Foundation
import CoreGraphics
import AppKit

/// 一位玩家的牌河在**虚拟坐标**（2560×1440，见 `CanvasMapper`）里的几何。
///
/// 为什么不按截图像素写死：canvas 会随窗口等比缩放，虚拟坐标才是稳定的那套。
///
/// ## 四家牌河的形状（实测自 2048×1662 的真实截图）
///
/// | 座位 | 行怎么堆 | 牌面（沿牌轴 × 沿堆叠轴） | 牌距 | 行距 |
/// |---|---|---|---|---|
/// | 自家 | 沿 y 向下 | 76 × 85 | 81 | 85 |
/// | 対面 | 沿 y 向上 | 65 × 66 | 72 | 66 |
/// | 上家 | 沿 x 向左 | 50 × 92 | 56 | 92 |
/// | 下家 | 沿 x 向右 | 54 × 90 | 65 | 125 |
///
/// 「牌轴」= 一行里牌与牌排开的方向；「堆叠轴」= 一行接一行加出去的方向。
/// 自家/対面这两条轴是 x/y，上家/下家换成了 y/x（牌本身仍然是**正立**的，
/// 只是排布方向转了 90°——这一点是看掩膜逐格核对过的）。
struct RiverSeat {
    var name: String
    /// 粗定位区域（虚拟坐标），只用来取"牌面掩膜"的范围
    var region: CGRect
    /// 行是否沿 y 堆叠（自家/対面 = true；上家/下家 = false）
    var rowsAlongY: Bool
    /// 第 1 行行带起点（沿堆叠轴）
    var rowStart: Double
    /// 行距（带符号：负号表示往轴的反方向堆）
    var rowPitch: Double
    var maxRows: Int
    /// 牌距（沿牌轴），只作先验；实际张数由运行时量出的范围决定
    var tilePitch: Double
    var maxPerRow: Int
    /// 牌面沿牌轴的尺寸（**牌自己的宽**）
    var faceAlong: Double
    /// 牌面沿堆叠轴的尺寸（**牌自己的高**）
    var faceAcross: Double
    /// 这一行的第 1 张牌，是不是在牌轴的**大**那一头
    /// （対面/下家是"他们的左边 = 屏幕右/下"，所以反着填）
    var fillReversed: Bool = false
    /// 采样时要不要把牌轴反过来（见 `sample` 的说明）。
    /// 上家/下家的牌在屏幕上**转了 90°**，两个方向各反一个轴，牌才是正立的。
    var flipAlong: Bool = false
    var flipAcross: Bool = false
}

/// 一家牌河的识别结果。
struct RiverReadResult {
    var seat: String
    /// 逐行、每行按打牌先后排列的牌名（nil = 该格没有牌或没认出来）
    var rows: [[String?]]
    /// 校正后的网格图（每格固定像素，供人/模型复核）
    var strip: CGImage?
    /// 认出来的张数
    var recognized: Int { rows.reduce(0) { $0 + $1.compactMap { $0 }.count } }
    /// 有效格子数（包括认牌失败的格子）
    var occupied: Int
    /// 已填满的行数
    var filledRows: Int { rows.prefix { !$0.isEmpty }.count }
    /// 牌名串，按打牌先后
    var flat: [String] { rows.flatMap { $0.compactMap { $0 } } }
    /// 认牌得分（NCC）的平均值。自家牌河实测 0.6~0.77（认得住的），
    /// 明显偏低就说明这一家的几何没标定好，上层应当降级处理、别当成事实。
    var confidence: Double = 0
    /// 置信够不够当"事实"用
    var isTrustworthy: Bool { confidence >= 0.55 }
}

/// 本地读牌河。
///
/// ## 做法
///
/// 1. **认牌面掩膜**：牌面是近白的纸（亮 + 低饱和），桌面是暗绿，区分度很大。
/// 2. **行**用标定好的起点与行距铺开（实测三张截图里这个几何是稳的）；
///    **一行里有几张牌、从哪到哪**由运行时量出的牌面范围决定 ——
///    所以「碰完没有进张」「某一行的张数不是 6」这些情况都能处理。
/// 3. **逐张认牌**走 `TileFaceMatcher` 的牌面级匹配：只比"白纸牌面"、按实测压缩比
///    缩放模板、用 NCC 而不是软 IoU（实拍笔画被 JPEG 糊粗，软 IoU 会系统性偏向
///    墨多的模板）。剩下几像素的"摆得不整齐"由平移搜索吸收。
///
/// ## 实测（2048×1662 真实截图）
///
/// 自家牌河 12 张里 **9 张牌名正确**，位置与"哪几格有牌" **100% 正确**。
/// 错的三张都是"同花色差一档"（6s→7s、4s→2s、6p→8p）：实拍牌面只有 ~60px 宽，
/// 笔画被 JPEG 糊粗后，相邻档位的图案差异已经接近分辨率极限。这是**天花板**，
/// 不是流程 bug —— 同一张截图手牌有 14/14，因为手牌一张有 ~160px 高。
enum RiverReader {

    // MARK: - 四家几何

    static let own = RiverSeat(
        name: "自家", region: CGRect(x: 990, y: 700, width: 570, height: 320),
        rowsAlongY: true, rowStart: 723.8, rowPitch: 85.0, maxRows: 4,
        tilePitch: 81.0, maxPerRow: 6, faceAlong: 76, faceAcross: 85)

    static let across = RiverSeat(
        name: "対面", region: CGRect(x: 1040, y: 235, width: 490, height: 195),
        rowsAlongY: true, rowStart: 325.0, rowPitch: -66.0, maxRows: 4,
        tilePitch: 72.0, maxPerRow: 6, faceAlong: 65, faceAcross: 66,
        fillReversed: true, flipAlong: true, flipAcross: true)

    static let left = RiverSeat(
        name: "上家", region: CGRect(x: 790, y: 370, width: 265, height: 365),
        rowsAlongY: false, rowStart: 938.8, rowPitch: -95.0, maxRows: 4,
        tilePitch: 56.3, maxPerRow: 6, faceAlong: 53, faceAcross: 92.4,
        flipAcross: true)

    static let right = RiverSeat(
        name: "下家", region: CGRect(x: 1498, y: 370, width: 265, height: 365),
        rowsAlongY: false, rowStart: 1509.0, rowPitch: 125.0, maxRows: 4,
        tilePitch: 65.2, maxPerRow: 6, faceAlong: 62, faceAcross: 90,
        fillReversed: true, flipAlong: true)

    static let seats: [RiverSeat] = [own, across, left, right]

    /// 自测用：打印每一行量到的范围、张数、以及每格的候选得分。
    static var verbose = false

    /// 立直牌横放、与同家其他牌差 90°：其他旋向要**明显更好**（高出这么多）才跟着换，
    /// 否则维持整家旋向，免得单张噪声乱跳。
    private static let rotDeviation = 0.12

    /// 四边形拉直后的目标尺寸。**长宽比必须等于素材牌面的 75:118** ——
    /// 这样"把四边形拉成矩形"顺带就把透视压缩还原了：素材是没压扁的原图，
    /// 实拍是压扁的，两边都映到同一个比例的框里就又能比了。
    /// 换成别的比例（比如正方形）会把压缩留着，比不准。
    private static let quadW = 50
    private static let quadH = 79          // 50 × 118/75 ≈ 78.7

    /// 下面是**退回老路径**（铺格子）时才用到的先验，主路径不需要。
    private static var tplFitAlong = 0.888
    private static var tplFitAcross = 0.97
    private static let padAlong = 6.0
    private static let padAcross = 6.0
    private static let cellW = 60
    private static let cellH = 94
    private static let occupiedFraction = 0.40

    // MARK: - 对外接口

    static func readOwnRiver(from cg: CGImage, canvas: CanvasFrame?) -> RiverReadResult? {
        read(seat: own, from: cg, canvas: canvas)
    }

    /// 读四家牌河（自家在前）。
    static func readAll(from cg: CGImage, canvas: CanvasFrame?) -> [RiverReadResult] {
        var list = seats
        // 标定期用的旋向覆盖面开关：MJ_FLIP=left:af,right:a 之类
        if let s = ProcessInfo.processInfo.environment["MJ_FLIP"] {
            for item in s.split(separator: ",") {
                let parts = item.split(separator: ":")
                guard parts.count == 2,
                      let i = list.firstIndex(where: { $0.name == String(parts[0]) }) else { continue }
                let f = String(parts[1])
                list[i].flipAlong = f.contains("a")
                list[i].flipAcross = f.contains("f")
            }
        }
        if let s = ProcessInfo.processInfo.environment["MJ_FIT"] {
            let p = s.split(separator: ",").compactMap { Double($0) }
            if p.count == 2 { tplFitAlong = p[0]; tplFitAcross = p[1] }
        }
        if let s = ProcessInfo.processInfo.environment["MJ_ASPECT"], let k = Double(s) {
            for i in list.indices where !list[i].rowsAlongY { list[i].faceAlong *= k }
        }
        return list.compactMap { read(seat: $0, from: cg, canvas: canvas) }
    }

    /// 读一家的牌河。
    ///
    /// **主路径：不铺格子，直接找每张牌的四边形。**
    ///
    /// 牌河里的牌是平放 + 带透视画的，每一家的透视还不一样（自家纵向压到 ~0.69、
    /// 対面 ~0.72、上家/下家干脆转了 90°）。铺格子意味着要把"牌面多大、行距多少、
    /// 往哪个方向转"全部标定准 —— 实测这就是上家/下家一直认不出来的原因：
    /// 格子对不上，模板再准也没用。
    ///
    /// 换成"牌面是近白的纸、边缘很清楚，那就直接把这张纸的四条边找出来"之后，
    /// **牌什么方向、什么透视都不用管，也不需要任何"牌面宽高"的先验**：
    /// 1. `TileQuadFinder` 找出每张牌面的四边形；
    /// 2. 把四边形按素材牌面的长宽比（75:118）拉成矩形 —— 顺带还原了透视压缩；
    /// 3. 角点顺序试 8 种（4 旋转 × 2 绕向），谁分高用谁 —— **连"牌转了多少度"
    ///    都不用判断**（180° 旋转曾经让我把対面整家认不出来）。
    static func read(seat: RiverSeat, from cg: CGImage, canvas: CanvasFrame?) -> RiverReadResult? {
        // 默认走**铺格子**那条路：它用实测标定过的"牌面宽高 + 透视压缩比"，
        // 自家牌河实测 13 张里 12 张牌名正确。
        //
        // 四边形那条路（`TileQuadFinder` + `readByQuad`）是用户提的思路：
        // 直接把牌面的四条边找出来、沿边拉成矩形 —— 不需要任何"牌面多大、
        // 往哪个方向转"的先验。检测本身是成功的（13/10/11/10 块，全对），
        // 但**拉直时还要知道透视压缩比才能定目标长宽比**：牌面在屏幕上是被压扁的，
        // 拉成 75:118 会把压缩留着 → 实测只有 4/13。所以先留着，等把压缩比也算出来
        // （或者让四边形只负责'找牌'、压缩比仍由标定给）再接上。
        if ProcessInfo.processInfo.environment["MJ_QUADS"] != nil {
            return readByQuad(seat: seat, from: cg, canvas: canvas)
        }
        if ProcessInfo.processInfo.environment["MJ_GRID"] != nil {
            return readByGrid(seat: seat, from: cg, canvas: canvas)
        }
        return readByPattern(seat: seat, from: cg, canvas: canvas)
    }

    /// **主路径：图案框归一化匹配**（见 `TilePatternMatcher` 的说明）。
    ///
    /// 1. `TileQuadFinder` 找出每张牌"正面那张纸"的四边形（这一步很稳：四家
    ///    13/10/11/10 块，与实际张数一致）；
    /// 2. 在每张牌附近收敛到**白纸本体** —— 把牌的灰色前沿、绿/橙侧面、桌面、
    ///    邻牌全部切掉（这些是"长方体除正面以外的面"，不切掉会主导图案框）；
    /// 3. 取白纸内部（再内缩几像素，切掉牌内缘那圈阴影）的 **图案框**，
    ///    归一化到 `TilePatternMatcher.canon` 与模板比对；
    /// 4. 旋向**不事先给** —— 同一家的牌旋向必然相同，把四家各自 4 个旋向的
    ///    得分求和、整家投票定一个（实测自家 0°、対面 180°、上家 90°、下家 270°）。
    private static func readByPattern(seat: RiverSeat, from cg: CGImage,
                                      canvas: CanvasFrame?) -> RiverReadResult? {
        guard TilePatternMatcher.isAvailable else { return readByGrid(seat: seat, from: cg, canvas: canvas) }
        let w = cg.width, h = cg.height
        guard let buf = rgba(of: cg) else { return nil }
        let sc = canvas?.scale ?? (Double(w) / CanvasFrame.virtualWidth)
        let ox = canvas?.x ?? 0
        let oy = canvas?.y ?? 0

        let rx0 = Int(ox + seat.region.minX * sc), rx1 = Int(ox + seat.region.maxX * sc)
        let ry0 = Int(oy + seat.region.minY * sc), ry1 = Int(oy + seat.region.maxY * sc)
        // 面积界用一个**共同**的参考（自家牌面的面积），不要按各家自己的
        // faceAlong×faceAcross 算 —— 四种透视下那个乘积差很多，按各家自己的算会让
        // 对面对那些"小碎块"也放行（实测対面会多找出 2 块）。
        let one = 76.0 * 85.0 * sc * sc
        let tiles = TileQuadFinder.findTiles(buf: buf, w: w, h: h,
                                             region: (rx0, ry0, rx1, ry1),
                                             minArea: Int(one * 0.35),
                                             maxArea: Int(one * 2.2))
        guard !tiles.isEmpty else { return nil }

        // 每张牌：先收敛到白纸、再内缩，然后四个旋向各认一次
        var perTile: [[TilePatternMatcher.Match?]] = []
        var crops: [[UInt8]] = []
        var dims: [(Int, Int)] = []
        var cents: [CGPoint] = []
        var areas: [Double] = []
        var sizeInfo: [(Int, Int, Int, Int, Int, Int)] = []

        for t in tiles {
            let xs = t.corners.map(\.x), ys = t.corners.map(\.y)
            let rect = (x0: Int(xs.min() ?? 0), y0: Int(ys.min() ?? 0),
                        x1: Int(xs.max() ?? 0) + 1, y1: Int(ys.max() ?? 0) + 1)
            let paper = TilePatternMatcher.paperBox(buf, w: w, h: h, rect: rect)
            let inner = TilePatternMatcher.innerBox(paper)
            guard inner.2 - inner.0 > 14, inner.3 - inner.1 > 14 else { continue }
            let (crop, cw2, ch2) = cropRect(buf, w: w, h: h, box: inner)
            if let dir = ProcessInfo.processInfo.environment["MJ_DUMP"] {
                dumpCrop(crop, w: cw2, h: ch2, dir: dir,
                         name: "\(seat.name)-\(sizeInfo.count)")
            }
            var cand: [TilePatternMatcher.Match?] = []
            for r in 0..<4 {
                cand.append(TilePatternMatcher.identify(crop, w: cw2, h: ch2, rotation: r))
            }
            perTile.append(cand)
            crops.append(crop); dims.append((cw2, ch2))
            cents.append(t.centroid); areas.append(t.area)
            sizeInfo.append((rect.x1 - rect.x0, rect.y1 - rect.y0,
                             paper.0, paper.1,
                             paper.2 - paper.0, paper.3 - paper.1))
        }
        guard !perTile.isEmpty else { return nil }

        // 整家投票定旋向：同一家的牌旋向必然相同
        var votes = [Double](repeating: 0, count: 4)
        for cand in perTile {
            for r in 0..<4 { votes[r] += max(cand[r]?.score ?? -1, -0.2) }
        }
        var rot = 0
        for r in 1..<4 where votes[r] > votes[rot] { rot = r }
        if verbose {
            print(String(format: "      [%@] 旋向投票 %@ → %d°",
                         seat.name, votes.map { String(format: "%.2f", $0) }.joined(separator: " "),
                         rot * 90))
        }

        var found: [(stack: Double, along: Double, name: String?, score: Double)] = []
        var cells: [(Int, Int, [UInt8], Int, Int)] = []
        var scores: [Double] = []

        for (i, cand) in perTile.enumerated() {
            // **立直牌是横着放的**：它和同一家其他牌的旋向差 90°，不能被整家投票盖掉。
            // 默认用整家的旋向；只有别的旋向**明显更好**才跟着换 —— 免得单张噪声乱跳。
            var pick = rot
            var bestScore = cand[rot]?.score ?? -2
            for r in 0..<4 where r != rot {
                if let mm = cand[r], mm.score > bestScore + rotDeviation {
                    bestScore = mm.score
                    pick = r
                }
            }
            let m = cand[pick]
            var name: String? = m.map { resolveRed($0) }
            let score = m?.score ?? -2
            if name != nil && score < TilePatternMatcher.minAcceptableScore { name = nil }
            if name == nil, (m?.score ?? -1) < 0 {
                // 四个旋向都出不了图案框 → 白板：雀魂的白板就是一张没有图案的白牌
                name = "5z"
            }
            let cxv = (cents[i].x - ox) / sc
            let cyv = (cents[i].y - oy) / sc
            let stackV = seat.rowsAlongY ? cyv : cxv
            let alongV = seat.rowsAlongY ? cxv : cyv
            if verbose {
                let r2 = m.map { String(format: "%@ %.3f / %@ %.3f", $0.name, $0.score,
                                        $0.runnerUp, $0.runnerUpScore) } ?? "无图案"
                print(String(format: "      [%@] 牌 (%6.1f,%6.1f) 检测%dx%d 白纸@(%d,%d) %dx%d 旋%3d° → %@",
                             seat.name, cxv, cyv,
                             sizeInfo[i].0, sizeInfo[i].1,
                             sizeInfo[i].2, sizeInfo[i].3,
                             sizeInfo[i].4, sizeInfo[i].5, pick * 90, r2))
            }
            found.append((stackV, alongV, name, score))
            if let name, name != "5z" { scores.append(score) }
            let up = pick == 0 ? crops[i] : TilePatternMatcher.rotate(crops[i], w: dims[i].0,
                                                                     h: dims[i].1, times: pick)
            let ud = pick % 2 == 0 ? dims[i] : (dims[i].1, dims[i].0)
            cells.append((0, 0, up, ud.0, ud.1))   // 行列号稍后用聚类结果回填
        }

        // **按坐标聚类分行**，不用几何表的绝对行距 ——
        // 各家透视不一样，同一个 rowPitch 在四家上并不一致；而"同一行的牌堆叠坐标
        // 几乎相同、不同行差着一整个牌高"是非常稳的信号。
        var order = Array(found.indices).sorted { found[$0].stack < found[$1].stack }
        var groups: [[Int]] = []
        let gap = max(18.0, seat.faceAcross * 0.55)
        for idx in order {
            if let last = groups.last, let lastIdx = last.last,
               abs(found[idx].stack - found[lastIdx].stack) <= gap {
                groups[groups.count - 1].append(idx)
            } else {
                groups.append([idx])
            }
        }
        // 第一行 = 最靠近桌面中央的那一行（牌河是从近中央往外填的）
        let centre = seat.rowsAlongY ? 720.0 : 1280.0
        groups.sort { a, b in
            let da = abs(a.reduce(0) { $0 + found[$1].stack } / Double(a.count) - centre)
            let db = abs(b.reduce(0) { $0 + found[$1].stack } / Double(b.count) - centre)
            return da < db
        }
        var rows: [[String?]] = []
        for (ri, g) in groups.prefix(seat.maxRows).enumerated() {
            var line = g.sorted { seat.fillReversed ? found[$0].along > found[$1].along
                                                    : found[$0].along < found[$1].along }
            if verbose {
                print("      [\(seat.name)] 第\(ri + 1)行 \(line.count) 张（堆叠坐标 "
                      + line.map { String(format: "%.0f", found[$0].stack) }
                        .joined(separator: ",") + "）")
            }
            rows.append(line.map { found[$0].name })
        }
        // 回填格子图的行列号（cells 与 found 同序）
        var stripCells: [(Int, Int, [UInt8], Int, Int)] = []
        for (ri, g) in groups.prefix(seat.maxRows).enumerated() {
            for (ci, idx) in g.enumerated() { stripCells.append((ri, ci, cells[idx].2,
                                                                 cells[idx].3, cells[idx].4)) }
        }

        let strip = makeStrip(cells: stripCells, maxRows: seat.maxRows, maxPerRow: seat.maxPerRow)
        let occupied = rows.reduce(0) { $0 + $1.count }
        let conf = scores.isEmpty ? 0 : scores.reduce(0, +) / Double(scores.count)
        return RiverReadResult(seat: seat.name, rows: rows, strip: strip,
                               occupied: occupied, confidence: conf)
    }

    /// 剪一块矩形像素出来（不做缩放，图案框最后本来就要重采样）。
    private static func cropRect(_ buf: [UInt8], w: Int, h: Int,
                                 box: (Int, Int, Int, Int)) -> ([UInt8], Int, Int) {        let x0 = max(0, box.0), y0 = max(0, box.1)
        let x1 = min(w, box.2), y1 = min(h, box.3)
        let cw = max(1, x1 - x0), ch = max(1, y1 - y0)
        var out = [UInt8](repeating: 0, count: cw * ch * 4)
        for y in 0..<ch {
            for x in 0..<cw {
                let s = ((y0 + y) * w + (x0 + x)) * 4
                let d = (y * cw + x) * 4
                out[d] = buf[s]; out[d + 1] = buf[s + 1]
                out[d + 2] = buf[s + 2]; out[d + 3] = 255
            }
        }
        return (out, cw, ch)
    }

    /// 标定用：把裁出来的白纸内部图 + 图案框导出（`MJ_DUMP=/tmp/x`）。
    private static func dumpCrop(_ rgba: [UInt8], w: Int, h: Int, dir: String, name: String) {
        guard let img = makeImage(rgba, w: w, h: h) else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = (dir as NSString).appendingPathComponent("crop-\(name).png")
        if let d = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:]) {
            try? d.write(to: URL(fileURLWithPath: path))
        }
        // 顺便把图案框画出来
        let ink = TilePatternMatcher.inkPlane(rgba, w: w, h: h)
        guard let box = TilePatternMatcher.patternBox(ink, w: w, h: h) else { return }
        var px = rgba
        for x in box.0..<box.2 {
            for y in [box.1, box.3 - 1] where y >= 0 && y < h && x >= 0 && x < w {
                let p = (y * w + x) * 4
                px[p] = 255; px[p + 1] = 0; px[p + 2] = 255
            }
        }
        for y in box.1..<box.3 {
            for x in [box.0, box.2 - 1] where x >= 0 && x < w && y >= 0 && y < h {
                let p = (y * w + x) * 4
                px[p] = 255; px[p + 1] = 0; px[p + 2] = 255
            }
        }
        guard let img2 = makeImage(px, w: w, h: h),
              let d2 = NSBitmapImageRep(cgImage: img2).representation(using: .png, properties: [:]) else { return }
        let path2 = (dir as NSString).appendingPathComponent("box-\(name).png")
        try? d2.write(to: URL(fileURLWithPath: path2))
    }

    /// 铺格子那条路（主路径）。
    ///
    /// 行用标定好的起点与行距铺开；**一行里有几张牌、从哪到哪**由运行时量出的
    /// 牌面范围决定；每格再按实测压缩比把模板缩到同一尺度去比。
    private static func readByGrid(seat: RiverSeat, from cg: CGImage,
                                   canvas: CanvasFrame?) -> RiverReadResult? {
        let w = cg.width, h = cg.height
        guard let buf = rgba(of: cg) else { return nil }
        let sc = canvas?.scale ?? (Double(w) / CanvasFrame.virtualWidth)
        let ox = canvas?.x ?? 0
        let oy = canvas?.y ?? 0

        let scene = Scene(buf: buf, w: w, h: h, sc: sc, ox: ox, oy: oy)
        let mask = scene.mask(in: seat.region)

        var rows: [[String?]] = []
        var cells: [(Int, Int, [UInt8], Int, Int)] = []
        var scores: [Double] = []

        for ri in 0..<seat.maxRows {
            let rowTop = seat.rowStart + Double(ri) * seat.rowPitch
            guard let span = scene.tileSpan(seat: seat, mask: mask, rowTop: rowTop) else {
                rows.append([])
                continue
            }
            let n = max(1, min(seat.maxPerRow,
                               Int(((span.to - span.from) / seat.tilePitch).rounded())))
            let pitch = (span.to - span.from) / Double(n)
            if verbose {
                print(String(format: "      [%@] 第%d行 stack=%.1f  牌轴 %.1f..%.1f (%.1f) → %d 张，牌距 %.1f",
                             seat.name, ri + 1, rowTop, span.from, span.to,
                             span.to - span.from, n, pitch))
            }

            var line: [String?] = []
            var anyTile = false
            for k in 0..<n {
                let kk = seat.fillReversed ? (n - 1 - k) : k
                let a0 = span.from + Double(kk) * pitch
                guard let face = scene.sample(seat: seat, stack: rowTop,
                                              along0: a0, along1: a0 + pitch) else {
                    line.append(nil); continue
                }
                guard face.brightFraction > occupiedFraction else {
                    line.append(nil); continue
                }
                anyTile = true
                // 采样图是"牌自己正立"的：图宽 = 牌自己的宽（faceAlong）、
                // 图高 = 牌自己的高（faceAcross）。按标定好的压缩比把模板缩到同一尺度。
                let scaleX = seat.faceAlong * sc * tplFitAlong / Double(TileFaceMatcher.faceW)
                let scaleY = seat.faceAcross * sc * tplFitAcross / Double(TileFaceMatcher.faceH)
                let tw = Double(TileFaceMatcher.faceW) * scaleX
                let th = Double(TileFaceMatcher.faceH) * scaleY
                let blockW = (pitch + 2 * padAlong) * sc
                let blockH = (seat.faceAcross + 2 * padAcross) * sc
                let m = TileFaceMatcher.identify(face.rgba, w: face.w, h: face.h,
                                                 scaleX: scaleX, scaleY: scaleY,
                                                 anchorX: max(0, Int(((blockW - tw) / 2).rounded())),
                                                 anchorY: max(0, Int(((blockH - th) / 2).rounded())))
                if verbose, let m {
                    print(String(format: "        格%d(%.0f..%.0f) 亮纸%.2f → %@ %.3f / %@ %.3f",
                                 k, a0, a0 + pitch, face.brightFraction,
                                 m.name, m.score, m.runnerUp, m.runnerUpScore))
                }
                if let m, m.score >= TileFaceMatcher.minAcceptableScore {
                    line.append(resolveRed(m))
                    scores.append(m.score)
                } else {
                    line.append(nil)
                }
                cells.append((ri, k, face.rgba, face.w, face.h))
            }
            rows.append(anyTile ? line : [])
        }

        let strip = makeStrip(cells: cells, maxRows: seat.maxRows, maxPerRow: seat.maxPerRow)
        let occupied = rows.reduce(0) { $0 + $1.count }
        let conf = scores.isEmpty ? 0 : scores.reduce(0, +) / Double(scores.count)
        return RiverReadResult(seat: seat.name, rows: rows, strip: strip,
                               occupied: occupied, confidence: conf)
    }

    /// 四边形那条路（`MJ_QUADS=1` 打开，见 `read` 的说明）。
    private static func readByQuad(seat: RiverSeat, from cg: CGImage,
                                   canvas: CanvasFrame?) -> RiverReadResult? {
        let w = cg.width, h = cg.height
        guard let buf = rgba(of: cg) else { return nil }
        let sc = canvas?.scale ?? (Double(w) / CanvasFrame.virtualWidth)
        let ox = canvas?.x ?? 0
        let oy = canvas?.y ?? 0

        let rx0 = Int(ox + seat.region.minX * sc), rx1 = Int(ox + seat.region.maxX * sc)
        let ry0 = Int(oy + seat.region.minY * sc), ry1 = Int(oy + seat.region.maxY * sc)

        // 一张牌面的屏幕面积 ≈ 牌面宽×高×scale²。给足宽容度 ——
        // 各家透视差别很大，而 `faceAlong/faceAcross` 只是粗值。
        let expected = seat.faceAlong * seat.faceAcross * sc * sc
        let tiles = TileQuadFinder.findTiles(buf: buf, w: w, h: h,
                                             region: (rx0, ry0, rx1, ry1),
                                             minArea: Int(expected * 0.18),
                                             maxArea: Int(expected * 4.0))
        guard !tiles.isEmpty else { return nil }

        // 标定用：把找到的四边形画在截图上导出，肉眼一看就知道切得对不对
        if let out = ProcessInfo.processInfo.environment["MJ_QUADDUMP"] {
            dumpQuads(buf: buf, w: w, h: h, tiles: tiles, seat: seat, to: out)
        }

        var found: [(row: Int, along: Double, name: String?, score: Double)] = []
        var cells: [(Int, Int, [UInt8], Int, Int)] = []
        var scores: [Double] = []
        var rowCounts: [Int: Int] = [:]

        for t in tiles {
            let base = TileQuadFinder.orderedQuad(t.corners)
            var bestName: String? = nil
            var bestMatch: TileFaceMatcher.Match? = nil
            var bestOrder = base
            // 第一轮：8 种顺序各比一次（不平移），定下"牌是哪个朝向"
            let orderLimit = ProcessInfo.processInfo.environment["MJ_ORDER"]
                .flatMap { Int($0) } ?? 8
            for k in 0..<orderLimit {
                let q = orderVariant(base, k)
                let img = warpQuad(buf, w: w, h: h, quad: q, outW: quadW, outH: quadH)
                guard let m = TileFaceMatcher.identify(img, w: quadW, h: quadH,
                                                       scaleX: Double(quadW) / Double(TileFaceMatcher.faceW),
                                                       scaleY: Double(quadH) / Double(TileFaceMatcher.faceH),
                                                       anchorX: 0, anchorY: 0, extraShift: 0) else { continue }
                if m.score > (bestMatch?.score ?? -2) {
                    bestMatch = m; bestName = m.name; bestOrder = q
                }
            }
            // 第二轮：顺序定了之后再做一次小平移（角点总有一两个像素的误差）
            if var m = bestMatch {
                let img = warpQuad(buf, w: w, h: h, quad: bestOrder, outW: quadW, outH: quadH)
                if let m2 = TileFaceMatcher.identify(img, w: quadW, h: quadH,
                                                     scaleX: Double(quadW) / Double(TileFaceMatcher.faceW),
                                                     scaleY: Double(quadH) / Double(TileFaceMatcher.faceH),
                                                     anchorX: 0, anchorY: 0, extraShift: 2),
                   m2.score >= m.score {
                    m = m2
                }
                bestMatch = m
                bestName = resolveRed(m)
            }

            let cxv = (t.centroid.x - ox) / sc
            let cyv = (t.centroid.y - oy) / sc
            let stackV = seat.rowsAlongY ? cyv : cxv
            let alongV = seat.rowsAlongY ? cxv : cyv
            let row = max(0, min(seat.maxRows - 1,
                                 Int(((stackV - seat.rowStart - seat.faceAcross / 2)
                                      / seat.rowPitch).rounded())))
            var name = bestName
            let score = bestMatch?.score ?? -2
            if name != nil && score < TileFaceMatcher.minAcceptableScore { name = nil }
            if verbose {
                let cs = t.corners.map { String(format: "(%.0f,%.0f)", $0.x, $0.y) }.joined()
                print(String(format: "      [%@] 牌 (%6.1f,%6.1f) 面积%.0f 角%@ → %@ %.3f（第%d行）",
                             seat.name, cxv, cyv, t.area, cs, name ?? "??", score, row + 1))
            }
            found.append((row, alongV, name, score))
            if name != nil { scores.append(score) }
            let col = rowCounts[row, default: 0]
            rowCounts[row] = col + 1
            cells.append((row, col,
                          warpQuad(buf, w: w, h: h, quad: bestOrder, outW: quadW, outH: quadH),
                          quadW, quadH))
        }

        var rows: [[String?]] = []
        for r in 0..<seat.maxRows {
            var line = found.filter { $0.row == r }
            guard !line.isEmpty else { rows.append([]); continue }
            line.sort { seat.fillReversed ? $0.along > $1.along : $0.along < $1.along }
            rows.append(line.map(\.name))
        }

        let strip = makeStrip(cells: cells, maxRows: seat.maxRows, maxPerRow: seat.maxPerRow)
        let occupied = rows.reduce(0) { $0 + $1.count }
        let conf = scores.isEmpty ? 0 : scores.reduce(0, +) / Double(scores.count)
        return RiverReadResult(seat: seat.name, rows: rows, strip: strip,
                               occupied: occupied, confidence: conf)
    }

    /// 标定用：把四边形画到截图上存成 PNG（`MJ_QUADDUMP=/tmp/x`）。
    private static func dumpQuads(buf: [UInt8], w: Int, h: Int,
                                  tiles: [TileQuadFinder.Tile], seat: RiverSeat, to dir: String) {
        var px = buf
        for t in tiles {
            for k in 0..<4 {
                let a = t.corners[k], b = t.corners[(k + 1) % 4]
                let n = max(2, Int(max(abs(b.x - a.x), abs(b.y - a.y))))
                for i in 0...n {
                    let u = Double(i) / Double(n)
                    let x = Int(a.x + (b.x - a.x) * u), y = Int(a.y + (b.y - a.y) * u)
                    if x >= 0, y >= 0, x < w, y < h {
                        let p = (y * w + x) * 4
                        px[p] = 255; px[p + 1] = 0; px[p + 2] = 255
                    }
                }
            }
        }
        guard let img = makeImage(px, w: w, h: h) else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = (dir as NSString).appendingPathComponent("quads-\(seat.name).png")
        if let d = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:]) {
            try? d.write(to: URL(fileURLWithPath: path))
        }
    }

    /// 四边形的 8 种角点顺序（4 个旋转 × 2 个绕向）。
    /// 上层全试一遍取分最高的 —— 这样"牌转了多少度"完全不用判断。
    private static func orderVariant(_ q: [CGPoint], _ k: Int) -> [CGPoint] {
        let n = q.count
        let rot = k % 4
        let rev = k >= 4
        var idx = (0..<n).map { (rot + $0) % n }
        if rev { idx = [idx[0]] + idx.dropFirst().reversed() }
        return idx.map { q[$0] }
    }

    /// 把四边形（tl,tr,br,bl 顺序）双线性采样成 outW×outH 的 RGBA。
    private static func warpQuad(_ buf: [UInt8], w: Int, h: Int, quad: [CGPoint],
                                 outW: Int, outH: Int) -> [UInt8] {
        guard quad.count == 4 else { return [UInt8](repeating: 0, count: outW * outH * 4) }
        let tl = quad[0], tr = quad[1], bl = quad[3]
        var out = [UInt8](repeating: 0, count: outW * outH * 4)
        let ax = tr.x - tl.x, ay = tr.y - tl.y
        let bx = bl.x - tl.x, by = bl.y - tl.y
        for y in 0..<outH {
            let v = (Double(y) + 0.5) / Double(outH)
            for x in 0..<outW {
                let u = (Double(x) + 0.5) / Double(outW)
                let sx = tl.x + u * ax + v * bx
                let sy = tl.y + u * ay + v * by
                let d = (y * outW + x) * 4
                guard sx >= 1, sy >= 1, sx < Double(w - 2), sy < Double(h - 2) else {
                    out[d + 3] = 255
                    continue
                }
                let x0 = Int(sx), y0 = Int(sy)
                let fx = sx - Double(x0), fy = sy - Double(y0)
                let i00 = (y0 * w + x0) * 4
                let i10 = i00 + 4, i01 = i00 + w * 4, i11 = i01 + 4
                for ch in 0..<3 {
                    let a = Double(buf[i00 + ch]) * (1 - fx) + Double(buf[i10 + ch]) * fx
                    let b = Double(buf[i01 + ch]) * (1 - fx) + Double(buf[i11 + ch]) * fx
                    out[d + ch] = UInt8(max(0, min(255, a * (1 - fy) + b * fy)))
                }
                out[d + 3] = 255
            }
        }
        return out
    }

    /// 赤五（0X）与普通五（5X）图案完全一样，只有颜色不同 —— 用牌面红色占比裁决。
    private static func resolveRed(_ m: TileFaceMatcher.Match) -> String {
        resolveRed(name: m.name, redRatio: m.redRatio)
    }

    private static func resolveRed(_ m: TilePatternMatcher.Match) -> String {
        resolveRed(name: m.name, redRatio: m.redRatio)
    }

    private static func resolveRed(name: String, redRatio: Double) -> String {
        guard name.count == 2, let rank = name.first, rank == "5" || rank == "0" else {
            return name
        }
        let suit = String(name.suffix(1))
        guard let r5 = TileFaceMatcher.redRatio("5" + suit),
              let r0 = TileFaceMatcher.redRatio("0" + suit) else { return name }
        return redRatio >= (r5 + r0) / 2 ? ("0" + suit) : ("5" + suit)
    }

    // MARK: - 场景（像素访问 + 虚拟坐标换算）

    private struct Face {
        var rgba: [UInt8]
        var w: Int
        var h: Int
        var brightFraction: Double
    }

    private struct Scene {
        let buf: [UInt8]
        let w: Int
        let h: Int
        let sc: Double
        let ox: Double
        let oy: Double

        @inline(__always)
        func pixel(_ vx: Double, _ vy: Double) -> Int? {
            let x = Int(ox + vx * sc), y = Int(oy + vy * sc)
            guard x >= 0, y >= 0, x < w, y < h else { return nil }
            return y * w + x
        }

        @inline(__always)
        func isFace(_ i: Int) -> Bool {
            let p = i * 4
            let r = Int(buf[p]), g = Int(buf[p + 1]), b = Int(buf[p + 2])
            let lum = (r * 299 + g * 587 + b * 114) / 1000
            if lum <= 150 { return false }
            return max(r, max(g, b)) - min(r, min(g, b)) < 45
        }

        /// 区域内的牌面掩膜（行优先，尺寸 w*h）
        func mask(in region: CGRect) -> [Bool] {
            var m = [Bool](repeating: false, count: w * h)
            var vy = region.minY
            while vy < region.maxY {
                var vx = region.minX
                while vx < region.maxX {
                    if let i = pixel(vx, vy) { m[i] = isFace(i) }
                    vx += 1
                }
                vy += 1
            }
            return m
        }

        /// 一行里牌面沿牌轴的范围（虚拟坐标）。
        ///
        /// ⚠️ 扫描范围要按**牌轴**取，别拿 x 范围当万能的：自家/対面的牌轴是 x，
        /// 上家/下家的牌轴是 **y**。之前写死成 `region.minX..maxX`，上家/下家就
        /// 一格都量不出来（表现为"0 行 / 0 张"）。
        func tileSpan(seat: RiverSeat, mask: [Bool], rowTop: Double) -> (from: Double, to: Double)? {
            let axisLo = seat.rowsAlongY ? seat.region.minX : seat.region.minY
            let axisHi = seat.rowsAlongY ? seat.region.maxX : seat.region.maxY
            var lo = Double.greatestFiniteMagnitude, hi = -Double.greatestFiniteMagnitude
            var a = axisLo
            while a < axisHi {
                var on = 0, tot = 0
                var s = rowTop
                while s < rowTop + seat.faceAcross {
                    let i = seat.rowsAlongY ? pixel(a, s) : pixel(s, a)
                    if let i {
                        tot += 1
                        if mask[i] { on += 1 }
                    }
                    s += 1
                }
                if tot > 0, Double(on) / Double(tot) > 0.30 {
                    lo = min(lo, a); hi = max(hi, a)
                }
                a += 1
            }
            guard hi > lo, hi - lo > seat.tilePitch * 0.5 else { return nil }
            // 掩膜比真实牌面小一两像素，向外补一点
            return (lo - 1.5, hi + 1.5)
        }

        /// 采样一格牌面（含四周 pad）。
        ///
        /// ## 产出的图必须是"牌自己正立"的样子
        ///
        /// 模板是正立的牌面，所以采样出来的图也得让牌正着站。
        ///
        /// - 自家 / 対面：牌在屏幕上就是正立的（实测），图的横轴 = 屏幕 x、纵轴 = 屏幕 y。
        /// - **上家 / 下家：牌在屏幕上转了 90°**（实测：上家的"萬"在"六"的右边、
        ///   下家的"萬"在"二"的右边 —— 两家的转向相反）。这时图的横轴要走牌轴的
        ///   方向、纵轴走堆叠轴的方向，而且两个轴里**恰好要反一个**，
        ///   牌才是正立的而不是上下颠倒的（`flipAlong` / `flipAcross`）。
        ///
        /// 另外给出"牌面本体的亮纸占比"，用来判这一格有没有牌。
        func sample(seat: RiverSeat, stack: Double, along0: Double, along1: Double) -> Face? {
            let alongMin = along0 - padAlong, alongMax = along1 + padAlong
            let acrossMin = stack - padAcross
            let acrossMax = stack + seat.faceAcross + padAcross
            let pw = Int(((alongMax - alongMin) * sc).rounded())
            let ph = Int(((acrossMax - acrossMin) * sc).rounded())
            guard pw > 8, ph > 8 else { return nil }

            var out = [UInt8](repeating: 0, count: pw * ph * 4)
            var bright = 0, total = 0
            for py in 0..<ph {
                let cv0 = acrossMin + (Double(py) + 0.5) / sc
                let c = seat.flipAcross ? (acrossMin + acrossMax - cv0) : cv0
                for pxx in 0..<pw {
                    let av0 = alongMin + (Double(pxx) + 0.5) / sc
                    let a = seat.flipAlong ? (alongMin + alongMax - av0) : av0
                    let vx = seat.rowsAlongY ? a : c
                    let vy = seat.rowsAlongY ? c : a
                    let d = (py * pw + pxx) * 4
                    guard let i = pixel(vx, vy) else {
                        out[d + 3] = 255
                        continue
                    }
                    let p = i * 4
                    out[d] = buf[p]; out[d + 1] = buf[p + 1]
                    out[d + 2] = buf[p + 2]; out[d + 3] = 255
                    if av0 >= along0, av0 < along1, cv0 >= stack, cv0 < stack + seat.faceAcross {
                        total += 1
                        if isFace(i) { bright += 1 }
                    }
                }
            }
            return Face(rgba: out, w: pw, h: ph,
                        brightFraction: total > 0 ? Double(bright) / Double(total) : 0)
        }
    }

    // MARK: - 校正网格图

    private static func makeStrip(cells: [(Int, Int, [UInt8], Int, Int)],
                                  maxRows: Int, maxPerRow: Int) -> CGImage? {
        guard !cells.isEmpty else { return nil }
        let gap = 4
        let sw = maxPerRow * (cellW + gap) + gap
        let sh = maxRows * (cellH + gap) + gap
        var out = [UInt8](repeating: 24, count: sw * sh * 4)
        for i in 0..<(sw * sh) { out[i * 4 + 3] = 255 }
        for (r, c, rgba, w, h) in cells {
            guard r < maxRows, c < maxPerRow else { continue }
            let ox = gap + c * (cellW + gap), oy = gap + r * (cellH + gap)
            // 等比缩放进格子（居中），**不要强行拉伸** —— 拉伸了就看不出采样对不对了
            let k = min(Double(cellW) / Double(w), Double(cellH) / Double(h))
            let dw = max(1, Int(Double(w) * k)), dh = max(1, Int(Double(h) * k))
            let dx = ox + (cellW - dw) / 2, dy = oy + (cellH - dh) / 2
            for y in 0..<dh {
                let sy = min(h - 1, y * h / dh)
                for x in 0..<dw {
                    let sx = min(w - 1, x * w / dw)
                    let s = (sy * w + sx) * 4
                    let d = ((dy + y) * sw + (dx + x)) * 4
                    out[d] = rgba[s]; out[d + 1] = rgba[s + 1]
                    out[d + 2] = rgba[s + 2]; out[d + 3] = 255
                }
            }
        }
        return makeImage(out, w: sw, h: sh)
    }

    // MARK: - 小工具

    private static func rgba(of cg: CGImage) -> [UInt8]? {
        let w = cg.width, h = cg.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &buf, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return buf
    }

    private static func makeImage(_ buf: [UInt8], w: Int, h: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(buf) as CFData) else { return nil }
        return CGImage(width: w, height: h,
                       bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: w * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil,
                       shouldInterpolate: true, intent: .defaultIntent)
    }
}
