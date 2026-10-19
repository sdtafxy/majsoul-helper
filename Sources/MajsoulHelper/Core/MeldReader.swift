import Foundation
import CoreGraphics

/// 副露（碰 / 吃 / 杠）识别。
///
/// ## 结构（实测四张 1920×979 扁窗口截图，scale 0.5719）
///
/// 一组副露 = **2~3 张竖着的牌 + 1 张横躺的牌**（吃/碰来的那张转了 90°）。
/// 竖牌约 62~70 × 67~70 像素，横躺牌约 76~80 × 54。
///
/// ## 切分：白纸掩膜 → 补洞 → 连通域
///
/// - **补洞是关键**：图案是"白纸里的洞"，不补的话一张牌会被切碎成几块。
///   补法与牌河一致（从区域边界灌水，灌不进的非白像素算洞）。
/// - **不要闭运算/膨胀**：牌缝本来就是断开的，加了反而把缝填掉。
///   （实测腐蚀 0/1/2 结果一样，说明牌缝很干净。）
/// - 副露的牌**紧贴但不叠压**，所以连通域能直接分开——不需要"上沿阶梯"那套。
///
/// ## 白纸本体 vs 图案（这里和牌河最大的不同）
///
/// 副露的牌**绿边很宽**（占掩膜 21%、亮度 < 160），而牌河的绿边只占 5%。
/// 所以：
/// - 不能拿"亮度阈值"当白纸 —— 副露的绿边会整圈被当成墨，图案框膨胀成整个方块；
/// - 也不能拿"白纸掩膜 F（lum>150）"当图案的载体 —— **图案本身是暗的**，
///   `(ink>0.5) & F` 会全零。
/// - 正确做法：**图案墨迹限制在"这块连通域自己的 solid 掩膜"内**。
///   solid 已经补过洞、只圈住这一张牌，既排除了邻牌残影，也排除了绿边和桌面。
///
/// ## 无框 = 白板
///
/// 图案框为空说明这张是**白板**（雀魂的白板就是一张没图案的白牌），不是识别失败。
///
/// ## 侧家（上家/下家）副露**物理上不可读**
///
/// 它们的牌是**侧对屏幕**的，画面上只看得到绿色侧板 + 一条白边，没有牌面。
/// 所以只报张数，不报牌名 —— 这是硬件限制，不是算法问题。
enum MeldReader {

    struct Tile {
        var name: String?          // nil = 没认出来
        var score: Double
        var rotated: Bool          // 是否横躺（吃/碰来的那张）
        /// 牌面中心（虚拟坐标）
        var center: CGPoint
    }

    struct Group {
        var tiles: [Tile]
    }

    struct Result {
        var seat: String
        var groups: [Group]
        var confidence: Double
        var note: String = ""
    }

    struct Seat {
        var name: String
        /// 副露区域（虚拟坐标，2560×1440）
        var region: CGRect
        /// 这家副露是否侧对屏幕（不可识别牌名）
        var sideOn: Bool
    }

    /// 副露区位置（虚拟坐标，实测四张截图一致）
    static let seats: [Seat] = [
        Seat(name: "自家", region: CGRect(x: 1760, y: 1245, width: 690, height: 150),
             sideOn: false),
        Seat(name: "上家", region: CGRect(x: 70, y: 780, width: 270, height: 510),
             sideOn: true),
        Seat(name: "下家", region: CGRect(x: 2290, y: 430, width: 110, height: 100),
             sideOn: true),
    ]

    /// 一次性读四家副露，产出可直接进提示词的句子。
    ///
    /// 分流规则与牌河一致：**置信够高才写牌名**，不够就只报张数 ——
    /// 不准的牌名会把模型带偏。
    static func localFacts(cgImage: CGImage, canvas: CanvasFrame?) -> [String] {
        guard let buf = TileSegmenter.buffers(of: cgImage) else { return [] }
        let w = Double(cgImage.width)
        let cf = canvas ?? CanvasFrame(x: 0, y: 0, width: w, height: w * 9 / 16)
        var out: [String] = []
        for seat in seats {
            guard let m = read(seat: seat, rgba: buf.rgba, w: buf.w, h: buf.h, canvas: cf)
            else { continue }
            let all = m.groups.flatMap { $0.tiles }
            guard !all.isEmpty else { continue }
            let n = all.count
            let names = all.compactMap { $0.name }
            let conf = String(format: "%.2f", m.confidence)
            let groupCount = m.groups.count
            if seat.sideOn {
                out.append("\(seat.name)有 \(n) 张副露（牌侧对屏幕，本地读不出牌名，"
                    + "牌名请你自己从全屏图里看）。")
            } else if m.confidence >= 0.38 {
                out.append("\(seat.name)有 \(groupCount) 组副露共 \(n) 张："
                    + names.joined(separator: " ")
                    + "（本地像素识别，置信 \(conf)）。")
            } else {
                out.append("\(seat.name)有 \(groupCount) 组副露共 \(n) 张"
                    + "（本地识别置信 \(conf)，牌名可能不准，请以全屏图为准）。")
            }
        }
        return out
    }

