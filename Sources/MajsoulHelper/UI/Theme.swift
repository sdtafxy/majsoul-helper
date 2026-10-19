import SwiftUI
import AppKit

enum Theme {
    // ── 语义色（系统色系，用于徽章/强调）──
    static let accent = Color(red: 0.16, green: 0.50, blue: 0.86)
    static let danger = Color(red: 0.85, green: 0.27, blue: 0.23)
    static let warn = Color(red: 0.92, green: 0.60, blue: 0.10)
    static let ok = Color(red: 0.18, green: 0.64, blue: 0.38)
    static let idle = Color.secondary
    /// 按钮专用色：识别=青、深度=紫（快速用 accent 蓝）
    static let teal = Color(red: 0.13, green: 0.62, blue: 0.62)
    static let purple = Color(red: 0.52, green: 0.36, blue: 0.85)

    // ── 布局尺度（原型 v5：墨璃）──
    static let panelRadius: CGFloat = 22        // 面板圆角
    static let heroRadius: CGFloat = 17         // Hero 卡圆角
    static let cardRadius: CGFloat = 15         // 普通卡片圆角
    static let smallRadius: CGFloat = 12        // 按钮/药丸圆角
    static let gap: CGFloat = 14                // 主间距（8pt 网格）
    static let cardPadding: CGFloat = 14

    // ── 背景层次（浅色模式）──
    /// 面板底色：极浅暖白（solid 白底模式专用，不跟随主题）
    static let panelSolid = Color(red: 0.973, green: 0.972, blue: 0.963)
    /// 卡片底：**跟随主题**（浅色近白、深色深灰）——用 controlBackgroundColor，
    ///   玻璃/深色模式下卡片自动变深、白字看得见；白底模式强制浅色环境，卡片近白。
    static let panelCard = Color(nsColor: .controlBackgroundColor)
    /// 卡片描边
    static let cardStroke = Color.primary.opacity(0.07)
    /// 分隔线
    static let hairline = Color.primary.opacity(0.12)

    // ── 墨璃色板（跟随玻璃/白底动态切换）──
    /// 当前是否玻璃模式（AppModel.updateSettings 同步）。白底下容器/描边
    /// 全部换成深色系，否则白底白字不可见（2026-10-14 用户反馈）。
    static var isGlass = true

    static var inkCard: Color { isGlass ? Color.white.opacity(0.05) : Color.primary.opacity(0.045) }
    static var inkCardHi: Color { isGlass ? Color.white.opacity(0.07) : Color.primary.opacity(0.035) }
    static var inkChip: Color { isGlass ? Color.white.opacity(0.07) : Color.primary.opacity(0.05) }
    static var inkStroke: Color { isGlass ? Color.white.opacity(0.10) : Color.primary.opacity(0.09) }
    static var inkHairline: Color { isGlass ? Color.white.opacity(0.07) : Color.primary.opacity(0.08) }
    static var inkDetail: Color { isGlass ? Color.white.opacity(0.04) : Color.primary.opacity(0.03) }
    /// 选中态底色（segmented/chips 通用）：玻璃=16% 白 / 白底=12% 深
    static var segOnFill: Color { isGlass ? Color.white.opacity(0.16) : Color.primary.opacity(0.12) }
    static let accentBright = Color(red: 0.353, green: 0.647, blue: 1.0)   // #5aa5ff
    static let tealBright = Color(red: 0.208, green: 0.784, blue: 0.784)   // #35c8c8
    static let purpleBright = Color(red: 0.690, green: 0.561, blue: 1.0)   // #b08fff
    static let okBright = Color(red: 0.271, green: 0.839, blue: 0.541)     // #45d68a
    static let warnBright = Color(red: 1.0, green: 0.722, blue: 0.302)     // #ffb84d

