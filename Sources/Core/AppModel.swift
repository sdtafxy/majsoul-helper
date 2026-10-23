import Foundation
import AppKit
import Combine
import CoreGraphics

/// 界面状态的唯一真相来源。所有 UI 变更都在 MainActor 上，网络/截图在后台。
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    /// 手牌是从哪来的。这个信息必须给用户看 —— 它直接决定结果可不可信。
    enum HandSource: Equatable {
        case tileSegment     // 切分 + 模板匹配（用雀魂自己的牌面素材，最可信）
        case modelImage      // 切分失败，模型直接从整屏读的（最不可信）
        case userCorrected   // 用户手工改过

        var label: String {
            switch self {
            case .tileSegment: return "模板匹配"
            case .modelImage: return "整屏识别"
            case .userCorrected: return "已人工修正"
            }
        }
    }

    // MARK: - 配置
    @Published var settings: Settings

    // MARK: - 运行状态
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var reasoningText: String = ""
    @Published private(set) var rawText: String = ""
    @Published private(set) var advice: Advice?
    @Published private(set) var lastShot: NSImage?
    @Published private(set) var shotInfo: String = ""
    @Published private(set) var lastJPEG: Data?
    @Published private(set) var usage: UsageInfo?
    @Published private(set) var elapsed: Double = 0
    @Published var showReasoning: Bool = false
    @Published var showRaw: Bool = false
    @Published var showImage: Bool = false

    // MARK: - 手牌（识别 + 修正）
    @Published private(set) var recognizedHand: [String] = []
    /// 发给模型的提示词原文（system + user），供界面展示核对（2026-10-10）
    @Published private(set) var llmPrompt: String = ""
    /// 左上角的**宝牌指示牌**（本地识别）。空数组表示这次没读到。
    @Published private(set) var recognizedDora: [String] = []
    /// 本地（像素级）检测到的、可以确定的事实，会以文字注入提示词。
    /// 目前包含：自己有几组副露、这一轮有没有进张。
    @Published private(set) var localFacts: [String] = []
    /// 玩家副露区的单独裁剪图（放大 2 倍），随分析一起送模型。
    /// 副露平放在桌面上、带透视压缩，整屏下发时模型会整个漏看。
    private var meldCropJPEG: Data?

    /// 自家牌河的**透视校正网格图**（6×3，每格 80×129），随分析一起送模型。
    ///
    /// 牌河是平放在桌面上画的，本地模板匹配校正后仍然只有 1~4/14（手牌是 14/14），
    /// 所以牌名交给模型；但**格子位置与"哪几格有牌"是本地确定性算出来的**，
    /// 并且校正成规整网格后模型读得准得多（实测 21% → 64%）。
    private var riverStripJPEG: Data?
    @Published private(set) var handSource: HandSource = .modelImage
    @Published private(set) var handProgress: (done: Int, total: Int)?
    @Published private(set) var segmentationNote: String?
    /// 切出来的单张牌缩略图，给用户核对切分对不对
    @Published private(set) var tileThumbnails: [NSImage] = []
    @Published private(set) var hasSegmentedTiles = false
    /// 手牌是否被用户改过（决定要不要显示「重算」按钮）
    @Published private(set) var handDirty = false

    /// 分析流程识别完成后回调（把结果交给 OverlayController 展示右栏 + 图层）
    var onRecognition: ((OverlayResult) -> Void)?

    // MARK: - 截图来源
    @Published private(set) var windows: [CapturableWindow] = []
    @Published private(set) var isLoadingWindows = false
    @Published private(set) var windowError: String?
    @Published private(set) var permissionGranted = ScreenPermission.isGranted
    @Published private(set) var repairMessage: String?

    private var runTask: Task<Void, Never>?
    private var ticker: Task<Void, Never>?
    private var startedAt: Date?
    /// 上一次抓到的图，供「改牌后重算」复用 —— 重新截图会截到另一个局面，改的牌就对不上了
    private var lastCapture: (jpeg: Data, cg: CGImage)?

    private init() {
        settings = ConfigStore.shared.settings
        Theme.tileScaleLevel = settings.tileScale
        Theme.isGlass = settings.panelBackground == "glass"
    }

    // MARK: - 派生状态

    var selectedWindow: CapturableWindow? {
        windows.first { $0.id == settings.windowID }
    }

    var sourceDescription: String {
        if !permissionGranted { return "缺少屏幕录制权限" }
        if let w = selectedWindow {
            return w.looksLikeMajsoul ? "\(w.appName) · \(w.title)" : w.label
        }
        if settings.windowID != 0 { return "已保存的窗口不在当前列表中（\(settings.windowLabel)）" }
        return "还没选择截图来源"
    }

    var canAnalyze: Bool {
        permissionGranted && settings.isConfigured && settings.windowID != 0 && !phase.isBusy
    }

    var canReanalyze: Bool { !phase.isBusy && lastCapture != nil && !recognizedHand.isEmpty }

    // MARK: - 设置

    func updateSettings(_ mutate: (inout Settings) -> Void) {
        mutate(&settings)
        ConfigStore.shared.update(mutate)
        Theme.tileScaleLevel = settings.tileScale
        Theme.isGlass = settings.panelBackground == "glass"
        // Overlay 配色主题变化 → 立即重绘（不改的话要等下次识别才换色）
        NotificationCenter.default.post(name: .mhOverlayThemeChanged, object: nil)
    }

    func refreshPermission() {
        permissionGranted = ScreenPermission.isGranted
        // ★ 2026-10-18 用户反馈：点「重新检测」没反应——已授权时原来只重读一遍
        //   布尔值，UI 没有任何变化。现在给明确反馈：成功弹一条 3 秒自动消失的
        //   提示，失败给出下一步动作。
        if permissionGranted {
            let t = DateFormatter()
            t.dateFormat = "HH:mm:ss"
            repairMessage = "✅ 屏幕录制权限正常（检测于 \(t.string(from: Date()))）"
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard let self, let m = self.repairMessage,
                      m.hasPrefix("✅") else { return }
                self.repairMessage = nil
            }
        } else {
            repairMessage = "未检测到屏幕录制权限。点「修复授权」重新申请，或到系统设置里勾选「雀魂助手」。"
        }
    }

    func requestPermission() {
        _ = ScreenPermission.request()
        Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            refreshPermission()
        }
    }

    /// 「修复授权」：清掉属于旧编译版本的那条 TCC 记录，再为当前版本重新申请。
    func repairPermission() {
        let ok = ScreenPermission.resetRecord()
        if ok {
            _ = ScreenPermission.request()
            repairMessage = ScreenPermission.repairInstruction
        } else {
            repairMessage = "自动清理失败。请手动到系统设置 → 录屏与系统录音，选中本 App 后点「−」移除，再重新打开本 App。"
        }
        refreshPermission()
    }

    func clearRepairMessage() { repairMessage = nil }

    // MARK: - 窗口列表

    func refreshWindows(autoPickIfEmpty: Bool = false) async {
        guard permissionGranted else {
            windowError = "需要先授予屏幕录制权限。"
            return
        }
        isLoadingWindows = true
        windowError = nil
        do {
            let list = try await WindowCatalog.list()
            windows = list
            Log.info("窗口列表刷新：\(list.count) 个候选")
            if autoPickIfEmpty, settings.windowID == 0,
               let pick = WindowCatalog.autoPick(from: list) {
                updateSettings {
                    $0.windowID = pick.id
                    $0.windowLabel = pick.label
                }
                Log.info("自动选中截图来源：\(pick.appName) / \(pick.title)")
            }
        } catch {
            windowError = "枚举窗口失败：\(error.localizedDescription)"
            Log.error("枚举窗口失败：\(error)")
        }
        isLoadingWindows = false
    }

    /// 找出雀魂窗口（2026-10-18）：标题或应用名含「雀魂 / Majsoul / Mahjong Soul」
    /// 的窗口（覆盖简繁中、英文客户端）。找不到返回 nil。
    func majsoulWindow() -> CapturableWindow? {
        let keys = ["雀魂", "majsoul", "mahjong soul"]
        return windows.first { w in
            let t = (w.title + " " + w.appName).lowercased()
            return keys.contains { t.contains($0.lowercased()) }
        }
    }


    func select(_ window: CapturableWindow) {
        updateSettings {
            $0.windowID = window.id
            $0.windowLabel = window.label
        }
    }

    // MARK: - 手牌修正

    /// 用户在卡片上直接改手牌（换牌 / 删牌 / 加牌）
    func setHand(_ hand: [String]) {
        let cleaned = hand.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        recognizedHand = cleaned
        handSource = .userCorrected
        handDirty = true
    }

    func replaceHandTile(at index: Int, with notation: String) {
        guard recognizedHand.indices.contains(index) else { return }
        var h = recognizedHand
        h[index] = notation
        setHand(h)
    }

    func removeHandTile(at index: Int) {
        guard recognizedHand.indices.contains(index) else { return }
        var h = recognizedHand
        h.remove(at: index)
        setHand(h)
    }

    func appendHandTile(_ notation: String) {
        setHand(recognizedHand + [notation])
    }

    /// 放弃修正，回到识别结果
    func resetHandToRecognized() {
        if let adv = advice, !(adv.effectiveHand ?? []).isEmpty, handSource == .userCorrected {
            recognizedHand = adv.effectiveHand ?? []
        }
        handDirty = false
    }

    // MARK: - 预览（--snapshot 用）

    func loadPreviewSample(permissionGranted granted: Bool = true,
                           withRepairMessage: Bool = false,
                           handDirty dirty: Bool = false) {
        permissionGranted = granted
        repairMessage = withRepairMessage ? ScreenPermission.repairInstruction : nil
        windows = [CapturableWindow(id: 1136, title: "雀魂麻將", appName: "Safari浏览器",
                                    bundleID: "com.apple.Safari", width: 863, height: 592,
                                    isOnScreen: true)]
        settings.windowID = 1136
        settings.windowLabel = "雀魂麻將"
        settings.expandAdvice = true // 快照验证展开态
        advice = AdvicePreview.sample
        rawText = AdvicePreview.rawSample
        reasoningText = AdvicePreview.reasoningSample
        usage = UsageInfo(promptTokens: 1698, completionTokens: 500, reasoningTokens: 0)
        elapsed = 3.4
        shotInfo = "2048×1229 · 432 KB"
        recognizedHand = AdvicePreview.sample.effectiveHand ?? []
        handSource = .tileSegment
        hasSegmentedTiles = true
        tileThumbnails = []
        handDirty = dirty
        phase = .done
    }

    // MARK: - 分析

    func analyze(deep: Bool) {
        guard !phase.isBusy else { return }
        guard permissionGranted else {
            phase = .failed("缺少屏幕录制权限，请在「系统设置 → 隐私与安全性 → 屏幕与系统音频录制」里勾选本 App。")
            return
        }
        guard settings.isConfigured else {
            phase = .failed("还没填 DeepSeek API Key，打开设置填一下。")
            return
        }
        guard settings.windowID != 0 else {
            phase = .failed("还没选截图来源，点上面的「选择窗口」。")
            return
        }

        resetForRun()
        let s = settings
        phase = .capturing
        startedAt = Date()

        runTask = Task { [weak self] in
            guard let self else { return }
            do {
                let shot = try await ScreenCaptureService.capture(windowID: s.windowID,
                                                                  maxSide: 2400,
                                                                  jpegQuality: 0.92)
                self.accept(shot: shot)
                // ★ 数据流统一（2026-10-10）：截图 → Python overlay_cli 识别
                //   （手牌/副露/牌河/宝牌一次出全），结果以文本喂 LLM。
                let ts: Double = Date().timeIntervalSince1970
                let tmp: URL = URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("mjh-analyze-" + String(Int(ts)) + ".jpg")
                try shot.jpeg.write(to: tmp)
                let rec = try await OverlayEngine.run(imagePath: tmp.path)
                try? FileManager.default.removeItem(at: tmp)

                let handTiles = rec.hand?.tiles ?? []
                self.recognizedHand = handTiles.compactMap { $0.name }   // 界面：纯牌名
                self.recognizedDora = rec.dora?.dora ?? []
                self.localFacts = Self.facts(from: rec)
                self.handSource = .tileSegment
                self.onRecognition?(rec)          // 右栏 + 图层展示识别结果
                // 喂 LLM 的手牌：摸排牌加「·摸」后缀（提示词已约定该记法）
                let handForLLM = handTiles.map { ($0.name ?? "?") + ($0.isDrawn ? "·摸" : "") }
                try await self.runAnalysis(settings: s,
                                           hand: handForLLM.isEmpty ? nil : handForLLM,
                                           deep: deep)
            } catch {
                self.stopTicker()
                let msg = Log.redact(error.localizedDescription)
                // ★ 窗口不存在时，截图来源区已在提示「已保存的窗口不在当前列表中」——
                //   别再弹第二个「找不到窗口 xx」的错误，去重（2026-10-12 用户反馈）
                if selectedWindow == nil, settings.windowID != 0 {
                    self.phase = .failed("请重新选择截图来源")
                    Log.error("分析失败（窗口不在列表）：\(msg)")
                } else {
                    self.phase = .failed(msg)
                    Log.error("分析失败：\(msg)")
                }
            }
        }
    }

    /// 从识别结果构造「牌河 + 副露」文本事实（喂给 LLM）。
    /// 副露组语义：吃/碰/杠 + 横牌位置（被鸣的牌）+ 暗杠。
    /// 横牌 = isRotated 的牌，在组内的位置代表从谁家鸣（日麻摆法，
    /// 第 1 张横=从左家(上家)、第 2 张横=从对面、第 3 张横=从右家(下家)）。
    /// 暗杠 = 4 张且全部没认出牌名（牌背朝上）。
    static func meldKind(_ tiles: [OverlayMeldTile]) -> String {
        // ★ 暗杠（2026-10-18）：Python 只识别中间 2 张明牌并标 kan——
        //   必须放在「吃/碰/杠」的判断之前，否则 2 张会被当成吃。
        if tiles.contains(where: { $0.isKan }) { return "暗杠" }
        let known = tiles.compactMap { $0.name }
        let n = tiles.count
        if n == 4 && known.isEmpty { return "暗杠，牌面朝下" }
        let horiz = tiles.enumerated().filter { $0.element.isRotated }.map { $0.offset + 1 }
        let htxt = horiz.isEmpty ? "" : "，第\(horiz.map(String.init).joined(separator: "、"))张横放"
        if n == 4 { return "杠" + htxt }
        if Set(known).count == 1 && known.count >= 2 { return "碰" + htxt }
        return "吃" + htxt
    }

    static func facts(from r: OverlayResult) -> [String] {
        var facts: [String] = []
        for seat in r.seats where !seat.tiles.isEmpty {
            let names = seat.tiles.map { ($0.name ?? "?") + ($0.isRiichi ? "(立直)" : "") }
            facts.append("\(seat.cnName)牌河\(seat.tiles.count)张：\(names.joined(separator: " "))")
        }
        let seatNames = ["own": "自家", "across": "对家", "left": "上家", "right": "下家"]
        for key in ["own", "across", "left", "right"] {
            guard let m = r.melds[key], !m.groups.isEmpty else { continue }
            for g in m.groups {
                let names = g.map { $0.name ?? "?" }.joined(separator: " ")
                facts.append("\(seatNames[key] ?? key)副露：\(names)（\(Self.meldKind(g))）")
            }
        }
        return facts
    }

    /// 用用户修正后的手牌重算。**复用上一次的截图** ——
    /// 用户是在看到上一次结果之后才改牌的，重新截图会截到另一个局面，改的牌就对不上了。
    /// ★ 2026-10-10 已停用：手牌修正框删除，识别结果直接采纳切分识别的。
    func reanalyze(with hand: [String]) {
        _ = hand   // 保留接口（历史调用点已移除），不再重算
    }

    func cancel() {
        runTask?.cancel()
        runTask = nil
        stopTicker()
        phase = .idle
        Log.info("用户取消分析")
    }

    // MARK: - 内部流程

    private func resetForRun() {
        reasoningText = ""
        rawText = ""
        advice = nil
        usage = nil
        elapsed = 0
        showReasoning = false
        showRaw = false
        llmPrompt = ""
        recognizedHand = []
        recognizedDora = []
        localFacts = []
        meldCropJPEG = nil
        riverStripJPEG = nil
        handProgress = nil
        segmentationNote = nil
        tileThumbnails = []
        hasSegmentedTiles = false
        handDirty = false
    }

    /// 第一段：把手牌行切成单张，逐张独立识别。
    /// 切分失败返回 nil，此时主分析不带 knownHand，退化成"模型自己从整屏读"。
    private func recognizeHand(settings s: Settings, shot: ScreenCaptureService.Shot) async -> [String]? {
        // 切分必须用**编码前的干净位图** —— 见 TileSegmenter.segment(cg:) 的说明：
        // 用 JPEG 切分、用位图裁牌，两者像素不一致会把赤五索判成普通五索。
        switch TileSegmenter.segment(cg: shot.cgImage) {
        case .failure(let e):
            let why = e.errorDescription ?? "未知原因"
            segmentationNote = "手牌切分失败（\(why)），本次由模型直接从整屏读取手牌，准确率会明显下降，建议事后核对并修正。"
            Log.warn("手牌切分失败：\(why)")
            return nil

        case .success(let seg):
            let cgTiles = TileSegmenter.tileCGImages(from: shot.cgImage, result: seg)
            Log.info(String(format: "手牌切分成功：%d 张，牌宽 %.1fpx，周期性 %.3f",
                            seg.count, seg.pitch, seg.correlation))
            guard !cgTiles.isEmpty else { return nil }

            hasSegmentedTiles = true
            tileThumbnails = cgTiles.map {
                NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height))
            }
            handProgress = nil
            phase = .readingHand

            // 用**雀魂自己的牌面素材**（ui.png + ui.atlas）做模板匹配。
            // 实测：素材自检 37/37、两张真机截图 14/14 —— 比让模型逐张识牌（74~85%）稳得多，
            // 而且纯本地、毫秒级、不花 token。
            guard TileTemplateMatcher.isAvailable else {
                segmentationNote = "牌面素材（ui.png / ui.atlas）没找到，本次回退到整屏读取，准确率会明显下降。"
                Log.warn("模板匹配不可用，回退整屏读取")
                return nil
            }

            // 一次把全部手牌认掉（内部按牌并行）
            let matches = TileTemplateMatcher.identifyAll(cgTiles)
            var names: [String] = []
            var uncertain: [String] = []
            for (i, m) in matches.enumerated() {
                if let m, m.score >= TileTemplateMatcher.minAcceptableScore {
                    names.append(m.name)
                    Log.info(String(format: "  牌 #%2d → %@  匹配 %.2f（次选 %@ %.2f，差 %.2f，红占比 %.2f）",
                                    i + 1, m.name, m.score, m.runnerUp, m.runnerUpScore,
                                    m.margin, m.redRatio))
                } else {
                    // 切分已经按"牌块"分过了，所以这里认不出就是真认不出（不是摸牌位空槽）
                    names.append("?")
                    uncertain.append("第 \(i + 1) 张")
                    Log.warn(String(format: "  牌 #%2d 未匹配（最高 %.2f）→ 标记为 ?", i + 1, m?.score ?? 0))
                }
            }

            // ---- 本地检测到的、可以确定的事实 ----
            //
            // 这些是**像素级确定性**的（切分按牌块分出来的），比模型看整屏靠谱，
            // 所以直接以文字注入提示词，免得模型自己数错手上的牌数。
            var facts: [String] = []
            if seg.meldGroups > 0 {
                facts.append("玩家自己已有 **\(seg.meldGroups) 组副露**（碰/吃/杠），共 \(seg.meldTiles) 张牌，"
                    + "摆在画面右下手牌区的右侧、平放在桌面上（有透视、比手牌小）。"
                    + "请从图中读出这些副露分别是哪几张牌。"
                    + "**注意：因为已有副露，玩家手上的暗牌只有 \(seg.concealedRects.count) 张，不是 13 张**，这是正常的。")
            }
            if seg.drawnRect == nil {
                facts.append("玩家这一轮**没有进张**（刚碰/吃完直接出牌，手上没有刚摸的那张），"
                    + "所以上面列出的是全部手牌；出牌后手上的牌会比现在少一张。")
            }

            var notes: [String] = []
            if !uncertain.isEmpty {
                notes.append("\(uncertain.joined(separator: "、"))没认出来，标成了 ?，请手改")
            }
            if seg.meldGroups > 0 {
                notes.append("已本地检测出 \(seg.meldGroups) 组副露（摆在桌面上带透视，副露的牌名未做本地识别）")
            }
            if !notes.isEmpty { segmentationNote = notes.joined(separator: "；") }

            recognizedHand = names
            localFacts = facts
            handSource = .tileSegment

            // ---- 副露区单独裁一张放大图，随分析一起送模型 ----
            //
            // 副露是平放在桌面上的（带透视压缩，纵向只有手牌的 ~55%），整屏下发时
            // 模型会直接漏看（实测它回答"全场均未副露"，而玩家明明有两个碰）。
            // 裁成一块单独送，它才读得出来。
            meldCropJPEG = nil
            if seg.meldBlock != nil {
                meldCropJPEG = TileSegmenter.meldCrop(from: shot.cgImage, result: seg)
                if let d = meldCropJPEG {
                    Log.info(String(format: "副露区已裁图送模型：%d KB（副露牌宽 %.1f / 实际高 %.1f，纵向已还原）",
                                    d.count / 1024, seg.meldTileWidth, seg.meldTileHeight))
                }
            }

            // ---- 四家牌河：**本地识牌**（不走模型、不花 token）----
            //
            // 牌河是平放在桌面上画的（自家纵向被透视压扁 ~0.69、还带错切；
            // 上家/下家的牌在屏幕上还**转了 90°**），整张牌的模板匹配在这里只有
            // 1~4/14。换成「只比白纸牌面 + 按实测比例缩放模板 + 用 NCC」之后，
            // 自家牌河实测 13 张位置全对、牌名对 9 张。剩下没认出来的多是
            // "同花色差一档"（6s→7s），是 ~60px 宽牌面的分辨率天花板。
            //
            // 三家机器的几何还没逐张标定，所以带上"置信度"：只有够高的才当成事实写进
            // 提示词，低的一律标注"本地不太确定"，让模型以全屏图为准。
            riverStripJPEG = nil
            let rivers = RiverReader.readAll(from: shot.cgImage, canvas: seg.canvas)
            for r in rivers where r.occupied > 0 {
                let names = r.flat
                if r.isTrustworthy, !names.isEmpty {
                    facts.append("\(r.seat)牌河\(r.occupied)张：\(names.joined(separator: " "))")
                } else {
                    // 名字不可信时只报张数，牌名让模型自己看图（张数确定性高）
                    facts.append("\(r.seat)牌河已打 \(r.occupied) 张（牌名未认准）")
                }
                Log.info("\(r.seat)牌河：本地认出 \(r.recognized)/\(r.occupied) 张，置信 "
                         + String(format: "%.2f", r.confidence) + " → \(names.joined(separator: " "))")
            }
            if rivers.isEmpty { Log.warn("牌河：四家都没读出内容") }

            // ---- 副露（碰/吃/杠）：本地识牌 ----
            //
            // 副露的牌是**斜着靠在桌沿、紧贴但不叠压**地摆的，所以：
            //   ① 切分 = 白纸掩膜 → 补洞 → 连通域（每块一张牌，实测张数全对）
            //   ② 识别 = 图案框限制在「本块连通域腐蚀 2px」内 → 归一化 → NCC
            //      ★ 副露的绿边很宽（占掩膜 21%，牌河只有 5%），不限制的话整圈绿边
            //        会被当墨，图案框膨胀成整个方块，NCC 掉到 0.2。
            //   ③ 上家/下家的副露是**侧对屏幕**的（只看得到绿侧板 + 一条白边），
            //      物理上不可读 —— 只报张数。
            // ---- 副露（碰/吃/杠）：本地识牌 ----
            //
            // 副露的牌**斜着靠在桌沿、紧贴但不叠压**：
            //   ① 切分 = 白纸掩膜 → 补洞 → 连通域（每块一张牌，实测张数全对）
            //   ② 识别 = 图案框限制在「本块连通域腐蚀 2px」内 → 归一化 → NCC
            //      ★ 副露的绿边很宽（占掩膜 21%，牌河只有 5%），不限制的话整圈绿边
            //        会被当墨，图案框膨胀成整个方块，NCC 从 0.4 掉到 0.2。
            //   ③ 上家/下家的副露**侧对屏幕**（只看得到绿侧板 + 一条白边），
            //      物理上不可读 —— 只报张数。
            for f in MeldReader.localFacts(cgImage: shot.cgImage, canvas: seg.canvas) {
                facts.append(f)
                Log.info("副露：\(f)")
            }

            Log.info("模板匹配结果（\(names.count) 张）：\(names.joined(separator: " "))")
            for f in facts { Log.info("本地事实：\(f)") }

            // 左上角的**宝牌指示牌**：本地读，换算成宝牌后喂给模型
            // （模型自己看整屏时会把指示牌读错，实测这张图它说成 6s，实际是 8s；
            //   且宝牌 = 指示牌下一张，别让模型再算一遍）
            let dora = DoraReader.read(from: shot.cgImage, tileWidth: seg.pitch)
            for d in dora.debug { Log.info(d) }
            recognizedDora = dora.indicators.compactMap { PromptTemplate.doraOf($0) }
            if !recognizedDora.isEmpty {
                Log.info("宝牌（本地）：\(recognizedDora.joined(separator: " "))")
            } else if let n = dora.note {
                Log.warn("宝牌指示牌没读到：\(n)")
            }
            return names
        }
    }

    /// 第二段：带上（已确认的）手牌 + 本地识别事实做策略分析。纯文本，不发图。
    private func runAnalysis(settings s: Settings, hand: [String]?, deep: Bool) async throws {
        phase = .thinking
        startTicker()
        let effort = deep ? s.deepEffort : s.quickEffort
        let maxTokens = deep ? s.deepMaxTokens : s.quickMaxTokens

        let result = try await DeepSeekClient.stream(settings: s,
                                                     effort: effort,
                                                     maxTokens: maxTokens,
                                                     deep: deep,
                                                     knownHand: hand,
                                                     knownDora: recognizedDora.isEmpty ? nil : recognizedDora,
                                                     localFacts: localFacts,
                                                     onPrompt: { [weak self] p in
            self?.llmPrompt = p
        }) { delta in
            await self.applyDelta(delta)
        }
        stopTicker()
        finish(result: result, mode: deep ? "deep" : "quick", knownHand: hand)
    }

    private func setHandProgress(_ done: Int, _ total: Int) {
        handProgress = (done, total)
    }

    private func accept(shot: ScreenCaptureService.Shot) {
        lastShot = shot.preview
        lastJPEG = shot.jpeg
        shotInfo = "\(shot.pixelWidth)×\(shot.pixelHeight) · \(shot.byteCount / 1024) KB"
        // 截图拿到就该进下一阶段：识别引擎要跑几百毫秒，
        // 停留在「截图中」会让人以为截图卡住了。
        phase = .readingHand
        Log.info("截图完成 \(shotInfo)")
    }

    func openLastShotInPreview() {
        guard let data = lastJPEG else { return }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("majsoul-helper-shot-\(Int(Date().timeIntervalSince1970)).jpg")
        do {
            try data.write(to: url)
            NSWorkspace.shared.open(url)
        } catch {
            Log.error("导出截图失败：\(error.localizedDescription)")
        }
    }

    private func applyDelta(_ d: DeepSeekClient.StreamDelta) {
        if let r = d.reasoning, !r.isEmpty { reasoningText += r }
        if let c = d.content, !c.isEmpty {
            if phase != .writing { phase = .writing }
            rawText += c
        }
    }

    private func finish(result: DeepSeekClient.StreamResult, mode: String, knownHand: [String]?) {
        elapsed = result.elapsed
        usage = result.usage
        rawText = result.content
        advice = AdviceParser.parse(result.content)
        phase = .done
        Log.info("分析完成 mode=\(mode) 耗时=\(String(format: "%.1f", result.elapsed))s advice=\(advice != nil ? "已解析" : "未能解析 JSON")")

        // 逐张识牌的结果优先：让模型回填 hand 字段时它可能又"顺手改"了
        if let h = knownHand, !h.isEmpty, handSource != .userCorrected {
            recognizedHand = h
        } else if recognizedHand.isEmpty, let h = advice?.effectiveHand, !h.isEmpty {
            recognizedHand = h
            handSource = .modelImage
        }

        guard let ad = advice else { return }
        ConfigStore.shared.appendHistory(HistoryRecord(
            at: Date(),
            mode: mode,
            elapsed: result.elapsed,
            turn: ad.effectiveTurn,
            hand: recognizedHand.isEmpty ? ad.effectiveHand : recognizedHand,
            recommendedTile: ad.recommended?.tile,
            confidence: ad.recommended?.confidence,
            reason: ad.reason,
            dangerLevel: ad.danger?.level,
            lesson: ad.lesson,
            promptTokens: result.usage?.promptTokens,
            completionTokens: result.usage?.completionTokens
        ))
    }

    private func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard let self, let t0 = self.startedAt else { continue }
                self.elapsed = Date().timeIntervalSince(t0)
            }
        }
    }

    private func stopTicker() {
        ticker?.cancel()
        ticker = nil
    }
}
