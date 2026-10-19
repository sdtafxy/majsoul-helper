import Foundation
import CoreGraphics
import ImageIO

/// 用**牌面上的"图案"**认平放的牌（牌河/副露）—— 用户提的思路，实测比牌面级匹配更稳。
///
/// ## 为什么这条路对
///
/// 透视把整张牌面按 `(sx, sy)` 压扁，而 `(sx, sy)` 对**同一家的所有牌是同一个常数**
/// （自家 ≈ 0.80、対面 ≈ 0.72、上家/下家压在堆叠轴上）、而且四家的常数都不一样，
/// 事先也没法量准（实测扫遍整体缩放与长宽比都提不上去，这正是上家/下家一直
/// 认不出来的原因）。
///
/// 但"图案那一块"（万字的 `一萬`、筒子的圆圈、索子的竹节）**跟着一起被压扁** ——
/// 于是把**查询的图案框和模板的图案框归一化到同一个尺寸**，这个未知常数就被约掉了：
///
///     query_pat = T(x/sx, y/sy)  ⇒  bbox_query = bbox_tpl · (sx, sy)
///     ⇒ 把两者的 bbox 都映到同一个 canon×canon，两边完全重合（与 sx, sy 无关）
///
/// **不再需要标定压缩比**。素材只用来出"图案框"和图案本身。
///
/// ## 四个坑（都实测踩过，少一条就崩）
///
/// 1. **墨迹判据必须是「绝对暗度 + 红墨」**：
///    `ink = max(clip((150−lum)/75), clip((r−max(g,b)−18)/60))`。
///    **不能用"比纸面暗多少"的相对阈值** —— 牌自己的灰色前沿（lum ≈ 172，纸面 ≈ 218）、
///    阴影、邻牌的边，亮度都介于纸面和墨之间，用相对阈值它们全被算成墨，
///    **图案框会膨胀成整个方块**，归一化之后每张牌长得一模一样（实测只有 0~3/13）。
///    **也不能加绿色判据** —— 桌面就是深绿，会一起被算进来。
/// 2. **图案框用覆盖率定**：某一行/列里超阈像素占比 ≥ 6% 才算数。
///    用"至少 N 个像素"会被 1~2px 噪点撑满。
/// 3. **素材右上角那个红色编号**（1~9 / E S W N G R / Wh）必须清掉，否则它主导
///    图案框的上边界。清法是**只清右上角那块矩形里的墨**（sprite y<56、x>52）。
/// 4. 查询和模板的图案框都缩到**同一个** `canon×canon`，比 **NCC**。
///
/// ## 实测（2048×1662 真实截图，四家共 42 张）
///
/// 自家 **13/13 全对**（旧的格子法 12/13）；旋向不用事先给 —— 同一家的牌旋向必然相同，
/// **整家投票**就能定出来（实测自家 0°、対面 180°、上家 90°、下家 270°，与物理完全一致）。
enum TilePatternMatcher {

    struct Match {
        var name: String
        var score: Double          // NCC，-1~1
        var runnerUp: String
        var runnerUpScore: Double
        /// 图案归一化后的红色占比（赤五 / 普通五图案一样，要靠颜色分）
        var redRatio: Double = 0
        var margin: Double { score - runnerUpScore }
    }

    // MARK: - 参数（实测标定）

    /// sprite 里"白纸牌面"的裁剪框（frame 是 80×129）。
    /// 白纸从 y=14 才开始 —— 上面是牌的顶边（琥珀色），裁进来会被当成墨。
    private static let faceTop = 14
    private static let faceLeft = 3
    private static let faceW = 74
    private static let faceH = 114

    /// 素材右上角编号所在区域（sprite 坐标）—— 这块里的墨要清零。
    private static let numBottom = 56
    private static let numLeft = 52

    /// 归一化目标边长
    static let canon = 48
    /// 墨迹判据
    private static let inkDark = 150.0
    private static let inkSpan = 75.0
    /// 图案框：这一行/列的超阈像素占比到这个比例才算"有图案"
    private static let patternCoverage = 0.06
    /// 阈值化用的分界（软墨迹平面 > 0.5 即算墨）
    private static let maskLevel: Float = 0.5
    /// 低于这个 NCC 就当没认出来
    static let minAcceptableScore = 0.25