    // ── 牌面 ──
    /// 牌面底色**固定用浅色**，不跟随主题（真实牌就是米白底）
    static let tileFace = Color(red: 0.984, green: 0.976, blue: 0.945)
    static let tileEdge = Color(red: 0.36, green: 0.34, blue: 0.30).opacity(0.55)
    static let tileFoot = Color(red: 0.86, green: 0.84, blue: 0.78)
    static let tileGlyphDark = Color(red: 0.13, green: 0.13, blue: 0.15)
    static let tileW: CGFloat = 30
    static let tileH: CGFloat = 40

    // ── 牌面大小（三挡，设置调节）──
    static var tileScaleLevel: Int = 1
    static var baseTileScale: CGFloat {
        switch tileScaleLevel { case 0: return 0.82; case 2: return 1.5; default: return 1.0 }
    }

    // ── 字体（层级）──
    static func title(_ size: CGFloat = 13) -> Font { .system(size: size, weight: .semibold) }
    static func body(_ size: CGFloat = 12) -> Font { .system(size: size) }
    static func caption(_ size: CGFloat = 11) -> Font { .system(size: size) }
    static func label(_ size: CGFloat = 10.5) -> Font { .system(size: size, weight: .semibold) }

    /// 危险度 / 把握度共用的色阶
    static func levelColor(_ level: String?) -> Color {
        switch (level ?? "").trimmingCharacters(in: .whitespaces).lowercased() {
        case "high", "高", "危险": return danger
        case "medium", "mid", "中", "中等": return warn
        case "low", "低", "安全": return ok
        default: return idle
        }
    }

    static func levelText(_ level: String?) -> String {
        switch (level ?? "").trimmingCharacters(in: .whitespaces).lowercased() {
        case "high": return "高"
        case "medium", "mid": return "中"
        case "low": return "低"
        default: return level ?? "—"
        }
    }

    /// 「把握度」与「危险度」的好坏事是**反的**：
    /// 把握高 = 这个建议可信 = 绿；危险高 = 危险 = 红。
    static func confidenceColor(_ level: String?) -> Color {
        switch (level ?? "").trimmingCharacters(in: .whitespaces).lowercased() {
        case "high": return ok
        case "medium", "mid": return warn
        case "low": return danger
        default: return idle
        }
    }
}

// MARK: - 卡片容器（现代 macOS 分组卡片）

/// 卡片修饰：近白底 + 极细描边 + 柔和投影（系统设置同款的分组卡片观感）。
struct CardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .fill(Theme.panelCard)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .stroke(Theme.cardStroke, lineWidth: 0.8)
            )
            .shadow(color: .black.opacity(0.05), radius: 6, x: 0, y: 2)
    }
}

extension View {
    func card() -> some View { modifier(CardModifier()) }
}

// MARK: - 牌面

struct TileFace {
    let top: String
    let bottom: String?
    let color: Color

    static let honorNames = ["东", "南", "西", "北", "白", "发", "中"]
    static let numeral = ["", "一", "二", "三", "四", "五", "六", "七", "八", "九"]

    /// "5m" -> 上「五」下「萬」（红）；"1z" -> 「东」；"0p" -> 上「赤」下「筒」
    static func parse(_ notation: String) -> TileFace {
        let s = notation.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let suit = s.last else {
            return TileFace(top: notation, bottom: nil, color: Theme.tileGlyphDark)
        }
        let numPart = String(s.dropLast())

        if suit == "z", let n = Int(numPart), (1...7).contains(n) {
            return TileFace(top: honorNames[n - 1], bottom: nil, color: Theme.tileGlyphDark)
        }
        let suitInfo: (String, Color)? = {
            switch suit {
            case "m": return ("萬", Color(red: 0.78, green: 0.15, blue: 0.13))
            case "p": return ("筒", Color(red: 0.11, green: 0.30, blue: 0.72))
            case "s": return ("索", Color(red: 0.09, green: 0.45, blue: 0.24))
            default: return nil
            }
        }()
        guard let (glyph, color) = suitInfo else {
            return TileFace(top: notation, bottom: nil, color: Theme.tileGlyphDark)
        }
        if numPart == "0" {
            return TileFace(top: "赤", bottom: glyph, color: color)
        }
        guard let n = Int(numPart), (1...9).contains(n) else {
            return TileFace(top: numPart, bottom: glyph, color: color)
        }
        return TileFace(top: numeral[n], bottom: glyph, color: color)
    }
}

