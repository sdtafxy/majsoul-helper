import Foundation
import AppKit
import Combine

/// Overlay 模式的状态与调度：选窗口 → 截图 → 调算法 → 交给图层画。
///
/// ★ 与原「分析」流程的关系 ★
/// 原流程是「截图 → 识牌 → 问 LLM → 出建议」；Overlay 模式**只做到识牌就停**
/// （用户明确说算法层更有价值，先不做 LLM）。两条流程共用截图与切分识别。
@MainActor
final class OverlayController: ObservableObject {

    enum Status: Equatable {
        case idle                       // 未开始
        case waitingPermission
        case running(String)             // 正在跑（描述当前阶段）
        case ok(elapsedMS: Int, total: Int, recognized: Int, blank: Int, low: Int)
        case failed(String)

        var hudText: String {
            switch self {
            case .idle:
                return "选一个窗口开始"
            case .waitingPermission:
                return "需要屏幕录制权限"
            case .running(let what):
                return "正在\(what)…"
            case .ok(let ms, let total, let rec, let blank, let low):
                var s = "共 \(total) 张 · 认出 \(rec) · 白板 \(blank) · \(ms)ms"
                if low > 0 { s += " · 低置信 \(low)" }
                return s
            case .failed(let e):
                return "失败：\(e)"
            }
        }

        var isBusy: Bool { if case .running = self { return true }; return false }
    }

    // MARK: - 状态

    @Published private(set) var status: Status = .idle
    /// 供快照注入预览状态（生产代码走setStatus）
    func previewSetStatus(_ s: Status) { status = s }
    @Published private(set) var windows: [CapturableWindow] = []
    @Published var selectedWindowID: Int = 0 {
        didSet { if selectedWindowID != oldValue { targetChanged() } }
    }
    @Published var showLabels = true { didSet { applyViewOptions() } }
    @Published var showHUD = true { didSet { applyViewOptions() } }
    /// 分类显示开关（2026-10-10）：手牌/牌河/副露/宝牌各自可关
    @Published var showHand = true { didSet { applyViewOptions() } }
    @Published var showRiver = true { didSet { applyViewOptions() } }
    @Published var showMeld = true { didSet { applyViewOptions() } }
    @Published var showDora = true { didSet { applyViewOptions() } }
    /// 自动刷新间隔（秒）。<= 0 表示关闭。
    @Published var autoInterval: Double = 0
    @Published var onlySideSeats = false
    /// 识别/分析后是否把结果画成悬浮图层（2026-10-10：分析也走识别，图层可开关）
    @Published var overlayEnabled = true {
        didSet {
            if overlayEnabled {
                // ★ 重新打开：若已有识别结果就立即画出来（否则关再开不显示）
                if lastResult.hand != nil || !lastResult.seats.isEmpty {
                    applyResult(lastResult)
                }
            } else {
                overlay.hide()
            }
        }
    }

    private let overlay = OverlayWindowController()
    private var autoTimer: Timer?
    private var lastResult: OverlayResult = .empty
    /// 最近一次「识别」用到的那张截图。导出排查包时复用，
    /// 保证排查包里的图 == 用户看到问题的那张（而不是重截一张）。
    private var lastCaptureURL: URL?

    /// 正在跑时置位，避免手动 + 自动同时触发两次
    private var busy = false

    // MARK: - 生命周期

    init() {}

    func bootstrap() {
        // 配色主题变化 → 立即重绘（2026-10-16）
        NotificationCenter.default.addObserver(
            forName: .mhOverlayThemeChanged, object: nil, queue: .main)
        { [weak self] _ in
            self?.overlay.view?.needsDisplay = true
        }
        overlay.attach()
        refreshWindows()
        startAutoIfNeeded()
    }

    func refreshWindows() {
        Task {
            do {
                let list = try await WindowCatalog.list()
                windows = list
                // ★ 不 autoPick（2026-10-12）：启动时自动选窗口会触发
                //   targetChanged → runNow，把识别结果画到「非用户选择」的
                //   窗口上（用户反馈：上次保存的窗口没打开时仍自动识别一次，
                //   结果画错窗口）。窗口只由用户显式选择。
                Log.info("Overlay: 窗口 \(list.count) 个")
            } catch {
                Log.error("Overlay: 枚举窗口失败 \(error)")
                status = .failed("枚举窗口失败：\(error.localizedDescription)")
            }
        }
    }

    // MARK: - 绑定

