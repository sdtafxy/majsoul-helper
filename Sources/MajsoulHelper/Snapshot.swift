import Foundation
import AppKit
import SwiftUI

/// 快照模式标记。用来绕开那些「在 ImageRenderer 下不渲染、但真机正常」的组件
/// （目前已知：`ScrollView`）。见 OverlaySelfTest.ContainerProbe 的对照实验。
struct SnapshotModeKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var snapshotMode: Bool {
        get { self[SnapshotModeKey.self] }
        set { self[SnapshotModeKey.self] = newValue }
    }
}

/// 界面快照自检。
///
/// 为什么需要它：这个 App 的界面要在真实授权、真实对局下才出效果，
/// 而"能编译"和"跑起来不崩"都**不能**证明牌面、色块、换行渲染正确 ——
/// 实测就漏过两个只有看图才能发现的 bug（牌面成了深底黑字、把握度显示成红色）。
///
/// 用法：`MajsoulHelper --snapshot <输出前缀>`
/// 会输出 `<前缀>-light.png` 和 `<前缀>-dark.png` 两张图。
enum Snapshot {

    static func run(prefix: String) {
        _ = NSApplication.shared
        NSApplication.shared.setActivationPolicy(.accessory)
        SnapshotMode.isActive = true

        Task { @MainActor in
            // 正常态：明暗两套
            for scheme in [ColorScheme.light, .dark] {
                AppModel.shared.loadPreviewSample()
                let name = scheme == .light ? "light" : "dark"
                render(scheme: scheme, to: "\(prefix)-\(name).png")
            }
            // 权限缺失态：这条提示条文案长、按钮多，最容易挤爆，必须单独看一眼
            AppModel.shared.loadPreviewSample(permissionGranted: false, withRepairMessage: true)
            render(scheme: .dark, to: "\(prefix)-permission.png")
            // 手牌修正态：选牌盘 4 行 × 9~10 列，是宽度最吃紧的一块
            AppModel.shared.loadPreviewSample(handDirty: true)
            render(scheme: .dark, to: "\(prefix)-handedit.png")

            // Overlay 面板：空态 / 有结果态 两张。
            // ★ 铁律：改完界面必须看图。Overlay 面板是新写的，
            //   而「牌名标签能不能排开」「结果列表会不会挤爆」
            //   都只有渲染出来才看得出。
            renderOverlay(scheme: .dark, to: "\(prefix)-overlay-empty.png", withResult: false)
            renderOverlay(scheme: .dark, to: "\(prefix)-overlay-result.png", withResult: true)
            // 容器兼容性对照：排查「界面空白」时先跑这个，别猜组件
            ContainerProbe.run(out: "\(prefix)-container-probe.png")
            // 设置界面（2026-10-12：表单重排后必须看图验证对齐）
            AppModel.shared.loadPreviewSample()
            renderSettings(width: 680, to: "\(prefix)-settings.png")
            // 窄窗口紧凑侧栏（2026-10-15：折叠态单独验）
            renderSettings(width: 500, to: "\(prefix)-settings-compact.png")
            // 窗口选择浮层（2026-10-16：外观跟随/标题/图标按钮重做后验证）
            renderPicker(to: "\(prefix)-picker.png")
            // 识别结果浮窗（2026-10-18：暗杠 4 张占位 + 标签验证）
            renderRecognition(to: "\(prefix)-recwindow.png")
            // 识别结果浮窗（2026-10-18：暗杠 4 张占位 + 标签验证）
            renderRecognition(to: "\(prefix)-recwindow.png")
            exit(0)
        }
        dispatchMain()
    }

