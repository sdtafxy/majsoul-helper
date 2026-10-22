import SwiftUI
import AppKit

/// Overlay 模式的主控面板：选窗口、刷新频率、显示开关、结果列表。
///
/// 刻意做成独立小窗而不是塞进原浮窗 —— 原浮窗是「截图+问 LLM」的分析流，
/// 两套流程的心智模型不同，混在一起会让人搞不清当前在做哪件事。
struct OverlayPanelView: View {
    @ObservedObject var ctrl: OverlayController
    /// 融合进主面板时为 false —— 顶栏由 MainPanelView 统一提供
    var showHeader: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showHeader {
                header
                Divider()
            }
            windowPicker
            Divider()
            controls
            Divider()
            statusBox
            Divider()
            resultList
        }
        .frame(width: 380)
        .background(WindowBackground())
    }

    // MARK: - 头部

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("切分 / 识别 图层")
                    .font(.system(size: 14, weight: .semibold))
                Text("在目标窗口上叠加切分框与牌名")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if ctrl.status.isBusy { ProgressView().controlSize(.small) }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - 窗口选择

    private var windowPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("目标窗口").font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    ctrl.refreshWindows()
                } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .help("重新枚举窗口")
            }
            Picker("", selection: Binding(
                get: { ctrl.selectedWindowID },
                set: { ctrl.selectedWindowID = $0 }
            )) {
                ForEach(ctrl.windows) { w in
                    Text("\(w.appName) — \(w.label)")
                        .tag(w.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - 控制项

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    ctrl.runNow()
                } label: {
                    Label("立即识别", systemImage: "play.fill").frame(maxWidth: .infinity)
                }
                .controlSize(.regular)
                .disabled(ctrl.selectedWindowID == 0 || ctrl.status.isBusy)

                Toggle("只显示侧家", isOn: Binding(
                    get: { ctrl.onlySideSeats },
                    set: { ctrl.onlySideSeats = $0 }
                ))
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
            }

            HStack(spacing: 8) {
                Text("自动刷新").font(.system(size: 11)).foregroundStyle(.secondary)
                Picker("", selection: Binding(
                    get: { ctrl.autoInterval },
                    set: { ctrl.autoInterval = $0; ctrl.autoIntervalChanged() }
                )) {
                    Text("关闭").tag(0.0)
                    Text("3 秒").tag(3.0)
                    Text("10 秒").tag(10.0)
                    Text("30 秒").tag(30.0)
                }
                .labelsHidden()
                .frame(width: 96)
                Spacer()
            }

            Button {
                ctrl.exportPackage()
            } label: {
                Label("导出排查包", systemImage: "shippingbox.fill")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.small)
            .disabled(ctrl.selectedWindowID == 0 || ctrl.status.isBusy)
            .help("把「最近一次识别用的截图」+ 识别结果 JSON + 渲染图存到\n设置里指定的目录（默认 ~/Downloads）/MajsoulHelper-<时间戳>/，完成后在 Finder 中显示。\n★ 复用你刚识别的那张图，不是重新截——排查的就是你看到的那张。\n识别结果不对时，把整个文件夹发回来即可排查。")

            HStack(spacing: 14) {
                Toggle("牌名", isOn: Binding(
                    get: { ctrl.showLabels },
                    set: { ctrl.setLabels($0) }))
                Toggle("状态条", isOn: Binding(
                    get: { ctrl.showHUD },
                    set: { ctrl.setHUD($0) }))
                Spacer()
            }
            .toggleStyle(.checkbox)
            .font(.system(size: 11))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - 状态

    private var statusBox: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor).frame(width: 7, height: 7)
            Text(ctrl.status.hudText)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var statusColor: Color {
        switch ctrl.status {
        case .ok: return .green
        case .failed: return .red
        case .running: return .blue
        case .waitingPermission: return .orange
        case .idle: return .secondary
        }
    }

    // MARK: - 结果列表（按家分组，标出低置信）

    private var resultList: some View {
        ResultList(result: ctrl.currentResult)
    }

}

// MARK: - 结果列表

