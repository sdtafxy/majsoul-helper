import Foundation
import AppKit
import CoreGraphics
import ScreenCaptureKit

// ══════════════════════════════════════════════════════════════════
//  Overlay 图层：把切分框与识别结果画在目标窗口之上
// ══════════════════════════════════════════════════════════════════
//
//  ★★★ 坐标系（本文件最容易错的地方）★★★
//  三套坐标，方向和原点都不一样：
//    ① 识别结果（来自 overlay_cli.py）= **原图像素坐标，原点左上，y 向下**
//    ② CGWindow.frame                = **全局 CG 坐标，原点主屏左上，y 向下**
//    ③ NSWindow.frame                = **Cocoa 坐标，原点主屏左下，y 向上**
//
//  绘制路径：① →（÷截图缩放比）→ 视图坐标 → 视图是翻转的 → NSBezierPath
//  NSView 默认 isFlipped = false（y 向上），所以视图坐标 y 要再翻一次。
//  ①② 之间只差缩放，②→③ 用 `cgToCocoa` 换算。
//
//  实测记录（都踩过）：
//   · 用 `NSView.isFlipped = true` 会连带影响子视图布局，这里不用。
//   · 直接把 CGWindow.frame 赋给 NSWindow.frame → 窗口上下颠倒。
//   · 截图缩放比必须算准：截图是 Retina 原生像素（如 2x），
//     而窗口 frame 是**点**，差一个 devicePixelRatio。

@MainActor
final class OverlayView: NSView {

    var result: OverlayResult = .empty {
        didSet {
            // 从「图片像素」到「视图点」的换算因子
            self.scaleToView = result.imageSize.width > 0
                ? bounds.width / result.imageSize.width : 1
            needsDisplay = true
        }
    }

    /// 截图像素 → 视图点
    private var scaleToView: CGFloat = 1
    /// 是否显示识别文字
    var showLabels: Bool = true
    /// 是否显示状态条
    var showHUD: Bool = true
    /// 分类开关（2026-10-10：手牌/牌河/副露/宝牌各自可关）
    var showHand: Bool = true
    var showRiver: Bool = true
    var showMeld: Bool = true
    var showDora: Bool = true
    /// 状态文字（识别中/失败原因等）
    var statusText: String = ""

    override var isFlipped: Bool { false }        // 用 Cocoa 坐标，下面手工翻 y

    override var acceptsFirstResponder: Bool { false }

    // MARK: - 绘制

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setShouldAntialias(true)

