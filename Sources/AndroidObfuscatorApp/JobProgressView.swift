import SwiftUI

struct JobProgressView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            if let job = model.activeJob {
                header(job)
                Divider()
                HSplitView {
                    steps(job)
                        .frame(minWidth: 260, idealWidth: 300, maxWidth: 340)
                    log(job)
                        .frame(minWidth: 580)
                }
                Divider()
                footer(job)
            } else {
                ContentUnavailableView("没有活动任务", systemImage: "tray")
            }
        }
        .frame(minWidth: 920, minHeight: 610)
    }

    private func header(_ job: ActiveJobViewState) -> some View {
        HStack(spacing: 14) {
            Image(systemName: job.status.symbol)
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(job.status.color)
                .frame(width: 42, height: 42)
                .background(job.status.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 3) {
                Text(job.plan.kind.title + " · " + job.plan.name)
                    .font(.headline)
                Text(job.currentStepTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            StatusPill(text: job.status.displayTitle, symbol: job.status.symbol, color: job.status.color)
        }
        .padding(18)
    }

    private func steps(_ job: ActiveJobViewState) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("总体进度")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(job.progress, format: .percent.precision(.fractionLength(0)))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: job.progress)
                    .tint(WorkbenchTheme.accent)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(job.plan.steps.enumerated()), id: \.element.id) { index, step in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: stepSymbol(job: job, index: index, stepID: step.id))
                                .foregroundStyle(stepColor(job: job, index: index, stepID: step.id))
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(step.title)
                                    .font(.subheadline.weight(index == job.currentStepIndex && job.isRunning ? .semibold : .regular))
                                Text(step.detail)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(.vertical, 8)
                    }
                }
            }
        }
        .padding(18)
    }

    private func log(_ job: ActiveJobViewState) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("实时日志", systemImage: "terminal")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(job.log, forType: .string)
                } label: {
                    Label("复制", systemImage: "doc.on.doc")
                }
                .buttonStyle(.borderless)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    Text(job.log)
                        .font(.system(size: 11.5, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(12)
                    Color.clear.frame(height: 1).id("bottom")
                }
                .background(Color.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 10))
                .foregroundStyle(Color.white.opacity(0.86))
                .onChange(of: job.log.count) { _, _ in
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
            if let error = job.errorMessage {
                Label(error, systemImage: "exclamationmark.octagon.fill")
                    .font(.caption)
                    .foregroundStyle(WorkbenchTheme.danger)
            }
        }
        .padding(18)
    }

    private func footer(_ job: ActiveJobViewState) -> some View {
        HStack {
            Text(job.plan.rootDirectory.path)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if job.isRunning {
                Button("取消任务", role: .destructive) { model.cancelJob() }
                    .buttonStyle(.bordered)
            } else {
                Button("在 Finder 中显示") { model.revealOutput() }
                    .buttonStyle(.bordered)
                    .disabled(job.plan.finalOutput == nil)
                Button("完成") { model.clearFinishedJobPanel() }
                    .buttonStyle(.borderedProminent)
                    .tint(WorkbenchTheme.accent)
            }
        }
        .padding(16)
    }

    private func stepSymbol(job: ActiveJobViewState, index: Int, stepID: UUID) -> String {
        if job.completedSteps.contains(stepID) { return "checkmark.circle.fill" }
        if job.isRunning && index == job.currentStepIndex { return "circle.dotted.circle.fill" }
        return "circle"
    }

    private func stepColor(job: ActiveJobViewState, index: Int, stepID: UUID) -> Color {
        if job.completedSteps.contains(stepID) { return WorkbenchTheme.accent }
        if job.isRunning && index == job.currentStepIndex { return WorkbenchTheme.cyan }
        return .secondary.opacity(0.55)
    }
}
