import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var panel: NSPanel?
    /// 识别结果独立浮窗（2026-10-12：从主浮窗提取出来）
    private var recognitionPanel: NSPanel?
    /// 窗口选择浮层（2026-10-13：主浮窗「选择窗口」药丸 / 菜单栏唤起）
    private var pickerPanel: NSPanel?
    /// picker 跟随的 debounce（拖动中反复重置，松手才执行）
    private var pickerFollowWork: DispatchWorkItem?
    /// 主浮窗位置观察者（picker 跟随）
    private var windowObservers: [NSObjectProtocol] = []
    private var settingsWindow: NSPanel?
    private var statusItem: NSStatusItem?

    /// 切分/识别图层（已融入主面板的「切分识别」tab，2026-10-10）
    let overlayCtrl = OverlayController()

    // MARK: - 生命周期

    func applicationWillFinishLaunching(_ notification: Notification) {
        // 关掉「退出时记住窗口」。否则上一次如果是在没有窗口的状态退出的，
        // 这次启动可能整个不显示任何窗口，用户只能强退。
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMainMenu()
        buildStatusItem()
        buildPanel()
        buildRecognitionPanel()
        overlayCtrl.bootstrap()
        observeNotifications()
        // Sparkle 更新（2026-10-16）：自动检查 + 手动确认安装
        UpdaterManager.shared.start()
        Log.info("启动完成 bundle=\(Bundle.main.bundleIdentifier ?? "无") 权限=\(ScreenPermission.isGranted)")

        // 首次启动主动弹一次系统授权框，省得用户不知道为什么截不到图。
        // 只在没弹过的时候弹 —— 系统本身每次启动都弹会很烦人。
        if !ScreenPermission.isGranted,
           !UserDefaults.standard.bool(forKey: "didAskScreenPermission") {
            UserDefaults.standard.set(true, forKey: "didAskScreenPermission")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                ScreenPermission.request()
                AppModel.shared.refreshPermission()
                Task { await AppModel.shared.refreshWindows(autoPickIfEmpty: true) }
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }

    // MARK: - 浮窗

    private func buildPanel() {
        let content = NSHostingView(rootView: MainPanelView(model: AppModel.shared,
                                                             overlay: overlayCtrl))
        // ★ borderless：去掉系统标题栏 —— 旧版「.titled + 透明标题栏」会让窗口
        //   顶栏是直角、内容区是系统圆角，看着不伦不类。现在圆角完全由
        //   MainPanelView 自己画（Theme.panelRadius），顶底一致。
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 630, height: 560),
                        styleMask: [.borderless, .nonactivatingPanel, .resizable],
                        backing: .buffered,
                        defer: false)

        // 悬浮 + 跨全屏 Space + 点按钮不激活本 App（游戏仍保持前台）。
        //
        // ⚠️ 这里**不能**同时给 `.canJoinAllSpaces` 和 `.moveToActiveSpace`：
        // 前者是「在所有空间都显示」，后者是「只跟着当前活动空间走」，语义互斥。
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isFloatingPanel = true
        p.becomesKeyOnlyIfNeeded = false
        p.hidesOnDeactivate = false
        p.isMovableByWindowBackground = true
        p.isReleasedWhenClosed = false
        p.isRestorable = false
        p.isOpaque = false
        p.backgroundColor = .clear
        finishPanel(p)   // ★ layer 圆角 mask + window 投影（直角边框根治）
        p.contentMinSize = NSSize(width: 376, height: 520)
        p.minSize = NSSize(width: 376, height: 520)   // borderless 面板用 minSize 才稳妥
        p.contentView = content

        let restored = p.setFrameUsingName("MajsoulHelperPanel")
        Log.info("面板恢复位置: \(restored) frame=\(fmt(p.frame))")
        if !restored { positionDefault(p) }
        p.setFrameAutosaveName("MajsoulHelperPanel")
        ensureOnScreen(p)
        Log.info("面板定位后 frame=\(fmt(p.frame)) screensIntersect=\(NSScreen.screens.contains { $0.visibleFrame.intersects(p.frame) })")

        panel = p
        p.orderFrontRegardless()
        Log.info("orderFrontRegardless 后 isVisible=\(p.isVisible) isOnActiveSpace=\(p.isOnActiveSpace) occlusion=\(p.occlusionState.contains(.visible)) level=\(p.level.rawValue)")
    }

    // MARK: - 识别结果浮窗（独立，可单独关闭 / 菜单唤出）

    private func buildRecognitionPanel() {
        let content = NSHostingView(rootView: RecognitionWindowView(overlay: overlayCtrl))
        // 初始宽度与主浮窗一致（630），避免两个窗口并排时宽度对不上
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 630, height: 640),
                        styleMask: [.borderless, .nonactivatingPanel, .resizable],
                        backing: .buffered,
                        defer: false)
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isFloatingPanel = true
        p.becomesKeyOnlyIfNeeded = false
        p.hidesOnDeactivate = false
        p.isMovableByWindowBackground = true
        p.isReleasedWhenClosed = false
        p.isRestorable = false
        p.isOpaque = false
        p.backgroundColor = .clear
        finishPanel(p)   // ★ layer 圆角 mask + window 投影（直角边框根治）
        p.contentMinSize = NSSize(width: 376, height: 520)
        p.contentView = content

        let restored = p.setFrameUsingName("MajsoulHelperRecognition")
        if !restored {
            // 默认放主面板左侧
            if let vf = NSScreen.main?.visibleFrame {
                let w: CGFloat = 430, h: CGFloat = 640
                p.setFrame(NSRect(x: vf.maxX - 630 - 18 - w - 10, y: vf.midY - h / 2,
                                  width: w, height: h), display: false)
            }
        }
        p.setFrameAutosaveName("MajsoulHelperRecognition")
        if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(p.frame) }) {
            p.center()
        }
        recognitionPanel = p
        // 启动时是否显示由设置决定（默认关；toggleRecognition/菜单仍可随时开关）
        if AppModel.shared.settings.showRecognitionOnLaunch {
            p.orderFrontRegardless()
        }
        Log.info("识别结果浮窗已创建（启动显示=\(AppModel.shared.settings.showRecognitionOnLaunch)）")
    }

    private func toggleRecognition() {
        guard let p = recognitionPanel else { return }
        if p.isVisible {
            p.orderOut(nil)
        } else {
            p.orderFrontRegardless()
        }
    }


    /// 收尾面板：hostingView layer 圆角 mask + window 投影。
    /// ★ SwiftUI 的 .shadow 走的是 NSHostingView 的矩形 layer-shadow（直角的），
    ///   所以必须：layer 设圆角 + masksToBounds，window 开 hasShadow ——
    ///   AppKit 会按 layer 的圆角形状投影（2026-10-14 直角边框的根治）。
    private func finishPanel(_ p: NSPanel) {
        if let hv = p.contentView {
            hv.wantsLayer = true
            hv.layer?.cornerRadius = Theme.panelRadius
            hv.layer?.masksToBounds = true
        }
        p.hasShadow = true
    }

    private func fmt(_ r: NSRect) -> String {
        String(format: "(%.0f,%.0f,%.0f,%.0f)", r.origin.x, r.origin.y, r.size.width, r.size.height)
    }

    private func positionDefault(_ p: NSWindow) {
        guard let vf = NSScreen.main?.visibleFrame else { return }
        let w: CGFloat = 630, h: CGFloat = 560
        p.setFrame(NSRect(x: vf.maxX - w - 18, y: vf.midY - h / 2, width: w, height: h), display: false)
    }

    /// 上次的窗口位置可能被保存在一块已经拔掉的显示器上，会看不见
    private func ensureOnScreen(_ p: NSWindow) {
        let visible = NSScreen.screens.contains { $0.visibleFrame.intersects(p.frame) }
        if !visible { positionDefault(p); p.center() }
    }

    private func togglePanel() {
        guard let p = panel else { return }
        if p.isVisible {
            p.orderOut(nil)
        } else {
            p.orderFrontRegardless()
        }
    }

    // MARK: - 菜单栏图标

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = Self.statusIcon()
        item.button?.toolTip = "雀魂助手"

        let menu = NSMenu()
        menu.addItem(menuItem("主浮窗", #selector(onTogglePanel), ""))
        menu.addItem(menuItem("识别结果", #selector(onToggleRecognition), ""))
        menu.addItem(.separator())
        menu.addItem(menuItem("识别", #selector(onRecognizeOnly), ""))
        // ★ 2026-10-18 用户反馈：statusItem 菜单上的快捷键（⌘⏎/⌥⏎）实际不生效
        //   （只在该菜单展开时可用）——移出快捷键，菜单里也不再显示提示。
        menu.addItem(menuItem("快速", #selector(onQuickAnalyze), ""))
        menu.addItem(menuItem("分析", #selector(onDeepAnalyze), ""))
        menu.addItem(.separator())
        menu.addItem(menuItem("设置…", #selector(onOpenSettings), ","))
        menu.addItem(menuItem("检查更新…", #selector(onCheckUpdates), ""))
        menu.addItem(menuItem("打开配置目录", #selector(onOpenConfigDir), ""))
        menu.addItem(.separator())
        menu.addItem(menuItem("退出雀魂助手", #selector(onQuit), "q"))
        item.menu = menu
        statusItem = item
    }

    private func menuItem(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    /// 菜单栏图标：**矢量绘制**（一对左右叠放的牌 + 前牌一筒挖空）。
    ///
    /// ★ 为什么不用 PNG（2026-10-14 调研结论）：
    ///   位图在 18pt 下必然有锯齿，且抗锯齿灰边会被系统误判为「半透明」，
    ///   Big Sur+ 渲染器直接降级 nearest-neighbor → 糊 + 发虚。
    ///   正解是 `NSImage(size:flipped:drawingHandler:)` 矢量动态生成：
    ///   任意分辨率重绘、无锯齿、无灰边。
    ///   template 规范：纯黑填充 + 透明背景（系统按 alpha 蒙版着色，
    ///   亮菜单栏着黑、暗菜单栏着白）。
    private static func statusIcon() -> NSImage {
        // ★ 21pt 画布（标准是 18）—— 一对竖牌的外接框天然窄高（约 16×13），
        //   18pt 画布下横向只占 14.8pt，比别家方块型图标显小一圈。
        //   放大画布 + 牌加大 + 横向撑到 92%，视觉才与别家菜单栏图标齐平
        //   （2026-10-14 用户反馈「图标不够大，别家都是大大的」）。
        let img = NSImage(size: NSSize(width: 21, height: 21), flipped: false) { _ in
            NSColor.black.setFill()

            // 后牌（左下，斜 -13°）
            let backRect = NSRect(x: 0.9, y: 5.2, width: 8.6, height: 12.0)
            let back = NSBezierPath(roundedRect: backRect, xRadius: 1.5, yRadius: 1.5)
            back.rotate(degrees: -13, about: CGPoint(x: backRect.midX, y: backRect.midY))
            back.fill()

            // 前牌（右上，斜 +8°）—— 中心圆盘 even-odd 挖空（一筒镂空）
            let frontRect = NSRect(x: 10.4, y: 2.6, width: 9.0, height: 12.6)
            let front = NSBezierPath(roundedRect: frontRect, xRadius: 1.6, yRadius: 1.6)
            let ringD: CGFloat = 3.8
            front.append(NSBezierPath(ovalIn: NSRect(
                x: frontRect.midX - ringD / 2, y: frontRect.midY - ringD / 2,
                width: ringD, height: ringD)))
            front.windingRule = .evenOdd
            front.rotate(degrees: 8, about: CGPoint(x: frontRect.midX, y: frontRect.midY))
            front.fill()

            return true
        }
        img.isTemplate = true
        return img
    }

    // MARK: - 应用主菜单（装了它，设置窗里的输入框才能用 ⌘C/⌘V/⌘A）

    private func buildMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(menuItem("设置…", #selector(onOpenSettings), ","))
        appMenu.addItem(.separator())
        appMenu.addItem(menuItem("隐藏浮窗", #selector(onHidePanel), "h"))
        appMenu.addItem(.separator())
        appMenu.addItem(menuItem("退出雀魂助手", #selector(onQuit), "q"))
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "编辑")
        edit.addItem(NSMenuItem(title: "撤销", action: Selector(("undo:")), keyEquivalent: "z"))
        edit.addItem(NSMenuItem(title: "重做", action: Selector(("redo:")), keyEquivalent: "Z"))
        edit.addItem(.separator())
        edit.addItem(NSMenuItem(title: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        edit.addItem(NSMenuItem(title: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = edit
        main.addItem(editItem)

        let winItem = NSMenuItem()
        let win = NSMenu(title: "窗口")
        win.addItem(NSMenuItem(title: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        win.addItem(NSMenuItem(title: "关闭", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        winItem.submenu = win
        main.addItem(winItem)

        NSApp.mainMenu = main
    }

    // MARK: - 设置窗口（自己建，不用 SwiftUI 的 Settings 场景）

    private func openSettings() {
        if settingsWindow == nil {
            // ★ borderless（2026-10-13）：红黄绿/系统标题栏融进自绘顶栏，
            //   与浮窗同一套墨璃语言。关闭由界面内 ✕ 按钮（mhCloseSettings）负责。
            let w = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 680, height: 560),
                            styleMask: [.borderless, .nonactivatingPanel, .resizable],
                            backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false      // 否则第二次 show 就是野指针
            w.level = .floating
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            w.isFloatingPanel = true
            w.becomesKeyOnlyIfNeeded = false
            w.hidesOnDeactivate = false
            w.isMovableByWindowBackground = true
            w.isOpaque = false
            w.backgroundColor = .clear
            finishPanel(w)
            w.contentMinSize = NSSize(width: 440, height: 420)   // 紧凑侧栏模式的最小可用宽
            w.contentView = NSHostingView(rootView: SettingsView(model: AppModel.shared))
            w.center()
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
        // 窗口刚出现时 AppKit 会把第一响应者给第一个控件，留一圈莫名其妙的焦点环
        DispatchQueue.main.async { [weak self] in
            self?.settingsWindow?.makeFirstResponder(nil)
        }
    }

    // MARK: - 通知

    private func observeNotifications() {
        let c = NotificationCenter.default
        c.addObserver(self, selector: #selector(onOpenSettings), name: .mhOpenSettings, object: nil)
        c.addObserver(self, selector: #selector(onHidePanel), name: .mhHidePanel, object: nil)
        c.addObserver(self, selector: #selector(onTogglePanel), name: .mhTogglePanel, object: nil)
        c.addObserver(self, selector: #selector(onToggleRecognition), name: .mhToggleRecognition, object: nil)
        c.addObserver(self, selector: #selector(onPickWindow), name: .mhPickWindow, object: nil)
        c.addObserver(self, selector: #selector(onClosePicker), name: .mhClosePicker, object: nil)
        c.addObserver(self, selector: #selector(onAutoPickWindow), name: .mhAutoPickWindow, object: nil)
        // ★ 主浮窗移动/缩放时，窗口选择浮层跟随（2026-10-16 用户反馈：
        // 原来 picker 留在原地）。block-based 因为要按 object 过滤主浮窗。
        windowObservers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: panel, queue: .main)
        { [weak self] _ in self?.schedulePickerFollow() })
        windowObservers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: panel, queue: .main)
        { [weak self] _ in self?.schedulePickerFollow() })
        c.addObserver(self, selector: #selector(onCloseSettings), name: .mhCloseSettings, object: nil)
        c.addObserver(self, selector: #selector(onQuit), name: .mhQuit, object: nil)
    }

    @objc private func onTogglePanel() { togglePanel() }
    @objc private func onToggleRecognition() { toggleRecognition() }

    @objc private func onRecognizeOnly() {
        overlayCtrl.selectedWindowID = AppModel.shared.settings.windowID
        overlayCtrl.runNow()
    }

    // MARK: - 窗口选择浮层

    @objc private func onPickWindow() { openWindowPicker() }

    private func openWindowPicker() {
        if pickerPanel == nil {
            let content = NSHostingView(rootView: WindowPickerView(
                model: AppModel.shared,
                onPick: { [weak self] w in
                    guard let self else { return }
                    AppModel.shared.select(w)
                    self.overlayCtrl.selectedWindowID = w.id
                    self.overlayCtrl.runNow()
                    self.pickerPanel?.orderOut(nil)
                }))
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 400),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
            p.level = .floating
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.isFloatingPanel = true
            p.becomesKeyOnlyIfNeeded = false
            p.hidesOnDeactivate = false
            p.isMovableByWindowBackground = true
            p.isReleasedWhenClosed = false
            p.isOpaque = false
            p.backgroundColor = .clear
            finishPanel(p)   // ★ layer 圆角 mask + window 投影（直角边框根治）
            p.contentView = content
            pickerPanel = p
        }
        Task { await AppModel.shared.refreshWindows() }
        guard let p = pickerPanel else { return }
        repositionPicker()
        p.orderFrontRegardless()
        Log.info("窗口选择浮层已打开")
    }

    @objc private func onClosePicker() {
        pickerPanel?.orderOut(nil)
    }

    /// 「自动选窗」（2026-10-18）：找标题含雀魂/英文名的窗口并选中；
    /// 找不到就打开选择浮层让用户手动选。
    @objc private func onAutoPickWindow() {
        guard let w = AppModel.shared.majsoulWindow() else {
            Log.info("自动选窗：没找到雀魂窗口，打开选择浮层")
            openWindowPicker()
            return
        }
        AppModel.shared.select(w)
        overlayCtrl.selectedWindowID = w.id
        overlayCtrl.runNow()
        Log.info("自动选窗：\(w.appName) — \(w.title)")
    }

    /// 松手后再跟随（2026-10-18）：拖动中 didMove 每帧触发，逐帧重定位
    /// 看起来断断续续——debounce 250ms，拖停/松手才真正挪 picker。
    private func schedulePickerFollow() {
        pickerFollowWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.repositionPicker() }
        pickerFollowWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: w)
    }

    /// picker 贴主浮窗左上（下方 10pt 间隙）。主浮窗移动/缩放时调用。
    /// ★ 不能加 isVisible 守卫：首次打开时 picker 还没 orderFront，守卫会跳过
    // 定位 → 窗口停在 NSPanel 创建原点 (0,0) = 屏幕左下角，之后拖主浮窗才
    // 跳过来（2026-10-16 用户反馈）。隐藏时设位置无副作用，随时可调。
    private func repositionPicker() {
        guard let p = pickerPanel, let main = panel else { return }
        p.setFrameOrigin(NSPoint(x: main.frame.minX,
                                 y: main.frame.minY - p.frame.height - 10))
    }
    @objc private func onHidePanel() { panel?.orderOut(nil) }
    @objc private func onOpenSettings() { openSettings() }
    @objc private func onCheckUpdates() { UpdaterManager.shared.checkForUpdates() }
    @objc private func onCloseSettings() { settingsWindow?.orderOut(nil) }
    @objc private func onQuickAnalyze() { AppModel.shared.analyze(deep: false) }
    @objc private func onDeepAnalyze() { AppModel.shared.analyze(deep: true) }

    @objc private func onOpenConfigDir() {
        NSWorkspace.shared.open(ConfigStore.shared.dirURL)
    }

    @objc private func onQuit() {
        Log.info("退出")
        NSApp.terminate(nil)
    }
}


// MARK: - NSBezierPath 旋转 helper（菜单栏矢量图标用）

private extension NSBezierPath {
    /// 绕 center 旋转（度）。注意 NSBezierPath.transform(using:) 要的是
    /// **SwiftUI AffineTransform**，不是 NSAffineTransform。
    func rotate(degrees: CGFloat, about center: CGPoint) {
        let rad = degrees * .pi / 180
        var cg = CGAffineTransform.identity
        cg = cg.translatedBy(x: center.x, y: center.y)
        cg = cg.rotated(by: rad)
        cg = cg.translatedBy(x: -center.x, y: -center.y)
        // 矩阵分量桥接（SDK 标签是 m11/m12/m21/m22/tX/tY）
        transform(using: AffineTransform(m11: cg.a, m12: cg.b, m21: cg.c,
                                         m22: cg.d, tX: cg.tx, tY: cg.ty))
    }
}
