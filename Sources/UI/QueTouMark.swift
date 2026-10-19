import SwiftUI

/// 雀头标识（界面用矢量版）——深色玻璃方圆 + 一对错位叠放的牌（麻将「雀头」）。
///
/// ★ 唯一几何基准在 `scripts/draw_quetou.py`（S=108 单位制）。
///   本文件的常量必须与它一致 —— 改这里要改那里（图标与界面漂移的根因）。
struct QueTouMark: View {
    var width: CGFloat = 28

    // ── 与 scripts/draw_quetou.py 对应 ──
    static let corner: CGFloat = 25          // 方圆圆角
    static let tileW: CGFloat = 34           // 牌宽
    static let tileH: CGFloat = 48           // 牌高
    static let tileBX: CGFloat = 22          // 后牌左上角 x（牌中心 = x+17）
    static let tileBY: CGFloat = 34          // 后牌左上角 y（牌中心 = y+24）
    static let tileBDeg: Double = -14        // 后牌旋转
    static let tileFX: CGFloat = 52          // 前牌左上角 x
    static let tileFY: CGFloat = 28          // 前牌左上角 y
    static let tileFDeg: Double = 10         // 前牌旋转
    static let ring: CGFloat = 17            // 一筒环直径
    static let ringW: CGFloat = 4.5          // 环宽

    private var k: CGFloat { width / 108 }

    var body: some View {
        ZStack {
            // 方圆底（深色渐变 + 顶部高光描边）
            RoundedRectangle(cornerRadius: Self.corner * k, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color(red: 0.173, green: 0.184, blue: 0.212),
                             Color(red: 0.063, green: 0.071, blue: 0.086)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(
                    RoundedRectangle(cornerRadius: Self.corner * k, style: .continuous)
                        .strokeBorder(
                            LinearGradient(colors: [.white.opacity(0.22), .clear],
                                           startPoint: .top, endPoint: .center),
                            lineWidth: max(1, 1.5 * k)))

            // 后牌（深色，斜 -14°）
            tileShape(light: false)
                .rotationEffect(.degrees(Self.tileBDeg))
                .offset(x: (Self.tileBX + Self.tileW / 2 - 54) * k,
                        y: (Self.tileBY + Self.tileH / 2 - 54) * k)

            // 前牌（米亮 + 一筒红环，斜 +10°）
            tileShape(light: true)
                .rotationEffect(.degrees(Self.tileFDeg))
                .offset(x: (Self.tileFX + Self.tileW / 2 - 54) * k,
                        y: (Self.tileFY + Self.tileH / 2 - 54) * k)
        }
        .frame(width: width, height: width)
        .shadow(color: .black.opacity(0.35), radius: width * 0.08, y: width * 0.04)
    }

    private func tileShape(light: Bool) -> some View {
        let w = Self.tileW * k
        let h = Self.tileH * k
        return ZStack {
            RoundedRectangle(cornerRadius: h * 0.11, style: .continuous)
                .fill(light
                      ? LinearGradient(colors: [Color(red: 0.957, green: 0.937, blue: 0.886),
                                                Color(red: 0.847, green: 0.824, blue: 0.753)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                      // ★ 背朝上的牌用雀魂默认暖黄牌底（2026-10-18，与 icns 同步）
                      : LinearGradient(colors: [Color(red: 0.914, green: 0.659, blue: 0.239),
                                                Color(red: 0.788, green: 0.498, blue: 0.149)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: w, height: h)
                .shadow(color: .black.opacity(0.35), radius: w * 0.12, y: w * 0.06)
                .overlay(
                    RoundedRectangle(cornerRadius: h * 0.11, style: .continuous)
                        .strokeBorder(.white.opacity(light ? 0.25 : 0.10),
                                      lineWidth: max(0.5, 0.5 * k)))
            if light {
                // 一筒红环（外发光 + 环）
                ZStack {
                    Circle()
                        .stroke(Color(red: 0.84, green: 0.235, blue: 0.235).opacity(0.28),
                                lineWidth: Self.ringW * k + 2)
                        .frame(width: Self.ring * k, height: Self.ring * k)
                    Circle()
                        .stroke(Color(red: 0.84, green: 0.235, blue: 0.235),
                                lineWidth: Self.ringW * k)
                        .frame(width: Self.ring * k, height: Self.ring * k)
                }
            }
        }
    }
}
