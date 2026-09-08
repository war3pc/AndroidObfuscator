import AppKit
import SwiftUI
import AndroidObfuscatorCore

struct HistoryView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(
                    title: "任务记录",
                    subtitle: "最多保留 100 条本地执行摘要，不记录密码与私钥",
                    symbol: "clock.arrow.circlepath"
                )

                HStack(spacing: 14) {
                    summary("全部", model.history.count, "tray.full.fill", WorkbenchTheme.cyan)
                    summary("成功", model.history.filter { $0.status == .succeeded }.count, "checkmark.circle.fill", WorkbenchTheme.accent)
                    summary("失败", model.history.filter { $0.status == .failed }.count, "xmark.circle.fill", WorkbenchTheme.danger)
                    summary("已取消", model.history.filter { $0.status == .cancelled }.count, "minus.circle.fill", Color.secondary)
                }

                WorkbenchCard {
                    if model.history.isEmpty {
                        ContentUnavailableView(
                            "还没有任务记录",
                            systemImage: "clock.badge.questionmark",
                            description: Text("完成源码保护或 APK 加固后会在这里显示摘要。")
                        )
                        .frame(minHeight: 300)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(model.history.enumerated()), id: \.element.id) { index, job in
                                historyRow(job)
                                if index < model.history.count - 1 { Divider().padding(.vertical, 9) }
                            }
                        }
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 1280)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .accessibilityIdentifier("page.history")
    }

    private func summary(_ title: String, _ value: Int, _ symbol: String, _ color: Color) -> some View {
        WorkbenchCard {
            HStack {
                Image(systemName: symbol)
                    .font(.title3)
                    .foregroundStyle(color)
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(value)")
                        .font(.title3.bold())
                    Text(title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func historyRow(_ job: JobRecord) -> some View {
        HStack(spacing: 13) {
            Image(systemName: job.kind == .source ? "curlybraces.square.fill" : "shippingbox.fill")
                .foregroundStyle(job.status.color)
                .frame(width: 40, height: 40)
                .background(job.status.color.opacity(0.11), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(job.name)
                        .font(.subheadline.weight(.semibold))
                    Text(job.kind.title)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.06), in: Capsule())
                }
                Text(job.summary.isEmpty ? "等待执行" : job.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let path = job.outputPath {
                    Text(path)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                StatusPill(text: job.status.displayTitle, symbol: job.status.symbol, color: job.status.color)
                Text(job.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let path = job.outputPath {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .help("在 Finder 中显示")
            }
        }
    }
}
