import SwiftUI

/// 建议卡（原型 v5 墨璃）：一次决策指令的视觉主体。
/// - Hero 居中：打 + 超大推荐牌 + 牌名 + 把握徽章。
/// - 第一行 chips：理由/危险/备选/要点（模型建议内容）。
/// - 第二行 chips：提示词/模型输出/截图（排查用原始材料，2026-10-15 从
///   主浮窗底部详情区搬入——放卡内才够得到，不用拉长浮窗）。
struct AdviceCard: View {
    let advice: Advice
    /// 是否默认展开全部详情（设置项）
    var defaultExpanded: Bool = false
    /// 观察 AppModel：读提示词/输出/截图（@Published 变化触发重绘）
    @ObservedObject private var model = AppModel.shared
    @State private var showReason = false
    @State private var showDanger = false
    @State private var showAlt = false
    @State private var showLesson = false
    @State private var showPrompt = false
    @State private var showOutput = false
    @State private var showShot = false

    private var rec: Advice.Recommended? { advice.recommended }
    private var tile: String { rec?.tile ?? "" }

    var body: some View {
        VStack(spacing: 0) {
            hero
            chips
            debugChips          // 第二行：提示词/模型输出/截图
            if showReason || showDanger || showAlt || showLesson
                || showPrompt || showOutput || showShot {
                VStack(alignment: .leading, spacing: 8) {
                    if showReason, let r = advice.reason, !r.isEmpty {
                        detailBlock { LabeledLine(label: "理由", text: r) }
                    }
                    if showDanger, let d = advice.danger, !(d.detail ?? "").isEmpty {
                        detailBlock {
                            LabeledLine(label: "危险", text: d.detail ?? "",
                                        color: Theme.warnBright)
                        }
                    }
                    if showAlt, let alts = advice.alternatives, !alts.isEmpty {
                        detailBlock { alternatives(alts) }
                    }
                    if showLesson, let l = advice.lesson, !l.isEmpty {
                        detailBlock { lesson(l) }
                    }
                    if showPrompt, !model.llmPrompt.isEmpty {
                        detailBlock { monoscroll(model.llmPrompt, size: 9.5) }
                    }
                    if showOutput {
                        detailBlock {
                            monoscroll(outputText, size: 10)
                        }
                    }
                    if showShot, let img = model.lastShot {
                        detailBlock {
                            VStack(alignment: .leading, spacing: 6) {
                                Image(nsImage: img)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(maxHeight: 190)
                                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .strokeBorder(Theme.inkStroke, lineWidth: 0.8))
                                Button("在预览中打开原图") { model.openLastShotInPreview() }
                                    .buttonStyle(.plain)
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(Theme.accent)
                            }
                        }
                    }
                }
                .padding(.top, 10)
            }
        }
        .padding(Theme.cardPadding)
        .frame(maxWidth: .infinity)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: Theme.heroRadius, style: .continuous)
                    .fill(Theme.inkCardHi)
                // 顶部径向蓝光 + 镜面高光（原型 hero 背景）
                RoundedRectangle(cornerRadius: Theme.heroRadius, style: .continuous)
                    .fill(RadialGradient(
                        colors: [Theme.accentBright.opacity(0.14), .clear],
                        center: .top, startRadius: 0, endRadius: 150))
                RoundedRectangle(cornerRadius: Theme.heroRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(colors: [.primary.opacity(0.12), .clear],
                                       startPoint: .top, endPoint: .center),
                        lineWidth: 1)
            })
        .onAppear {
            if defaultExpanded {
                showReason = advice.reason != nil
                showDanger = advice.danger != nil
                showAlt = !(advice.alternatives ?? []).isEmpty
                showLesson = advice.lesson != nil
            }
        }
    }

    // MARK: - Hero

    private var hero: some View {
        VStack(spacing: 0) {
            Text((rec?.action ?? "").isEmpty ? "打" : rec!.action!)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
            if !tile.trimmingCharacters(in: .whitespaces).isEmpty {
                MahjongTile(notation: tile, scale: 1.45)
                    .padding(.vertical, 9)
                    .shadow(color: .black.opacity(0.45), radius: 12, y: 5)
                Text(Advice.display(tile))
                    .font(.system(size: 23, weight: .heavy))
            } else {
                Text("模型没给出明确的打牌建议")
                    .font(Theme.body(12))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 20)
            }
            if let c = rec?.confidence, !c.isEmpty {
                Chip(text: "把握 " + Theme.levelText(c),
                     color: Theme.confidenceColor(c), filled: true)
                    .padding(.top, 7)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - chips

    private func chip(_ title: String, _ on: Binding<Bool>, has: Bool) -> some View {
        Button { on.wrappedValue.toggle() } label: {
            HStack(spacing: 3) {
                Image(systemName: on.wrappedValue ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                Text(title)
                    .font(.system(size: 10.5, weight: .semibold))
            }
            // 选中：玻璃=亮蓝字 / 白底=深蓝字（accentBright 在白底上太浅）
            .foregroundStyle(on.wrappedValue
                             ? (Theme.isGlass ? Theme.accentBright : Theme.accent)
                             : .primary.opacity(0.62))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(on.wrappedValue
                                       ? (Theme.isGlass ? Theme.accentBright.opacity(0.20) : Theme.accent.opacity(0.12))
                                       : Theme.inkChip))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!has)
        .opacity(has ? 1 : 0.35)
    }

    private var chips: some View {
        HStack(spacing: 6) {
            chip("理由", $showReason, has: advice.reason?.isEmpty == false)
            chip("危险", $showDanger, has: advice.danger != nil)
            chip("备选", $showAlt, has: !(advice.alternatives ?? []).isEmpty)
            chip("要点", $showLesson, has: advice.lesson?.isEmpty == false)
        }
        .padding(.top, 12)
    }

    /// 第二行 chips：提示词 / 模型输出 / 截图（排查原始材料）
    private var debugChips: some View {
        HStack(spacing: 6) {
            chip("提示词", $showPrompt, has: !model.llmPrompt.isEmpty)
            chip("模型输出", $showOutput, has: !model.rawText.isEmpty)
            chip("截图", $showShot, has: model.lastShot != nil)
        }
        .padding(.top, 6)
    }

    /// 模型输出文本（原始输出 + 思考过程拼在一起）
    private var outputText: String {
        var s = model.rawText
        if !model.reasoningText.isEmpty {
            s = "── 思考过程 ──\n" + model.reasoningText + "\n\n── 原始输出 ──\n" + s
        }
        return s
    }

    /// 等宽文本块（长文本限高 + 可选内部滚动）
    private func monoscroll(_ text: String, size: CGFloat) -> some View {
        Group {
            if SnapshotMode.isActive {
                Text(text)
            } else {
                ScrollView(.vertical) {
                    Text(text)
                }
                .frame(maxHeight: 160)
            }
        }
        .font(.system(size: size, design: .monospaced))
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - 详情块

    private func detailBlock<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        content()
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Theme.inkDetail))
    }

    private func alternatives(_ alts: [Advice.Alternative]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("备选")
                .font(Theme.caption(11))
                .foregroundStyle(.secondary)
            ForEach(Array(alts.enumerated()), id: \.offset) { _, alt in
                HStack(alignment: .top, spacing: 8) {
                    if let t = alt.tile, !t.isEmpty {
                        MahjongTile(notation: t, scale: 0.75)
                    }
                    Text(alt.why ?? "")
                        .font(Theme.body(11.5))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func lesson(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "lightbulb.fill")
                .font(.system(size: 10))
                .foregroundStyle(Theme.warnBright)
                .padding(.top, 2)
            Text(text)
                .font(Theme.body(11.5))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}