    /// 找"白纸本体"时，纸面亮度阈值 = 该窗口第 98 百分位 × 这个系数。
    /// 0.92 足以排除牌的灰色前沿（≈0.80×纸面）和阴影，又能容下纸面的亮度梯度。
    private static let paperRel = 0.92
    /// 找纸时的外扩像素
    private static let paperExpand = 6
    /// 找到白纸框之后再向内缩这么多像素，切掉牌内缘那圈阴影。
    private static let paperInset = 4

    // MARK: - 内部表示

    private struct Plane {
        var name: String
        var v: [Float]        // 已零均值、已归一化，canon×canon
        var redRatio: Double
    }

    private static let templates: [Plane] = loadTemplates()

    static var isAvailable: Bool { !templates.isEmpty }
    static var count: Int { templates.count }
    static var names: [String] { templates.map(\.name) }

    /// 自测用：打印图案框尺寸与墨迹占比
    static let debug = ProcessInfo.processInfo.environment["MJ_PATDBG"] != nil

    // MARK: - 对外接口

    /// 认一张牌。
    ///
    /// - Parameters:
    ///   - rgba: 这一张牌附近的 RGBA 像素块（比牌面大一圈没关系，内部会自己找白纸）
    ///   - rect: 牌在白纸搜索窗里的位置（像素，`x0,y0,x1,y1`）
    ///   - rotation: 逆时针转 90° 的次数（0~3）。四家的旋向由上层投票决定。
    static func identify(_ rgba: [UInt8], w: Int, h: Int, rotation: Int) -> Match? {
        guard !templates.isEmpty, w > 8, h > 8 else { return nil }
        let times = ((rotation % 4) + 4) % 4
        let swapped = times % 2 == 1
        let img = times == 0 ? rgba : rotate(rgba, w: w, h: h, times: times)
        let iw = swapped ? h : w
        let ih = swapped ? w : h

        let ink = inkPlane(img, w: iw, h: ih)
        guard let box = patternBox(ink, w: iw, h: ih) else { return nil }
        let (x0, y0, x1, y1) = box
        guard x1 - x0 >= 6, y1 - y0 >= 6 else { return nil }
        if debug {
            var on = 0
            for v in ink where v > maskLevel { on += 1 }
            print(String(format: "        [pat] %dx%d rot%d 图案框 %dx%d 墨占比 %.3f",
                         iw, ih, rotation * 90, x1 - x0, y1 - y0,
                         Double(on) / Double(iw * ih)))
        }

        var redSum: Float = 0, inkSum: Float = 0
        for y in y0..<y1 {
            for x in x0..<x1 {
                let p = (y * iw + x) * 4
                let r = Float(img[p]), g = Float(img[p + 1]), b = Float(img[p + 2])
                let red = min(1, max(0, (r - max(g, b) - 18) / 60))
                let v = ink[y * iw + x]
                inkSum += v; redSum += v * red
            }
        }
        let q = normalize(resize(ink, w: iw, h: ih, box: box))

        var best = ("", -2.0), second = ("", -2.0)
        var ranked: [(Double, String)] = []
        for t in templates {
            var dot: Float = 0
            for i in 0..<(canon * canon) { dot += q[i] * t.v[i] }
            let s = Double(dot)
            ranked.append((s, t.name))
            if s > best.1 {
                second = best; best = (t.name, s)
            } else if s > second.1 {
                second = (t.name, s)
            }
        }
        if debug {
            var qsq: Float = 0
            for v in q { qsq += v * v }
            ranked.sort { $0.0 > $1.0 }
            print(String(format: "        [ncc] qΣ²=%.3f → %@",
                         qsq, ranked.prefix(3).map { String(format: "%@ %.3f", $0.1, $0.0) }
                            .joined(separator: " ")))
        }
        guard !best.0.isEmpty else { return nil }
        return Match(name: best.0, score: best.1, runnerUp: second.0, runnerUpScore: second.1,
                     redRatio: inkSum < 1 ? 0 : Double(redSum / inkSum))
    }

