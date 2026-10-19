import Foundation
import AppKit
import CoreGraphics
import ScreenCaptureKit

/// 截图 + 编码。全链路 nonisolated，方便 `--selftest` 无界面调用。
enum ScreenCaptureService {

    struct Shot {
        let jpeg: Data
        let cgImage: CGImage      // 手牌切分要用原始位图，不能只留 JPEG
        let pixelWidth: Int
        let pixelHeight: Int
        let preview: NSImage
        var byteCount: Int { jpeg.count }
        var megapixels: Double { Double(pixelWidth * pixelHeight) / 1_000_000 }
    }

    enum CaptureError: LocalizedError {
        case windowNotFound(Int)
        case encodeFailed
        case noDisplay

        var errorDescription: String? {
            switch self {
            case .windowNotFound(let id): return "找不到窗口 \(id)，可能已关闭或最小化，请重新选择截图来源。"
            case .encodeFailed: return "截图编码失败。"
            case .noDisplay: return "没有找到可捕获的显示器。"
            }
        }
    }

    // MARK: - 按窗口捕获

    /// 抓指定窗口。用 `desktopIndependentWindow` 过滤器，因此：
    /// ① 窗口被别的窗口挡住也能拍到；② 拍出来只有这个窗口本身，不会把助手浮窗一起拍进去。
    static func capture(windowID: Int, maxSide: Int, jpegQuality: Double) async throws -> Shot {
        let content = try await SCShareableContent
            .excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let win = content.windows.first(where: { Int($0.windowID) == windowID }) else {
            throw CaptureError.windowNotFound(windowID)
        }
        let filter = SCContentFilter(desktopIndependentWindow: win)
        return try await shoot(filter: filter,
                               frameInCGPoints: win.frame,
                               maxSide: maxSide,
                               jpegQuality: jpegQuality)
    }

    // MARK: - 按显示器捕获（备选 / 自测用）

    static func captureDisplay(maxSide: Int, jpegQuality: Double) async throws -> Shot {
        let content = try await SCShareableContent
            .excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw CaptureError.noDisplay }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let frame = NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1512, height: 982)
        return try await shoot(filter: filter,
                               frameInCGPoints: frame,
                               maxSide: maxSide,
                               jpegQuality: jpegQuality)
    }

    // MARK: - 公共实现

    private static func shoot(filter: SCContentFilter,
                              frameInCGPoints frame: CGRect,
                              maxSide: Int,
                              jpegQuality: Double) async throws -> Shot {
        let scale = backingScaleFactor(forCGFrame: frame)
        // 目标像素：先按 Retina 原生像素算，再等比缩到「最长边」上限
        var w = frame.width * scale
        var h = frame.height * scale
        guard w >= 1, h >= 1 else { throw CaptureError.encodeFailed }
        let longest = max(w, h)
        if longest > CGFloat(maxSide) {
            let k = CGFloat(maxSide) / longest
            w *= k
            h *= k
        }

        let cfg = SCStreamConfiguration()
        cfg.width = max(1, Int(w.rounded()))
        cfg.height = max(1, Int(h.rounded()))
        cfg.showsCursor = false
        cfg.ignoreShadowsSingleWindow = true
        cfg.capturesAudio = false
        cfg.queueDepth = 1

        let cg = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let data = rep.representation(using: .jpeg,
                                            properties: [.compressionFactor: jpegQuality]) else {
            throw CaptureError.encodeFailed
        }
        return Shot(jpeg: data,
                    cgImage: cg,
                    pixelWidth: cg.width,
                    pixelHeight: cg.height,
                    preview: NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)))
    }

    /// 这块窗口落在哪个屏幕上，就取那个屏幕的缩放（Retina 通常 2）。
    ///
    /// 坐标要翻轴：CGWindow 的 bounds 原点在**主屏左上**、y 向下；
    /// NSScreen.frame 的原点在**主屏左下**、y 向上。所以 cocoaY = 主屏高 − cgMaxY。
    /// （多屏上下堆叠的极端摆放会有误差，此时退化为「取所有屏幕里最大的缩放」，
    ///   结果只是让 SC 多缩一次，不会丢细节。）
    static func backingScaleFactor(forCGFrame frame: CGRect) -> CGFloat {
        let screens = NSScreen.screens
        guard let main = screens.first else { return 2 }
        if frame.width > 0, frame.height > 0 {
            let cocoaY = main.frame.height - frame.maxY
            let center = CGPoint(x: frame.midX, y: cocoaY + frame.height / 2)
            for s in screens where s.frame.contains(center) { return s.backingScaleFactor }
        }
        return screens.map(\.backingScaleFactor).max() ?? 2
    }
}