        if showRiver {
            for seat in result.seats {
                for t in seat.tiles {
                    drawTile(t, seat: seat, in: ctx)
                }
            }
        }
        // 自家手牌（2026-10-09）：青色框 + 牌名，摸牌单独加粗
        if showHand, let hand = result.hand {
            for t in hand.tiles { drawHandTile(t, in: ctx) }
        }
        // 副露逐张框（2026-10-11）：之前只画 hand.meldRect 的虚线大框，
        //   用户反馈「切分框画得不对」——改画 meld_split 的逐张四边形
        if showMeld {
            for (_, m) in result.melds {
                for g in m.groups {
                    for t in g where t.quad.count == 4 {
                        drawMeldTile(t, in: ctx)
                    }
                }
            }
        }
        // 宝牌指示牌（2026-10-09）：橙色框
        if showDora, let dora = result.dora {
            for s in dora.slots { drawDoraSlot(s, in: ctx) }
        }
        if showHUD { drawHUD(in: ctx) }
    }

    /// 宝牌指示牌槽位：橙色框 + 牌名
    private func drawDoraSlot(_ s: (rect: CGRect, name: String?, score: Double),
                              in ctx: CGContext) {
        let r = s.rect
        let pts = [
            CGPoint(x: r.minX * scaleToView, y: bounds.height - r.minY * scaleToView),
            CGPoint(x: r.maxX * scaleToView, y: bounds.height - r.minY * scaleToView),
            CGPoint(x: r.maxX * scaleToView, y: bounds.height - r.maxY * scaleToView),
            CGPoint(x: r.minX * scaleToView, y: bounds.height - r.maxY * scaleToView),
        ]
        let color = NSColor.systemOrange.cgColor
        ctx.saveGState()
        ctx.setStrokeColor(color)
        ctx.setLineWidth(1.5)
        ctx.move(to: pts[0])
        for p in pts.dropFirst() { ctx.addLine(to: p) }
        ctx.closePath()
        ctx.strokePath()
        ctx.restoreGState()

        guard showLabels, let name = s.name else { return }
        let text = "宝" + name
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .bold),
            .foregroundColor: NSColor.systemOrange,
        ]
        let att = NSAttributedString(string: text, attributes: attrs)
        let size = att.size()
        let topMid = CGPoint(x: (pts[0].x + pts[1].x) / 2, y: (pts[0].y + pts[1].y) / 2)
        var box = NSRect(x: topMid.x - size.width / 2 - 3, y: topMid.y + 2,
                         width: size.width + 6, height: size.height + 2)
        if box.minY < 0 { box.origin.y = topMid.y - box.height - 4 }
        if box.minX < 2 { box.origin.x = 2 }
        box = box.intersection(bounds)
        guard box.width > 0, box.height > 0 else { return }
        let path = NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3)
        NSColor.black.withAlphaComponent(0.72).setFill()
        path.fill()
        att.draw(at: NSPoint(x: box.minX + 3, y: box.minY + 1))
    }

    /// 自家副露区：淡紫色虚线框（摆放在手牌右侧、透视压缩，只提示「有副露」）
    private func drawMeldBox(_ rect: CGRect, in ctx: CGContext) {
        let p0 = CGPoint(x: rect.minX * scaleToView, y: bounds.height - rect.minY * scaleToView)
        let p1 = CGPoint(x: rect.maxX * scaleToView, y: bounds.height - rect.maxY * scaleToView)
        ctx.saveGState()
        ctx.setStrokeColor(NSColor.systemPurple.cgColor)
        ctx.setLineWidth(1.5)
        ctx.setLineDash(phase: 0, lengths: [5, 3])
        ctx.stroke(CGRect(x: p0.x, y: p1.y, width: p1.x - p0.x, height: p0.y - p1.y))
        ctx.restoreGState()
    }

    private func drawMeldTile(_ t: OverlayMeldTile, in ctx: CGContext) {
        let pts = t.quad.map {
            CGPoint(x: $0.x * scaleToView, y: bounds.height - $0.y * scaleToView)
        }
        ctx.saveGState()
        ctx.setStrokeColor(NSColor.systemPurple.cgColor)
        ctx.setLineWidth(1.8)
        ctx.move(to: pts[0])
        for p in pts.dropFirst() { ctx.addLine(to: p) }
        ctx.closePath()
        ctx.strokePath()
        ctx.setFillColor(NSColor.systemPurple.withAlphaComponent(0.08).cgColor)
        ctx.fillPath()
        ctx.restoreGState()
        guard showLabels, let n = t.name else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .bold),
            .foregroundColor: NSColor.systemPurple,
        ]
        let att = NSAttributedString(string: n, attributes: attrs)
        let size = att.size()
        let topMid = CGPoint(x: (pts[0].x + pts[1].x) / 2, y: (pts[0].y + pts[1].y) / 2)
        var box = NSRect(x: topMid.x - size.width / 2 - 3, y: topMid.y + 2,
                         width: size.width + 6, height: size.height + 2)
        if box.minY + box.height > bounds.maxY { box.origin.y = topMid.y - box.height - 6 }
        if box.minX < 2 { box.origin.x = 2 }
        if box.maxX > bounds.maxX - 2 { box.origin.x = bounds.maxX - box.width - 2 }
        box = box.intersection(bounds)
        guard box.width > 0, box.height > 0 else { return }
        let path = NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3)
        NSColor.black.withAlphaComponent(0.72).setFill()
        path.fill()
        att.draw(at: NSPoint(x: box.minX + 3, y: box.minY + 1))
    }

    private func drawHandTile(_ t: OverlayHandTile, in ctx: CGContext) {
        let r = t.rect
        let pts = [
            CGPoint(x: r.minX * scaleToView, y: bounds.height - r.minY * scaleToView),
            CGPoint(x: r.maxX * scaleToView, y: bounds.height - r.minY * scaleToView),
            CGPoint(x: r.maxX * scaleToView, y: bounds.height - r.maxY * scaleToView),
            CGPoint(x: r.minX * scaleToView, y: bounds.height - r.maxY * scaleToView),
        ]
        // 摸牌更醒目：青色实线 + 淡青填充；暗牌普通
        let color = NSColor.systemCyan.cgColor
        ctx.saveGState()
        ctx.setStrokeColor(color)
        ctx.setLineWidth(t.isDrawn ? 3.0 : 1.5)
        ctx.move(to: pts[0])
        for p in pts.dropFirst() { ctx.addLine(to: p) }
        ctx.closePath()
        ctx.strokePath()
        ctx.setFillColor(NSColor.systemCyan.withAlphaComponent(0.10).cgColor)
        ctx.fillPath()
        ctx.restoreGState()

        guard showLabels else { return }
        drawHandLabel(t, at: pts)
    }

    private func drawHandLabel(_ t: OverlayHandTile, at pts: [CGPoint]) {
        let text = (t.name ?? "?") + (t.isDrawn ? "·摸" : "")
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .bold),
            .foregroundColor: NSColor.systemCyan,
        ]
        let att = NSAttributedString(string: text, attributes: attrs)
        let size = att.size()
        let topMid = CGPoint(x: (pts[0].x + pts[1].x) / 2, y: (pts[0].y + pts[1].y) / 2)
        var box = NSRect(x: topMid.x - size.width / 2 - 3, y: topMid.y + 2,
                         width: size.width + 6, height: size.height + 2)
        if box.minY + box.height > bounds.maxY { box.origin.y = topMid.y - box.height - 6 }
        if box.minX < 2 { box.origin.x = 2 }
        if box.maxX > bounds.maxX - 2 { box.origin.x = bounds.maxX - box.width - 2 }
        box = box.intersection(bounds)
        guard box.width > 0, box.height > 0 else { return }
        let path = NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3)
        NSColor.black.withAlphaComponent(0.72).setFill()
        path.fill()
        att.draw(at: NSPoint(x: box.minX + 3, y: box.minY + 1))
    }

    private func drawTile(_ t: OverlayTile, seat: OverlaySeat, in ctx: CGContext) {
        guard t.quad.count == 4 else { return }
        // 图片像素 → 视图点（y翻转）
        let pts = t.quad.map { p -> CGPoint in
            CGPoint(x: p.x * scaleToView, y: bounds.height - p.y * scaleToView)
        }

        let color = Self.color(for: t, seatKey: seat.key)
        ctx.saveGState()
        ctx.setStrokeColor(color)
        ctx.setLineWidth(2.0)
        ctx.setLineJoin(.round)
        if t.quad.count == 4 {
            ctx.move(to: pts[0])
            for p in pts.dropFirst() { ctx.addLine(to: p) }
            ctx.closePath()
        }
        ctx.strokePath()
        // 半透明填充，让框在牌面上更容易看
        if let c = NSColor(cgColor: color)?.withAlphaComponent(0.10) {
            ctx.setFillColor(c.cgColor)
            ctx.fillPath()
        }
        ctx.restoreGState()

        guard showLabels else { return }
        drawLabel(t, at: pts, color: color)
    }

    /// 标签画在框的**紧邻上方**，优先放框顶之上；顶到边界就翻到框内下方。
    private func drawLabel(_ t: OverlayTile, at pts: [CGPoint], color: CGColor) {
        let text = t.name ?? "?"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .bold),
            .foregroundColor: NSColor(cgColor: color) ?? .white,
        ]
        let att = NSAttributedString(string: text, attributes: attrs)
        let size = att.size()
        // 以框顶边的中点为锚
        let topMid = CGPoint(x: (pts[0].x + pts[1].x) / 2, y: (pts[0].y + pts[1].y) / 2)

        var box = NSRect(x: topMid.x - size.width / 2 - 3,
                         y: topMid.y + 2,          // Cocoa y 向上 → 放上方
                         width: size.width + 6,
                         height: size.height + 2)
        if box.minY + box.height > bounds.maxY { box.origin.y = topMid.y - box.height - 6 }
        if box.minX < 2 { box.origin.x = 2 }
        if box.maxX > bounds.maxX - 2 { box.origin.x = bounds.maxX - box.width - 2 }
        box = box.intersection(bounds)
        guard box.width > 0, box.height > 0 else { return }

        let path = NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3)
        NSColor.black.withAlphaComponent(0.72).setFill()
        path.fill()
        NSColor(cgColor: color)?.setStroke()
        path.lineWidth = 1
        path.stroke()
        att.draw(at: NSPoint(x: box.minX + 3, y: box.minY + 1))
    }

    private func drawHUD(in ctx: CGContext) {
        guard !statusText.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let att = NSAttributedString(string: statusText, attributes: attrs)
        let size = att.size()
        // 左下角（2026-10-18 用户要求：避开窗口红黄绿灯所在的左上角）
        let box = NSRect(x: 8, y: 8,
                         width: size.width + 12, height: size.height + 6)
        NSColor.black.withAlphaComponent(0.66).setFill()
        NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
        att.draw(at: NSPoint(x: box.minX + 6, y: box.minY + 3))
    }

    /// 框的颜色 = 主题 + 置信 + 花色。语义优先级：失败 > 白板 > 低置信 > 四家色。
    /// 主题来自 Settings.overlayTheme（2026-10-16：预设/自定义，OverlayController
    /// 在主题变化时主动重绘）。
    static func color(for t: OverlayTile, seatKey: String) -> CGColor {
        let theme = AppModel.shared.settings.overlayTheme
        if t.name == nil { return theme.color(.fail) }
        // ★ 白板不再单独灰框（2026-10-18 用户反馈：白板也是算法识别结果，
        //   不该被特殊标记）——按所属家的正常色画。
        if t.isLow { return theme.color(.low) }
        if let k = OverlayTheme.Key(rawValue: seatKey) {
            return theme.color(k)
        }
        // 未知 seat（理论不出现）：回退低置信色
        return theme.color(.low)
    }
}

