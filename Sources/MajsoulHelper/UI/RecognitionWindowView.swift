import SwiftUI
import AppKit

/// 识别结果独立浮窗（2026-10-12）：主浮窗专注分析，识别结果单独成窗。
/// - 顶栏：标题 + 关闭按钮（可拖拽移动，双击顶栏也可关）。
/// - 内容：真实牌面分组（宝牌/手牌/副露/牌河），比主浮窗里更大。
struct RecognitionWindowView: View {
    @ObservedObject var overlay: OverlayController
    @Environment(\.colorScheme) private var sysScheme

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            Rectangle().fill(Theme.hairline).frame(height: 1)
            RecognitionPane(overlay: overlay)
                .padding(Theme.gap)
        }
        .frame(minWidth: 380, minHeight: 520)
        .background(PanelBackground(mode: AppModel.shared.settings.panelBackground))
        .environment(\.colorScheme,
                     AppModel.shared.settings.panelBackground == "solid" ? .light : .dark)
        .clipShape(RoundedRectangle(cornerRadius: Theme.panelRadius, style: .continuous))
        .overlay(
            ZStack {
                RoundedRectangle(cornerRadius: Theme.panelRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(colors: [.primary.opacity(0.14), .clear],
                                       startPoint: .top, endPoint: .center),
                        lineWidth: 1)
                RoundedRectangle(cornerRadius: Theme.panelRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
            })
        
    }

    private var titleBar: some View {
        HStack(spacing: 9) {
            QueTouMark(width: 30)
            Text("识别结果")
                .font(.system(size: 14, weight: .bold))
            Spacer(minLength: 0)
            Button {
                NotificationCenter.default.post(name: .mhToggleRecognition, object: nil)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("关闭识别结果窗口（菜单栏可再唤出）")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background {
            if !SnapshotMode.isActive { RecognitionDragArea() }
        }
    }
}

private struct RecognitionDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { RecognitionDragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class RecognitionDragView: NSView {
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}
