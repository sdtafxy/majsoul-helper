import Foundation
import AppKit

/// 无界面自测。用途：把「枚举窗口 → 截图 → 编码 → 请求 → 解析」整条链路在命令行跑通，
/// 不依赖任何鼠标操作，也不弹窗。这样代码改完可以先在这里验证，再交给人工验收界面。
///
///   MajsoulHelper --selftest                 完整链路（自动挑窗口截图 → 快速档分析）
///   MajsoulHelper --selftest --deep          用深度档
///   MajsoulHelper --selftest --list          只列出可捕获窗口
///   MajsoulHelper --selftest --image a.jpg   用指定图片，跳过截图
///   MajsoulHelper --selftest --show-reasoning 把模型的思考过程也打出来
///   MajsoulHelper --selftest --capture-only out.jpg
///                                            只截图存盘，不调用任何接口
enum SelfTest {

    static func run() {
        setvbuf(stdout, nil, _IONBF, 0)
        // 关键：先碰一下 NSApplication。
        // 直接执行 .app 里的可执行文件时，进程还没和窗口服务器建立连接，
        // 后面调 ScreenCaptureKit 会撞上 `CGS_REQUIRE_INIT` 断言直接 SIGABRT。
        // （跑 .build/debug 下的裸二进制反而不触发，因为没被 LaunchServices 注册成 GUI 应用。）
        //
        // ⚠️ 但**纯计算的子命令不能碰它**：在沙箱/无窗口服务的终端里，
        // `NSApplication.shared` 会一直阻塞在连窗口服务器的 mach 端口上
        // （表现：进程活着、CPU 0%、一个字都不输出）。踩过这个坑。
        // ★ 纯计算子命令**绝不能**碰 NSApplication：没窗口服务时会一直阻塞在
        //   mach 端口连接上（进程活着、CPU 0%、一个字都不输出）。踩过。
        //   新增子命令时必须同时加进这里和 main.swift 的 headlessCommands。
        let pureCommands = ["--river", "--meld", "--overlay",
                            "--debug-tiles", "--tiles-robustness", "--selftest"]
        let headless = pureCommands.contains { CommandLine.arguments.contains($0) }
        if !headless {
            _ = NSApplication.shared
            NSApplication.shared.setActivationPolicy(.accessory)
        }
        // 输出别攒着：重定向到文件时 stdout 是块缓冲的，卡住就什么都看不到
        setvbuf(stdout, nil, _IONBF, 0)

        Task {
            let code = await perform()
            exit(code)
        }
        dispatchMain()   // 常驻，靠上面的 exit 结束
    }

    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var _reasoning = ""
        private var _content = ""
        var reasoning: String { lock.lock(); defer { lock.unlock() }; return _reasoning }
        var content: String { lock.lock(); defer { lock.unlock() }; return _content }
        func append(reasoning r: String?, content c: String?) {
            lock.lock(); defer { lock.unlock() }
            if let r { _reasoning += r }
            if let c { _content += c }
        }
    }

    static func perform() async -> Int32 {
        let args = CommandLine.arguments
        let s = ConfigStore.shared.settings

        print("========== 雀魂助手 · 自测 ==========")
        print("配置目录    : \(ConfigStore.shared.dirURL.path)")
        print("配置文件    : \(FileManager.default.fileExists(atPath: ConfigStore.shared.configURL.path) ? "存在" : "不存在（将用默认值）")")
        print("API Key     : \(s.apiKey.isEmpty ? "未设置 ❌" : "已设置，长度 \(s.apiKey.count) ✅")")
        print("模型        : \(s.model)   接口: \(s.baseURL)")
        print("档位        : 快速=\(s.quickEffort)(上限\(s.quickMaxTokens))  深度=\(s.deepEffort)(上限\(s.deepMaxTokens))")
        print("屏幕录制权限: \(ScreenPermission.isGranted ? "已授予 ✅" : "未授予 ❌")")
        print("")

        // ---- 切分尺寸鲁棒性：同一张图缩放到不同大小，看还认不认得出 ----
        if let idx = args.firstIndex(of: "--tiles-robustness"), idx + 1 < args.count {
            return debugRobustness(path: args[idx + 1])
        }

        // ---- 只切牌、不调接口：验证手牌切分是否准确 ----
        if let idx = args.firstIndex(of: "--debug-tiles"), idx + 1 < args.count {
            let path = args[idx + 1]
            let outDir = (idx + 2 < args.count && !args[idx + 2].hasPrefix("--"))
                ? args[idx + 2] : NSTemporaryDirectory() + "majsoul-tiles"
            guard let data = FileManager.default.contents(atPath: path) else {
                print("读不到图片: \(path)"); return 1
            }
            return debugTiles(jpeg: data, outDir: outDir)
        }

        // ---- 只读牌河：验证四家牌河的本地识别 ----
        if let idx = args.firstIndex(of: "--river"), idx + 1 < args.count {
            let outDir = (idx + 2 < args.count && !args[idx + 2].hasPrefix("--"))
                ? args[idx + 2] : NSTemporaryDirectory() + "majsoul-river"
            return debugRiver(path: args[idx + 1], outDir: outDir)
        }

        // ---- Overlay 链路：给定图片 → 切分+识别 → 画出图层会画的东西 ----
        if let idx = args.firstIndex(of: "--overlay"), idx + 1 < args.count {
            let outDir = (idx + 2 < args.count && !args[idx + 2].hasPrefix("--"))
                ? args[idx + 2] : NSTemporaryDirectory() + "majsoul-overlay"
            return await OverlaySelfTest.run(imagePath: args[idx + 1], outDir: outDir)
        }

        // ---- 只读副露：验证四家副露的本地识别 ----
        if let idx = args.firstIndex(of: "--meld"), idx + 1 < args.count {
            return await debugMeld(path: args[idx + 1])
        }

        // ---- 只列窗口 ----
        if args.contains("--list") {
            guard ScreenPermission.isGranted else {
                print("没有屏幕录制权限，无法枚举窗口。")
                return 1
            }
            do {
                let list = try await WindowCatalog.list()
                print("可捕获窗口 \(list.count) 个：")
                for w in list.prefix(30) {
                    var flags: [String] = []
                    if w.priority == 0 { flags.append("雀魂✓") }
                    else if w.priority == 1 { flags.append("疑似") }
                    if w.isBrowser { flags.append("浏览器") }
                    flags.append(w.isOnScreen ? "在屏" : "离屏")
                    flags.append("优先级\(w.priority)")
                    let app = w.appName.padding(toLength: 22, withPad: " ", startingAt: 0)
                    print("  [\(w.id)] \(app) \(w.width)x\(w.height)  \(flags.joined(separator: ","))")
                    if !w.title.isEmpty { print("            标题: \(w.title)") }
                }
                if let pick = WindowCatalog.autoPick(from: list) {
                    print("\n自动挑中的窗口: [\(pick.id)] \(pick.appName) / \(pick.title)")
                } else {
                    print("\n没有自动挑中任何窗口。")
                }
            } catch {
                print("枚举窗口失败: \(error)")
                return 1
            }
            return 0
        }

        // ---- 取图 ----
        var jpeg: Data
        var cg: CGImage?
        var sourceDesc: String

        if let idx = args.firstIndex(of: "--image"), idx + 1 < args.count {
            let path = args[idx + 1]
            guard let d = loadJPEG(path: path, quality: s.jpegQuality) else {
                print("读不到图片: \(path)")
                return 1
            }
            jpeg = d
            cg = loadCGImage(path: path)
            sourceDesc = "文件 \(path)"
        } else {
            guard ScreenPermission.isGranted else {
                print("没有屏幕录制权限，无法截图。请到「系统设置 → 隐私与安全性 → 屏幕与系统音频录制」勾选本 App，然后重启 App。")
                return 1
            }
            let t0 = Date()
            do {
                let list = try await WindowCatalog.list()
                var target = list.first { $0.id == s.windowID }
                if target == nil { target = WindowCatalog.autoPick(from: list) }

                if let t = target {
                    let shot = try await ScreenCaptureService.capture(windowID: t.id,
                                                                     maxSide: s.maxImageSide,
                                                                     jpegQuality: s.jpegQuality)
                    jpeg = shot.jpeg
                    cg = shot.cgImage
                    sourceDesc = "窗口 [\(t.id)] \(t.appName) / \(t.title)"
                    print(String(format: "截图完成 %.2fs  %dx%d  %d KB", Date().timeIntervalSince(t0), shot.pixelWidth, shot.pixelHeight, shot.byteCount / 1024))
                } else {
                    print("没找到可用窗口，退回整屏捕获。")
                    let shot = try await ScreenCaptureService.captureDisplay(maxSide: s.maxImageSide,
                                                                            jpegQuality: s.jpegQuality)
                    jpeg = shot.jpeg
                    cg = shot.cgImage
                    sourceDesc = "整屏（兜底）"
                    print(String(format: "截图完成 %.2fs  %dx%d  %d KB", Date().timeIntervalSince(t0), shot.pixelWidth, shot.pixelHeight, shot.byteCount / 1024))
                }
            } catch {
                print("截图失败: \(error.localizedDescription)")
                return 1
            }
        }

        print("图片来源    : \(sourceDesc)")
        print("送图大小    : \(jpeg.count / 1024) KB")
        print("")

        // ---- 只截图落盘，不调 API（用来验证截图链路，且不把画面发到任何地方）----
        if let idx = args.firstIndex(of: "--capture-only") {
            let out = (idx + 1 < args.count && !args[idx + 1].hasPrefix("--"))
                ? args[idx + 1]
                : (NSTemporaryDirectory() + "majsoul-helper-capture.jpg")
            do {
                try jpeg.write(to: URL(fileURLWithPath: out))
                print("✅ 已保存截图（未调用任何接口）：\(out)")
            } catch {
                print("❌ 保存失败：\(error.localizedDescription)")
                return 1
            }
            return 0
        }

        // ---- 切分 + 逐张识牌（与 App 主流程一致）----
        var knownHand: [String]?
        var knownDora: [String]?
        var localFacts: [String] = []
        var meldCrop: Data?
        var riverStrip: Data?
        if !args.contains("--skip-tiles") {
            if let cg {
                // 必须与裁牌同一张图：用干净位图切分，不要用 JPEG
                switch TileSegmenter.segment(cg: cg) {
                case .failure(let e):
                    print("手牌切分：❌ 失败（\(e.errorDescription ?? "未知")）→ 本次退化为整屏读取")
                case .success(let seg):
                    print(String(format: "手牌切分：✅ %d 张  牌宽 %.1fpx  周期性 %.3f",
                                 seg.count, seg.pitch, seg.correlation))
                    // 走**与 App 完全一致的路径**：本地模板匹配，不调模型
                    let cgTiles = TileSegmenter.tileCGImages(from: cg, result: seg)
                    guard TileTemplateMatcher.isAvailable else {
                        print("模板匹配：❌ 素材 ui.png / ui.atlas 没找到")
                        return 1
                    }
                    print("模板匹配 \(cgTiles.count) 张（本地，不调模型）…")
                    let tStart = Date()
                    var names: [String] = []
                    var weak: [String] = []
                    for (i, m) in TileTemplateMatcher.identifyAll(cgTiles).enumerated() {
                        guard let m, m.score >= TileTemplateMatcher.minAcceptableScore else {
                            weak.append("#\(i + 1)")
                            continue
                        }
                        names.append(m.name)
                    }
                    if !weak.isEmpty {
                        print("   低于门槛（按空槽/认不出处理）：\(weak.joined(separator: "、"))")
                    }
                    knownHand = names
                    print(String(format: "模板匹配：%.2fs  %@",
                                 Date().timeIntervalSince(tStart), names.joined(separator: " ")))
                    if let expect = args.firstIndex(of: "--expect"), expect + 1 < args.count {
                        let truth = args[expect + 1].split(separator: " ").map(String.init)
                        let right = zip(names, truth).filter { $0 == $1 }.count
                        print("对照真值：正确 \(right)/\(truth.count)")
                        for (i, (a, b)) in zip(names, truth).enumerated() where a != b {
                            print("   #\(i + 1) 读成 \(a)，实际 \(b)")
                        }
                    }

                    // ---- 宝牌指示牌（左上角面板，本地读）----
                    let dora = DoraReader.read(from: cg, tileWidth: seg.pitch)
                    for d in dora.debug { print("   " + d) }
                    if !dora.indicators.isEmpty {
                        knownDora = dora.indicators
                        print("宝牌指示牌：\(dora.indicators.joined(separator: " "))")
                    }
                    if let n = dora.note { print("   ⚠️ \(n)") }

                    // ---- 副露区 / 进张：与 App 一致的本地事实 ----
                    if seg.meldGroups > 0 {
                        localFacts.append("玩家自己已有 **\(seg.meldGroups) 组副露**（碰/吃/杠），共 \(seg.meldTiles) 张牌，"
                            + "摆在画面右下手牌区的右侧、平放在桌面上。"
                            + "**注意：因为已有副露，玩家手上的暗牌只有 \(seg.concealedRects.count) 张，不是 13 张**。")
                    }
                    if seg.drawnRect == nil {
                        localFacts.append("玩家这一轮**没有进张**（刚碰/吃完直接出牌），所以上面是全部手牌。")
                    }
                    if seg.meldBlock != nil {
                        meldCrop = TileSegmenter.meldCrop(from: cg, result: seg)
                        if let d = meldCrop {
                            print(String(format: "副露裁剪图：%d KB（副露牌宽 %.1f / 实际高 %.1f，纵向已还原到 80:129）",
                                         d.count / 1024, seg.meldTileWidth, seg.meldTileHeight))
                        }
                    }
                    for f in localFacts { print("本地事实：\(f)") }

                    // ---- 四家牌河：本地识牌 ----
                    let rivers = RiverReader.readAll(from: cg, canvas: seg.canvas)
                    for r in rivers where r.occupied > 0 {
                        localFacts.append("\(r.seat)牌河共 \(r.occupied) 张：\(r.flat.joined(separator: " "))")
                        print("\(r.seat)牌河：本地认出 \(r.recognized)/\(r.occupied) 张 → "
                              + r.flat.joined(separator: " "))
                    }
                    if let ownRiver = rivers.first, let s = ownRiver.strip {
                        riverStrip = TileSegmenter.jpeg(from: s)
                        let path = "/tmp/m9/river-strip.png"
                        try? FileManager.default.createDirectory(atPath: "/tmp/m9",
                                                                 withIntermediateDirectories: true)
                        if let rep = NSBitmapImageRep(cgImage: s).representation(using: .png, properties: [:]) {
                            try? rep.write(to: URL(fileURLWithPath: path))
                            print("   自家牌河格子图 → \(path)")
                        }
                    }
                    for r in rivers where r.strip != nil {
                        let path = "/tmp/m9/river-\(r.seat).png"
                        try? FileManager.default.createDirectory(atPath: "/tmp/m9",
                                                                 withIntermediateDirectories: true)
                        if let rep = NSBitmapImageRep(cgImage: r.strip!).representation(using: .png, properties: [:]) {
                            try? rep.write(to: URL(fileURLWithPath: path))
                        }
                    }
                }
            }
            print("")
        }

        // ---- 调模型 ----
        guard s.isConfigured else {
            print("没有 API Key，跳过模型调用。")
            return 1
        }
        let deep = args.contains("--deep")
        let sink = Sink()
        do {
            let result = try await DeepSeekClient.stream(
                settings: s,
                effort: deep ? s.deepEffort : s.quickEffort,
                maxTokens: deep ? s.deepMaxTokens : s.quickMaxTokens,
                deep: deep,
                knownHand: knownHand,
                knownDora: knownDora,
                localFacts: localFacts
            ) { delta in
                sink.append(reasoning: delta.reasoning, content: delta.content)
            }

            print(String(format: "====== 分析完成 %.2fs（档位 %@ / 上限 %d）======",
                         result.elapsed, deep ? s.deepEffort : s.quickEffort,
                         deep ? s.deepMaxTokens : s.quickMaxTokens))
            if let u = result.usage {
                print("用量: 输入 \(u.promptTokens) · 输出 \(u.completionTokens)（含思考 \(u.reasoningTokens)）")
            }
            print("思考过程长度: \(sink.reasoning.count) 字")
            if args.contains("--show-reasoning") {
                print("--- 思考过程 ---")
                print(sink.reasoning)
                print("--- 思考过程结束 ---")
            }
            print("")
            print("--- 模型输出 ---")
            print(result.content)
            print("--- 输出结束 ---")
            print("")

            if let advice = AdviceParser.parse(result.content) {
                print("✅ JSON 解析成功")
                let hand = advice.effectiveHand?.joined(separator: " ") ?? "—"
                print("  手牌    : \(hand)  （\(advice.effectiveHand?.count ?? 0) 张）")
                if let m = advice.effectiveMelds { print("  副露    : \(m.joined(separator: " "))") }
                if let d = advice.effectiveDora { print("  宝牌指示: \(d.joined(separator: " "))") }
                print("  轮次    : \(advice.effectiveTurn ?? "—")")
                print("  推荐    : \(advice.recommended?.action ?? "打") \(advice.recommended?.tile ?? "—")  (把握 \(advice.recommended?.confidence ?? "—"))")
                print("  理由    : \(advice.reason ?? "—")")
                print("  危险    : [\(advice.danger?.level ?? "—")] \(advice.danger?.detail ?? "—")")
                for a in advice.alternatives ?? [] {
                    print("  备选    : \(a.tile ?? "—") — \(a.why ?? "")")
                }
                print("  牌理    : \(advice.lesson ?? "—")")
                if let u = advice.effectiveUncertain {
                    print("  不确定  : \(u.joined(separator: "；"))")
                }
                return 0
            } else {
                print("❌ JSON 解析失败 —— 界面会退化成显示模型原文")
                if let j = AdviceParser.extractJSONObject(from: result.content) {
                    print("   （能抠出 JSON 片段但字段不匹配，长度 \(j.count)）")
                }
                return 2
            }
        } catch {
            print("❌ 调用失败: \(Log.redact(error.localizedDescription))")
            return 1
        }
    }

    /// `--tiles-robustness <图>`：把同一张图缩放到不同尺寸再切分。
    /// 用来回答"浏览器窗口大小每次都不一样，切分还准不准"这个问题 ——
    /// 缩放不改内容，只改尺度，所以能直接看出检测是否随尺度自适应。
    private static func debugRobustness(path: String) -> Int32 {
        print("========== 切分尺寸鲁棒性 ==========")
        guard let base = loadCGImage(path: path) else {
            print("❌ 读不到图片：\(path)"); return 1
        }
        print("基准尺寸 \(base.width)x\(base.height)")
        print("（牌宽与尺寸应当成比例；张数应当始终 14）")
        print("")
        var allGood = true
        for f in [0.45, 0.6, 0.75, 0.9, 1.0, 1.15, 1.35, 1.6] {
            let w = Int(Double(base.width) * f), h = Int(Double(base.height) * f)
            guard let ctx = CGContext(data: nil, width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { continue }
            ctx.interpolationQuality = .high
            ctx.draw(base, in: CGRect(x: 0, y: 0, width: w, height: h))
            guard let scaled = ctx.makeImage(),
                  let d = NSBitmapImageRep(cgImage: scaled)
                    .representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else { continue }

            switch TileSegmenter.segment(jpegData: d) {
            case .failure(let e):
                allGood = false
                print(String(format: "  %4.0f%%  %4dx%-4d  ❌ %@", f * 100, w, h, e.errorDescription ?? "未知"))
            case .success(let r):
                let ok = r.count == 14
                if !ok { allGood = false }
                print(String(format: "  %4.0f%%  %4dx%-4d  %@ %2d 张   牌宽 %5.1f（理想 %5.1f）  周期性 %.3f  跨度 %.0f",
                             f * 100, w, h, ok ? "✅" : "⚠️", r.count, r.pitch, 101 * f, r.correlation, r.band.width))
            }
        }
        print("")
        print(allGood ? "✅ 所有尺寸下都切出了 14 张 —— 窗口大小变化不影响切分。"
                      : "⚠️ 有尺寸没切准，需要看看是不是检测阈值对该尺度不适用。")
        return allGood ? 0 : 2
    }

    /// `--river <图> [输出目录]`：只跑牌河识别，把四家的格子图导出来人工核对。
    ///
    /// 牌河是**本地识牌**（不走模型、不花 token）。这条自测用来回答：
    /// 「格子找得对不对」「牌名认得对不对」。
    private static func debugRiver(path: String, outDir: String) -> Int32 {
        print("========== 牌河本地识别自测 ==========")
        guard let cg = loadCGImage(path: path) else {
            print("❌ 读不到图片：\(path)"); return 1
        }
        print("原图: \(cg.width)x\(cg.height)")
        guard TileFaceMatcher.isAvailable else {
            print("❌ 牌面素材 ui.png / ui.atlas 没找到，牌面级匹配不可用"); return 2
        }
        print("牌面模板: \(TileFaceMatcher.count) 张（\(TileFaceMatcher.faceW)x\(TileFaceMatcher.faceH)）")

        var canvas: CanvasFrame?
        if case .success(let seg) = TileSegmenter.segment(cg: cg) { canvas = seg.canvas }
        RiverReader.verbose = CommandLine.arguments.contains("--verbose")
        if let c = canvas {
            print(String(format: "画布: x %.0f  y %.0f  scale %.4f", c.x, c.y, c.scale))
        } else {
            print("画布: ⚠️ 没认出来，退回按图宽推 scale")
        }
        print("")

        let t0 = Date()
        let results = RiverReader.readAll(from: cg, canvas: canvas)
        let ms = Date().timeIntervalSince(t0) * 1000

        let fm = FileManager.default
        try? fm.createDirectory(atPath: outDir, withIntermediateDirectories: true)

        var totalVisible = 0, totalNamed = 0
        for r in results {
            print("── \(r.seat)：\(r.filledRows) 行 / 有效格 \(r.occupied) / 认出 \(r.recognized)"
                  + String(format: " / 置信 %.3f%@", r.confidence, r.isTrustworthy ? " ✅" : " ⚠️"))
            for (i, line) in r.rows.enumerated() {
                let s = line.map { $0 ?? "??" }.joined(separator: " ")
                print("    第\(i + 1)行(\(line.count)格): \(s)")
            }
            totalVisible += r.occupied
            totalNamed += r.recognized
            if let strip = r.strip {
                let p = (outDir as NSString).appendingPathComponent("river-\(r.seat).png")
                if let d = NSBitmapImageRep(cgImage: strip).representation(using: .png, properties: [:]) {
                    try? d.write(to: URL(fileURLWithPath: p))
                    print("    格子图: \(p)")
                }
            }
        }
        print("")
        print(String(format: "用时 %.0f ms   有效格 %d   认出 %d", ms, totalVisible, totalNamed))
        print("提示：格子图导出来之后**人眼看一遍**，别只看数字 —— 位置对不对、有没有串格。")
        return 0
    }

    private static func loadJPEG(path: String, quality: Double) -> Data? {        guard let img = NSImage(contentsOfFile: path),
              let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
    }

    private static func loadCGImage(path: String) -> CGImage? {
        guard let data = FileManager.default.contents(atPath: path),
              let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    /// `--debug-tiles <图> [输出目录]`：只跑手牌切分，把每张牌导出来人工核对。
    private static func debugTiles(jpeg: Data, outDir: String) -> Int32 {
        print("========== 手牌切分自测 ==========")
        guard let src = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            print("❌ 无法解码图片"); return 1
        }
        print("原图: \(cg.width)x\(cg.height)")

        switch TileSegmenter.segment(jpegData: jpeg) {
        case .failure(let e):
            print("❌ 切分失败: \(e.errorDescription ?? "未知")")
            return 2
        case .success(let r):
            if let c = r.canvas {
                print(String(format: "画布: x %.0f..%.0f  y %.0f..%.0f  (高 %.0f = 图宽×9/16)  scale %.4f",
                             c.x, c.x + c.width, c.y, c.y + c.height, c.height, c.scale))
                print(String(format: "      手牌行虚拟坐标 y %.0f..%.0f（实测应在 1225..1428 一带）",
                             c.virtualY(r.band.minY), c.virtualY(r.band.maxY)))
            } else {
                print("画布: ⚠️ 没认出来（退回按图宽推牌宽）")
            }
            print(String(format: "✅ 手牌行 y %.0f..%.0f   牌宽 %.2fpx   周期性 %.3f",
                         r.band.minY, r.band.maxY, r.pitch, r.correlation))
            print("   暗牌 \(r.concealedRects.count) 张" +
                  (r.drawnRect == nil ? "  摸牌：无（这一轮没有进张 —— 碰/吃之后直接出牌）"
                                      : String(format: "  摸牌：有（x %.0f..%.0f）",
                                               r.drawnRect!.minX, r.drawnRect!.maxX)))
            if let m = r.meldBlock {
                print(String(format: "   副露区: x %.0f..%.0f（宽 %.0f ≈ %d 张，约 %d 组）—— 摆在桌面上带透视，不作本地识别",
                             m.minX, m.maxX, m.width, r.meldTiles, r.meldGroups))
            }
            print("   合计手牌 \(r.count) 张" +
                  (r.meldGroups > 0 ? " + 副露 \(r.meldGroups) 组 → 共 \(r.count + r.meldGroups * 3) 张" : ""))
            for (i, rect) in r.tileRects.enumerated() {
                let tag = (r.drawnRect != nil && i == r.tileRects.count - 1) ? "摸" : "  "
                print(String(format: "   #%2d%@ x %.0f..%.0f  y %.0f..%.0f",
                             i + 1, tag, rect.minX, rect.maxX, rect.minY, rect.maxY))
            }
            try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
            let jpegs = TileSegmenter.tileJPEGs(from: cg, result: r)
            print("导出 \(jpegs.count) 张牌 -> \(outDir)")
            for (i, d) in jpegs.enumerated() {
                let p = "\(outDir)/tile-\(String(format: "%02d", i + 1)).jpg"
                try? d.write(to: URL(fileURLWithPath: p))
            }
            // 本地竹节计数（不调模型）：只对索子有效，其余牌应当输出「—」。
            // 索子那一格若是数字，就是竹节根数，可以直接当答案用。
            let ranks = jpegs.map { LocalTileReader.souzuRank(ofTileJPEG: $0) }
            let parts = ranks.enumerated().map { i, r in r.map { "#\(i + 1)=\($0)根" } ?? "#\(i + 1)=—" }
            print("本地竹节计数（非索子应为「—」）：" + parts.joined(separator: "  "))

            // 模板匹配（正式路径）：用 ui.png + ui.atlas 逐张认牌，完全不调模型
            if TileTemplateMatcher.isAvailable {
                print("模板匹配（素材共 \(TileTemplateMatcher.templateNames.count) 张）：")
                var names: [String] = []
                for (i, cg) in TileSegmenter.tileCGImages(from: cg, result: r).enumerated() {
                    guard let m = TileTemplateMatcher.identify(cg) else {
                        print(String(format: "   #%2d  ✗ 认不出", i + 1)); continue
                    }
                    let ok = m.score >= TileTemplateMatcher.minAcceptableScore
                    print(String(format: "   #%2d  %@ %-4@ 匹配 %.2f  次选 %-4@ %.2f  差 %.2f  红占比 %.2f",
                                 i + 1, ok ? "✅" : "⚠️", m.name as NSString,
                                 m.score, m.runnerUp as NSString, m.runnerUpScore, m.margin, m.redRatio))
                    if ok { names.append(m.name) }
                }
                print("   → " + names.joined(separator: " "))
            } else {
                print("模板匹配：素材 ui.png / ui.atlas 没找到")
            }
            // 再拼一张横向对照图，方便一眼看出切歪了没
            if let strip = contactSheet(cg: cg, result: r, outDir: outDir) {
                print("对照图 -> \(strip)")
            }
            return 0
        }
    }

    private static func contactSheet(cg: CGImage, result: TileSegmenter.Result, outDir: String) -> String? {
        let pad = 8
        let tiles = result.tileRects
        guard let first = tiles.first else { return nil }
        let tw = Int(first.width), th = Int(first.height)
        let totalW = tiles.count * (tw + pad) + pad
        guard let ctx = CGContext(data: nil, width: totalW, height: th + pad * 2,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: totalW, height: th + pad * 2))
        for (i, r) in tiles.enumerated() {
            guard let sub = cg.cropping(to: r) else { continue }
            ctx.draw(sub, in: CGRect(x: Double(pad + i * (tw + pad)), y: Double(pad),
                                     width: Double(tw), height: Double(th)))
        }
        guard let img = ctx.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: img)
        guard let d = rep.representation(using: .png, properties: [:]) else { return nil }
        let p = "\(outDir)/contact-sheet.png"
        try? d.write(to: URL(fileURLWithPath: p))
        return p
    }

    /// 副露识别自测：打印四家副露的分组与牌名。
    private static func debugMeld(path: String) async -> Int32 {
        print("========== 副露本地识别自测 ==========")
        guard let cg = loadCGImage(path: path) else {
            print("打不开图片：\(path)")
            return 1
        }
        print("原图: \(cg.width)x\(cg.height)")
        guard let b = TileSegmenter.buffers(of: cg),
              case .success(let seg) = TileSegmenter.segment(cg: cg) else {
            print("切分失败")
            return 1
        }
        let canvas = seg.canvas
            ?? CanvasFrame(x: 0, y: 0, width: Double(cg.width), height: Double(cg.height) * 9 / 16)
        print(String(format: "画布: x %.0f y %.0f scale %.4f", canvas.x, canvas.y, canvas.scale))

        var total = 0, named = 0
        for seat in MeldReader.seats {
            guard let r = MeldReader.read(seat: seat, rgba: b.rgba, w: b.w, h: b.h,
                                           canvas: canvas) else {
                print("── \(seat.name)：（无）")
                continue
            }
            print("── \(r.seat)：\(r.groups.count) 组  置信 \(String(format: "%.3f", r.confidence))  \(r.note)")
            for (i, g) in r.groups.enumerated() {
                let desc = g.tiles.map { t in
                    (t.name ?? "??") + String(format: "(%.2f", t.score) + (t.rotated ? ",横" : "") + ")"
                }.joined(separator: " ")
                print("    第\(i + 1)组: \(desc)")
                for t in g.tiles {
                    total += 1
                    if t.name != nil { named += 1 }
                }
            }
        }
        print(String(format: "用时 —  共 %d 张，认出 %d 张", total, named))
        return 0
    }
}