/// 单张麻将牌（优先用雀魂原样牌面素材 ui.png；找不到则回退自绘）。
struct MahjongTile: View {
    let notation: String
    var scale: CGFloat = 1
    /// 背牌占位（暗杠两端盖住的牌）——渲染雀魂同款深绿背面
    var isBack: Bool = false
    /// 观察 AppModel：牌面大小设置变化时即时重绘（2026-10-14）
    @ObservedObject private var model = AppModel.shared

    var body: some View {
        // 牌面大小随设置的三挡调节（设置里改了立即重绘）
        let s = scale * Theme.baseTileScale
        if isBack {
            back(s)
        } else if let img = TileFaceStore.image(notation) {
            // ★ 雀魂原样牌面（含右上角编号）：高 129/80 的比例，按高度定宽
            Image(nsImage: img)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(height: Theme.tileH * s)
                .shadow(color: .black.opacity(0.18), radius: 1, y: 0.5)
                .help(notation)
        } else {
            fallback(s)
        }
    }

    /// 背牌（暗杠两端）：雀魂同款深绿渐变 + 浅描边 + 内框
    private func back(_ s: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 4 * s, style: .continuous)
            .fill(LinearGradient(
                colors: [Color(red: 0.30, green: 0.52, blue: 0.42),
                         Color(red: 0.17, green: 0.35, blue: 0.28)],
                startPoint: .top, endPoint: .bottom))
            .frame(width: Theme.tileW * s, height: Theme.tileH * s)
            .overlay(
                RoundedRectangle(cornerRadius: 3 * s, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.22), lineWidth: 1)
                    .padding(2 * s))
            .overlay(
                RoundedRectangle(cornerRadius: 4 * s, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.25), lineWidth: 1))
            .shadow(color: .black.opacity(0.18), radius: 1, y: 0.5)
            .help("背面")
    }

    /// 素材缺失时自绘兜底（保留原逻辑，不让界面空白）
    private func fallback(_ s: CGFloat) -> some View {
        let face = TileFace.parse(notation)
        return VStack(spacing: -1 * s) {
            Text(face.top)
                .font(.system(size: 13 * s, weight: .semibold))
            if let b = face.bottom {
                Text(b)
                    .font(.system(size: 11 * s, weight: .semibold))
            }
        }
        .foregroundStyle(face.color)
        .frame(width: Theme.tileW * s, height: Theme.tileH * s)
        .background(
            RoundedRectangle(cornerRadius: 4 * s, style: .continuous)
                .fill(Theme.tileFace)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4 * s, style: .continuous)
                .stroke(Theme.tileEdge, lineWidth: 1)
        )
        .overlay(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 2 * s, style: .continuous)
                .fill(Theme.tileFoot)
                .frame(height: 3 * s)
                .padding(.horizontal, 2 * s)
                .padding(.bottom, 1.5 * s)
        }
        .help(notation)
    }
}

/// 一排牌，自动换行
struct MahjongTileRow: View {
    let notations: [String]
    var scale: CGFloat = 1

    var body: some View {
        FlowLayout(spacing: 3 * scale) {
            ForEach(Array(notations.enumerated()), id: \.offset) { _, n in
                MahjongTile(notation: n, scale: scale)
            }
        }
    }
}

/// 极简流式布局：一行放不下就换行。SwiftUI 自带 Layout 协议实现，避免引入第三方。
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > 0 && x + sz.width > maxWidth {
                x = 0; y += rowHeight + spacing; rowHeight = 0
            }
            x += sz.width + spacing
            rowHeight = max(rowHeight, sz.height)
        }
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > bounds.minX && x + sz.width > bounds.maxX {
                x = bounds.minX; y += rowHeight + spacing; rowHeight = 0
            }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(sz))
            x += sz.width + spacing
            rowHeight = max(rowHeight, sz.height)
        }
    }
}
