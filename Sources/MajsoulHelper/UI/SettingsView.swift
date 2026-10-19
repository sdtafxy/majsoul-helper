import SwiftUI
import AppKit

/// 设置界面（原型 v5 墨璃 v2）：
/// - borderless 自绘顶栏（雀头 + 设置 + ✕，无系统红黄绿）。
/// - Liquid Glass 侧栏导航 + 内容区一页一类。
/// - 控件全部自绘（InkSegmented / InkTextField / InkToggle），对齐与字号完全可控。

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var updater = UpdaterManager.shared
    @State private var revealKey = false
    @State private var testState: TestState = .idle
    @State private var tab = "外观"

    enum TestState: Equatable {
        case idle, running, ok(String), fail(String)
    }

    private let efforts = ["none", "low", "high", "max"]

    private let tabs: [(title: String, icon: String)] = [
        // 顺序 = 逻辑分组：视觉（外观/标注配色）→ 模型（配置/档位/提示词）
        //   → 输入（截图处理）→ 对局 → 维护（工具/更新垫底）
        ("外观", "paintbrush"),
        ("标注配色", "paintpalette"),
        ("模型配置", "cpu"),
        ("分析档位", "dial.medium"),
        ("系统提示词", "text.alignleft"),
        ("截图处理", "photo"),
        ("对局", "square.grid.3x3"),
        ("工具", "wrench.and.screwdriver"),
        ("更新", "arrow.triangle.2.circlepath"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            // ★ 窄窗口侧栏折叠：宽度 < 560 时侧栏收成图标条（52pt），
            //   内容区让位（2026-10-15 补齐昨日遗留）
            GeometryReader { geo in
                HStack(spacing: 0) {
                    sidebar(compact: geo.size.width < 560)
                    content
                }
            }
        }
        // ★ 不写死宽度——由窗口（AppDelegate contentRect）或外层 frame 决定，
        //   否则 GeometryReader 读不到真实宽度、compact 侧栏永远不触发。
        .frame(minHeight: 540)
        .background(PanelBackground(mode: model.settings.panelBackground))
        .environment(\.colorScheme, model.settings.panelBackground == "solid" ? .light : .dark)
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
        
        .tint(Theme.accentBright)
    }

    // MARK: - 自绘顶栏（无系统标题栏）

    private var titleBar: some View {
        HStack(spacing: 9) {
            QueTouMark(width: 28)
            Text("设置")
                .font(.system(size: 14, weight: .bold))
            Spacer(minLength: 0)
            Button {
                NotificationCenter.default.post(name: .mhCloseSettings, object: nil)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 20)
                    .background(Capsule().fill(Theme.inkCard))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("关闭设置")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background {
            if !SnapshotMode.isActive { SettingsDragArea() }
        }
    }

    // MARK: - 侧栏

    private func sidebar(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(tabs, id: \.title) { t in
                Button {
                    withAnimation(.easeInOut(duration: 0.12)) { tab = t.title }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: t.icon)
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 20)
                        if !compact {
                            Text(t.title)
                                .font(.system(size: 12, weight: tab == t.title ? .semibold : .medium))
                            Spacer(minLength: 0)
                        }
                    }
                    .foregroundStyle(tab == t.title ? Color.primary : Color.primary.opacity(0.65))
                    .padding(.horizontal, compact ? 0 : 9)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity,
                           alignment: compact ? .center : .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(tab == t.title ? Theme.accentBright.opacity(0.20) : .clear)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .help(t.title)
            }
            Spacer(minLength: 0)
        }
        .padding(compact ? 10 : 14)
        .padding(.top, 4)
        .frame(width: compact ? 52 : 184)
        .background(Color.primary.opacity(0.035))
        .overlay(alignment: .trailing) {
            Rectangle().fill(Color.primary.opacity(0.07)).frame(width: 1)
        }
    }

    // MARK: - 内容区

    private var contentBody: some View {
        Group {
            switch tab {
            case "外观": appearanceSection
            case "模型配置": apiSection
            case "分析档位": analysisSection
            case "截图处理": imageSection
            case "对局": gameSection
            case "系统提示词": promptSection
            case "更新": updateSection
            case "标注配色": overlayThemeSection
            default: toolsSection
            }
        }
        .padding(18)
        // ★ 2026-10-18 用户反馈：滚动条不贴窗口右缘、改宽度也不动——根因是
        //   这里限死了 maxWidth 480，ScrollView 的指示器跟着「内容宽度」走。
        //   改为撑满内容区（表单行内部有各自的内边距，不会变宽难读）。
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var content: some View {
        // ★ 快照模式下 ImageRenderer 渲染不了 ScrollView（整块空白），必须条件化
        Group {
            if SnapshotMode.isActive {
                contentBody
            } else {
                ScrollView { contentBody }
            }
        }
    }

    // MARK: - 外观

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("外观", icon: "paintbrush")
                .padding(.bottom, 6)

            settingsCard {
                row("牌面大小") {
                    InkSegmented(options: [("小", 0), ("中", 1), ("大", 2)],
                                 selection: Binding(
                                    get: { model.settings.tileScale },
                                    set: { v in model.updateSettings { $0.tileScale = v } }))
                }
            }

            settingsCard {
                row("浮窗背景") {
                    InkSegmented(options: [("玻璃", "glass"), ("白底", "solid"), ("通透", "clear")],
                                 selection: Binding(
                                    get: { model.settings.panelBackground },
                                    set: { v in model.updateSettings { $0.panelBackground = v } }))
                }
            }

            settingsCard {
                row("建议卡") {
                    HStack(spacing: 10) {
                        InkToggle(on: Binding(
                            get: { model.settings.expandAdvice },
                            set: { v in model.updateSettings { $0.expandAdvice = v } }))
                        Text("默认展开详情")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.primary.opacity(0.85))
                    }
                }
            }

            settingsCard {
                row("识别结果") {
                    HStack(spacing: 10) {
                        InkToggle(on: Binding(
                            get: { model.settings.showRecognitionOnLaunch },
                            set: { v in model.updateSettings { $0.showRecognitionOnLaunch = v } }))
                        Text("启动后自动打开")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.primary.opacity(0.85))
                    }
                }
            }
        }
    }

    // MARK: - 模型配置

    private var apiSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("模型配置", icon: "cpu")
                .padding(.bottom, 6)

            settingsCard {
                row("服务商") {
                    InkSegmented(options: ModelProvider.presets.map { ($0.name, $0.id) },
                                 selection: Binding(
                                    get: { model.settings.provider },
                                    set: { v in
                                        model.updateSettings {
                                            $0.provider = v
                                            if let p = ModelProvider.preset(v) {
                                                $0.baseURL = p.baseURL
                                                $0.model = p.model
                                            }
                                        }
                                    }))
                }
            }

            settingsCard {
                row("接口地址") {
                    InkTextField(placeholder: "https://...", text: Binding(
                        get: { model.settings.baseURL },
                        set: { v in model.updateSettings { $0.baseURL = v } }), mono: true)
                }
                row("模型名称") {
                    InkTextField(placeholder: "", text: Binding(
                        get: { model.settings.model },
                        set: { v in model.updateSettings { $0.model = v } }), mono: true)
                }
            }

            settingsCard {
                row("API Key") {
                    HStack(spacing: 8) {
                        InkTextField(placeholder: "sk-...", text: Binding(
                            get: { model.settings.apiKey },
                            set: { v in model.updateSettings { $0.apiKey = v.trimmingCharacters(in: .whitespacesAndNewlines) } }), mono: true)
                        if !revealKey {
                            Image(systemName: "eye.slash")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                        Button(revealKey ? "隐藏" : "显示") { revealKey.toggle() }
                            .buttonStyle(.plain)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.accentBright)
                        Button("测试") { runTest() }
                            .buttonStyle(.plain)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.accentBright)
                            .disabled(testState == .running)
                        if testState == .running { ProgressView().controlSize(.mini) }
                    }
                }
                if case let .ok(m) = testState { okLine(m) }
                if case let .fail(m) = testState {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "xmark.octagon.fill")
                            .font(.system(size: 10)).foregroundStyle(Theme.danger).padding(.top, 1)
                        Text(m).font(Theme.caption(11)).foregroundStyle(Theme.danger)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    // MARK: - 分析档位

    private var analysisSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("分析档位", icon: "dial.medium")
                .padding(.bottom, 6)

            settingsCard {
                row("快速档") {
                    HStack(spacing: 12) {
                        InkSegmented(options: efforts.map { (effortLabel($0), $0) },
                                     selection: Binding(
                                        get: { model.settings.quickEffort },
                                        set: { v in model.updateSettings { $0.quickEffort = v } }))
                    }
                }
                row("深度档") {
                    HStack(spacing: 12) {
                        InkSegmented(options: efforts.map { (effortLabel($0), $0) },
                                     selection: Binding(
                                        get: { model.settings.deepEffort },
                                        set: { v in model.updateSettings { $0.deepEffort = v } }))
                    }
                }
            }

            settingsCard {
                sliderRow("快速档上限", value: Binding(
                    get: { Double(model.settings.quickMaxTokens) },
                    set: { v in model.updateSettings { $0.quickMaxTokens = Int(v) } }),
                          range: 400...8000, step: 100,
                          text: "\(model.settings.quickMaxTokens) token")
                sliderRow("深度档上限", value: Binding(
                    get: { Double(model.settings.deepMaxTokens) },
                    set: { v in model.updateSettings { $0.deepMaxTokens = Int(v) } }),
                          range: 1000...40000, step: 500,
                          text: "\(model.settings.deepMaxTokens) token")
            }
        }
    }

    private func effortLabel(_ e: String) -> String {
        switch e {
        case "none": return "关闭思考"
        case "low": return "轻量思考"
        case "high": return "完整思考"
        case "max": return "最大思考"
        default: return e
        }
    }

    // MARK: - 截图处理

    private var imageSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("截图处理", icon: "photo")
                .padding(.bottom, 6)
            settingsCard {
                sliderRow("最长边", value: Binding(
                    get: { Double(model.settings.maxImageSide) },
                    set: { v in model.updateSettings { $0.maxImageSide = Int(v) } }),
                          range: 1024...4096, step: 128,
                          text: "\(model.settings.maxImageSide) px")
                sliderRow("JPEG 质量", value: Binding(
                    get: { model.settings.jpegQuality },
                    set: { v in model.updateSettings { $0.jpegQuality = v } }),
                          range: 0.5...1.0, step: 0.05,
                          text: String(format: "%.2f", model.settings.jpegQuality))
            }
        }
    }

    // MARK: - 对局

    private var gameSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("对局", icon: "square.grid.3x3")
                .padding(.bottom, 6)
            settingsCard {
                row("牌局类型") {
                    HStack(spacing: 10) {
                        InkToggle(on: Binding(
                            get: { model.settings.isSanma },
                            set: { v in model.updateSettings { $0.isSanma = v } }))
                        Text("这是三人麻将（三麻没有万子）")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.primary.opacity(0.85))
                    }
                }
                row("复盘日志") {
                    HStack(spacing: 10) {
                        InkToggle(on: Binding(
                            get: { model.settings.saveHistory },
                            set: { v in model.updateSettings { $0.saveHistory = v } }))
                        Text("把每次分析记到复盘日志")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.primary.opacity(0.85))
                    }
                }
            }
        }
    }

    // MARK: - 提示词

    private var promptSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                sectionTitle("系统提示词", icon: "text.alignleft")
                Spacer(minLength: 0)
                Button("恢复默认") {
                    model.updateSettings { $0.systemPrompt = PromptTemplate.defaultSystem }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(Theme.accentBright)
            }
            settingsCard {
                TextEditor(text: Binding(
                    get: { model.settings.systemPrompt },
                    set: { v in model.updateSettings { $0.systemPrompt = v } }))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.primary.opacity(0.9))
                    .frame(minHeight: 280)
                    .padding(6)
            }
        }
    }

    // MARK: - 更新（Sparkle，2026-10-16）

    private var updateSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("更新", icon: "arrow.triangle.2.circlepath")
                .padding(.bottom, 6)

            settingsCard {
                row("自动检查") {
                    InkToggle(on: Binding(
                        get: { updater.automaticallyChecksForUpdates },
                        set: { updater.automaticallyChecksForUpdates = $0 }))
                }
            }

            settingsCard {
                row("当前版本") {
                    Text(Bundle.main.appVersionString)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                row("手动检查") {
                    Button {
                        updater.checkForUpdates()
                    } label: {
                        Text("检查更新…")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Theme.accentBright))
                            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(!updater.canCheckForUpdates)
                }
            }
        }
    }

    // MARK: - 标注配色（Overlay 主题，2026-10-16）

    private var overlayThemeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("标注配色", icon: "paintpalette")
                .padding(.bottom, 6)

            settingsCard {
                row("预设主题") {
                    HStack(spacing: 8) {
                        ForEach(OverlayTheme.presets, id: \.name) { p in
                            presetButton(p)
                        }
                        customButton
                    }
                }
            }

            settingsCard {
                ForEach(OverlayTheme.Key.allCases, id: \.rawValue) { k in
                    colorRow(k)
                }
            }

            settingsCard {
                row("重置") {
                    Button("恢复经典配色") {
                        model.updateSettings { $0.overlayTheme = .classic }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Theme.accentBright))
                    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
        }
    }

    /// 预设按钮（四色预览 + 名字，选中高亮）
    private func presetButton(_ p: OverlayTheme) -> some View {
        let cur = model.settings.overlayTheme
        let on = cur.name == p.name && cur.colorsEqual(p)
        return Button {
            model.updateSettings { $0.overlayTheme = p }
        } label: {
            VStack(spacing: 5) {
                HStack(spacing: 3) {
                    ForEach([p.own, p.across, p.left, p.right], id: \.self) { hex in
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(Color(NSColor(hex: hex) ?? .gray))
                            .frame(width: 13, height: 13)
                    }
                }
                Text(p.name)
                    .font(.system(size: 10.5, weight: on ? .bold : .medium))
            }
            .foregroundStyle(on ? Color.primary : Color.primary.opacity(0.6))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(on ? (Theme.isGlass ? Theme.accentBright.opacity(0.18) : Theme.accent.opacity(0.12)) : Theme.inkCard)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Color.primary.opacity(on ? 0.25 : 0.06), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    /// 「自定义」主题卡片（2026-10-18）：点一下把当前配色复制成自定义副本，
    /// 之后颜色行才可编辑——预设主题本身不可改。
    private var customButton: some View {
        let cur = model.settings.overlayTheme
        let on = cur.name == "自定义"
        return Button {
            model.updateSettings { $0.overlayTheme.name = "自定义" }
        } label: {
            VStack(spacing: 5) {
                HStack(spacing: 3) {
                    ForEach([cur.own, cur.across, cur.left, cur.right], id: \.self) { hex in
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(Color(NSColor(hex: hex) ?? .gray))
                            .frame(width: 13, height: 13)
                    }
                }
                Text("自定义")
                    .font(.system(size: 10.5, weight: on ? .bold : .medium))
            }
            .foregroundStyle(on ? Color.primary : Color.primary.opacity(0.6))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(on ? (Theme.isGlass ? Theme.accentBright.opacity(0.18) : Theme.accent.opacity(0.12)) : Theme.inkCard)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Color.primary.opacity(on ? 0.25 : 0.06), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("点一下把当前配色复制为自定义副本，然后点下方色块调色")
    }

    /// 常用色板（自绘，不依赖系统 NSColorPanel——.accessory app 下它拿不到激活）
    private static let swatches: [String] = [
        "#FF3B30", "#FF9500", "#FFCC00", "#34C759",
        "#00C7BE", "#5AA5FF", "#B08FFF", "#FF6B8A",
        "#FFFFFF", "#C7C7CC", "#8E8E93", "#5A5A5F",
    ]

    /// 颜色行：当前值色块 + 12 个常用色点。仅「自定义」主题可点（预设保护）。
    private func colorRow(_ k: OverlayTheme.Key) -> some View {
        let cur = model.settings.overlayTheme
        let hex = cur.hexString(k)
        let editable = cur.name == "自定义"
        return row(k.label) {
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color(NSColor(hex: hex) ?? .systemGray))
                    .frame(width: 22, height: 16)
                    .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
                ForEach(Self.swatches, id: \.self) { h in
                    Circle()
                        .fill(Color(NSColor(hex: h) ?? .gray))
                        .frame(width: 13, height: 13)
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.18),
                                                       lineWidth: 0.5))
                        .opacity(editable ? 1 : 0.25)
                        .contentShape(Circle())
                        .onTapGesture {
                            guard editable else { return }
                            model.updateSettings { $0.overlayTheme.setHex(h, k) }
                        }
                }
                Text(hex)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 58, alignment: .trailing)
            }
        }
    }

    // MARK: - 工具

    private var toolsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("工具", icon: "wrench.and.screwdriver")
                .padding(.bottom, 6)
            settingsCard {
                HStack(spacing: 8) {
                    toolButton("打开配置目录") { NSWorkspace.shared.open(ConfigStore.shared.dirURL) }
                    toolButton("查看运行日志") {
                        NSWorkspace.shared.open(ConfigStore.shared.dirURL.appendingPathComponent("app.log"))
                    }
                    toolButton("查看复盘日志") {
                        NSWorkspace.shared.open(ConfigStore.shared.historyURL)
                    }
                    toolButton("重新检测屏幕权限") { model.refreshPermission() }
                }
            }
        }
    }

    // MARK: - 组件（墨璃表单）

    private func settingsCard<C: View>(@ViewBuilder content: () -> C) -> some View {
        content()
            .padding(Theme.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .fill(Theme.inkCard)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .strokeBorder(Theme.inkStroke, lineWidth: 0.8)
            )
    }

    private func toolButton(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.primary.opacity(0.8))
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Theme.inkCardHi))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Theme.inkStroke, lineWidth: 0.8))
        }
        .buttonStyle(.plain)
    }

    private func sectionTitle(_ t: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(t)
                .font(.system(size: 13, weight: .bold))
        }
    }

    private func row<C: View>(_ label: String, @ViewBuilder content: () -> C) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(label)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .frame(width: 84, alignment: .leading)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func sliderRow(_ label: String, value: Binding<Double>,
                           range: ClosedRange<Double>, step: Double,
                           text: String) -> some View {
        row(label) {
            HStack(spacing: 10) {
                Slider(value: value, in: range, step: step)
                    .tint(Theme.accentBright)
                Text(text)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 78, alignment: .trailing)
            }
        }
    }

    private func okLine(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 10))
            Text(text).font(Theme.caption(11))
        }
        .foregroundStyle(Theme.okBright)
    }

    // MARK: - 连通性测试

    private func runTest() {
        testState = .running
        Task {
            do {
                let answer = try await DeepSeekClient.ping(settings: model.settings)
                await MainActor.run { testState = .ok("连接正常，模型回复：\(answer)") }
            } catch {
                await MainActor.run { testState = .fail(Log.redact(error.localizedDescription)) }
            }
        }
    }
}

/// 设置窗口顶栏拖拽区（borderless 窗口用）。
private struct SettingsDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { SettingsDragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class SettingsDragView: NSView {
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}
