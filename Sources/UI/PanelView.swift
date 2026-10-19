import SwiftUI
import AppKit

struct PanelView: View {
    @ObservedObject var model: AppModel
    /// 融合进主面板时为 false —— 顶栏由 MainPanelView 统一提供
    var showHeader: Bool = true
    /// 「识别」按钮的 action（2026-10-10 左右两栏：识别结果显示在右栏）
    var recognizeAction: (() -> Void)? = nil
    /// 展示发给模型的原文
    @State private var showPrompt = false

    var body: some View {
        VStack(spacing: 0) {
            if showHeader {
                header
                Divider().opacity(0.4)
            }
            // 快照模式下不套 ScrollView：ImageRenderer 渲染不了 ScrollView 的内容
            // （不会报错，就是整块空白），套着的话 --snapshot 出来的图看不到卡片。
            if SnapshotMode.isActive {
                content
            } else {
                ScrollView(.vertical) { content }
            }
        }
        // 快照时不约束高度，让面板取内容自然高度；否则超出 560 的部分（顶栏 + 截图来源）
        // 会被裁掉，快照就只看到半张图 —— 而"看不见的那半边"恰恰最容易藏 bug。
        .frame(minWidth: 300, idealWidth: 400, maxWidth: 680,
               minHeight: SnapshotMode.isActive ? nil : 360,
               idealHeight: SnapshotMode.isActive ? nil : 560)
        .background(VisualEffectBackground())
        .task {
            guard !SnapshotMode.isActive else { return }
            model.refreshPermission()
            await model.refreshWindows(autoPickIfEmpty: true)
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 11) {
            if !model.permissionGranted { permissionBanner }
            sourceSection
            actionSection
            statusRow
            resultArea
            disclosures
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 顶栏

    private var header: some View {
        HStack(spacing: 7) {
            MahjongTile(notation: "1z", scale: 0.42)
            Text("雀魂助手")
                .font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 0)
            iconButton("gearshape", help: "设置") {
                NotificationCenter.default.post(name: .mhOpenSettings, object: nil)
            }
            iconButton("eye.slash", help: "隐藏浮窗（点菜单栏图标可再打开）") {
                NotificationCenter.default.post(name: .mhHidePanel, object: nil)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func iconButton(_ name: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 11.5, weight: .medium))
                .frame(width: 22, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
    }

    // MARK: - 权限

    private var permissionBanner: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11)).foregroundStyle(Theme.warn)
                Text("需要屏幕录制权限")
                    .font(.system(size: 12, weight: .semibold))
            }

