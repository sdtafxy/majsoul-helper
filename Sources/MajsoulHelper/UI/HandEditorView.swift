import SwiftUI

/// 手牌区：显示识别结果，并且**可以直接改**。
///
/// 为什么必须可改：实测模型认雀魂的筒子/索子图案就是不稳定 ——
/// 整屏读 14 张只能对 1~4 张，逐张切出来单独读能对 8~12 张，
/// 但**做不到 14/14**。所以「识别 + 一键改错」是必须成对出现的，
/// 少了后者这个工具就不好用。
struct HandEditorView: View {
    @ObservedObject var model: AppModel
    // 快照模式下自动展开选牌盘：这块 4 行 × 9~10 列的网格最容易在 404pt 宽度里挤爆，
    // 必须能一眼看到，不能靠人工点开才发现。
    @State private var editingIndex: Int? = SnapshotMode.isActive ? 0 : nil
    @State private var adding = false

    private static let pickerRows: [[String]] = [
        (1...9).map { "\($0)m" },
        (1...9).map { "\($0)p" },
        (1...9).map { "\($0)s" },
        ["1z", "2z", "3z", "4z", "5z", "6z", "7z", "0m", "0p", "0s"]
    ]

    var body: some View {
        SectionBox(title: nil, icon: nil) {
            VStack(alignment: .leading, spacing: 8) {
                header
                if model.recognizedHand.isEmpty {
                    Text("还没有读到手牌。点上面「快速分析」跑一次。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    handRow
                }
                if editingIndex != nil || adding { picker }
                if model.handDirty { reanalyzeBar }
                if let note = model.segmentationNote { noteView(note) }
                segmentedPreview
            }
        }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 6) {
            Text("手牌")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            if !model.recognizedHand.isEmpty {
                Text("\(model.recognizedHand.count) 张")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                Chip(text: model.handSource.label, color: sourceColor, filled: model.handSource == .modelImage)
                if let p = model.handProgress {
                    Text("识别中 \(p.done)/\(p.total)")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.accent)
                }
            }
            Spacer(minLength: 0)
            if !model.recognizedHand.isEmpty {
                Button(adding ? "取消添加" : "＋加牌") {
                    adding.toggle(); editingIndex = nil
                }
                .buttonStyle(.plain)
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.accent)
            }
        }
    }

    private var sourceColor: Color {
        switch model.handSource {
        case .tileSegment: return Theme.ok
        case .userCorrected: return Theme.accent
        case .modelImage: return Theme.warn
        }
    }

    // MARK: - 手牌行（点一张牌进入编辑）

    private var handRow: some View {
        FlowLayout(spacing: 3) {
            ForEach(Array(model.recognizedHand.enumerated()), id: \.offset) { idx, t in
                Button {
                    editingIndex = (editingIndex == idx) ? nil : idx
                    adding = false
                } label: {
                    MahjongTile(notation: t, scale: 0.86)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .stroke(editingIndex == idx ? Theme.accent : Color.clear, lineWidth: 2)
                        )
                        .opacity(t == "?" ? 0.45 : 1)
                }
                .buttonStyle(.plain)
                .help(t == "?" ? "这一张没认出来，点一下改成正确的牌" : "点一下修改这张（\(Advice.display(t))）")
            }
        }
    }

    // MARK: - 选牌盘

    private var picker: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(adding ? "选一张要加进来的牌" : "选一张替换第 \(editingIndex! + 1) 张")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if let i = editingIndex {
                    Button("删除这张") {
                        model.removeHandTile(at: i)
                        editingIndex = nil
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.danger)
                }
                Button("关闭") { editingIndex = nil; adding = false }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(Self.pickerRows.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 3) {
                        ForEach(row, id: \.self) { t in
                            Button {
                                if adding { model.appendHandTile(t) }
                                else if let i = editingIndex { model.replaceHandTile(at: i, with: t) }
                                editingIndex = nil
                                adding = false
                            } label: {
                                MahjongTile(notation: t, scale: 0.66)
                            }
                            .buttonStyle(.plain)
                            .help(Advice.display(t))
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.06)))
        }
    }

    // MARK: - 改完后重算

    private var reanalyzeBar: some View {
        HStack(spacing: 7) {
            Button {
                model.reanalyze(with: model.recognizedHand)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.clockwise").font(.system(size: 10, weight: .semibold))
                    Text("用手改的手牌重新分析").font(.system(size: 11, weight: .medium))
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(Theme.accent))
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(!model.canReanalyze)

            Button("撤销修改") { model.resetHandToRecognized() }
                .buttonStyle(.plain)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Theme.accent.opacity(0.10)))
    }

    // MARK: - 提示 / 切分核对

    private func noteView(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 5) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9)).foregroundStyle(Theme.warn).padding(.top, 2)
            Text(text)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var segmentedPreview: some View {
        if !model.tileThumbnails.isEmpty {
            Disclosure(title: "切分出的单张牌",
                       detail: "\(model.tileThumbnails.count) 张 · 核对切歪了没",
                       expanded: Binding(
                        get: { showSegmented },
                        set: { showSegmented = $0 })) {
                HStack(spacing: 4) {
                    ForEach(Array(model.tileThumbnails.enumerated()), id: \.offset) { _, img in
                        Image(nsImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(height: 46)
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                            .overlay(RoundedRectangle(cornerRadius: 3)
                                .stroke(Color.primary.opacity(0.15), lineWidth: 1))
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    @State private var showSegmented = false
}
