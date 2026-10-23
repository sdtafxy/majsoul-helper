import SwiftUI
import AppKit

/// 主浮窗（原型 v5「墨璃」）：一次决策指令。
/// - 顶栏：雀头 Logo + 标题 + 图标按钮组（识别结果窗口/设置/隐藏）。
/// - 来源药丸：极简一行状态。
/// - 中部：建议卡 Hero（超大推荐牌 + 把握 + 详情 chips）+ 分析详情折叠区
///   （模型原文/思考/原始输出/截图，2026-10-15 恢复）。
/// - 底部：操作主次分级（快速=主按钮带快捷键；识别/深度=轻量玻璃块），
///   ZStack 固定底部不随内容滚动。
struct MainPanelView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var overlay: OverlayController
    @Environment(\.colorScheme) private var sysScheme
    // 分析详情折叠开关
    @State private var showPrompt = false
    @State private var showReasoning = false
    @State private var showRaw = false
    @State private var showImage = false

    var body: some View {
        // ★ 条件化必须放在**顶层**（整个面板两个变体）——放在 VStack 中间时
        //   ImageRenderer 的 ideal 高度会算错，底部 actions/详情区整段丢失。
        panel(useScroll: !SnapshotMode.isActive)
    }

    private func panel(useScroll: Bool) -> some View {
        let mode = model.settings.panelBackground
        // ★ ZStack：操作栏固定底部（不参与高度计算；且 HUD 语义上按钮
        //   就该永远可见，内容在中间滚动）。
        return ZStack(alignment: .bottom) {
            Group {
                if useScroll {
                    ScrollView {
                        VStack(spacing: 0) {
                            titleBar
                            srcbar
                            VStack(spacing: 0) {
                                content
                            }
                        }
                    }
                } else {
                    VStack(spacing: 0) {
                        titleBar
                        srcbar
                        content
                    }
                }
            }
            actions
                .frame(maxWidth: .infinity)
                .background(PanelBackground(mode: mode))
                .overlay(alignment: .top) {
                    Rectangle().fill(Theme.inkHairline).frame(height: 1)
                }
        }
        // 跟随窗口宽度（原来固定 336：窗口拉到 630 时两侧留大片空白，
        // 拉到最窄时又被 336 卡住，和识别窗口的最小宽度对不上）。
        // minWidth/minHeight 同时写在内容层：borderless NSPanel 的
        // contentMinSize 在用户拖拽时不一定生效，内容固有尺寸才是硬约束。
        .frame(minWidth: 376, maxWidth: .infinity,
               minHeight: 420, maxHeight: .infinity)
        .background(PanelBackground(mode: mode))
        // 墨璃=深色文字环境；白底=浅色；通透=跟随系统
        .environment(\.colorScheme, mode == "glass" ? .dark
            : (mode == "clear" ? sysScheme : .light))
        .clipShape(RoundedRectangle(cornerRadius: Theme.panelRadius, style: .continuous))
        .overlay(
            ZStack {
                // 顶部镜面高光（原型 inset 0 1px 0 rgba(255,255,255,.14)）
                RoundedRectangle(cornerRadius: Theme.panelRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(colors: [.primary.opacity(0.14), .clear],
                                       startPoint: .top, endPoint: .center),
                        lineWidth: 1)
                // 外描边
                RoundedRectangle(cornerRadius: Theme.panelRadius, style: .continuous)
                    .strokeBorder(Theme.inkStroke, lineWidth: 1)
            })
        .task {
            guard !SnapshotMode.isActive else { return }
            model.refreshPermission()
            await model.refreshWindows(autoPickIfEmpty: true)
            overlay.bootstrap()
            model.onRecognition = { [weak overlay] rec in
                overlay?.applyResult(rec)
            }
        }
    }

    /// 「识别」按钮：用当前窗口跑一次本地识别（切窗口 + 识别）。
    private func recognize() {
        overlay.selectedWindowID = model.settings.windowID
        overlay.runNow()
    }

    // MARK: - 顶栏

    private var titleBar: some View {
        HStack(spacing: 9) {
            QueTouMark(width: 30)
            Text("雀魂助手")
                .font(.system(size: 14, weight: .bold))
            Spacer(minLength: 0)
            iconButton("rectangle.grid.2x2", help: "显示 / 隐藏识别结果窗口") {
                NotificationCenter.default.post(name: .mhToggleRecognition, object: nil)
            }
            iconButton("gearshape", help: "设置") {
                NotificationCenter.default.post(name: .mhOpenSettings, object: nil)
            }
            iconButton("eye.slash", help: "隐藏浮窗（点菜单栏图标可再打开）") {
                NotificationCenter.default.post(name: .mhHidePanel, object: nil)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background {
            if !SnapshotMode.isActive { DragArea() }
        }
    }

    private func iconButton(_ name: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 25)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: - 来源药丸

    private var srcbar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 7) {
                Circle()
                    .fill(Theme.okBright)
                    .frame(width: 6, height: 6)
                    .shadow(color: Theme.okBright.opacity(0.8), radius: 4)
                Text(model.sourceDescription)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Capsule().fill(Theme.inkCard))
            Button {
                NotificationCenter.default.post(name: .mhAutoPickWindow, object: nil)
            } label: {
                Text("自动选窗")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Theme.inkCard))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("自动选择标题含「雀魂 / Majsoul / Mahjong Soul」的窗口")
            Button {
                NotificationCenter.default.post(name: .mhPickWindow, object: nil)
            } label: {
                Text("选择窗口")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Theme.inkCard))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("重新选择截图来源窗口")
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
    }

    // MARK: - 中部内容（建议卡）

    // ★ 必须是单一 Group 视图，不能是 @ViewBuilder 多子项属性——后者在 VStack 里
    //   的 ideal 高度会「填满父级」，把后面的 debugSection 整段推出画外
    //   （2026-10-15 实测：快照里 content 之后的内容全部丢失）。
    private var content: some View {
        Group {
            if let advice = model.advice {
                AdviceCard(advice: advice,
                           defaultExpanded: model.settings.expandAdvice)
            } else if model.phase.isBusy {
                busyCard
            } else {
                emptyCard
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 6)
    }

    private var busyCard: some View {
        VStack(spacing: 10) {
            ProgressView().controlSize(.regular)
            Text(model.phase.label)
                .font(Theme.caption(11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
        .background(RoundedRectangle(cornerRadius: Theme.heroRadius, style: .continuous)
            .fill(Theme.inkCardHi))
    }

    /// 还没有结果时的占位卡：介绍底部三个按钮各自做什么。
    private var emptyCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            hintRow(icon: "bolt.fill", tint: Theme.accentBright,
                    title: "快速", detail: "一两秒给出这一巡打哪张")
            hintRow(icon: "circle.dotted", tint: .secondary,
                    title: "深度", detail: "让模型多想一会儿，复杂局面更稳")
            hintRow(icon: "rectangle.grid.2x2", tint: .secondary,
                    title: "识别", detail: "只读牌面，不出打牌建议")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 22)
        .padding(.vertical, 22)
        .background(RoundedRectangle(cornerRadius: Theme.heroRadius, style: .continuous)
            .fill(Theme.inkCardHi))
    }

    private func hintRow(icon: String, tint: Color, title: String, detail: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(tint)
                .frame(width: 16)
            Text(title)
                .font(Theme.caption(11))
                .fontWeight(.semibold)
                .frame(width: 30, alignment: .leading)
            Text(detail)
                .font(Theme.caption(11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    // MARK: - 底部操作（主次分级）

    private var actions: some View {
        HStack(spacing: 8) {
            MainActionButton(title: "快速", icon: "bolt.fill") {
                model.analyze(deep: false)
            }

            GhostActionButton(title: "深度", icon: "circle.dotted",
                              color: Theme.purpleBright) {
                model.analyze(deep: true)
            }

            GhostActionButton(title: "识别", icon: "rectangle.grid.2x2",
                              color: Theme.tealBright) {
                recognize()
            }
        }
        .padding(14)
    }
}

/// 顶栏拖拽区：borderless 窗口用 `isMovableByWindowBackground` 会被铺满的
/// ScrollView/按钮内容拦截（点不到"背景"），所以顶栏显式放一个 DragView。
private struct DragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class DragView: NSView {
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}