    /// 从**已经算好的墨迹平面**里匹配（副露用）。
    ///
    /// 副露的绿边很宽（占掩膜 21%），牌河那套"亮度阈值当白纸 → 再找图案"的流程在它上面
    /// 会把整圈绿边当成墨。这里改成：调用方先把"这块牌的 solid 掩膜"算好，
    /// 图案框只在 `valid` 内找 —— 绿边、桌面、邻牌残影天然都被排除。
    ///
    /// - Parameters:
    ///   - ink: 墨迹平面（行优先 `[Float]`，0~1）
    ///   - valid: 允许出现墨迹的区域（`true` = 可以）
    static func matchInkPlane(_ ink: [Float], valid: [Bool], w: Int, h: Int) -> Match? {
        guard !templates.isEmpty, w > 6, h > 6, ink.count == w * h, valid.count == w * h
        else { return nil }

        // 图案框 = 行/列的墨迹覆盖率 ≥ patternCoverage 的极值
        let colNeed = max(1, Int(ceil(Double(w) * patternCoverage)))
        let rowNeed = max(1, Int(ceil(Double(h) * patternCoverage)))
        var anyCol = [Int](repeating: 0, count: w)
        var anyRow = [Int](repeating: 0, count: h)
        var total = 0
        for y in 0..<h {
            let base = y * w
            for x in 0..<w where ink[base + x] > maskLevel && valid[base + x] {
                anyCol[x] += 1; anyRow[y] += 1; total += 1
            }
        }
        guard total >= 20 else { return nil }
        var x0 = -1, x1 = -1, y0 = -1, y1 = -1
        for x in 0..<w where anyCol[x] >= colNeed {
            if x0 < 0 { x0 = x }
            x1 = x
        }
        for y in 0..<h where anyRow[y] >= rowNeed {
            if y0 < 0 { y0 = y }
            y1 = y
        }
        guard x0 >= 0, y0 >= 0, x1 - x0 >= 5, y1 - y0 >= 5 else { return nil }

        let bw = x1 - x0 + 1, bh = y1 - y0 + 1
        var flat = [Float](repeating: 0, count: bw * bh)
        for y in 0..<bh {
            let src = (y + y0) * w + x0
            for x in 0..<bw { flat[y * bw + x] = ink[src + x] }
        }
        return matchNormalized(flat, w: bw, h: bh)
    }


    /// 把墨迹平面逆时针转 90°（`times` 次）。副露用（横躺的吃/碰牌）。
    static func rotatePlane(_ a: [Float], w: Int, h: Int, times: Int) -> [Float] {
        var out = a
        var cw = w, ch = h
        for _ in 0..<((times % 4 + 4) % 4) {
            var b = [Float](repeating: 0, count: cw * ch)
            for y in 0..<ch {
                for x in 0..<cw { b[x * ch + (ch - 1 - y)] = out[y * cw + x] }
            }
            out = b
            let t = cw; cw = ch; ch = t
        }
        return out
    }

    /// `rotatePlane` 的掩膜版
    static func rotateMask(_ a: [Bool], w: Int, h: Int, times: Int) -> [Bool] {
        var out = a
        var cw = w, ch = h
        for _ in 0..<((times % 4 + 4) % 4) {
            var b = [Bool](repeating: false, count: cw * ch)
            for y in 0..<ch {
                for x in 0..<cw { b[x * ch + (ch - 1 - y)] = out[y * cw + x] }
            }
            out = b
            let t = cw; cw = ch; ch = t
        }
        return out
    }

