import Foundation
import CoreGraphics

/// 从"牌面掩膜"里找出**一张一张牌的四边形**。
///
/// ## 为什么不能铺规则格子
///
/// 牌河里的牌是平放在桌面上、带透视画的，每一家的透视还不一样（自家纵向压到 ~0.69、
/// 対面 ~0.72、上家/下家干脆转了 90°）。铺格子意味着要先把"牌面多大、行距多少、
/// 往哪个方向转"全部标定准 —— 实测这就是上家/下家一直认不出来的原因：
/// 格子对不上，模板再准也没用。
///
/// 换个思路：**牌面是近白的纸、边缘很清楚，那就直接把这张纸的四条边找出来**，
/// 沿着这四条边把四边形拉成矩形再比。这样"牌什么方向、什么透视"全都不用管，
/// 也不需要任何"牌面宽高"的先验。
///
/// ## 做法
///
/// 1. **补洞**：牌面里的墨迹本身不是"纸"，会变成洞。先做一次"从边界灌水"，
///    凡是灌不到的非纸像素都是**洞**，一并算成纸 —— 每张牌就成了一整块。
///    （不能用形态学闭运算：自家牌河相邻两牌的缝只有 ~5px，一膨胀就粘一起了。）
/// 2. **连通域**：一整块 = 一张牌。按面积筛掉噪点。
/// 3. **凸包 → 取四个角**：牌面是凸四边形，凸包上"转折最猛"的四个顶点就是四个角。
/// 4. 角点顺序交给上层（上层会把 8 种顺序都试一遍，谁分高用谁 ——
///    这样连"牌转了多少度"都不用判断）。
enum TileQuadFinder {

    struct Tile {
        /// 四个角，像素坐标，按凸包顺序（不自交）
        var corners: [CGPoint]
        /// 外接面积（像素²）
        var area: Double
        var centroid: CGPoint
    }

    /// 在 `region`（像素矩形）里找出所有牌面四边形。
    ///
    /// - Parameter minArea/maxArea: 面积筛选（像素²）。一张牌面大约 `(40..120)²`。
    static func findTiles(buf: [UInt8], w: Int, h: Int,
                          region: (x0: Int, y0: Int, x1: Int, y1: Int),
                          minArea: Int, maxArea: Int) -> [Tile] {
        let rx0 = max(0, region.x0), ry0 = max(0, region.y0)
        let rx1 = min(w, region.x1), ry1 = min(h, region.y1)
        let rw = rx1 - rx0, rh = ry1 - ry0
        guard rw > 8, rh > 8 else { return [] }

        // ---- 1. 牌面掩膜（局部坐标） ----
        var face = [Bool](repeating: false, count: rw * rh)
        for y in 0..<rh {
            let base = (ry0 + y) * w + rx0
            for x in 0..<rw {
                face[y * rw + x] = isPaper(buf, (base + x) * 4)
            }
        }

        // ---- 2. 从边界灌水，灌不到的非纸像素 = 洞 → 补成纸 ----
        var solid = face
        var seen = [Bool](repeating: false, count: rw * rh)
        var stack: [Int] = []
        stack.reserveCapacity(rw * 2 + rh * 2)
        for x in 0..<rw {
            for y in [0, rh - 1] where !face[y * rw + x] && !seen[y * rw + x] {
                seen[y * rw + x] = true; stack.append(y * rw + x)
            }
        }
        for y in 0..<rh {
            for x in [0, rw - 1] where !face[y * rw + x] && !seen[y * rw + x] {
                seen[y * rw + x] = true; stack.append(y * rw + x)
            }
        }
        while let i = stack.popLast() {
            let x = i % rw, y = i / rw
            for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                let nx = x + dx, ny = y + dy
                guard nx >= 0, ny >= 0, nx < rw, ny < rh else { continue }
                let j = ny * rw + nx
                if !face[j] && !seen[j] { seen[j] = true; stack.append(j) }
            }
        }
        for i in 0..<(rw * rh) where !face[i] && !seen[i] { solid[i] = true }   // 洞