    private func targetChanged() {
        guard selectedWindowID != 0 else {
            overlay.stopFollowing()
            overlay.hide()
            status = .idle
            return
        }
        // ★ 只跟随窗口位置，不自动识别/画图层（2026-10-14 用户反馈：
        //   选窗口来源只是换来源，不该立即识别并把 overlay 画上去）
        overlay.follow(windowID: selectedWindowID)
    }

    // MARK: - 手动刷新

    /// 跑一次「截图 → 识别」。exportTo ≠ nil 时同时导出排查包。
    func runNow(exportTo: URL? = nil) {
        guard !busy else { Log.info("Overlay: 上一次还没跑完，跳过") ; return }
        let id = selectedWindowID
        guard id != 0 else { status = .idle; return }

        guard ScreenPermission.isGranted else {
            status = .waitingPermission
            ScreenPermission.request()
            return
        }
        busy = true
        status = .running("截图")

        Task {
            do {
                // 截图：maxSide 放大到 2400，保证牌面像素够（实战图实测 1800 偏糊）
                let shot = try await ScreenCaptureService.capture(
                    windowID: id, maxSide: 2400, jpegQuality: 0.92)
                // 文件名带时间戳；★ 整条链显式给类型（Swift 5 下 `Int(Date()...)`
                //   曾报 conformingTo 歧义，拆三步 + 标注后稳定）。
                let ts: Double = Date().timeIntervalSince1970
                let stamp: Int = Int(ts)
                let fname: String = "mjh-overlay-" + String(stamp) + ".jpg"
                let tmp: URL = URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent(fname)
                try shot.jpeg.write(to: tmp)
                // ★ 保留这张供导出复用（只留最新，删掉更早的）
                let prev = self.lastCaptureURL
                self.lastCaptureURL = tmp
                if let p = prev { try? FileManager.default.removeItem(at: p) }

                await self.recognizeAndPresent(imagePath: tmp.path, exportTo: exportTo)
            } catch {
                await MainActor.run {
                    self.busy = false
                    self.status = .failed(error.localizedDescription)
                    Log.error("Overlay: 失败 \(error)")
                }
            }
        }
    }

    /// 识别一张已存在的截图，把结果贴到图层；exportTo ≠ nil 时顺带导出排查包。
    private func recognizeAndPresent(imagePath: String, exportTo: URL?) async {
        await MainActor.run {
            self.status = .running(exportTo == nil ? "识别" : "识别 + 导出")
        }
        do {
            let r = try await OverlayEngine.run(imagePath: imagePath,
                                                exportDir: exportTo?.path)
            await MainActor.run {
                self.busy = false
                self.applyResult(r)
                if let dir = exportTo {
                    Log.info("Overlay: 排查包 → \(dir.path)")
                    NSWorkspace.shared.activateFileViewerSelecting([dir])
                }
                Log.info("Overlay: 识别完成 \(r.elapsedMS)ms total=\(r.summary["total"] ?? 0)")
            }
        } catch {
            await MainActor.run {
                self.busy = false
                self.status = .failed(error.localizedDescription)
                Log.error("Overlay: 失败 \(error)")
            }
        }
    }

    /// 导出排查包（面板按钮入口）。
    ///
    /// ★ 复用**最近一次识别用的截图**，而不是重新截一张 ★
    ///   用户工作流是「先识别 → 发现问题 → 再导出」：若导出时重截，
    ///   牌局可能已进牌 / 白光已过去，排查包就和用户看到问题的那张对不上。
    ///   只有还没截过图时才现截一张兜底。
    func exportPackage() {
        let ts: Double = Date().timeIntervalSince1970
        let stamp: Int = Int(ts)
        let custom = ConfigStore.shared.settings.debugExportDir
        let root: URL = custom.isEmpty
            ? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
            : URL(fileURLWithPath: custom)
        let dir: URL = root.appendingPathComponent("MajsoulHelper-" + String(stamp))

        if let last = lastCaptureURL, FileManager.default.fileExists(atPath: last.path) {
            guard !busy else { Log.info("Overlay: 上一次还没跑完，跳过") ; return }
            busy = true
            status = .running("导出排查包")
            Log.info("Overlay: 导出复用上次识别截图 \(last.lastPathComponent)")
            Task { await recognizeAndPresent(imagePath: last.path, exportTo: dir) }
        } else {
            runNow(exportTo: dir)
        }
    }

