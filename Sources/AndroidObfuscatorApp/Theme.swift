import SwiftUI
import AndroidObfuscatorCore

enum WorkbenchTheme {
    static let accent = Color(red: 0.20, green: 0.70, blue: 0.55)
    static let cyan = Color(red: 0.25, green: 0.66, blue: 0.90)
    static let violet = Color(red: 0.57, green: 0.46, blue: 0.93)
    static let warning = Color(red: 0.96, green: 0.64, blue: 0.22)
    static let danger = Color(red: 0.93, green: 0.34, blue: 0.39)

    static let pageGradient = LinearGradient(
        colors: [
            Color(nsColor: .windowBackgroundColor),
            Color(nsColor: .windowBackgroundColor).opacity(0.96),
            accent.opacity(0.035)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

struct WorkbenchCard<Content: View>: View {
    var padding: CGFloat = 20
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08))
                    .allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(0.035), radius: 14, y: 5)
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

struct PageHeader<Trailing: View>: View {
    let title: String
    let subtitle: String
    let symbol: String
    @ViewBuilder var trailing: Trailing

    init(title: String, subtitle: String, symbol: String, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            Image(systemName: symbol)
                .font(.system(size: 23, weight: .semibold))
                .foregroundStyle(WorkbenchTheme.accent)
                .frame(width: 48, height: 48)
                .background(WorkbenchTheme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 13, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 16)
            trailing
        }
    }
}

extension PageHeader where Trailing == EmptyView {
    init(title: String, subtitle: String, symbol: String) {
        self.init(title: title, subtitle: subtitle, symbol: symbol) { EmptyView() }
    }
}

struct SectionHeading: View {
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.headline)
            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct StatusPill: View {
    let text: String
    let symbol: String
    let color: Color

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(color.opacity(0.12), in: Capsule())
    }
}

struct PathSelectionRow: View {
    let title: String
    let subtitle: String
    let url: URL?
    let buttonTitle: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(url == nil ? Color.secondary : WorkbenchTheme.accent)
                    .frame(width: 34, height: 34)
                    .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                    Text(url?.path ?? subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                Text(buttonTitle)
                    .font(.subheadline)
                    .foregroundStyle(WorkbenchTheme.accent)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 7))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title)，\(buttonTitle)")
    }
}

struct ProfilePicker: View {
    let selected: ProtectionProfile
    let onSelect: (ProtectionProfile) -> Void

    var body: some View {
        HStack(spacing: 8) {
            ForEach(ProtectionProfile.allCases) { profile in
                Button {
                    onSelect(profile)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(profile.title)
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            if selected == profile {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(WorkbenchTheme.accent)
                            }
                        }
                        Text(profile.summary)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, minHeight: 48, alignment: .topLeading)
                    .padding(10)
                    .background(
                        selected == profile ? WorkbenchTheme.accent.opacity(0.11) : Color.primary.opacity(0.035),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(selected == profile ? WorkbenchTheme.accent.opacity(0.55) : Color.primary.opacity(0.07))
                            .allowsHitTesting(false)
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct OptionRow: View {
    let title: String
    let detail: String
    let symbol: String
    @Binding var isOn: Bool
    var badge: String? = nil
    var enabled: Bool = true

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .foregroundStyle(isOn ? WorkbenchTheme.accent : Color.secondary)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 7) {
                        Text(title)
                            .font(.subheadline.weight(.medium))
                        if let badge {
                            Text(badge)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(WorkbenchTheme.violet)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(WorkbenchTheme.violet.opacity(0.12), in: Capsule())
                        }
                    }
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
            }
            .contentShape(Rectangle())
        }
        .toggleStyle(.switch)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.55)
        .help(enabled ? "点击整行切换" : "需要先选择工程或配置对应工具")
    }
}

struct PlanPreview: View {
    let result: Result<PipelinePlan, Error>

    var body: some View {
        switch result {
        case .success(let plan):
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(plan.steps.enumerated()), id: \.element.id) { index, step in
                    HStack(alignment: .top, spacing: 11) {
                        VStack(spacing: 0) {
                            Text("\(index + 1)")
                                .font(.caption2.bold())
                                .foregroundStyle(.white)
                                .frame(width: 22, height: 22)
                                .background(WorkbenchTheme.accent, in: Circle())
                            if index < plan.steps.count - 1 {
                                Rectangle()
                                    .fill(Color.primary.opacity(0.12))
                                    .frame(width: 1, height: 37)
                            }
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(step.title)
                                .font(.subheadline.weight(.medium))
                            Text(step.preview)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .truncationMode(.middle)
                        }
                        .padding(.bottom, index < plan.steps.count - 1 ? 10 : 0)
                    }
                }
            }
        case .failure(let error):
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(WorkbenchTheme.warning)
                Text(error.localizedDescription)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(WorkbenchTheme.warning.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

extension JobStatus {
    var displayTitle: String {
        switch self {
        case .running: return "运行中"
        case .succeeded: return "已完成"
        case .failed: return "失败"
        case .cancelled: return "已取消"
        }
    }

    var color: Color {
        switch self {
        case .running: return WorkbenchTheme.cyan
        case .succeeded: return WorkbenchTheme.accent
        case .failed: return WorkbenchTheme.danger
        case .cancelled: return .secondary
        }
    }

    var symbol: String {
        switch self {
        case .running: return "arrow.triangle.2.circlepath"
        case .succeeded: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .cancelled: return "minus.circle.fill"
        }
    }
}
