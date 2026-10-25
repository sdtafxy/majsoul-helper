import SwiftUI

/// 识别结果左栏：宝牌 / 手牌 / 各家副露 / 四家牌河，真实牌面渲染。
/// 数据来自 OverlayController（Python overlay_cli）的最近一次识别。
struct RecognitionPane: View {
    @ObservedObject var overlay: OverlayController
    /// 关闭窗口（独立浮窗用；嵌在主界面里时为 nil）
    var onClose: (() -> Void)? = nil

    var body: some View {
        let r = overlay.currentResult
        VStack(alignment: .leading, spacing: 12) {
            header
            layerControls
            Divider().opacity(0.5)

            if r.hand == nil && r.seats.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "rectangle.grid.2x2")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text("按主浮窗的「识别 / 快速 / 深度」")
                        .font(Theme.caption(11))
                        .foregroundStyle(.secondary)
                    Text("这里会显示切分识别的牌面")
                        .font(Theme.caption(10.5))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 30)
            } else {
                // ★ 快照模式下 ImageRenderer 渲染不了 ScrollView（整块空白）
                let content = VStack(alignment: .leading, spacing: 11) {
                    if let dora = r.dora, !dora.indicators.isEmpty {
                        tileRow("宝牌", dora.dora.isEmpty ? dora.indicators : dora.dora, scale: 0.68)
                    }
                    if let hand = r.hand, !hand.tiles.isEmpty {
                        handRow(hand)
                    }
                    let seatNames = ["own": "自家", "across": "对家", "left": "上家", "right": "下家"]
                    ForEach(["own", "across", "left", "right"], id: \.self) { key in
                        if let m = r.melds[key], !m.groups.isEmpty {
                            ForEach(Array(m.groups.enumerated()), id: \.offset) { gi, g in
                                if g.contains(where: { $0.isKan }), g.count == 2 {
                                    // 暗杠：4 张占位（背 / 明 / 明 / 背）+ 标签
                                    kanRow("\(seatNames[key] ?? key)副露",
                                           g.map { $0.name ?? "?" }, scale: 0.60)
                                } else {
                                    tileRow("\(seatNames[key] ?? key)副露",
                                            g.map { $0.name ?? "?" }, scale: 0.60)
                                }
                            }
                        }
                    }
                    ForEach(r.seats, id: \.key) { seat in
                        if !seat.tiles.isEmpty {
                            tileRow(seat.cnName + "牌河",
                                    seat.tiles.map { $0.name ?? "?" }, scale: 0.60)
                        }
                    }
                }
                if SnapshotMode.isActive {
                    content
                } else {
                    ScrollView(.vertical) { content }
                        .frame(maxHeight: 620)
                }
            }
        }
        .padding(Theme.cardPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card()
    }

    // MARK: - 顶栏（标题 + 状态 + 排查包）

    private var header: some View {
        HStack(spacing: 7) {
            Image(systemName: "rectangle.grid.2x2")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("识别结果")
                .font(Theme.title(13))
            Spacer(minLength: 0)
            StatusBadge(kind: overlay.status.isBusy ? .busy
                            : (overlay.currentResult.hand != nil || !overlay.currentResult.seats.isEmpty ? .ok : .idle),
                        text: overlay.status.isBusy ? "识别中" : "就绪")
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("关闭识别结果窗口（菜单栏可再唤出）")
            }
        }
    }

    // MARK: - 图层开关 + 排查包

    private var layerControls: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Button {
                    overlay.overlayEnabled.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(overlay.overlayEnabled ? Theme.ok : Color.secondary.opacity(0.5))
                            .frame(width: 6, height: 6)
                        Text("图层 " + (overlay.overlayEnabled ? "开" : "关"))
                            .font(Theme.label(10.5))
                    }
                    .padding(.horizontal, 9).padding(.vertical, 3.5)
                    .background(Capsule().fill(
                        overlay.overlayEnabled ? Theme.ok.opacity(0.14) : Color.primary.opacity(0.06)))
                    .foregroundStyle(overlay.overlayEnabled ? Theme.ok : Color.secondary)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("识别 / 分析后，把结果叠加到游戏窗口上")

                Spacer(minLength: 0)

                Button { overlay.captureOnly() } label: {
                    Label("截图", systemImage: "camera")
                        .font(Theme.label(10.5))
                        .padding(.horizontal, 8).padding(.vertical, 3.5)
                        .background(Capsule().fill(Color.primary.opacity(0.06)))
                        .foregroundStyle(.secondary)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(overlay.status.isBusy || overlay.selectedWindowID == 0)
                .help("只截一张当前画面存到「截图保存位置」（默认下载文件夹），不跑识别")

                Button { overlay.exportPackage() } label: {
                    Label("排查包", systemImage: "shippingbox")
                        .font(Theme.label(10.5))
                        .padding(.horizontal, 8).padding(.vertical, 3.5)
                        .background(Capsule().fill(Color.primary.opacity(0.06)))
                        .foregroundStyle(.secondary)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(overlay.status.isBusy || overlay.selectedWindowID == 0)
                .help("把最近一次识别用的截图和结果存到「下载」文件夹，识别不对时把整个文件夹发回来即可")
            }
            HStack(spacing: 4) {
                chipToggle("手牌", $overlay.showHand)
                chipToggle("牌河", $overlay.showRiver)
                chipToggle("副露", $overlay.showMeld)
                chipToggle("宝牌", $overlay.showDora)
                chipToggle("状态", $overlay.showHUD)
            }
        }
    }

    private func chipToggle(_ label: String, _ on: Binding<Bool>) -> some View {
        Button { on.wrappedValue.toggle() } label: {
            Text(label)
                .font(Theme.caption(10.5))
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Capsule().fill(
                    on.wrappedValue ? Theme.accent.opacity(0.14) : Color.primary.opacity(0.05)))
                .foregroundStyle(on.wrappedValue ? Theme.accent : .secondary)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func handRow(_ hand: OverlayHand) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("手牌").font(Theme.caption(10.5)).fontWeight(.semibold)
                .foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 26), spacing: 3)],
                      alignment: .leading, spacing: 3) {
                ForEach(hand.tiles) { t in
                    MahjongTile(notation: t.name ?? "?", scale: 0.68)
                        .overlay(
                            RoundedRectangle(cornerRadius: 2)
                                .stroke(Color.orange, lineWidth: 1.5)
                                .opacity(t.isDrawn ? 1 : 0)
                        )
                }
            }
        }
    }

    private func tileRow(_ title: String, _ names: [String], scale: CGFloat = 0.60) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(Theme.caption(10.5)).fontWeight(.semibold)
                .foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 26), spacing: 3)],
                      alignment: .leading, spacing: 3) {
                ForEach(Array(names.enumerated()), id: \.offset) { _, n in
                    MahjongTile(notation: n, scale: scale)
                }
            }
        }
    }

    /// 暗杠：背 / 明 / 明 / 背 四张占位 + 「暗杠」标签
    /// （Python 只识别中间两张明牌，两端盖住的背牌用占位表现）
    private func kanRow(_ title: String, _ names: [String], scale: CGFloat = 0.60) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(title).font(Theme.caption(10.5)).fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                Text("暗杠")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(Capsule().fill(Theme.accent.opacity(0.14)))
            }
            HStack(spacing: 3) {
                MahjongTile(notation: "", scale: scale, isBack: true)
                ForEach(Array(names.prefix(2).enumerated()), id: \.offset) { _, n in
                    MahjongTile(notation: n, scale: scale)
                }
                MahjongTile(notation: "", scale: scale, isBack: true)
            }
        }
    }
}
