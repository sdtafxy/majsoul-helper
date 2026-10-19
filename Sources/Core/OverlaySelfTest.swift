import Foundation
import AppKit
import CoreGraphics
import SwiftUI

/// Overlay 链路的**无界面自测**。
///
/// 存在的理由（很实际）：
/// Overlay 是「窗口 + 图层 + 定时器 + 子进程」四件套，一旦出问题，
/// 光看界面很难判断是「切分错了」「识别错了」「坐标映射错了」还是「图层没跟上」。
/// 所以必须有一条能离线跑的验证命令：给定一张图 → 跑算法 → **画出图层实际会画的东西**
/// 与原图叠在一起 → 人眼核对。
///
/// 命令：
///     --overlay <图片路径> [--out 目录]
///
/// 输出：
///     <目录>/overlay_对照.png     原图 + 框 + 牌名（就是用户看到的图层）
///     stdout:逐张清单 + 耗时 + 汇总
enum OverlaySelfTest {

    /// ★ 用 `await` 而不是 `DispatchSemaphore.wait()` ★
    ///   之前在 async 函数里 `sem.wait()` 阻塞当前线程，而 `OverlayEngine.run`
    ///   内部要 hop 到 MainActor —— 若当前就是主线程，**必然死锁**
    ///   （表现：打印完「CLI:」就永远停住，一个字都不出来）。
    static func run(imagePath: String, outDir: String) async -> Int32 {
        print("========== Overlay 切分/识别 自测 ==========")
        guard FileManager.default.fileExists(atPath: imagePath) else {
            print("❌ 读不到图片：\(imagePath)")
            return 1
        }
        print("输入: \(imagePath)")

        // ---- 1. 找 Python ----
        let pys = OverlayEngine.pythonCandidates()
        guard !pys.isEmpty else {
            print("❌ 找不到 Python。试过：\(OverlayEngine.pythonCandidates().joined(separator: ", "))")
            print("   Overlay 模式需要内置引擎或同级目录的 majsoul-vision。")
            return 2
        }
        print("Python: \(pys[0])")
        print("脚本  : \(OverlayEngine.devScript() ?? "（无，使用内置引擎）")")

        // ---- 2. 跑 ----
        var result: OverlayResult?
        var errMsg = ""
        do {
            result = try await OverlayEngine.run(imagePath: imagePath, lowScore: 0.70)
        } catch {
            errMsg = error.localizedDescription
        }

        if let e = result {
            print("识别耗时: \(e.elapsedMS) ms")
            print("图像\(Int(e.imageSize.width))×\(Int(e.imageSize.height))"
                  + "  画布 \(Int(e.canvas.minX)),\(Int(e.canvas.minY)) "
                  + "\(Int(e.canvas.width))×\(Int(e.canvas.height))")
            let s = e.summary
            print("汇总: 共 \(s["total"] ?? 0) · 认出 \(s["recognized"] ?? 0)"
                  + " · 白板 \(s["blank"] ?? 0) · 无结果 \(s["none"] ?? 0)"
                  + " · 低置信 \(s["low"] ?? 0)")
            print("")
            for seat in e.seats {
                print("── \(seat.cnName)（\(seat.key)）\(seat.tiles.count) 张")
                var line = [String]()
                for t in seat.tiles {
                    let mark: String
                    if t.name == nil { mark = "★未识别" }
                    else if t.isBlank { mark = "" }
                    else if t.isLow { mark = "↓" }
                    else { mark = "" }
                    line.append("\(t.name ?? "?")\(mark)")
                }
                print("    \(line.joined(separator: " "))")
            }
            if let hand = e.hand, !hand.tiles.isEmpty {
                let names = hand.tiles.map { ($0.name ?? "?") + ($0.isDrawn ? "·摸" : "") }
                print("── 手牌 \(hand.tiles.count) 张"
                      + (hand.meldTiles > 0 ? "（副露 \(hand.meldTiles) 张）" : ""))
                print("    \(names.joined(separator: " "))")
            }

            // ---- 3. 出对照图（就是图层会画的东西）----
            if let img = loadCG(imagePath) {
                try? FileManager.default.createDirectory(atPath: outDir,
                                                         withIntermediateDirectories: true)
                let png = renderOverlayPreview(base: img, result: e)
                let out = (outDir as NSString).appendingPathComponent("overlay_对照.png")
                // CGImage 自己不能写 PNG，要借 NSBitmapImageRep 编码
                let rep = NSBitmapImageRep(cgImage: png)
                if let d = rep.representation(using: .png, properties: [:]) {
                    try? d.write(to: URL(fileURLWithPath: out))
                    print("")
                    print("✅ 对照图（用户看到的图层效果）：\(out)")
                    print("   ↑绿=自家/对家 黄=侧家 橙=低置信 灰=白板 红=未识别 ↓=低置信牌")
                }
            }
            return 0
        }

        print("❌ 失败：\(errMsg)")
        return 1
    }

