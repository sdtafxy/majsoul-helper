import Foundation
import AppKit

// ══════════════════════════════════════════════════════════════════
//  桥接：调用 majsoul-vision 包（python -m majsoul_vision）
// ══════════════════════════════════════════════════════════════════
//
//  为什么要走 Python 而不是 Swift 侧那套：
//  实测（2026-10-07，GT 4032×2058 + 实战 1920×979）
//      Python：判别式 68/68，端到端 67/68 = 98.5%，四家张数全对
//      Swift：认出 47/52 = 90%，侧家只切到 12/18 张
//  差距在「侧家切分张数」上，是数量级问题，不是精度问题。
//  所以先把 Python 成果接进来用，Swift 侧重写留给后续（见 docs/接续清单.md）。
//
//  代价：依赖本机 Python 环境。python 路径可配置，找不到时明确报错而不是静默失败。

/// 一张牌的识别结果
struct OverlayTile: Identifiable {
    let id: Int
    /// 4 个顶点，顺时针 TL/TR/BR/BL，**原图像素坐标、原点左上**
    let quad: [CGPoint]
    let name: String?          // nil = 没识别出来
    let score: Double
    let iou: Double
    let ncc: Double
    let isBlank: Bool          // 判为白板（5z）
    let isLow: Bool            // 低置信，值得用户看一眼
    let isKanTop1: Bool        // 由规则 D（拓扑仲裁）强判的结果
    let isRiichi: Bool         // 立直牌：相对该家方向躺倒 90°（extra_rot != 0）
}

/// 一家的结果
struct OverlaySeat {
    let key: String
    let cnName: String
    let tiles: [OverlayTile]
}

/// 自家手牌一张（2026-10-09 新增，来自 Python hand_split）
struct OverlayHandTile: Identifiable {
    let id: Int
    /// 矩形 (x0,y0,x1,y1)，原图像素坐标
    let rect: CGRect
    let name: String?
    let score: Double
    let isDrawn: Bool          // 摸牌（与暗牌之间有空隙的那张）
}

/// 自家手牌整体
struct OverlayHand {
    let tiles: [OverlayHandTile]
    /// 自家副露区（摆放在手牌右侧，牌叠放/透视）
    let meldRect: CGRect?
    let meldTiles: Int
}

/// 宝牌指示牌（左上角面板，2026-10-09 移植 Swift DoraReader）
struct OverlayDora {
    let indicators: [String]
    let dora: [String]          // 换算后的宝牌（指示牌下一张）
    /// 每个指示牌的槽位框 + 识别（与 indicators 对应）
    let slots: [(rect: CGRect, name: String?, score: Double)]
}

/// 一张副露牌（含四边形坐标，供图层画逐张框）
struct OverlayMeldTile {
    let name: String?
    let quad: [CGPoint]     // 4 顶点（整图坐标）
    let isRotated: Bool     // 横放（被鸣的那张）
    /// 暗杠（2026-10-18）：Python 只识别中间 2 张明牌（两端背牌盖住）并标 kan
    var isKan: Bool = false
}

/// 一家副露（meld_split）
struct OverlayMeldSeat {
    let groups: [[OverlayMeldTile]]
    let note: String?
}

struct OverlayResult {
    let imageSize: CGSize
    let canvas: CGRect          // 游戏画面在原图里的范围
    let seats: [OverlaySeat]
    let hand: OverlayHand?      // 自家手牌 + 副露区（2026-10-09）
    let dora: OverlayDora?      // 宝牌指示牌（2026-10-09）
    let melds: [String: OverlayMeldSeat]   // 各家副露（2026-10-10）
    let elapsedMS: Int
    let summary: [String: Int]

    var totalTiles: Int { seats.reduce(0) { $0 + $1.tiles.count } }

    /// 窗口消失/识别失败时用它清空图层
    static let empty = OverlayResult(imageSize: .zero, canvas: .zero,
                                     seats: [], hand: nil, dora: nil, melds: [:],
                                     elapsedMS: 0, summary: [:])
}