    /// 只截一张存盘，不跑识别。
    /// 识别窗口的「截图」按钮用：想把当前画面留下来（发 issue / 存档）时，
    /// 不必等识别跑完。存到设置里的「截图保存位置」，默认 ~/Downloads。
    func captureOnly() {
        let id = selectedWindowID
        guard id != 0 else { status = .idle; return }
        guard !busy else { return }
        guard ScreenPermission.isGranted else {
            status = .waitingPermission
            ScreenPermission.request()
            return
        }
        busy = true
        status = .running("截图")
        Task {
            do {
                let shot = try await ScreenCaptureService.capture(
                    windowID: id, maxSide: 2400, jpegQuality: 0.92)
                let custom = ConfigStore.shared.settings.captureSaveDir
                let dir = custom.isEmpty
                    ? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
                    : URL(fileURLWithPath: custom)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let name = "MajsoulHelper-shot-\(Int(Date().timeIntervalSince1970)).jpg"
                let url = dir.appendingPathComponent(name)
                try shot.jpeg.write(to: url)
                await MainActor.run {
                    self.busy = false
                    self.status = .running("截图已保存")
                    Log.info("Overlay: 截图 → \(url.path)")
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            } catch {
                await MainActor.run {
                    self.busy = false
                    self.status = .failed(error.localizedDescription)
                    Log.error("Overlay: 截图失败 \(error)")
                }
            }
        }
    }

    /// 展示一份识别结果：存 lastResult + 状态 + 图层（供「识别」与「分析」两条路共用）。
    func applyResult(_ r: OverlayResult) {
        lastResult = r
        let s = r.summary
        status = .ok(elapsedMS: r.elapsedMS,
                     total: s["total"] ?? 0,
                     recognized: s["recognized"] ?? 0,
                     blank: s["blank"] ?? 0,
                     low: s["low"] ?? 0)
        overlay.view?.result = onlySideSeats
            ? OverlayResult(imageSize: r.imageSize, canvas: r.canvas,
                            seats: r.seats.filter { $0.key == "left" || $0.key == "right" },
                            hand: r.hand, dora: r.dora, melds: r.melds,
                            elapsedMS: r.elapsedMS, summary: r.summary)
            : r
        applyViewOptions()
        if overlayEnabled {
            overlay.show()
        } else {
            overlay.hide()
        }
    }

    // MARK: - 自动刷新

    func startAutoIfNeeded() {
        autoTimer?.invalidate()
        autoTimer = nil
        guard autoInterval > 0 else { return }
        let iv = autoInterval
        let t = Timer.scheduledTimer(withTimeInterval: iv, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.runNow() }
        }
        RunLoop.main.add(t, forMode: .common)
        autoTimer = t
        Log.info("Overlay: 自动刷新 \(iv)s")
    }

    func autoIntervalChanged() { startAutoIfNeeded() }

    // MARK: - 视图开关

    func applyViewOptions() {
        overlay.view?.showLabels = showLabels
        overlay.view?.showHUD = showHUD
        overlay.view?.showHand = showHand
        overlay.view?.showRiver = showRiver
        overlay.view?.showMeld = showMeld
        overlay.view?.showDora = showDora
        overlay.view?.statusText = status.hudText
        overlay.view?.needsDisplay = true
    }

    func setLabels(_ v: Bool) { showLabels = v; applyViewOptions() }
    func setHUD(_ v: Bool) { showHUD = v; applyViewOptions() }

    // MARK: - 供快照/自测用

    var currentResult: OverlayResult { lastResult }
    var overlayView: OverlayView? { overlay.view }