    // MARK: - 出图

    /// 把 OverlayView 的绘制逻辑搬到 CGContext 上，画进原图。
    ///
    /// ★ 为什么不直接截 NSView ★
    /// 自测是无界面模式，没有 NSWindow 可截。而**验证的重点正是「映射对不对」**
    /// （像素 → 点、y 翻转、缩放比），所以必须在**真实像素尺寸**上画，
    /// 再把结果当成用户会看到的样子来核对。
    private static func renderOverlayPreview(base: CGImage, result: OverlayResult) -> CGImage {
        let W = base.width, H = base.height
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: W, height: H,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return base }
        ctx.draw(base, in: CGRect(x: 0, y: 0, width: W, height: H))

        // 叠加一层暗底，让框更醒目
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.22).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))

        // ★★ 坐标换算：ctx 保持**Cocoa 朝向（y 向上）**，不翻转 ctx ★★
        //   识别结果的坐标是「原图像素、原点左上、y 向下」，
        //   所以在这里一次性转成 Cocoa：y_cocoa = H − y_img。
        //
        //   为什么不能靠翻转 ctx 来适配 ★★★
        //   翻转 ctx（translate + scale(1,-1)）之后，**所有**绘制都会跟着翻：
        //   CoreText 的 CTLineDraw、NSAttributedString.draw 都不例外。
        //   踩过一次：翻ctx 之后侧家牌名全部上下颠倒（`2s`→`s2`）；
        //   改成「不翻 ctx、在算点时转y」立刻正确。
        //   —— 翻转 ctx 会让「画形状」变方便，但会让「画文字」反向，
        //      而文字必须正，两头讨好不了，只能选一边：选「不翻」。
        let Hf = CGFloat(H)
        func toCocoa(_ p: CGPoint) -> CGPoint {
            CGPoint(x: p.x, y: Hf - p.y)
        }

        let scale = result.imageSize.width > 0 ? CGFloat(W) / result.imageSize.width : 1
        for seat in result.seats {
            for t in seat.tiles where t.quad.count == 4 {
                let pts = t.quad.map { CGPoint(x: $0.x * scale, y: $0.y * scale) }.map(toCocoa)
                let color = Self.color(for: t, seatKey: seat.key)
                ctx.saveGState()
                ctx.setStrokeColor(color)
                ctx.setLineWidth(2.0)
                ctx.setLineJoin(.round)
                ctx.move(to: pts[0])
                for p in pts.dropFirst() { ctx.addLine(to: p) }
                ctx.closePath()
                ctx.strokePath()
                if let c = NSColor(cgColor: color)?.withAlphaComponent(0.12) {
                    ctx.setFillColor(c.cgColor)
                    ctx.fillPath()
                }
                ctx.restoreGState()
                Self.drawLabel(t.name ?? "?", at: pts, color: color, ctx: ctx,
                               canvasW: CGFloat(W), canvasH: Hf)
            }
        }
        // 自家手牌：青色框 + 摸牌加粗；副露区紫色虚线
        if let hand = result.hand {
            if let m = hand.meldRect {
                let a = toCocoa(CGPoint(x: m.minX * scale, y: m.minY * scale))
                let b = toCocoa(CGPoint(x: m.maxX * scale, y: m.maxY * scale))
                ctx.saveGState()
                ctx.setStrokeColor(NSColor.systemPurple.cgColor)
                ctx.setLineWidth(1.5)
                ctx.setLineDash(phase: 0, lengths: [6, 4])
                ctx.stroke(CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                                  width: abs(b.x - a.x), height: abs(b.y - a.y)))
                ctx.restoreGState()
            }
            for t in hand.tiles {
                let pts = [CGPoint(x: t.rect.minX * scale, y: t.rect.minY * scale),
                           CGPoint(x: t.rect.maxX * scale, y: t.rect.minY * scale),
                           CGPoint(x: t.rect.maxX * scale, y: t.rect.maxY * scale),
                           CGPoint(x: t.rect.minX * scale, y: t.rect.maxY * scale)]
                    .map(toCocoa)
                ctx.saveGState()
                ctx.setStrokeColor(NSColor.systemCyan.cgColor)
                ctx.setLineWidth(t.isDrawn ? 3.0 : 1.5)
                ctx.setLineJoin(.round)
                ctx.move(to: pts[0])
                for p in pts.dropFirst() { ctx.addLine(to: p) }
                ctx.closePath()
                ctx.strokePath()
                ctx.restoreGState()
                Self.drawLabel((t.name ?? "?") + (t.isDrawn ? "·摸" : ""),
                               at: pts, color: NSColor.systemCyan.cgColor,
                               ctx: ctx, canvasW: CGFloat(W), canvasH: Hf)
            }
        }
        // 宝牌指示牌：橙色框 + 「宝」前缀标签
        if let dora = result.dora {
            for s in dora.slots {
                let pts = [CGPoint(x: s.rect.minX * scale, y: s.rect.minY * scale),
                           CGPoint(x: s.rect.maxX * scale, y: s.rect.minY * scale),
                           CGPoint(x: s.rect.maxX * scale, y: s.rect.maxY * scale),
                           CGPoint(x: s.rect.minX * scale, y: s.rect.maxY * scale)]
                    .map(toCocoa)
                ctx.saveGState()
                ctx.setStrokeColor(NSColor.systemOrange.cgColor)
                ctx.setLineWidth(1.5)
                ctx.move(to: pts[0])
                for p in pts.dropFirst() { ctx.addLine(to: p) }
                ctx.closePath()
                ctx.strokePath()
                ctx.restoreGState()
                if let n = s.name {
                    Self.drawLabel("宝" + n, at: pts,
                                   color: NSColor.systemOrange.cgColor,
                                   ctx: ctx, canvasW: CGFloat(W), canvasH: Hf)
                }
            }
        }
        return ctx.makeImage() ?? base
    }

    /// 用 CoreText 画标签。**不用 NSAttributedString.draw**。
    ///
    /// ★ 为什么不用 AppKit 的文本绘制 ★
    /// `NSAttributedString.draw` 只认 Cocoa 坐标（y 向上），而这里的 ctx 为了
    /// 直接吃识别结果的坐标已经翻成「y 向下」。两者混用要靠
    /// `NSGraphicsContext(cgContext:flipped:)` 二次翻转，而那个 `flipped`
    /// 参数的语义实测**与直觉相反**（`flipped: true` 画出来的字是倒的），
    /// 踩了一次：侧家牌名全部上下颠倒（`2s` → `s2`），自家/对家却看着正常。
    ///
    /// CoreText 的 `CTLineDraw` 直接吃 CGGContext 的当前用户空间坐标，
    /// 不做任何隐式翻转 —— 没有歧义，也没有第二次翻转。
    private static func drawLabel(_ text: String, at pts: [CGPoint],
                                  color: CGColor, ctx: CGContext,
                                  canvasW: CGFloat, canvasH: CGFloat) {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .bold)
        let attr = NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: NSColor(cgColor: color) ?? .white,
        ])
        let line = CTLineCreateWithAttributedString(attr)
        let b = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        // ★ CTLine 的 bounds.origin.y 通常是**负数**（基线以下），
        //   height = maxY − minY 是正的，但 `bounds.height` 这个简写
        //   在 Swift 里等价于 (maxY − minY)，实测是**负的**（例：−3.8/21.2）。
        //   → 直接用它算框高会得到负值，框被画到画面外，**标签整段消失**。
        //     实测踩过：框都对、标签一个都没有。
        //   正确做法：只用 origin.x 与 width，垂直方向自己按行高算。
        let padX: CGFloat = 3
        let lineH: CGFloat = ceil(font.ascender - font.descender)
        let padY: CGFloat = 1

        // pts 已是 Cocoa 坐标（y 向上）→ 「框顶之上」= y 更大
        let topMid = CGPoint(x: (pts[0].x + pts[1].x) / 2,
                             y: max(pts[0].y, pts[1].y))
        let w = b.width + padX*2
        let h = lineH + padY*2
        var x = topMid.x - w/2
        var y = topMid.y + 3 + h          // 上方
        if y + h > canvasH { y = topMid.y - h - 3 }       // 顶到边界就翻到框内
        if x < 2 { x = 2 }
        if x + w > canvasW { x = canvasW - w - 2 }
        let box = CGRect(x: x, y: y, width: w, height: h)

        ctx.saveGState()
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.75).cgColor)
        ctx.fill(box)
        ctx.setStrokeColor(color)
        ctx.setLineWidth(1)
        ctx.stroke(box)
        // ctx 是 Cocoa 朝向（y 向上），CoreText 直接用这个坐标
        // 基线对齐：行盒底 + (行高 − (ascender−descender))/2 − descender
        let tx = box.minX + padX - b.origin.x
        let ty = box.minY + padY - font.descender
        ctx.textMatrix = .identity
        ctx.textPosition = CGPoint(x: tx, y: ty)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    private static func color(for t: OverlayTile, seatKey: String) -> CGColor {
        if t.name == nil { return NSColor.systemRed.cgColor }
        if t.isBlank { return NSColor.systemGray.cgColor }
        if t.isLow { return NSColor.systemOrange.cgColor }
        return (seatKey == "own" || seatKey == "across")
            ? NSColor.systemYellow.cgColor
            : NSColor.systemGreen.cgColor
    }

    static func loadCG(_ path: String) -> CGImage? {
        guard let img = NSImage(contentsOfFile: path) else { return nil }
        var rect = NSRect(origin: .zero, size: img.size)
        return img.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }
}

