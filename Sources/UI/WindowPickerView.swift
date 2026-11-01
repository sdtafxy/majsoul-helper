import SwiftUI

/// 窗口选择浮层（主浮窗「选择窗口」药丸 / 菜单栏唤起）。
/// - 外观跟随设置（玻璃/白底/通透），与主浮窗同一套墨璃语言。
/// - 位置跟随主浮窗（AppDelegate.repositionPicker 负责）。
/// - 顶栏：标题「选择窗口」+ 刷新 / 关闭（主浮窗同款图标按钮）。
struct WindowPickerView: View {
    @ObservedObject var model: AppModel
    var onPick: (CapturableWindow) -> Void
    /// 跟随设置里的浮窗背景（2026-10-16 用户反馈：原来写死墨璃）
    @ObservedObject private var pickerModel = AppModel.shared

    var body: some View {
        let mode = pickerModel.settings.panelBackground
        VStack(spacing: 0) {
            titleBar
            if model.windows.isEmpty {
                emptyState
            } else {
                windowList
            }
        }
        // 尺寸跟随容器（窗口侧按主浮窗当前宽度设置，见 AppDelegate）
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PanelBackground(mode: mode))
        .environment(\.colorScheme, mode == "solid" ? .light : .dark)
        .clipShape(RoundedRectangle(cornerRadius: Theme.panelRadius, style: .continuous))
        .overlay(
            ZStack {
                RoundedRectangle(cornerRadius: Theme.panelRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(colors: [.primary.opacity(0.14), .clear],
                                       startPoint: .top, endPoint: .center),
                        lineWidth: 1)
                RoundedRectangle(cornerRadius: Theme.panelRadius, style: .continuous)
                    .strokeBorder(Theme.inkStroke, lineWidth: 1)
            })
    }

    // MARK: - 顶栏（标题 + 刷新/关闭，主浮窗同款图标按钮）

    private var titleBar: some View {
        HStack(spacing: 9) {
            Text("选择窗口")
                .font(.system(size: 14, weight: .bold))
            Spacer(minLength: 0)
            iconButton("arrow.clockwise", help: "刷新窗口列表") {
                Task { await model.refreshWindows() }
            }
            iconButton("xmark", help: "关闭") {
                NotificationCenter.default.post(name: .mhClosePicker, object: nil)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func iconButton(_ name: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 25)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Theme.inkCard))
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: - 内容

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "rectangle.dashed")
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(.tertiary)
            Text(model.windowError ?? "没有发现可捕获的窗口，先把雀魂网页版打开。")
                .font(Theme.caption(11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var windowList: some View {
        // ★ 快照模式下 ImageRenderer 渲染不了 ScrollView（铁律，条件化）
        Group {
            if SnapshotMode.isActive {
                listRows
            } else {
                ScrollView { listRows }
            }
        }
    }

    /// 列表行（单一非泛型视图——快照/真机两路都用它）
    private var listRows: some View {
        VStack(spacing: 4) {
            ForEach(model.windows) { w in
                Button { onPick(w) } label: { row(w) }
                    .buttonStyle(.plain)
            }
        }
    }

    private func row(_ w: CapturableWindow) -> some View {
        let on = model.settings.windowID == w.id
        return HStack(spacing: 9) {
            Image(systemName: on ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 13))
                .foregroundStyle(on ? Theme.okBright : .primary.opacity(0.35))
            VStack(alignment: .leading, spacing: 1) {
                Text(w.appName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.9))
                Text(w.title)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.primary.opacity(0.5))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Text("\(w.width)×\(w.height)")
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.primary.opacity(0.35))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(on ? (Theme.isGlass ? Theme.accentBright.opacity(0.14) : Theme.accent.opacity(0.12)) : Theme.inkCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.primary.opacity(on ? 0.22 : 0.06), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