/// majsoul-vision 的 JSON → OverlayResult
private struct RawOut: Decodable {
    struct Tile: Decodable {
        let id: Int
        let quad: [[Double]]
        let name: String?
        let score: Double
        let iou: Double
        let ncc: Double
        let blank: Bool
        let low: Bool?
        let kan_top1: Bool?
        let rot: Int?           // 立直牌 extra_rot（0=正放）
    }
    struct Seat: Decodable {
        let name: String
        let tiles: [Tile]
    }
    struct HandTile: Decodable {
        let id: Int
        let quad: [Double]      // 矩形 [x0,y0,x1,y1]
        let name: String?
        let score: Double
        let drawn: Bool
    }
    struct Hand: Decodable {
        let tiles: [HandTile]
        let meld_rect: [Double]?
        let meld_tiles: Int
    }
    struct DoraSlot: Decodable {
        let quad: [Int]         // [x0,y0,x1,y1]
        let name: String?
        let score: Double
    }
    struct Dora: Decodable {
        let indicators: [String]
        let dora: [String]?      // 换算后的宝牌（指示牌下一张，Python 已算）
        let dora_rects: [DoraSlot]
        let note: String?
    }
    struct MeldTile: Decodable {
        let name: String?
        let score: Double
        let rotated: Bool
        let quad: [Int]
        let quad4: [[Double]]?    // 4 顶点（透视四边形）
        /// 暗杠标记（Python meld_split._ankou_sides 判定：2 张明牌两侧绿背）
        let kan: Bool?
    }
    struct MeldSeat: Decodable {
        let groups: [[MeldTile]]
        let note: String?
    }
    struct Summary: Decodable {
        let total: Int
        let recognized: Int
        let blank: Int
        let none: Int
        let low_score: Int
    }
    let ok: Bool
    let error: String?
    let image: [Int]
    let canvas: [Int]
    let seats: [String: Seat]
    let hand: Hand?           // 可选 —— 旧版 CLI 没有这个字段
    let dora: Dora?
    let melds: [String: MeldSeat]?   // 各家副露（可选）
    let elapsed_ms: Int
    let summary: Summary
}

enum OverlayEngine {

