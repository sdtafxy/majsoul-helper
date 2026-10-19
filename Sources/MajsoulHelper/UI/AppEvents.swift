import Foundation
import SwiftUI
import AppKit

extension Notification.Name {
    static let mhOpenSettings = Notification.Name("mh.openSettings")
    static let mhHidePanel = Notification.Name("mh.hidePanel")
    static let mhTogglePanel = Notification.Name("mh.togglePanel")
    static let mhToggleRecognition = Notification.Name("mh.toggleRecognition")
    static let mhPickWindow = Notification.Name("mh.pickWindow")
    /// 自动选择雀魂窗口（2026-10-18：主浮窗「自动选窗」按钮）
    static let mhAutoPickWindow = Notification.Name("mh.autoPickWindow")
    static let mhClosePicker = Notification.Name("mh.closePicker")
    static let mhCloseSettings = Notification.Name("mh.closeSettings")
    static let mhOverlayThemeChanged = Notification.Name("mh.overlayThemeChanged")
    static let mhQuit = Notification.Name("mh.quit")
}

/// 快照模式开关。
///
/// 为什么需要：`ImageRenderer` **渲染不了 `NSViewRepresentable`** —— 它不会报错，
/// 而是把那一块画成一个巨大的黄色禁止符号占位图，把整个界面盖住。
/// 所以毛玻璃背景必须在快照时换成纯色，否则 `--snapshot` 出来的图完全没法看。
enum SnapshotMode {
    static var isActive = false
}

/// 窗口背后真正的毛玻璃。做成 hitTest 返回 nil 的「放行视图」——
/// 否则它会盖在内容上把点击全吃掉（这是 NSVisualEffectView 铺满窗口时的经典坑）。
final class PassThroughVisualEffectView: NSVisualEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

struct VisualEffectBackground: View {
    var material: NSVisualEffectView.Material = .underWindowBackground

    var body: some View {
        if SnapshotMode.isActive {
            Color(nsColor: .windowBackgroundColor)
        } else {
            VisualEffectRepresentable(material: material)
        }
    }
}

/// 墨璃：深色玻璃（HUD 材质 + 深色叠加）。原型 rgba(24,26,30,.66) + blur。
struct InkGlassBackground: View {
    var body: some View {
        ZStack {
            if SnapshotMode.isActive {
                // 快照近似：ImageRenderer 不渲染 NSVisualEffectView
                Color(red: 0.094, green: 0.102, blue: 0.118).opacity(0.97)
            } else {
                VisualEffectRepresentable(material: .hudWindow)
                Color(red: 0.094, green: 0.102, blue: 0.118).opacity(0.66)
            }
        }
    }
}

/// 浮窗背景：三种效果
/// - glass（默认）：墨璃深色玻璃——压在游戏画面上不抢戏、跨背景可读
/// - solid：固定暖白底（浅色文字环境）
/// - clear：通透（透出桌面/游戏）
struct PanelBackground: View {
    var mode: String

    var body: some View {
        Group {
            if SnapshotMode.isActive {
                // 快照下照实画（否则看不到真实效果）
                if mode == "clear" { Color.clear }
                else if mode == "glass" { Color(red: 0.094, green: 0.102, blue: 0.118).opacity(0.97) }
                else { Theme.panelSolid }
            } else if mode == "glass" {
                InkGlassBackground()
            } else if mode == "clear" {
                Color.clear
            } else {
                Theme.panelSolid
            }
        }
    }
}

private struct VisualEffectRepresentable: NSViewRepresentable {
    var material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSView {
        let v = PassThroughVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .active
        v.autoresizingMask = [.width, .height]
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