    // MARK: - 参数

    /// 纸面像素判据：亮 + 低饱和
    @inline(__always)
    private static func isPaper(_ r: Int, _ g: Int, _ b: Int) -> Bool {
        let lum = (r * 299 + g * 587 + b * 114) / 1000
        let mx = max(r, max(g, b)), mn = min(r, min(g, b))
        return lum > 150 && mx - mn < 45
    }

    /// 图案墨迹判据：绝对暗度 + 红墨（与牌河一致）
    @inline(__always)
    private static func ink(_ r: Int, _ g: Int, _ b: Int) -> Float {
        let lum = (r * 299 + g * 587 + b * 114) / 1000
        let k = max(0, min(1, Float(150 - lum) / 75.0))
        let mx = max(g, b)
        let red = max(0, min(1, Float(r - mx - 18) / 60.0))
        return max(k, red)
    }

    /// 图案框的行列墨迹覆盖率下限
    private static let patternCoverage = 0.06
    private static let minArea = 300
    private static let minAcceptableScore = 0.30

    // MARK: - 读一家

    static func read(seat: Seat, rgba: [UInt8], w: Int, h: Int,
                     canvas: CanvasFrame) -> Result? {
        let x0 = max(0, Int(canvas.pxX(seat.region.minX)))
        let y0 = max(0, Int(canvas.pxY(seat.region.minY)))
        let x1 = min(w, Int(canvas.pxX(seat.region.maxX)))
        let y1 = min(h, Int(canvas.pxY(seat.region.maxY)))
        let rw = x1 - x0, rh = y1 - y0
        guard rw > 24, rh > 24 else { return nil }

        // ---- 1. 白纸掩膜 ----
        var paper = [Bool](repeating: false, count: rw * rh)
        var any = false
        for y in 0..<rh {
            let src = ((y0 + y) * w + x0) * 4
            for x in 0..<rw {
                let p = src + x * 4
                if isPaper(Int(rgba[p]), Int(rgba[p + 1]), Int(rgba[p + 2])) {
                    paper[y * rw + x] = true
                    any = true
                }
            }
        }
        guard any else { return nil }

        // ---- 2. 补洞：从区域边界灌水，灌不进 = 洞 ----
        var solid = paper
        var outside = [Bool](repeating: false, count: rw * rh)
        var dq: [Int] = []
        for x in 0..<rw {
            if !paper[x] { outside[x] = true; dq.append(x) }
            let b = (rh - 1) * rw + x
            if !paper[b] { outside[b] = true; dq.append(b) }
        }
        for y in 0..<rh {
            let a = y * rw
            if !paper[a] { outside[a] = true; dq.append(a) }
            let b = y * rw + rw - 1
            if !paper[b] { outside[b] = true; dq.append(b) }
        }
        var head = 0
        while head < dq.count {
            let i = dq[head]; head += 1
            let x = i % rw, y = i / rw
            if x > 0 {
                let n = i - 1
                if !paper[n] && !outside[n] { outside[n] = true; dq.append(n) }
            }
            if x < rw - 1 {
                let n = i + 1
                if !paper[n] && !outside[n] { outside[n] = true; dq.append(n) }
            }
            if y > 0 {
                let n = i - rw
                if !paper[n] && !outside[n] { outside[n] = true; dq.append(n) }
            }
            if y < rh - 1 {
                let n = i + rw
                if !paper[n] && !outside[n] { outside[n] = true; dq.append(n) }
            }
        }
        for i in 0..<(rw * rh) where !outside[i] { solid[i] = true }

        // ---- 3. 连通域（8 邻域） ----
        var label = [Int32](repeating: -1, count: rw * rh)
        var comps: [(x: Int, y: Int, w: Int, h: Int, area: Int, label: Int32)] = []
        for start in 0..<(rw * rh) where solid[start] && label[start] < 0 {
            let id = Int32(comps.count)
            var stack = [start]
            label[start] = id
            var minX = rw, maxX = -1, minY = rh, maxY = -1, cnt = 0
            while let s = stack.popLast() {
                let cx = s % rw, cy = s / rw
                cnt += 1
                if cx < minX { minX = cx }
                if cx > maxX { maxX = cx }
                if cy < minY { minY = cy }
                if cy > maxY { maxY = cy }
                for dy in -1...1 {
                    for dx in -1...1 {
                        if dx == 0 && dy == 0 { continue }
                        let nx = cx + dx, ny = cy + dy
                        if nx < 0 || ny < 0 || nx >= rw || ny >= rh { continue }
                        let n = ny * rw + nx
                        if solid[n] && label[n] < 0 {
                            label[n] = id
                            stack.append(n)
                        }
                    }
                }
            }
            if cnt >= minArea && maxX - minX >= 12 && maxY - minY >= 12 {
                comps.append((minX, minY, maxX - minX + 1, maxY - minY + 1, cnt, id))
            }
        }
        guard !comps.isEmpty else {
            return Result(seat: seat.name, groups: [], confidence: 0, note: "没找到牌")
        }
        comps.sort { $0.x < $1.x }

        if verbose {
            print("   [\(seat.name)] 切出 \(comps.count) 张: "
                  + comps.map { String(format: "%dx%d@%d", $0.w, $0.h, $0.x) }
                    .joined(separator: " "))
        }

        // ---- 4. 逐张识别 ----
        var tiles: [Tile] = []
        var scores: [Double] = []
        for c in comps {
            let cx = canvas.virtualX(Double(x0 + c.x) + Double(c.w) / 2)
            let cy = canvas.virtualY(Double(y0 + c.y) + Double(c.h) / 2)
            if seat.sideOn {
                // 侧对屏幕：只能确定有一张牌
                tiles.append(Tile(name: nil, score: -1, rotated: false,
                                  center: CGPoint(x: cx, y: cy)))
                continue
            }
            // 裁块：左侧多留 12px —— 竖牌常被左邻牌压住一点，
            // 而 valid（solid 掩膜）会把超出本块的部分挡住，所以多留无妨。
            let px0 = max(0, c.x - 4), py0 = max(0, c.y - 4)
            let px1 = min(rw, c.x + c.w + 4), py1 = min(rh, c.y + c.h + 4)
            let pw = px1 - px0, ph = py1 - py0
            guard pw > 12, ph > 12 else { continue }

            // ★ valid = 这块连通域**腐蚀 2px**。
            //   直接用连通域本身会把与邻牌相接的那一圈也算进来，图案框被撑大、
            //   归一化后全是拉伸变形（NCC 掉到 0.2）；腐蚀掉那一圈后图案笔画完整，
            //   实测图4 副露 6/6 全对。
            //   ⚠️ 不能改成"连通域 ∩ 白纸掩膜"—— 图案本身是暗的，会被白纸判据排掉。
            var own = [Bool](repeating: false, count: pw * ph)
            var ownCount = 0
            for y in 0..<ph {
                for x in 0..<pw {
                    let gx = px0 + x, gy = py0 + y
                    if gx < 0 || gy < 0 || gx >= rw || gy >= rh { continue }
                    if label[gy * rw + gx] != c.label { continue }
                    var near = false
                    outer: for dy in -2...2 {
                        for dx in -2...2 {
                            let nx = gx + dx, ny = gy + dy
                            if nx < 0 || ny < 0 || nx >= rw || ny >= rh { near = true; break outer }
                            if label[ny * rw + nx] != c.label { near = true; break outer }
                        }
                    }
                    if !near { own[y * pw + x] = true; ownCount += 1 }
                }
            }
            if ownCount < 60 {
                // 腐蚀过头（细长牌）→ 退回未腐蚀
                ownCount = 0
                for y in 0..<ph {
                    for x in 0..<pw {
                        let gx = px0 + x, gy = py0 + y
                        if gx < 0 || gy < 0 || gx >= rw || gy >= rh { continue }
                        if label[gy * rw + gx] == c.label { own[y * pw + x] = true; ownCount += 1 }
                    }
                }
            }
            guard ownCount >= 40 else { continue }

            var inkFlat = [Float](repeating: 0, count: pw * ph)
            var inkCount = 0
            for y in 0..<ph {
                for x in 0..<pw {
                    let p = ((y0 + py0 + y) * w + x0 + px0 + x) * 4
                    let v = ink(Int(rgba[p]), Int(rgba[p + 1]), Int(rgba[p + 2]))
                    inkFlat[y * pw + x] = v
                    if v > 0.5 && own[y * pw + x] { inkCount += 1 }
                }
            }

            var best: TilePatternMatcher.Match?
            var bestScore = -2.0
            var bestRot = 0
            for rot in 0..<4 where rot == 0 || rot == 1 || rot == 3 {
                // 横躺的吃/碰牌要试 0°/90°/270°
                let (ii, vv): ([Float], [Bool])
                if rot == 0 {
                    ii = inkFlat; vv = own
                } else {
                    ii = TilePatternMatcher.rotatePlane(inkFlat, w: pw, h: ph, times: rot)
                    vv = TilePatternMatcher.rotateMask(own, w: pw, h: ph, times: rot)
                }
                let iw = rot % 2 == 0 ? pw : ph
                let ih = rot % 2 == 0 ? ph : pw
                guard let m = TilePatternMatcher.matchInkPlane(ii, valid: vv, w: iw, h: ih)
                else { continue }
                if m.score > bestScore { bestScore = m.score; best = m; bestRot = rot }
            }

            guard let m = best else {
                // 图案框为空 = 这张是**白板**（雀魂的白板就是一张没图案的白牌），
                // 不是识别失败。判据是"连通域够大（确实是一张牌）但里面没有墨"。
                // 连通域够大（确实是一张牌）却完全没墨 → 白板
                tiles.append(Tile(name: "5z", score: 0,
                                  rotated: false, center: CGPoint(x: cx, y: cy)))
                continue
            }
            let name = m.score >= minAcceptableScore ? m.name : nil
            if let name { scores.append(m.score) }
            if verbose {
                print(String(format: "      牌 (%6.0f,%6.0f) %dx%d 旋%3d° → %@ %.3f / %@ %.3f",
                             cx, cy, c.w, c.h, bestRot * 90,
                             m.name, m.score, m.runnerUp, m.runnerUpScore))
            }
            tiles.append(Tile(name: name, score: m.score, rotated: bestRot != 0,
                              center: CGPoint(x: cx, y: cy)))
        }

        guard !tiles.isEmpty else {
            return Result(seat: seat.name, groups: [], confidence: 0, note: "没切出牌")
        }

        // ---- 5. 按间距分组：一组 = 一个副露 ----
        var groups: [Group] = []
        var cur: [Tile] = []
        var pitch = 0.0
        for (i, t) in tiles.enumerated() {
            if i > 0 {
                let gap = abs(t.center.x - tiles[i - 1].center.x)
                if pitch == 0 { pitch = max(gap, 1) }
                if gap > max(pitch * 1.45, 60) {
                    groups.append(Group(tiles: cur)); cur = []
                }
            }
            cur.append(t)
        }
        if !cur.isEmpty { groups.append(Group(tiles: cur)) }

        let conf = scores.isEmpty ? 0 : scores.reduce(0, +) / Double(scores.count)
        // "认出"= 非白板且分数过阈值；白板单独计数（它是对的，不是识别成功）
        let blanks = tiles.filter { $0.score == 0 && $0.name == "5z" }.count
        let named = scores.count
        let note: String
        if seat.sideOn {
            note = "\(tiles.count) 张（侧对屏幕，牌名不可读）"
        } else {
            note = "认出 \(named)/\(tiles.count) 张"
                + (blanks > 0 ? "（含 \(blanks) 张白板）" : "")
        }
        return Result(seat: seat.name, groups: groups, confidence: conf, note: note)
    }

    /// 自测用：打印每张牌的切分与得分
    static var verbose = false

    // MARK: - 匹配

    private static let canon = TilePatternMatcher.canon

}