    enum EngineError: LocalizedError {
        case pythonNotFound(String)
        case moduleMissing(String)
        case badOutput(String)
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .pythonNotFound(let p):
                return "找不到 Python（试过：\(p)）。请在设置里指定，或用受管运行时。"
            case .moduleMissing(let p):
                return "找不到识别引擎（\(p)）。发布版应包含 Resources/vision，开发时请把 majsoul-vision 放在同级目录"
            case .badOutput(let s):
                return "识别脚本输出无法解析：\(s.prefix(200))"
            case .failed(let s):
                return "识别失败：\(s)"
            }
        }
    }

    /// 受管 Python 优先（跟项目其它脚本一致），其次系统 python3
    static func pythonCandidates() -> [String] {
        var out: [String] = []
        let managed = NSHomeDirectory()
            + "/.workbuddy/binaries/python/envs/default/bin/python"
        if FileManager.default.isExecutableFile(atPath: managed) { out.append(managed) }
        for p in ["/usr/bin/python3", "/opt/homebrew/bin/python3"] {
            if FileManager.default.isExecutableFile(atPath: p) { out.append(p) }
        }
        return out
    }

    /// 内置识别引擎（App 打包时放在 Contents/Resources/vision/majsoul-vision，
    /// PyInstaller 产物，含 Python 运行时与 OpenCV——零依赖、开箱即用）。
    static func bundledVision() -> String? {
        guard let res = Bundle.main.resourceURL else { return nil }
        let p = res.appendingPathComponent("vision/majsoul-vision").path
        return FileManager.default.isExecutableFile(atPath: p) ? p : nil
    }

    /// 开发模式：同级目录下的 majsoul-vision 仓库脚本
    /// （~/Developer/majsoul-helper 与 ~/Developer/majsoul-vision 并列）
    static func devScript() -> String? {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Core
            .deletingLastPathComponent()   // Sources
            .deletingLastPathComponent()   // <repo>
        let p = repo.deletingLastPathComponent()
            .appendingPathComponent("majsoul-vision/recognize.py").path
        return FileManager.default.fileExists(atPath: p) ? p : nil
    }

    /// 跑一次切分 + 识别。**在后台线程调用**。
    ///
    /// exportDir ≠ nil 时额外让 CLI 导出排查包（原图副本 + result.json +
    /// overlay.png 渲染图），用于把实机异常打包发回排查。
    static func run(imagePath: String,
                    lowScore: Double = 0.70,
                    timeout: TimeInterval = 30,
                    exportDir: String? = nil) async throws -> OverlayResult {
        // ① 内置引擎（发布版走这条路，零依赖）
        if let bin = bundledVision() {
            let r = try await exec(exe: bin, prefix: [], image: imagePath,
                                   lowScore: lowScore, timeout: timeout,
                                   exportDir: exportDir)
            switch r {
            case .success(let out): return out
            case .failure(let msg): throw EngineError.failed(msg)
            }
        }
        // ② 开发模式：同级目录的识别脚本
        guard let script = devScript() else {
            throw EngineError.moduleMissing("没有内置引擎，也找不到 ../majsoul-vision/recognize.py")
        }
        let pys = pythonCandidates()
        guard !pys.isEmpty else {
            throw EngineError.moduleMissing("找不到 python3")
        }

        var lastErr = ""
        for py in pys {
            let r = try await exec(exe: py, prefix: [script], image: imagePath,
                                   lowScore: lowScore, timeout: timeout,
                                   exportDir: exportDir)
            switch r {
            case .success(let out): return out
            case .failure(let msg): lastErr = msg
            }
        }
        throw EngineError.failed(lastErr)
    }

    private enum ExecResult {
        case success(OverlayResult)
        case failure(String)
    }

    private static func exec(exe: String, prefix: [String], image: String,
                             lowScore: Double,
                             timeout: TimeInterval,
                             exportDir: String? = nil) async throws -> ExecResult {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: exe)
        var argv = prefix + [image, "--low-score", String(lowScore)]
        if let d = exportDir { argv += ["--export", d] }
        proc.arguments = argv
        let out = Pipe()
        let err = Pipe()
        proc.standardOutput = out
        proc.standardError = err

        do { try proc.run() } catch {
            throw EngineError.pythonNotFound(exe + "（启动失败：\(error.localizedDescription)）")
        }

        // ★★★ 整段不能有任何同步阻塞 ★★★
        //   `proc.waitUntilExit()` / `group.wait()` / `lock()` 在 async 上下文里
        //   都是 "unavailable from asynchronous contexts" —— Swift 5 只是 warning，
        //   **Swift 6 直接是 error**。本项目语言模式是 .v5，但别欠债。
        //   做法：把「跑进程 + 读管道」放进一个**非 async 的同步上下文**
        //   （DispatchQueue 闭包里没有 async 限制），外面用 continuation 包一层。
        //
        // ★ 这一段还有两个踩过的坑：
        //   ① 必须**同时**把 stdout 与 stderr 都读干 —— 只读一个会写满管道死锁。
        //      stdout 可以到几百 KB（69 张牌的四边形 + 名称）。
        //   ② errText 曾经误写成 `String(data: outBytes ...)`，
        //      于是出错时看到的是 stdout 内容，完全指不到真因。
        let outBytes: Data
        let errBytes: Data
        let termStatus: Int32
        do {
            (outBytes, errBytes, termStatus) = try await withCheckedThrowingContinuation {
                cont in
                DispatchQueue.global(qos: .userInitiated).async {
                    var o = Data(), e = Data()
                    let g = DispatchGroup()
                    DispatchQueue.global().async(group: g) {
                        o = out.fileHandleForReading.readDataToEndOfFile()
                    }
                    DispatchQueue.global().async(group: g) {
                        e = err.fileHandleForReading.readDataToEndOfFile()
                    }
                    // 超时兜底：脚本卡住时强杀，不让界面永远转圈
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                        if proc.isRunning { proc.terminate() }
                    }
                    proc.waitUntilExit()      // 此处是同步上下文，安全
                    g.wait()                   // 进程已退出，两条读线程必然结束
                    cont.resume(returning: (o, e, proc.terminationStatus))
                }
            }
        } catch {
            return .failure("进程调用失败：\(error.localizedDescription)")
        }

        let errText = String(data: errBytes, encoding: .utf8) ?? ""
        let outText = String(data: outBytes, encoding: .utf8) ?? ""
        guard termStatus == 0 else {
            let first = errText.split(separator: "\n").first.map(String.init) ?? ""
            return .failure(first.isEmpty ? "退出码 \(termStatus)" : first)
        }

        guard let data = outText.data(using: .utf8),
              let raw = try? JSONDecoder().decode(RawOut.self, from: data) else {
            return .failure(outText.isEmpty ? "（无输出）\(errText)" : outText)
        }
        guard raw.ok else {
            return .failure(raw.error ?? "未知错误")
        }
        return .success(convert(raw))
    }

    private static func convert(_ r: RawOut) -> OverlayResult {
        var seats: [OverlaySeat] = []
        for key in ["own", "across", "left", "right"] {
            guard let s = r.seats[key] else { continue }
            let tiles = s.tiles.map { t in
                OverlayTile(id: t.id,
                            quad: t.quad.map { CGPoint(x: $0[0], y: $0[1]) },
                            name: t.name,
                            score: t.score,
                            iou: t.iou,
                            ncc: t.ncc,
                            isBlank: t.blank,
                            isLow: t.low ?? false,
                            isKanTop1: t.kan_top1 ?? false,
                            isRiichi: (t.rot ?? 0) != 0)
            }
            seats.append(OverlaySeat(key: key, cnName: s.name, tiles: tiles))
        }
        let im0 = at(r.image, 0) ?? 0, im1 = at(r.image, 1) ?? 0
        let c0 = at(r.canvas, 0) ?? 0, c1 = at(r.canvas, 1) ?? 0
        let c2 = at(r.canvas, 2) ?? 0, c3 = at(r.canvas, 3) ?? 0
        return OverlayResult(imageSize: CGSize(width: im0, height: im1),
                             canvas: CGRect(x: CGFloat(c0), y: CGFloat(c1),
                                            width: CGFloat(c2 - c0),
                                            height: CGFloat(c3 - c1)),
                             seats: seats,
                             hand: convertHand(r.hand),
                             dora: convertDora(r.dora),
                             melds: convertMelds(r.melds),
                             elapsedMS: r.elapsed_ms,
                             summary: ["total": r.summary.total,
                                       "recognized": r.summary.recognized,
                                       "blank": r.summary.blank,
                                       "none": r.summary.none,
                                       "low": r.summary.low_score])
    }

    private static func convertHand(_ h: RawOut.Hand?) -> OverlayHand? {
        guard let h else { return nil }
        let tiles = h.tiles.map { t in
            OverlayHandTile(id: t.id,
                            rect: CGRect(x: dAt(t.quad, 0), y: dAt(t.quad, 1),
                                         width: dAt(t.quad, 2) - dAt(t.quad, 0),
                                         height: dAt(t.quad, 3) - dAt(t.quad, 1)),
                            name: t.name, score: t.score, isDrawn: t.drawn)
        }
        let meld: CGRect?
        if let m = h.meld_rect, m.count == 4, m[2] > m[0] {
            meld = CGRect(x: m[0], y: m[1], width: m[2] - m[0], height: m[3] - m[1])
        } else {
            meld = nil
        }
        return OverlayHand(tiles: tiles, meldRect: meld, meldTiles: h.meld_tiles)
    }

    private static func convertDora(_ d: RawOut.Dora?) -> OverlayDora? {
        guard let d else { return nil }
        let slots = d.dora_rects.map { s in
            (rect: CGRect(x: iAt(s.quad, 0), y: iAt(s.quad, 1),
                          width: iAt(s.quad, 2) - iAt(s.quad, 0),
                          height: iAt(s.quad, 3) - iAt(s.quad, 1)),
             name: s.name, score: s.score)
        }
        return OverlayDora(indicators: d.indicators, dora: d.dora ?? [],
                           slots: slots)
    }

    private static func convertMelds(_ m: [String: RawOut.MeldSeat]?) -> [String: OverlayMeldSeat] {
        guard let m else { return [:] }
        var out: [String: OverlayMeldSeat] = [:]
        for (k, v) in m {
            let groups = v.groups.map { g in g.map { t in
                let pts: [CGPoint]
                if let q4 = t.quad4, q4.count == 4 {
                    pts = q4.map { CGPoint(x: $0[0], y: $0[1]) }
                } else {
                    let (x0, y0, x1, y1) = (Double(t.quad[0]), Double(t.quad[1]),
                                            Double(t.quad[2]), Double(t.quad[3]))
                    pts = [CGPoint(x: x0, y: y0), CGPoint(x: x1, y: y0),
                           CGPoint(x: x1, y: y1), CGPoint(x: x0, y: y1)]
                }
                return OverlayMeldTile(name: t.name, quad: pts,
                                       isRotated: t.rotated,
                                       isKan: t.kan ?? false)
            }}
            out[k] = OverlayMeldSeat(groups: groups, note: v.note)
        }
        return out
    }
}

/// 下标安全取值。
///
/// ★ 刻意**不用** `Array[safe]` —— Swift 标准库已经有一个同名 subscript
///   （返回 `Element` 而不是 `Element?`），重名会解析歧义，
///   报"initializer 'init(_:radix:)' requires that 'Element' conform to
///   'StringProtocol'"这种完全看不出原因的错（踩过）。
private func at(_ a: [Int], _ i: Int) -> Int? {
    (i >= 0 && i < a.count) ? a[i] : nil
}

private func dAt(_ a: [Double], _ i: Int) -> Double {
    (i >= 0 && i < a.count) ? a[i] : 0
}

private func iAt(_ a: [Int], _ i: Int) -> CGFloat {
    (i >= 0 && i < a.count) ? CGFloat(a[i]) : 0
}
