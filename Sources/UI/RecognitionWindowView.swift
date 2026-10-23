import SwiftUI
import AppKit

/// 识别结果独立浮窗（2026-10-12）：主浮窗专注分析，识别结果单独成窗。
/// - 顶栏：标题 + 关闭按钮（可拖拽移动，双击顶栏也可关）。
/// - 内容：真实牌面分组（宝牌/手牌/副露/牌河），比主浮窗里更大。
struct RecognitionWindowView: View {
    @ObservedObject var overlay: OverlayController
    /// 观察 AppModel，设置里改外观（浮窗背景/牌面大小）时窗口立即重绘。
    /// 之前是直接读 AppModel.shared.settings 的字面值，SwiftUI 观察不到，
    /// 改设置后窗口一直保持旧外观，关掉再开（窗口只是 hide/show）也不变。
    @ObservedObject var model: AppModel = .shared
    @Environment(\.colorScheme) private var sysScheme

    var body: some View {
        VStack(spacing: 0) {
            // 顶部只留一条极薄拖动区：原来的外层标题栏（雀头 + 「识别结果」 +
            // 关闭）与内层 header 的标题重复，改成内层 header 自带关闭按钮。
            DragStrip(height: 12)
            RecognitionPane(overlay: overlay) {
                NotificationCenter.default.post(name: .mhToggleRecognition, object: nil)
            }
            .padding(Theme.gap)
        }
        .frame(minWidth: 380, minHeight: 520)
        .background(PanelBackground(mode: model.settings.panelBackground))
        .environment(\.colorScheme,
                     model.settings.panelBackground == "solid" ? .light : .dark)
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