/// 结果列表单独抽成一个 View。
///
/// ★★ 不能写成 `@ViewBuilder var x: some View { let r = ...; if ... }` ★★
///   那种「局部 let + 裸 if」的结构在 `ImageRenderer`（也就是 `--snapshot`）下
///   **整块渲染成空白**，而真机 App 里完全正常 —— 于是「能编译、能跑」都过了，
///   只有快照抓得到。踩过两次：先怀疑自定义 `Layout`、再怀疑 `LazyVGrid`，
///   都不是它。→ 数据在父 View 取好，传给一个无局部变量的子 View。
struct ResultList: View {
    let result: OverlayResult

    /// ★ 真机用 ScrollView（69 张牌要能滚），快照用裸 VStack ★
    ///
    /// `ScrollView` 在 `ImageRenderer`（也就是 `--snapshot`）下**不渲染内容** ——
    /// 真机 App 里完全正常。实测对照（`ContainerProbe`，见 OverlaySelfTest.swift）：
    /// ScrollView 空白 / 裸 VStack 正常 / LazyVGrid 正常。
    ///
    /// ★ 这类 bug 只有快照抓得到 ★
    /// 「能编译、能跑、App 里看着没问题」全都过了，只有 `--snapshot` 空白。
    /// 所以 SnapshotMode 开启时强制走无滚动路径。
    @Environment(\.snapshotMode) private var snapshot

    var body: some View {
        if result.seats.isEmpty && result.hand == nil && result.dora == nil {
            Text("还没有结果")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 14)
        } else {
            if snapshot {
                VStack(alignment: .leading, spacing: 8) {
                    doraBlock
                    handBlock
                    seatBlocks
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        doraBlock
                        handBlock
                        seatBlocks
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
                .frame(height: 190)
            }
        }
    }

    /// 宝牌指示牌（橙色）
    @ViewBuilder
    private var doraBlock: some View {
        if let dora = result.dora, !dora.indicators.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text("宝牌指示")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.orange)
                Text(dora.indicators.joined(separator: " "))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.orange)
            }
        }
    }

    /// 自家手牌（青色）；摸牌标「摸」，副露区报组数。
    @ViewBuilder
    private var handBlock: some View {
        if let hand = result.hand, !hand.tiles.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text("手牌  \(hand.tiles.count) 张\(hand.meldTiles > 0 ? " · 副露 \(hand.meldTiles) 张" : "")")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.cyan)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 30), spacing: 4)],
                          alignment: .leading, spacing: 4) {
                    ForEach(hand.tiles) { t in
                        Text(t.isDrawn ? (t.name ?? "?") + "·摸" : (t.name ?? "?"))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(t.name == nil ? Color.red : .black)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 3)
                                .fill(t.name == nil ? Color.red.opacity(0.2)
                                      : Color.cyan.opacity(t.isDrawn ? 0.55 : 0.16)))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var seatBlocks: some View {
        ForEach(result.seats, id: \.key) { seat in
            VStack(alignment: .leading, spacing: 3) {
                Text("\(seat.cnName)  \(seat.tiles.count) 张")
                    .font(.system(size: 11, weight: .semibold))
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 30), spacing: 4)],
                    alignment: .leading, spacing: 4) {
                    ForEach(seat.tiles) { t in
                        TileChip(text: t.name ?? "?",
                                 tint: Palette.tint(for: t),
                                 filled: t.isLow || t.name == nil)
                    }
                }
            }
        }
    }
}

// MARK: - 小部件

/// 牌名标签的颜色语义：识别失败红、白板灰、低置信橙、正常绿。
/// 与 OverlayView.color 保持同一套判定，面板与图层不会一个绿一个橙。
enum Palette {
    static func tint(for t: OverlayTile) -> Color {
        if t.name == nil { return .red }
        if t.isBlank { return .secondary }
        if t.isLow { return .orange }
        return .green
    }
}

/// 牌名小标签。**刻意不叫 Chip** —— `UI/Components.swift` 里已有一个同名组件，
/// 重复声明会撞名（踩过）。
struct TileChip: View {
    let text: String
    var tint: Color = .green
    var filled: Bool = false

    var body: some View {
        Text(text)
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(filled ? Color.black : tint)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(filled ? tint : tint.opacity(0.16))
            )
    }
}

struct WindowBackground: View {
    var body: some View {
        Color(nsColor: .windowBackgroundColor).ignoresSafeArea()
    }
}