            if let m = model.repairMessage {
                Text(m)
                    .font(.system(size: 10.5))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            } else {
                Text("没有这个权限就截不到游戏画面。首次使用、或者明明在系统设置里显示「已授权」却仍截不到图，都点下面那个按钮 —— 那条记录很可能属于上一个编译版本（改一次代码，签名身份就变一次，系统会当成另一个 App）。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 6) {
                Button("修复授权") { model.repairPermission() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(Capsule().fill(Theme.accent))
                    .foregroundStyle(.white)
                Button("打开系统设置") { ScreenPermission.openSystemSettings() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
                Button("重新检测") {
                    model.clearRepairMessage()
                    model.refreshPermission()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
            .fill(Theme.warn.opacity(0.12)))
    }

    // MARK: - 截图来源

    private var sourceSection: some View {
        SectionBox(title: "截图来源", icon: "macwindow") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: model.selectedWindow == nil ? "questionmark.circle" : "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(model.selectedWindow == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Theme.ok))
                    Text(model.sourceDescription)
                        .font(.system(size: 11.5, weight: .medium))
                        .lineLimit(1)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }

                // ★ 窗口列表改用系统 Menu 下拉：inline 展开的列表会与
                //   「选择窗口」「识别/分析」按钮上下重合（2026-10-10 反馈）
                HStack(spacing: 6) {
                    Menu {
                        ForEach(model.windows.prefix(40)) { w in
                            Button { model.select(w) } label: {
                                Text(menuLabel(w))
                            }
                        }
                    } label: {
                        Label("选择窗口", systemImage: "chevron.down")
                            .font(.system(size: 11))
                            .padding(.horizontal, 9).padding(.vertical, 4)
                            .background(Capsule().fill(Color.primary.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Button {
                        Task { await model.refreshWindows(autoPickIfEmpty: true) }
                    } label: {
                        Label("自动识别", systemImage: "wand.and.stars")
                            .font(.system(size: 11))
                            .padding(.horizontal, 9).padding(.vertical, 4)
                            .background(Capsule().fill(Theme.accent.opacity(0.14)))
                            .foregroundStyle(Theme.accent)
                    }
                    .buttonStyle(.plain)

                    if model.isLoadingWindows {
                        ProgressView().controlSize(.mini)
                    }
                }

                if let e = model.windowError {
                    Text(e).font(.system(size: 10.5)).foregroundStyle(Theme.danger)
                }
            }
        }
    }

    private func menuLabel(_ w: CapturableWindow) -> String {
        var tag = ""
        if w.priority == 0 { tag = "雀魂 ✓ " }
        else if w.priority == 1 { tag = "疑似 " }
        return tag + w.appName + " — " + w.label
    }

    // MARK: - 操作

    private var actionSection: some View {
        HStack(spacing: 8) {
            ActionButton(title: "识别",
                         subtitle: "只识牌",
                         icon: "rectangle.grid.2x2",
                         prominent: true,
                         tint: Theme.teal,
                         enabled: model.permissionGranted && model.settings.windowID != 0) {
                recognizeAction?()
            }

            ActionButton(title: "快速",
                         subtitle: "约 \(quickHint)",
                         icon: "bolt.fill",
                         prominent: true,
                         tint: Theme.accent,
                         enabled: model.canAnalyze) {
                model.analyze(deep: false)
            }
            .keyboardShortcut(.return, modifiers: .command)

            ActionButton(title: "深度",
                         subtitle: "约 \(deepHint)",
                         icon: "brain.head.profile",
                         prominent: true,
                         tint: Theme.purple,
                         enabled: model.canAnalyze) {
                model.analyze(deep: true)
            }
            .keyboardShortcut(.return, modifiers: [.command, .shift])
        }
    }

    private var quickHint: String {
        model.settings.quickEffort == "none" ? "2 秒" : "数十秒"
    }
    private var deepHint: String {
        switch model.settings.deepEffort {
        case "none": return "2 秒"
        case "low": return "半分钟"
        default: return "一两分钟"
        }
    }

    // MARK: - 状态

    private var statusRow: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                statusDot
                Text(model.phase.label)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if model.phase.isBusy {
                    Text(String(format: "%.1fs", model.elapsed))
                        .font(.system(size: 10.5).monospacedDigit())
                        .foregroundStyle(.secondary)
                    Button("取消") { model.cancel() }
                        .buttonStyle(.plain)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.danger)
                }
            }
            if model.phase.isBusy {
                ProgressView().progressViewStyle(.linear).tint(Theme.accent).controlSize(.small)
            }
        }
    }

    @ViewBuilder private var statusDot: some View {
        switch model.phase {
        case .idle: Circle().fill(Theme.idle.opacity(0.6)).frame(width: 7, height: 7)
        case .capturing, .readingHand, .thinking, .writing:
            Circle().fill(Theme.accent).frame(width: 7, height: 7)
        case .done: Circle().fill(Theme.ok).frame(width: 7, height: 7)
        case .failed: Circle().fill(Theme.danger).frame(width: 7, height: 7)
        }
    }

    // MARK: - 结果

    @ViewBuilder private var resultArea: some View {
        if case let .failed(msg) = model.phase {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "xmark.octagon.fill")
                    .font(.system(size: 11)).foregroundStyle(Theme.danger).padding(.top, 1)
                Text(msg)
                    .font(.system(size: 11))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .fill(Theme.danger.opacity(0.10)))
        }

        if let advice = model.advice {
            AdviceCard(advice: advice,
                       defaultExpanded: model.settings.expandAdvice)
        } else if !model.rawText.isEmpty {
            SectionBox(title: "模型原文（未能解析成建议卡片）", icon: "doc.text") {
                Text(model.rawText)
                    .font(.system(size: 10.5, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if !model.phase.isBusy, case .idle = model.phase {
            emptyHint
        }
    }

    private var emptyHint: some View {
        VStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(.tertiary)
            Text("按 ⌘↩ 快速分析 · ⇧⌘↩ 深度分析")
                .font(Theme.caption(11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
    }

    // MARK: - 折叠区

    private var disclosures: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !model.llmPrompt.isEmpty {
                Disclosure(title: "发给模型的原文",
                           detail: "\(model.llmPrompt.count) 字",
                           expanded: $showPrompt) {
                    Text(model.llmPrompt)
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !model.reasoningText.isEmpty {
                Disclosure(title: "模型思考过程",
                           detail: "\(model.reasoningText.count) 字",
                           expanded: $model.showReasoning) {
                    Text(model.reasoningText)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !model.rawText.isEmpty, model.advice != nil {
                Disclosure(title: "模型原始输出",
                           detail: nil,
                           expanded: $model.showRaw) {
                    Text(model.rawText)
                        .font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let img = model.lastShot {
                Disclosure(title: "模型看到的画面",
                           detail: model.shotInfo,
                           expanded: $model.showImage) {
                    VStack(alignment: .leading, spacing: 6) {
                        Image(nsImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxHeight: 190)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.primary.opacity(0.15), lineWidth: 1))
                        Button("在预览中打开原图") { model.openLastShotInPreview() }
                            .buttonStyle(.plain)
                            .font(.system(size: 10.5))
                            .foregroundStyle(Theme.accent)
                    }
                }
            }
            if let u = model.usage, !u.summary.isEmpty {
                Text(u.summary + String(format: " · 本次 %.1fs", model.elapsed))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 2)
            }
        }
    }
}