    /// 塞一份样例结果，供界面快照用。
    /// 样例里**故意**混入低置信、失败、白板三种状态 —— 只放理想数据的话
    /// 排版问题（标签挤在一起、颜色区分不出来）根本不会暴露。
    func previewSample() {
        func tile(_ i: Int, _ name: String?, _ score: Double, low: Bool = false) -> OverlayTile {
            let pts: [CGPoint] = [
                CGPoint(x: 100 + Double(i)*40, y: 100),
                CGPoint(x: 160 + Double(i)*40, y: 100),
                CGPoint(x: 160 + Double(i)*40, y: 180),
                CGPoint(x: 100 + Double(i)*40, y: 180),
            ]
            return OverlayTile(id: i, quad: pts, name: name, score: score,
                               iou: score, ncc: score,
                               isBlank: name == "5z", isLow: low,
                               isKanTop1: false, isRiichi: false)
        }
        var t: [OverlayTile] = []
        let own = ["6m", "2m", "4m", "5z", "1s", "7p", "3s", "2p",
                   "9s", "4s", "1p", "8m", "6s", "3p", "7s", "5m", "2s"]
        for (i, n) in own.enumerated() { t.append(tile(i, n, 0.78)) }
        let across = ["1z", "9m", "4p", "6s", "2s", "8p", "7m", "5z",
                      "3m", "1s", "4s", "2z", "6m", "8s", "1p", "9p", "3s", "7p"]
        for (i, n) in across.enumerated() { t.append(tile(i, n, 0.75)) }
        // 侧家：故意混入低置信与失败
        let left = ["8s", "7s", "2s", "8s", "7s", "?", "1s", "3s", "6s",
                    "5z", "5z", "1z", "2z", "6m", "1z", "6m", "7s"]
        for (i, n) in left.enumerated() {
            t.append(tile(i, n, n == "?" ? 0.0 : 0.52, low: n != "?"))
        }
        let right = ["3m", "4z", "7z", "6z", "1z", "5z", "6z", "7s",
                     "8m", "9p", "3z", "3m", "9s", "2p", "3p", "9p", "3s"]
        for (i, n) in right.enumerated() { t.append(tile(i, n, 0.74)) }

        lastResult = OverlayResult(
            imageSize: CGSize(width: 1920, height: 979),
            canvas: CGRect(x: 52, y: 35, width: 1816, height: 875),
            seats: [
                OverlaySeat(key: "own", cnName: "自家", tiles: Array(t[0..<17])),
                OverlaySeat(key: "across", cnName: "对家", tiles: Array(t[17..<35])),
                OverlaySeat(key: "left", cnName: "上家", tiles: Array(t[35..<52])),
                OverlaySeat(key: "right", cnName: "下家", tiles: Array(t[52..<69])),
            ],
            hand: OverlayHand(
                tiles: [
                    OverlayHandTile(id: 0, rect: CGRect(x: 400, y: 790, width: 70, height: 118),
                                    name: "4m", score: 0.82, isDrawn: false),
                    OverlayHandTile(id: 1, rect: CGRect(x: 470, y: 790, width: 70, height: 118),
                                    name: "5p", score: 0.72, isDrawn: false),
                    OverlayHandTile(id: 2, rect: CGRect(x: 1140, y: 790, width: 70, height: 118),
                                    name: "6p", score: 0.78, isDrawn: true),
                ],
                meldRect: CGRect(x: 1550, y: 800, width: 60, height: 100),
                meldTiles: 3),
            dora: OverlayDora(indicators: ["5m"], dora: ["6m"],
                              slots: [(rect: CGRect(x: 60, y: 260, width: 55, height: 78),
                                       name: "5m", score: 0.81)]),
            melds: ["own": OverlayMeldSeat(groups: [[
                        // 暗杠示例（快照验证 4 张占位 + 标签）
                        OverlayMeldTile(name: "5m", quad: [], isRotated: false,
                                        isKan: true),
                        OverlayMeldTile(name: "0m", quad: [], isRotated: false,
                                        isKan: true)]],
                        note: "认出 2/2 张（含暗杠）"),
                    "left": OverlayMeldSeat(groups: [[
                        OverlayMeldTile(name: "6m", quad: [], isRotated: false),
                        OverlayMeldTile(name: "4m", quad: [], isRotated: false),
                        OverlayMeldTile(name: "5m", quad: [], isRotated: true)]], note: nil),
                    "across": OverlayMeldSeat(groups: [[
                        OverlayMeldTile(name: "7p", quad: [], isRotated: false),
                        OverlayMeldTile(name: "6p", quad: [], isRotated: true),
                        OverlayMeldTile(name: "8p", quad: [], isRotated: false)]], note: nil),
                    "right": OverlayMeldSeat(groups: [[
                        OverlayMeldTile(name: nil, quad: [], isRotated: true),
                        OverlayMeldTile(name: nil, quad: [], isRotated: true),
                        OverlayMeldTile(name: "6s", quad: [], isRotated: false)]], note: nil)],
            elapsedMS: 355,
            summary: ["total": 69, "recognized": 65, "blank": 4,
                      "none": 1, "low": 26])
    }

    /// 给快照填状态条文字 + 结果。样例状态要和真实运行时**逐字段一致**
    /// （含耗时、张数、失败数），否则排版问题会被掩盖——
    /// 踩过：只塞结果不设状态 → 状态条显示「正在截图…」、结果区整块空白。
    func previewHUD(withResult: Bool) {
        if withResult {
            status = .ok(elapsedMS: 355, total: 69, recognized: 65,
                         blank: 4, low: 26)
        } else {
            status = .idle
        }
        applyViewOptions()
    }

    /// 快照专用：注入样例窗口列表 + 目标窗口。
    /// 走单独入口而不是放开 `windows` 的 setter —— 生产代码不该被快照改写。
    func previewSetup(windows ws: [CapturableWindow], selected id: Int) {
        windows = ws
        // 直接改存储、不走 didSet，避免触发 targetChanged() 去真截图
        selectedWindowID = id
    }
}