/// 透明置顶图层窗口
@MainActor
final class OverlayWindowController {

    private(set) var window: NSWindow?
    private(set) var view: OverlayView?
    private var followTimer: Timer?
    /// 用户手动 hide 后，follow timer 不得再自动 show（2026-10-10）
    private var manuallyHidden = false
    /// 当前跟随的目标窗口
    private(set) var targetWindowID: Int = 0

    /// 目标窗口上一次的位置/大小，用来判断要不要重画
    private var lastTargetFrame: CGRect = .zero

    func attach() {
        guard window == nil else { return }
        let v = OverlayView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let w = NSWindow(contentRect: v.frame,
                         styleMask: [.borderless],
                         backing: .buffered,
                         defer: false)
        w.contentView = v
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.level = .floating          // 浮在普通窗口之上
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        w.isMovableByWindowBackground = false
        w.isReleasedWhenClosed = false
        w.isRestorable = false
        w.ignoresMouseEvents = true        // ★ 完全不吃点击，游戏照常操作
        w.hidesOnDeactivate = false
        window = w
        view = v
    }

    func show() {
        manuallyHidden = false
        attach()
        window?.orderFrontRegardless()
    }

    func hide() {
        manuallyHidden = true
        window?.orderOut(nil)
    }

    /// 绑定目标窗口并开始跟随
    func follow(windowID: Int) {
        attach()
        targetWindowID = windowID
        startFollowing()
    }

