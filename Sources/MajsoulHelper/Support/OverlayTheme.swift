import AppKit
import SwiftUI

/// Overlay 标注配色主题（2026-10-16 用户需求：多套预设 + 自定义）。
///
/// 语义槽位：
/// - own/across/left/right：四家牌河/手牌的框色（正常识别）
/// - low：低置信（分数低于阈值，提醒人工核对）
/// - fail：识别失败（name == nil）
/// - blank：白板
///
/// 持久化：Settings.overlayTheme（Codable，hex 字符串存储）。
struct OverlayTheme: Codable, Equatable {
    var name: String = "经典"
    var own: String = "#FFCC00"
    var across: String = "#FFCC00"
    var left: String = "#34C759"
    var right: String = "#34C759"
    var low: String = "#FF9500"
    var fail: String = "#FF3B30"

    // MARK: - 预设

    /// 经典（原实现配色：seat 暖/冷 + 系统语义色）
    static let classic = OverlayTheme(
        name: "经典", own: "#FFCC00", across: "#FFCC00",
        left: "#34C759", right: "#34C759",
        low: "#FF9500", fail: "#FF3B30")

    /// 墨璃（与 app UI 同语言：蓝/紫/青/绿）
    static let inkGlass = OverlayTheme(
        name: "墨璃", own: "#5AA5FF", across: "#B08FFF",
        left: "#35C8C8", right: "#45D68A",
        low: "#FFB84D", fail: "#FF6B5E")

    /// 高对比（强可辨，适合明亮游戏画面/直播）
    static let highContrast = OverlayTheme(
        name: "高对比", own: "#FF3B30", across: "#FF9500",
        left: "#00C7BE", right: "#FFCC00",
        low: "#FFFFFF", fail: "#FF2D55")

    /// 柔色（低饱和护眼，长时间挂机）
    static let soft = OverlayTheme(
        name: "柔色", own: "#AF52DE", across: "#5856D6",
        left: "#5AC8FA", right: "#4CD964",
        low: "#FFCC00", fail: "#FF6482")

    static let presets: [OverlayTheme] = [.classic, .inkGlass, .highContrast, .soft]

    // MARK: - 取色

    func color(_ key: Key) -> CGColor {
        nsColor(key).cgColor
    }

    func nsColor(_ key: Key) -> NSColor {
        NSColor(hex: hex(key)) ?? .systemGray
    }

    private func hex(_ key: Key) -> String {
        switch key {
        case .own: return own
        case .across: return across
        case .left: return left
        case .right: return right
        case .low: return low
        case .fail: return fail
        }
    }

    enum Key: String, CaseIterable {
        case own, across, left, right, low, fail
        var label: String {
            switch self {
            case .own: return "自家"
            case .across: return "对家"
            case .left: return "上家"
            case .right: return "下家"
            case .low: return "低置信"
            case .fail: return "识别失败"
            }
        }
    }

    /// 当前主题与某预设是否一致（用于 UI 高亮）
    func matches(_ preset: OverlayTheme) -> Bool {
        name == preset.name && colorsEqual(preset)
    }

    /// 七槽颜色是否与另一主题一致（不管名字）
    func colorsEqual(_ o: OverlayTheme) -> Bool {
        own == o.own && across == o.across && left == o.left && right == o.right
            && low == o.low && fail == o.fail
    }

    /// 公开取某槽 hex（设置 UI 用）
    func hexString(_ key: Key) -> String { hex(key) }

    /// 设置某槽 hex（自定义微调；调用方负责把 name 改成「自定义」）
    mutating func setHex(_ hex: String, _ key: Key) {
        switch key {
        case .own: own = hex
        case .across: across = hex
        case .left: left = hex
        case .right: right = hex
        case .low: low = hex
        case .fail: fail = hex
        }
    }

    static func == (l: Self, r: Self) -> Bool {
        l.name == r.name && l.own == r.own && l.across == r.across
            && l.left == r.left && l.right == r.right && l.low == r.low
            && l.fail == r.fail
    }
}

// MARK: - hex 互转

extension NSColor {
    /// "#RRGGBB" → NSColor（大小写/无# 都容忍）；非法返回 nil
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(red: CGFloat((v >> 16) & 0xFF) / 255,
                  green: CGFloat((v >> 8) & 0xFF) / 255,
                  blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    var hexString: String {
        let r = Int((redComponent * 255).rounded())
        let g = Int((greenComponent * 255).rounded())
        let b = Int((blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