/// 容器渲染兼容性对照（ImageRenderer 下的空白排查）。
///
/// ★ 为什么需要它 ★
/// 「界面空白」时最容易被带着猜组件（我猜过自定义 Layout、猜过 LazyVGrid，都不是）。
/// 正解是：**把几种容器并排渲染一次**，看哪个在 `ImageRenderer` 下不画内容。
/// 实测结论：`ScrollView` 在 `ImageRenderer` 下**不渲染其内容**——
/// 而真机 App 里完全正常，所以这类 bug 只有 --snapshot 抓得到。
enum ContainerProbe {
    struct V: View {
        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                Text("A ScrollView").font(.system(size: 11, weight: .bold))
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(0..<8) { i in
                            Text("scroll-\(i)").font(.system(size: 9))
                        }
                    }
                }
                .frame(height: 76)
                .background(Color.orange.opacity(0.25))

                Text("B 裸 VStack").font(.system(size: 11, weight: .bold))
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(0..<8) { i in
                        Text("plain-\(i)").font(.system(size: 9))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 76, alignment: .top)
                .background(Color.green.opacity(0.25))

                Text("C LazyVGrid").font(.system(size: 11, weight: .bold))
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 34), spacing: 3)],
                          alignment: .leading, spacing: 3) {
                    ForEach(0..<12) { i in
                        Text("g\(i)").font(.system(size: 9))
                    }
                }
                .frame(height: 60, alignment: .top)
                .background(Color.blue.opacity(0.25))
            }
            .frame(width: 300)
            .padding(10)
        }
    }

    @MainActor
    static func run(out path: String) {
        let r = ImageRenderer(content: V())
        r.scale = 2
        guard let img = r.nsImage, let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            print("容器对照图失败")
            return
        }
        try? png.write(to: URL(fileURLWithPath: path))
        print("  ✓ \(path)  ← A 有内容=ScrollView 可用；A 空白=ScrollView 在 ImageRenderer 下不渲染")
    }
}