        // ---- 2.5 先腐蚀 1 像素再连通 ----
        //
        // 相邻两张牌之间只有 ~5px 缝、行与行之间也只有 ~5px，但画面上有抗锯齿和
        // JPEG 毛边，直接 8 邻接连通的话**整行牌会连成一大块**（实测：自家牌河
        // 13 张只认出 7 张，剩下的都被并进大块、又被面积上限筛掉了）。
        // 先腐蚀 1 像素把细桥切断，连通域就一张牌一块；角点最后再往外放 1.5px 补回来。
        let erodePx = 2.0
        var eroded = [Bool](repeating: false, count: rw * rh)
        for y in 0..<rh {
            for x in 0..<rw {
                guard solid[y * rw + x] else { continue }
                var ok = true
                for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1),
                                 (1, 1), (1, -1), (-1, 1), (-1, -1)] {
                    let nx = x + dx, ny = y + dy
                    if nx < 0 || ny < 0 || nx >= rw || ny >= rh || !solid[ny * rw + nx] {
                        ok = false; break
                    }
                }
                eroded[y * rw + x] = ok
            }
        }

        // ---- 3. 连通域（8 邻域） ----
        let dbg = ProcessInfo.processInfo.environment["MJ_QUADDBG"] != nil
        var nComp = 0, nArea = 0, nHull = 0, nQuad = 0
        var areaList: [Int] = []
        var label = [Int32](repeating: -1, count: rw * rh)
        var out: [Tile] = []
        var comp: [Int] = []
        for start in 0..<(rw * rh) where eroded[start] && label[start] < 0 {
            nComp += 1
            let id = Int32(out.count + 1)
            comp.removeAll(keepingCapacity: true)
            label[start] = id
            stack = [start]
            while let i = stack.popLast() {
                comp.append(i)
                let x = i % rw, y = i / rw
                for dy in -1...1 {
                    for dx in -1...1 where !(dx == 0 && dy == 0) {
                        let nx = x + dx, ny = y + dy
                        guard nx >= 0, ny >= 0, nx < rw, ny < rh else { continue }
                        let j = ny * rw + nx
                        if eroded[j] && label[j] < 0 { label[j] = id; stack.append(j) }
                    }
                }
            }
            areaList.append(comp.count)
            guard comp.count >= minArea, comp.count <= maxArea else { continue }
            nArea += 1
            // 边界点（有邻居不在本块里的）
            var pts: [CGPoint] = []
            pts.reserveCapacity(comp.count / 4 + 8)
            for i in comp {
                let x = i % rw, y = i / rw
                var edge = false
                for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                    let nx = x + dx, ny = y + dy
                    if nx < 0 || ny < 0 || nx >= rw || ny >= rh { edge = true; break }
                    if !eroded[ny * rw + nx] { edge = true; break }
                }
                if edge { pts.append(CGPoint(x: Double(x), y: Double(y))) }
            }
            guard pts.count >= 8 else { continue }
            let hull = convexHull(pts)
            nHull += 1
            // **用轴对齐包围盒**。
            //
            // 实测四家的牌在屏幕上都**是轴对齐的**：自家/対面正立，
            // 上家/下家整张转了 90°（转 90° 之后包围盒照样轴对齐）。
            // 所以包围盒就是最稳、最确定的选择 —— 而且"牌转了多少度、哪边是宽"
            // 全不用判断，上层把 8 种角点顺序都试一遍即可。
            //
            // 试过但不如包围盒稳的：凸包取"转折最猛的四个点"（抗锯齿把角磨圆后
            // 会挑错点，切出来的四边形是歪的）、PCA 主方向包围盒（牌面接近正方形，
            // 主方向不稳定）、最小面积外接矩形（同样会在对角方向找到面积相近的解）。
            var quad: [CGPoint] = []
            do {
                var x0 = Double.greatestFiniteMagnitude, x1 = -x0, y0 = x0, y1 = -x0
                for i in comp {
                    let x = Double(i % rw), y = Double(i / rw)
                    if x < x0 { x0 = x }; if x > x1 { x1 = x }
                    if y < y0 { y0 = y }; if y > y1 { y1 = y }
                }
                guard x1 - x0 > 3, y1 - y0 > 3 else { continue }
                quad = [CGPoint(x: x0, y: y0), CGPoint(x: x1, y: y0),
                        CGPoint(x: x1, y: y1), CGPoint(x: x0, y: y1)]
            }
            nQuad += 1
            // 把腐蚀掉的那 1.5px 补回来（角点沿"从中心往外"的方向外扩）
            let qcx = quad.reduce(0) { $0 + $1.x } / 4
            let qcy = quad.reduce(0) { $0 + $1.y } / 4
            quad = quad.map { p in
                let dx = p.x - qcx, dy = p.y - qcy
                let l = (dx * dx + dy * dy).squareRoot()
                guard l > 1e-6 else { return p }
                return CGPoint(x: p.x + dx / l * erodePx, y: p.y + dy / l * erodePx)
            }
            let cx = Double(rx0) + quad.reduce(0) { $0 + $1.x } / 4
            let cy = Double(ry0) + quad.reduce(0) { $0 + $1.y } / 4
            let shifted = quad.map { CGPoint(x: $0.x + Double(rx0), y: $0.y + Double(ry0)) }
            out.append(Tile(corners: shifted, area: polygonArea(shifted),
                            centroid: CGPoint(x: cx, y: cy)))
        }
        if dbg {
            print("  连通域 \(nComp) 个；过面积 \(nArea)；有凸包 \(nHull)；出四边形 \(nQuad)"
                  + "；min=\(minArea) max=\(maxArea)")
            print("  面积前20: \(areaList.sorted(by: >).prefix(20))")
        }
        return out.sorted { $0.centroid.y < $1.centroid.y }
    }

    /// 牌面 = 亮 + 低饱和（纸是近白的，桌面是暗绿）
    @inline(__always)
    static func isPaper(_ buf: [UInt8], _ p: Int) -> Bool {
        let r = Int(buf[p]), g = Int(buf[p + 1]), b = Int(buf[p + 2])
        let lum = (r * 299 + g * 587 + b * 114) / 1000
        if lum <= 150 { return false }
        return max(r, max(g, b)) - min(r, min(g, b)) < 45
    }

    // MARK: - 凸包（Andrew monotone chain）

    static func convexHull(_ pts: [CGPoint]) -> [CGPoint] {
        guard pts.count >= 3 else { return pts }
        let s = pts.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
        func cross(_ o: CGPoint, _ a: CGPoint, _ b: CGPoint) -> Double {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }
        var lower: [CGPoint] = []
        for p in s {
            while lower.count >= 2, cross(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 {
                lower.removeLast()
            }
            lower.append(p)
        }
        var upper: [CGPoint] = []
        for p in s.reversed() {
            while upper.count >= 2, cross(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 {
                upper.removeLast()
            }
            upper.append(p)
        }
        lower.removeLast()
        upper.removeLast()
        return lower + upper
    }

    /// 凸包上"转折最猛"的四个顶点 = 四边形四角。
    ///
    /// 先按步长抽稀（抗锯齿会让包边有点毛刺），再算每个顶点的外角。
    ///
    /// ⚠️ **不能简单地"取外角最大的四个"**：抗锯齿会把真正的直角磨圆，
    /// 于是一个角会连着出现两三个"外角都很大"的相邻点，取前四就变成了
    /// "同一个角占了两个名额"。实测这样会让 14 块牌面里 10 块直接判失败。
    /// 正确做法是**贪心 + 最小间隔**：按外角从大到小挑，且和已挑的角至少隔开 n/8。
    static func quadCorners(hull: [CGPoint], target: Int = 4) -> [CGPoint]? {
        var h = hull
        guard h.count >= target else { return nil }
        if h.count > 60 {
            let step = h.count / 60 + 1
            h = stride(from: 0, to: h.count, by: step).map { h[$0] }
        }
        let n = h.count
        guard n >= target else { return nil }
        var turns: [(Double, Int)] = []
        for i in 0..<n {
            let a = h[(i - 1 + n) % n], b = h[i], c = h[(i + 1) % n]
            let v1 = CGPoint(x: b.x - a.x, y: b.y - a.y)
            let v2 = CGPoint(x: c.x - b.x, y: c.y - b.y)
            let l1 = (v1.x * v1.x + v1.y * v1.y).squareRoot()
            let l2 = (v2.x * v2.x + v2.y * v2.y).squareRoot()
            guard l1 > 1e-6, l2 > 1e-6 else { continue }
            let cosv = max(-1, min(1, (v1.x * v2.x + v1.y * v2.y) / (l1 * l2)))
            turns.append((acos(cosv), i))
        }
        guard turns.count >= target else { return nil }
        let minSep = max(3, n / 8)
        var picked: [Int] = []
        for (_, i) in turns.sorted(by: { $0.0 > $1.0 }) {
            if picked.count == target { break }
            let ok = picked.allSatisfy { p in
                let d = abs(p - i)
                return min(d, n - d) >= minSep
            }
            if ok { picked.append(i) }
        }
        guard picked.count == target else { return nil }
        return picked.sorted().map { h[$0] }
    }

    /// 最小面积外接矩形（粗扫 3° + 在最好的角度附近细扫 0.5°）。
    ///
    /// 为什么不用 PCA：牌面在屏幕上接近正方形（自家 60×68、対面 55×60），
    /// 两个特征值太接近 → 主方向不稳定，一点噪声方向就乱转
    /// （实测换成 PCA 包围盒后，自家牌河只剩 3 张认得出来）。
    /// "最小面积矩形"这个定义是明确的，抗这个。
    static func minAreaRect(_ hull: [CGPoint]) -> [CGPoint]? {
        guard hull.count >= 3 else { return nil }
        var bestArea = Double.greatestFiniteMagnitude
        var bestTheta = 0.0
        var bestExt = (uMin: 0.0, uMax: 0.0, vMin: 0.0, vMax: 0.0)

        func evaluate(_ theta: Double) {
            let ux = cos(theta), uy = sin(theta)
            let vx = -uy, vy = ux
            var uMin = Double.greatestFiniteMagnitude, uMax = -Double.greatestFiniteMagnitude
            var vMin = uMin, vMax = uMax
            for p in hull {
                let u = p.x * ux + p.y * uy
                let v = p.x * vx + p.y * vy
                if u < uMin { uMin = u }; if u > uMax { uMax = u }
                if v < vMin { vMin = v }; if v > vMax { vMax = v }
            }
            let a = (uMax - uMin) * (vMax - vMin)
            if a < bestArea { bestArea = a; bestTheta = theta; bestExt = (uMin, uMax, vMin, vMax) }
        }

        var t = 0.0
        while t < Double.pi { evaluate(t); t += 3.0 * Double.pi / 180.0 }
        let coarseBest = bestTheta
        var f = coarseBest - 3.0 * Double.pi / 180.0
        while f <= coarseBest + 3.0 * Double.pi / 180.0 {
            evaluate(f); f += 0.25 * Double.pi / 180.0
        }
        guard bestArea > 4 else { return nil }

        let ux = cos(bestTheta), uy = sin(bestTheta)
        let vx = -uy, vy = ux
        func pt(_ u: Double, _ v: Double) -> CGPoint {
            CGPoint(x: u * ux + v * vx, y: u * uy + v * vy)
        }
        let q = [pt(bestExt.uMin, bestExt.vMin), pt(bestExt.uMax, bestExt.vMin),
                 pt(bestExt.uMax, bestExt.vMax), pt(bestExt.uMin, bestExt.vMax)]
        // 至少得是个有面积的形状
        guard abs(q[1].x - q[0].x) + abs(q[1].y - q[0].y) > 3,
              abs(q[3].x - q[0].x) + abs(q[3].y - q[0].y) > 3 else { return nil }
        return q
    }

    /// 主方向包围盒（保留作参考；牌面接近正方形时不可靠，别用）。
    static func orientedBox(_ pts: [CGPoint]) -> [CGPoint]? {
        guard pts.count >= 4 else { return nil }
        let n = Double(pts.count)
        let cx = pts.reduce(0) { $0 + $1.x } / n
        let cy = pts.reduce(0) { $0 + $1.y } / n
        var sxx = 0.0, syy = 0.0, sxy = 0.0
        for p in pts {
            let dx = p.x - cx, dy = p.y - cy
            sxx += dx * dx; syy += dy * dy; sxy += dx * dy
        }
        sxx /= n; syy /= n; sxy /= n
        // 主方向（2×2 协方差阵的最大特征向量）
        let theta = 0.5 * atan2(2 * sxy, sxx - syy)
        let ux = cos(theta), uy = sin(theta)
        let vx = -uy, vy = ux
        var uMin = Double.greatestFiniteMagnitude, uMax = -Double.greatestFiniteMagnitude
        var vMin = uMin, vMax = uMax
        for p in pts {
            let dx = p.x - cx, dy = p.y - cy
            let u = dx * ux + dy * uy
            let v = dx * vx + dy * vy
            uMin = min(uMin, u); uMax = max(uMax, u)
            vMin = min(vMin, v); vMax = max(vMax, v)
        }
        guard uMax - uMin > 3, vMax - vMin > 3 else { return nil }
        func pt(_ u: Double, _ v: Double) -> CGPoint {
            CGPoint(x: cx + u * ux + v * vx, y: cy + u * uy + v * vy)
        }
        return [pt(uMin, vMin), pt(uMax, vMin), pt(uMax, vMax), pt(uMin, vMax)]
    }

    static func polygonArea(_ q: [CGPoint]) -> Double {        var s = 0.0
        for i in 0..<q.count {
            let a = q[i], b = q[(i + 1) % q.count]
            s += a.x * b.y - b.x * a.y
        }
        return abs(s) / 2
    }

    /// 把四边形按一个确定的方向排好（先取最左上的角，再逆时针）。
    /// 上层会在此基础上试 8 种顺序，所以这里只要**自洽**即可。
    static func orderedQuad(_ q: [CGPoint]) -> [CGPoint] {
        let cx = q.reduce(0) { $0 + $1.x } / Double(q.count)
        let cy = q.reduce(0) { $0 + $1.y } / Double(q.count)
        let sorted = q.sorted {
            atan2($0.y - cy, $0.x - cx) < atan2($1.y - cy, $1.x - cx)
        }
        // 从"最左上"那个角开始
        var best = 0, bestVal = Double.greatestFiniteMagnitude
        for (i, p) in sorted.enumerated() {
            let v = p.x + p.y
            if v < bestVal { bestVal = v; best = i }
        }
        return (0..<sorted.count).map { sorted[(best + $0) % sorted.count] }
    }
}