    /// 把一块 `w×h` 的墨迹重采样到 `canon×canon` 并与全部模板比 NCC。
    static func matchNormalized(_ flat: [Float], w: Int, h: Int) -> Match? {
        guard !templates.isEmpty, w >= 6, h >= 6, flat.count == w * h else { return nil }
        var buf = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w { buf[y * w + x] = flat[y * w + x] }
        }
        let q = normalize(resize(buf, w: w, h: h,
                                 box: (0, 0, w, h)))
        var best = ("", -2.0), second = ("", -2.0)
        for t in templates {
            var dot: Float = 0
            for i in 0..<(canon * canon) { dot += q[i] * t.v[i] }
            let s = Double(dot)
            if s > best.1 {
                second = best; best = (t.name, s)
            } else if s > second.1 {
                second = (t.name, s)
            }
        }
        guard !best.0.isEmpty else { return nil }
        return Match(name: best.0, score: best.1,
                     runnerUp: second.0, runnerUpScore: second.1, redRatio: 0)
    }

    /// 在 `rect`（像素坐标）附近找这张牌的**白纸本体**包围盒。
    ///
    /// 一张牌在屏幕上从上到下是：**白纸面 → 灰色前沿 → 绿/橙侧面 → 桌面**。
    /// 后三层都是"长方体除正面以外的面"（还有阴影、邻牌），必须切掉，否则
    /// 它们会主导图案框。判据：白纸是**整幅里最亮的**，而且**低饱和**。
    ///
    /// - 外扩 `paperExpand` 像素再把纸掩膜灌水（从窗口中央起），保证不会并到邻牌；
    /// - 补洞（图案是纸里的"洞"）；
    /// - 取包围盒。
    static func paperBox(_ rgba: [UInt8], w: Int, h: Int,
                         rect: (x0: Int, y0: Int, x1: Int, y1: Int)) -> (Int, Int, Int, Int) {
        var x0 = max(0, rect.x0 - paperExpand), x1 = min(w, rect.x1 + paperExpand)
        var y0 = max(0, rect.y0 - paperExpand), y1 = min(h, rect.y1 + paperExpand)
        if x1 - x0 < 8 { x0 = max(0, x0 - 4); x1 = min(w, x1 + 4) }
        if y1 - y0 < 8 { y0 = max(0, y0 - 4); y1 = min(h, y1 + 4) }
        let cw = x1 - x0, ch = y1 - y0
        guard cw > 8, ch > 8 else { return (x0, y0, x1, y1) }

        var lum = [Float](repeating: 0, count: cw * ch)
        for y in 0..<ch {
            for x in 0..<cw {
                let p = ((y0 + y) * w + (x0 + x)) * 4
                let r = Float(rgba[p]), g = Float(rgba[p + 1]), b = Float(rgba[p + 2])
                lum[y * cw + x] = 0.299 * r + 0.587 * g + 0.114 * b
            }
        }
        var sorted = lum
        sorted.sort()
        let lvl = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.98))]
        let thr = Float(paperRel) * lvl

        var paper = [Bool](repeating: false, count: cw * ch)
        for y in 0..<ch {
            for x in 0..<cw {
                let i = y * cw + x
                if lum[i] <= thr { continue }
                let p = ((y0 + y) * w + (x0 + x)) * 4
                let r = Int(rgba[p]), g = Int(rgba[p + 1]), b = Int(rgba[p + 2])
                if max(r, max(g, b)) - min(r, min(g, b)) >= 60 { continue }
                paper[i] = true
            }
        }

        // 从窗口中央约 40% 的区域灌水 —— 锁定"这一张"的纸
        // （区域别取太大：外扩之后窗口里可能已经有邻牌，种子落到邻牌上就会认错一张）
        let cy0 = ch * 30 / 100, cy1 = max(cy0 + 1, ch * 70 / 100)
        let cx0 = cw * 30 / 100, cx1 = max(cx0 + 1, cw * 70 / 100)
        var lab = flood(paper, cw: cw, ch: ch, seed: (cx0, cy0, cx1, cy1))
        if lab.filter({ $0 }).count < 100 {
            lab = flood(paper, cw: cw, ch: ch, seed: (0, 0, cw, ch))
            if lab.filter({ $0 }).count < 100 { return (x0, y0, x1, y1) }
        }
        guard let bb = solidBBox(lab, cw: cw, ch: ch) else { return (x0, y0, x1, y1) }
        return (x0 + bb.0, y0 + bb.1, x0 + bb.2, y0 + bb.3)
    }

    /// 白纸框取好之后再内缩，切掉牌内缘的阴影（那圈亮度 ~130，会被当成墨）。
    static func innerBox(_ box: (Int, Int, Int, Int)) -> (Int, Int, Int, Int) {
        (box.0 + paperInset, box.1 + paperInset, box.2 - paperInset, box.3 - paperInset)
    }

    // MARK: - 墨迹 / 图案框

    /// 软墨迹平面（0~1）。见类型注释里的坑 1。
    static func inkPlane(_ rgba: [UInt8], w: Int, h: Int) -> [Float] {
        var out = [Float](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            let p = i * 4
            let r = Float(rgba[p]), g = Float(rgba[p + 1]), b = Float(rgba[p + 2])
            let lum = 0.299 * r + 0.587 * g + 0.114 * b
            var v = Float((inkDark - Double(lum)) / inkSpan)
            v = v < 0 ? 0 : (v > 1 ? 1 : v)
            var red = (r - max(g, b) - 18) / 60
            red = red < 0 ? 0 : (red > 1 ? 1 : red)
            out[i] = max(v, red)
        }
        return out
    }

    /// 图案的最小外接框：行/列上超阈像素的**覆盖率** ≥ `patternCoverage` 才算数。
    static func patternBox(_ ink: [Float], w: Int, h: Int) -> (Int, Int, Int, Int)? {
        var rowHit = [Int](repeating: 0, count: h)
        var colHit = [Int](repeating: 0, count: w)
        for y in 0..<h {
            let base = y * w
            for x in 0..<w where ink[base + x] > maskLevel {
                rowHit[y] += 1; colHit[x] += 1
            }
        }
        // ⚠️ 用 ceil 而不是 Int() 截断：`Int(74 × 0.06) = 4`，而"占比 ≥ 6%"实际要求
        // 5 个像素（4/74 = 5.4% < 6%）。差这 1 个像素，模板的图案框会一直延伸到
        // 牌面最底边（那里有 4 个噪点），归一化后整块模板就废了 —— 实测分数从 0.79 掉到 0.19。
        let rowNeed = max(1, Int(ceil(Double(w) * patternCoverage)))
        let colNeed = max(1, Int(ceil(Double(h) * patternCoverage)))
        guard let ry0 = rowHit.firstIndex(where: { $0 >= rowNeed }),
              let ry1 = rowHit.lastIndex(where: { $0 >= rowNeed }),
              let cx0 = colHit.firstIndex(where: { $0 >= colNeed }),
              let cx1 = colHit.lastIndex(where: { $0 >= colNeed }) else { return nil }
        return (cx0, ry0, cx1 + 1, ry1 + 1)
    }

    // MARK: - 归一化 / NCC

    /// 把 `box` 里的软墨迹重采样成 canon×canon。
    ///
    /// **缩小**用面积平均（抗锯齿：多个源像素并成 1 个输出像素）；
    /// **放大**用双线性插值 —— 面积平均在放大时退化为最近邻（每个输出点只采
    /// 1 个源像素），边缘变块状，1s 这种细笔画图案的分会被压掉 0.1 还多
    /// （实测同一张 1s：双线性 0.333、最近邻 0.202）。
    static func resize(_ ink: [Float], w: Int, h: Int,
                       box: (Int, Int, Int, Int)) -> [Float] {
        let (x0, y0, x1, y1) = box
        let bw = x1 - x0, bh = y1 - y0
        var out = [Float](repeating: 0, count: canon * canon)
        if bw >= canon && bh >= canon {
            for y in 0..<canon {
                let sy0 = y0 + y * bh / canon, sy1 = max(sy0 + 1, y0 + (y + 1) * bh / canon)
                for x in 0..<canon {
                    let sx0 = x0 + x * bw / canon, sx1 = max(sx0 + 1, x0 + (x + 1) * bw / canon)
                    var acc: Float = 0
                    var n = 0
                    for yy in sy0..<min(sy1, y0 + bh) {
                        let base = yy * w
                        for xx in sx0..<min(sx1, x0 + bw) { acc += ink[base + xx]; n += 1 }
                    }
                    out[y * canon + x] = n > 0 ? acc / Float(n) : 0
                }
            }
            return out
        }
        // 双线性（放大或一轴放大一轴缩小）
        let fx = Double(bw) / Double(canon), fy = Double(bh) / Double(canon)
        for y in 0..<canon {
            let gy = (Double(y) + 0.5) * fy - 0.5
            let iy = Int(floor(gy))
            let ty = Float(max(0, min(1, gy - Double(iy))))
            let yy0 = y0 + max(0, min(bh - 1, iy))
            let yy1 = y0 + max(0, min(bh - 1, iy + 1))
            for x in 0..<canon {
                let gx = (Double(x) + 0.5) * fx - 0.5
                let ix = Int(floor(gx))
                let tx = Float(max(0, min(1, gx - Double(ix))))
                let xx0 = x0 + max(0, min(bw - 1, ix))
                let xx1 = x0 + max(0, min(bw - 1, ix + 1))
                let v00 = ink[yy0 * w + xx0], v10 = ink[yy0 * w + xx1]
                let v01 = ink[yy1 * w + xx0], v11 = ink[yy1 * w + xx1]
                out[y * canon + x] = (v00 * (1 - tx) + v10 * tx) * (1 - ty)
                                     + (v01 * (1 - tx) + v11 * tx) * ty
            }
        }
        return out
    }

    private static func normalize(_ a: [Float]) -> [Float] {
        var mean: Float = 0
        for v in a { mean += v }
        mean /= Float(a.count)
        var norm: Float = 0
        for v in a { let d = v - mean; norm += d * d }
        norm = norm.squareRoot()
        guard norm > 1e-6 else { return a }
        return a.map { ($0 - mean) / norm }
    }

    private static func ncc(_ a: [Float], _ b: [Float]) -> Double {
        var d: Float = 0
        for i in 0..<min(a.count, b.count) { d += a[i] * b[i] }
        return Double(d)
    }

    // MARK: - 模板

    private static func loadTemplates() -> [Plane] {
        guard let atlasURL = TileTemplateMatcher.assetURL("ui.atlas"),
              let pngURL = TileTemplateMatcher.assetURL("ui.png"),
              let atlasData = try? Data(contentsOf: atlasURL),
              let obj = try? JSONSerialization.jsonObject(with: atlasData) as? [String: Any],
              let frames = obj["frames"] as? [String: Any],
              let pngData = try? Data(contentsOf: pngURL),
              let sheet = decodeFirstImage(pngData),
              let buf = rgbaBuffer(sheet) else {
            Log.warn("牌面素材缺失，图案匹配不可用（牌河只能退回交给模型）")
            return []
        }
        var out: [Plane] = []
        for (file, value) in frames {
            let name = file.replacingOccurrences(of: ".png", with: "")
            if name == "back" { continue }
            guard let f = value as? [String: Any],
                  let fr = f["frame"] as? [String: Any],
                  let fx = fr["x"] as? Int, let fy = fr["y"] as? Int,
                  let fw = fr["w"] as? Int, let fh = fr["h"] as? Int,
                  fw >= faceLeft + faceW, fh >= faceTop + faceH else { continue }
            let ox = fx + faceLeft, oy = fy + faceTop
            var gray = [Float](repeating: 0, count: faceW * faceH)
            for y in 0..<faceH {
                for x in 0..<faceW {
                    let p = ((oy + y) * sheet.width + (ox + x)) * 4
                    let r = Float(buf[p]), g = Float(buf[p + 1]), b = Float(buf[p + 2])
                    gray[y * faceW + x] = 0.299 * r + 0.587 * g + 0.114 * b
                }
            }
            // 素材右上角印着编号（1~9 / E S W N G R / Wh），真机上没有 —— 清掉，
            // 否则它决定图案框的上边界，而查询里没有这块墨。
            let numRows = max(0, numBottom - faceTop)
            let numCols = max(0, numLeft - faceLeft)
            for y in 0..<min(numRows, faceH) {
                for x in numCols..<faceW { gray[y * faceW + x] = 255 }
            }
            var ink = [Float](repeating: 0, count: faceW * faceH)
            for i in 0..<(faceW * faceH) {
                var v = Float((inkDark - Double(gray[i])) / inkSpan)
                v = v < 0 ? 0 : (v > 1 ? 1 : v)
                ink[i] = v
            }
            guard let box = patternBox(ink, w: faceW, h: faceH) else { continue }
            let v = normalize(resize(ink, w: faceW, h: faceH, box: box))
            if debug, out.count < 6 {
                var sq: Float = 0
                for z in v { sq += z * z }
                print(String(format: "      [tpl] %@ 图案框(%d,%d,%d,%d) %dx%d Σ²=%.3f",
                             name, box.0, box.1, box.2, box.3,
                             box.2 - box.0, box.3 - box.1, sq))
            }
            out.append(Plane(name: name, v: v, redRatio: 0))
        }
        Log.info("图案模板载入 \(out.count) 张（牌面 \(faceW)×\(faceH)，归一化到 \(canon)×\(canon)）")
        return out.sorted { $0.name < $1.name }
    }

    // MARK: - 小工具

    static func rotate(_ src: [UInt8], w: Int, h: Int, times: Int) -> [UInt8] {
        var cur = src, cw = w, ch = h
        guard times % 4 != 0 else { return src }
        for _ in 0..<(times % 4) {
            var dst = [UInt8](repeating: 0, count: cw * ch * 4)
            let nw = ch, nh = cw
            for y in 0..<ch {
                for x in 0..<cw {
                    // 逆时针 90°：(x, y) → (y, cw-1-x)
                    let nx = y, ny = cw - 1 - x
                    let s = (y * cw + x) * 4, d = (ny * nw + nx) * 4
                    dst[d] = cur[s]; dst[d + 1] = cur[s + 1]
                    dst[d + 2] = cur[s + 2]; dst[d + 3] = 255
                }
            }
            cur = dst; cw = nw; ch = nh
        }
        return cur
    }

    private static func flood(_ m: [Bool], cw: Int, ch: Int,
                              seed: (Int, Int, Int, Int)) -> [Bool] {
        var lab = [Bool](repeating: false, count: cw * ch)
        var stack: [Int] = []
        for y in max(0, seed.1)..<min(ch, seed.3) {
            for x in max(0, seed.0)..<min(cw, seed.2) where m[y * cw + x] && !lab[y * cw + x] {
                lab[y * cw + x] = true; stack.append(y * cw + x)
            }
        }
        while let i = stack.popLast() {
            let y = i / cw, x = i % cw
            for dy in -1...1 {
                for dx in -1...1 where !(dy == 0 && dx == 0) {
                    let ny = y + dy, nx = x + dx
                    guard ny >= 0, nx >= 0, ny < ch, nx < cw else { continue }
                    let j = ny * cw + nx
                    if m[j] && !lab[j] { lab[j] = true; stack.append(j) }
                }
            }
        }
        return lab
    }

    /// 把连通域里的洞补上（图案是纸里的洞），返回包围盒。
    private static func solidBBox(_ lab: [Bool], cw: Int, ch: Int) -> (Int, Int, Int, Int)? {
        var outside = [Bool](repeating: false, count: cw * ch)
        var stack: [Int] = []
        func push(_ y: Int, _ x: Int) {
            let i = y * cw + x
            if !lab[i] && !outside[i] { outside[i] = true; stack.append(i) }
        }
        for x in 0..<cw { push(0, x); push(ch - 1, x) }
        for y in 0..<ch { push(y, 0); push(y, cw - 1) }
        while let i = stack.popLast() {
            let y = i / cw, x = i % cw
            for (dy, dx) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                let ny = y + dy, nx = x + dx
                guard ny >= 0, nx >= 0, ny < ch, nx < cw else { continue }
                push(ny, nx)
            }
        }
        var x0 = cw, x1 = -1, y0 = ch, y1 = -1, n = 0
        for y in 0..<ch {
            for x in 0..<cw {
                let i = y * cw + x
                if lab[i] || !outside[i] {
                    n += 1
                    if x < x0 { x0 = x }; if x > x1 { x1 = x }
                    if y < y0 { y0 = y }; if y > y1 { y1 = y }
                }
            }
        }
        guard n >= 300, x1 >= x0, y1 >= y0 else { return nil }
        return (x0, y0, x1 + 1, y1 + 1)
    }

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
