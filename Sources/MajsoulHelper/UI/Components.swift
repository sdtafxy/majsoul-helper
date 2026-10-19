import SwiftUI

/// 分组卡片容器：近白底 + 极细描边 + 柔和投影（系统设置同款观感）。
struct SectionBox<Content: View>: View {
    var title: String?
    var icon: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                HStack(spacing: 6) {
                    if let icon {
                        Image(systemName: icon)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    Text(title)
                        .font(Theme.title(12.5))
                }
            }
            content
        }
        .padding(Theme.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

/// 小徽章（胶囊）。filled = 实心彩底白字；否则描边 + 浅底。
struct Chip: View {
    let text: String
    var color: Color = .secondary
    var filled: Bool = false

    var body: some View {
        Text(text)
            .font(Theme.label(10.5))
            .foregroundStyle(filled ? Color.white : color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(filled ? color : color.opacity(0.13))
            )
            .overlay(
                Capsule().stroke(filled ? Color.clear : color.opacity(0.35), lineWidth: 0.8)
            )
    }
}

/// 主按钮 / 次按钮。prominent = 用 tint 色实心；normal = 浅灰底。
struct ActionButton: View {
    let title: String
    var subtitle: String?
    var icon: String
    var prominent: Bool = false
    var tint: Color = Theme.accent
    var enabled: Bool = true
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).font(Theme.title(12.5))
                    if let subtitle {
                        Text(subtitle)
                            .font(Theme.caption(9.5))
                            .opacity(prominent ? 0.9 : 0.65)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, subtitle == nil ? 9 : 7)
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: Theme.smallRadius, style: .continuous)
                    .fill(prominent
                          ? tint.opacity(enabled ? (hovering ? 1.0 : 0.9) : 0.32)
                          : Color.primary.opacity(hovering ? 0.09 : 0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.smallRadius, style: .continuous)
                    .stroke(prominent ? Color.clear : Color.primary.opacity(0.06), lineWidth: 0.8)
            )
            .shadow(color: prominent ? tint.opacity(hovering ? 0.32 : 0.20) : .clear,
                    radius: 5, x: 0, y: 2)
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .contentShape(RoundedRectangle(cornerRadius: Theme.smallRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering = $0 && enabled }
    }
}

/// 一行「标签 + 内容」（label 灰色窄栏 + 正文）
struct LabeledLine: View {
    let label: String
    let text: String
    var color: Color = .primary

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Text(label)
                .font(Theme.caption(11))
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .leading)
            Text(text)
                .font(Theme.body(11.5))
                .foregroundStyle(color)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }
}

/// 状态徽章（识别完成/识别中/失败）
struct StatusBadge: View {
    enum Kind { case busy, ok, fail, idle }
    let kind: Kind
    let text: String

    private var color: Color {
        switch kind {
        case .busy: return Theme.accent
        case .ok: return Theme.ok
        case .fail: return Theme.danger
        case .idle: return .secondary
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            if kind == .busy {
                ProgressView().controlSize(.mini)
            } else {
                Circle().fill(color).frame(width: 5, height: 5)
            }
            Text(text)
                .font(Theme.caption(10.5))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.10)))
    }
}

/// 可折叠区块（chevron 旋转 + 展开内容）
struct Disclosure<Content: View>: View {
    let title: String
    var detail: String? = nil
    @Binding var expanded: Bool
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Text(title).font(Theme.caption(11)).fontWeight(.medium)
                    if let detail {
                        Text(detail).font(Theme.caption(10)).foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, 3)

            if expanded {
                content.padding(.top, 4)
            }
        }
    }
}

// MARK: - 原型 v5 墨璃按钮（主次分级）

/// 主按钮（快速）：蓝渐变 + 内高光 + 投影，可带快捷键徽章。单行「图标 + 词」。
struct MainActionButton: View {
    let title: String
    var icon: String
    var key: String? = nil
    var enabled: Bool = true
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                Text(title)
                    .font(.system(size: 13, weight: .bold))
                    .lineLimit(1)
                Spacer(minLength: 6)
                if let key {
                    Text(key)
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(.white.opacity(0.22)))
                        .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(.white.opacity(0.3), lineWidth: 0.5))
                        .fixedSize()
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: Theme.smallRadius, style: .continuous)
                    .fill(LinearGradient(
                        colors: [Theme.accentBright, Color(red: 0.239, green: 0.525, blue: 0.878)],
                        startPoint: .top, endPoint: .bottom))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.smallRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(colors: [.primary.opacity(0.35), .clear],
                                       startPoint: .top, endPoint: .center),
                        lineWidth: 1)
            )
            .shadow(color: Theme.accentBright.opacity(hovering ? 0.45 : 0.30),
                    radius: 8, x: 0, y: 3)
            .contentShape(RoundedRectangle(cornerRadius: Theme.smallRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .environment(\.colorScheme, .dark)   // 蓝底白字固定
        .onHover { hovering = $0 && enabled }
    }
}

/// 次按钮（识别/深度）：轻量玻璃块 + 彩色图标点睛。单行「图标 + 词」。
struct GhostActionButton: View {
    let title: String
    var icon: String
    var color: Color = .secondary
    var enabled: Bool = true
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(color)
                    .fixedSize()
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.85))
                    .fixedSize()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: Theme.smallRadius, style: .continuous)
                    .fill(Theme.inkCard)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.smallRadius, style: .continuous)
                    .strokeBorder(.primary.opacity(hovering ? 0.14 : 0.07), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: Theme.smallRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering = $0 && enabled }
    }
}

// MARK: - 原型 v5 墨璃自绘控件（替代系统控件，解决对不齐/字号不和谐）

/// 自绘开关（墨璃胶囊 + 圆点）。
struct InkToggle: View {
    @Binding var on: Bool
    var body: some View {
        Button { on.toggle() } label: {
            ZStack(alignment: on ? .trailing : .leading) {
                Capsule()
                    .fill(on ? Theme.okBright : .primary.opacity(0.14))
                    .frame(width: 34, height: 20)
                Circle()
                    .fill(.white)
                    .frame(width: 16, height: 16)
                    .padding(2)
                    .shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5)
            }
        }
        .buttonStyle(.plain)
    }
}

/// 自绘输入框（textFieldStyle(.plain) + 墨璃底，摆脱系统输入框的尺寸/对齐）。
struct InkTextField: View {
    var placeholder: String
    @Binding var text: String
    var mono: Bool = false

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(mono ? .system(size: 11.5, design: .monospaced) : .system(size: 11.5))
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(.primary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(.primary.opacity(0.10), lineWidth: 0.8)
            )
    }
}

/// 自绘分段选择（墨璃 segmented）。
struct InkSegmented<Value: Hashable>: View {
    let options: [(String, Value)]
    @Binding var selection: Value

    var body: some View {
        // ★ FlowLayout 自动换行——选项再多也不会把文字挤到两行
        //   （2026-10-14：服务商 5 个选项用 HStack 把 DeepSeek/Kimi 挤换行）
        FlowLayout(spacing: 4) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, opt in
                let on = opt.1 == selection
                Button { selection = opt.1 } label: {
                    Text(opt.0)
                        .font(.system(size: 11, weight: on ? .bold : .medium))
                        .foregroundStyle(on ? Color.primary : Color.primary.opacity(0.55))
                        .fixedSize()
                        .padding(.horizontal, 11)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(on ? Theme.segOnFill : .clear)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Theme.inkChip)
        )
    }
}