    func stopFollowing() {
        followTimer?.invalidate()
        followTimer = nil
        targetWindowID = 0
    }

    /// 目标窗口的位置/大小可能随时变（拖动、缩放、切屏），
    /// 所以要持续轮询它的 frame 并同步到图层窗口。
    private func startFollowing() {
        followTimer?.invalidate()
        followTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncToTarget() }
        }
        // 先立刻同步一次，别等第一个 tick
        syncToTarget()
        RunLoop.main.add(followTimer!, forMode: .common)
    }

    /// 查询目标窗口当前 frame 并同步图层窗口。
    ///
    /// 用 ScreenCaptureKit 的共享内容拿窗口（与截图同一套 API，权限一致）。
    private func syncToTarget() {
        guard let w = window, targetWindowID != 0 else { return }
        Task { [weak self] in
            guard let self else { return }
            guard let f = await Self.frame(ofWindow: targetWindowID) else {
                // 窗口没了 → 收起图层，别留一个错位的框在那儿误导用户
                self.window?.orderOut(nil)
                return
            }
            let cocoa = Self.cgToCocoa(f)
            // 目标窗口没动就别白折腾
            if abs(cocoa.origin.x - self.lastTargetFrame.origin.x) > 0.5 ||
               abs(cocoa.origin.y - self.lastTargetFrame.origin.y) > 0.5 ||
               abs(cocoa.width - self.lastTargetFrame.width) > 0.5 ||
               abs(cocoa.height - self.lastTargetFrame.height) > 0.5 {
                self.lastTargetFrame = cocoa
                self.window?.setFrame(cocoa, display: true)
                self.view?.frame = NSRect(origin: .zero, size: cocoa.size)
                self.view?.needsDisplay = true
            }
            // ★ 用户手动 hide 后，follow timer 不能又把它 show 出来
            //   （否则点「图层」关闭 → 0.35s 后又弹出，2026-10-10 反馈）
            if !w.isVisible && !self.manuallyHidden { w.orderFrontRegardless() }
        }
    }

    static func frame(ofWindow id: Int) async -> CGRect? {
        guard let content = try? await SCShareableContent
            .excludingDesktopWindows(false, onScreenWindowsOnly: false) else { return nil }
        guard let win = content.windows.first(where: { Int($0.windowID) == id }) else { return nil }
        return win.frame
    }

    /// CG 全局坐标 → Cocoa 全局坐标。y 轴翻转，用主屏高度。
    static func cgToCocoa(_ f: CGRect) -> CGRect {
        let mainH = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: f.origin.x,
                      y: mainH - f.origin.y - f.height,
                      width: f.width, height: f.height)
    }
}

import ScreenCaptureKit