    /// 识别结果浮窗快照（2026-10-18：暗杠占位/标签、副露行验证）。
    @MainActor
    private static func renderRecognition(to path: String) {
        let ctrl = OverlayController()
        ctrl.previewSample()
        let view = RecognitionWindowView(overlay: ctrl)
            .frame(width: 430, height: 640)
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let img = renderer.nsImage,
              let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .png, properties: [:]) else {
            print("渲染失败 \(path)")
            return
        }
        do {
            try data.write(to: URL(fileURLWithPath: path))
            print("快照已生成: \(path)  \(img.size.width)x\(img.size.height)")
        } catch {
            print("写文件失败 \(path): \(error.localizedDescription)")
        }
    }

    /// 窗口选择浮层快照（2026-10-16：验证外观跟随 + 「选择窗口」标题 + 图标按钮）。
    @MainActor
    private static func renderPicker(to path: String) {
        AppModel.shared.loadPreviewSample()
        let view = WindowPickerView(model: AppModel.shared, onPick: { _ in })
            .frame(width: 340, height: 400)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let img = renderer.nsImage,
              let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .png, properties: [:]) else {
            print("渲染失败 \(path)")
            return
        }
        do {
            try data.write(to: URL(fileURLWithPath: path))
            print("快照已生成: \(path)  \(img.size.width)x\(img.size.height)")
        } catch {
            print("写文件失败 \(path): \(error.localizedDescription)")
        }
    }

    /// 设置界面快照（浅色，因为设置窗口强制 light 环境）。
    @MainActor
    private static func renderSettings(width: CGFloat, to path: String) {
        let view = SettingsView(model: AppModel.shared)
            .frame(width: width, height: 900)
            .environment(\.colorScheme, .light)
            .environment(\.snapshotMode, true)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let img = renderer.nsImage,
              let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .png, properties: [:]) else {
            print("渲染失败 \(path)")
            return
        }
        do {
            try data.write(to: URL(fileURLWithPath: path))
            print("快照已生成: \(path)  \(img.size.width)x\(img.size.height)")
        } catch {
            print("写文件失败 \(path): \(error.localizedDescription)")
        }
    }

    /// Overlay 面板快照。样例数据是**造的**，但格式与真实输出一致
    /// （含低置信 `↓`、未识别 `?`、白板），这样排版问题才会暴露出来。
    @MainActor
    private static func renderOverlay(scheme: ColorScheme, to path: String,
                                      withResult: Bool) {
        let ctrl = OverlayController()
        ctrl.previewSetup(windows: [
            CapturableWindow(id: 1, title: "雀魂", appName: "Google Chrome",
                             bundleID: "com.google.Chrome", width: 1800, height: 950,
                             isOnScreen: true),
            CapturableWindow(id: 2, title: "雀魂麻將 - 雀姬", appName: "Notes",
                             bundleID: "com.apple.Notes", width: 900, height: 700,
                             isOnScreen: true),
        ], selected: 1)
        if withResult {
            ctrl.previewSample()
            // ★ 断言数据真的到位 ★「能编译能跑」都过了但视图空白时，
            //   先证明数据到了，再怀疑视图 —— 我在这上面猜错了三次。
            let r = ctrl.currentResult
            print("  [snapshot] 注入结果: seats=\(r.seats.count) "
                  + "tiles=\(r.totalTiles) status=\(ctrl.status.hudText)")
            if r.totalTiles == 0 { print("  ⚠️ 数据没到位，视图空白不是布局问题") }
        }
        ctrl.previewHUD(withResult: withResult)
        // ★ .frame 固定高度：ImageRenderer 对这个视图树的 ideal 高度算不准
        // （VStack 尾部子项 debugSection/actions 会整段丢失）——快照侧给死
        //   尺寸逼出完整内容（2026-10-15）。
        let view = ZStack {
            Color(white: scheme == .dark ? 0.13 : 0.93)
            MainPanelView(model: AppModel.shared, overlay: ctrl)
                .frame(width: 336, height: 980)
        }
        .environment(\.colorScheme, scheme)
        .environment(\.snapshotMode, true)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let img = renderer.nsImage,
              let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            print("快照失败: \(path)")
            return
        }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            print("  ✓ \(path)")
        } catch {
            print("快照写入失败 \(path): \(error)")
        }
    }

    @MainActor
    private static func render(scheme: ColorScheme, to path: String) {
        let view = ZStack {
            (scheme == .dark ? Color(white: 0.13) : Color(white: 0.93))
            MainPanelView(model: AppModel.shared, overlay: OverlayController())
                // 让面板取内容自然高度，否则超出 560 的部分（含顶栏和截图来源）会被裁掉，
                // 快照就只看到半张图 —— 而"看不见的那半边"恰恰最容易藏 bug。
                .fixedSize(horizontal: false, vertical: true)
        }
        .environment(\.colorScheme, scheme)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let img = renderer.nsImage,
              let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            print("快照失败: \(path)")
            return
        }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            print("快照已生成: \(path)  \(img.size.width)x\(img.size.height)")
        } catch {
            print("写文件失败 \(path): \(error.localizedDescription)")
        }
    }
}

/// 快照用的样例数据。刻意造得"信息最全"：有副露、有宝牌、有备选、有不确定项、
/// 有不确定的字牌 —— 这样一屏就能暴露所有渲染分支的问题。
enum AdvicePreview {
    static let sample = Advice(
        hand: ["1m", "2m", "3m", "5m", "6m", "0p", "5p", "7p", "2s", "3s", "4s", "6s", "7s", "1z"],
        turn: "自己出牌",
        melds: ["9p", "9p", "9p"],
        dora: ["7p", "3s", "1z"],
        uncertain: ["右侧牌河第 5 张看不清"],
        recommended: Advice.Recommended(tile: "8m", action: "打", confidence: "high"),
        reason: "门清两向听（3355 66 8m / 556s / 12s / 77p / 44z），宝牌 6m 成对是 2 番价值。打 8m 保留 3355m + 66m 的连续形，摸 4m、7m、5m 都有进展。",
        danger: Advice.Danger(level: "medium", detail: "上家已立直，8s 之后是危险牌；下家牌河有两张中，注意不要打生张字牌。"),
        alternatives: [
            Advice.Alternative(tile: "5m", why: "保留 8m 的浮牌，但会拆掉 56m 的两面搭子，进张从 16 张降到 8 张，明显更差。"),
            Advice.Alternative(tile: "7p", why: "想留宝牌 6m 时的另一种选择，但 7p 能靠 5p/6p/8p/9p，价值高于孤张 8m。")
        ],
        lesson: "一向听时优先切掉完全孤立的浮牌，把两副面子、两个两面搭子和雀头全部留住；进张数最大化的那一打通常就是最稳的一打。",
        readback: nil
    )

    static let rawSample = """
    {"hand":["1m","2m","3m","5m","6m","0p","5p","7p","2s","3s","4s","6s","7s","1z"],\
    "turn":"自己出牌","recommended":{"tile":"8m","action":"打","confidence":"high"}}
    """

    static let reasoningSample = """
    先看手牌：1m2m3m 已成顺，5m6m 是两面搭子，0p5p7p 里 5p5p 对子可作雀头…
    宝牌指示牌是 7p、3s、东，说明 6m 不是宝牌，但 6m6m 成对已经是现成的 2 番。
    数一下向听：现有两副面子（123m、234s），两个两面搭子（56m、67s），一个对子（55p）…
    切 8m 之后有效牌是 4m/7m/5s/8s 共 16 张。
    """
}
