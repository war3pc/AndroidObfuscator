import SwiftUI
import AndroidObfuscatorCore

struct DashboardView: View {
    @EnvironmentObject private var model: AppModel

    private let columns = [GridItem(.adaptive(minimum: 210), spacing: 14)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                hero
                metrics
                capabilityGrid
                recentJobs
            }
            .padding(28)
            .frame(maxWidth: 1280, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .accessibilityIdentifier("page.overview")
    }

    private var hero: some View {
        WorkbenchCard(padding: 0) {
            ZStack(alignment: .bottomTrailing) {
                LinearGradient(
                    colors: [Color(red: 0.05, green: 0.18, blue: 0.17), Color(red: 0.06, green: 0.12, blue: 0.20)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .allowsHitTesting(false)
                Circle()
                    .fill(WorkbenchTheme.accent.opacity(0.18))
                    .frame(width: 280, height: 280)
                    .blur(radius: 2)
                    .offset(x: 85, y: 95)
                    .allowsHitTesting(false)
                Image(systemName: "shield.checkered")
                    .font(.system(size: 150, weight: .ultraLight))
                    .foregroundStyle(.white.opacity(0.07))
                    .offset(x: -28, y: 45)
                    .allowsHitTesting(false)

                HStack(alignment: .center, spacing: 30) {
                    VStack(alignment: .leading, spacing: 13) {
                        StatusPill(text: "LOCAL ONLY", symbol: "lock.laptopcomputer", color: WorkbenchTheme.accent)
                        Text("让 Android 保护流程\n可见、可控、可复现")
                            .font(.system(size: 32, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                        Text("从安全工作副本到 R8、DEX 壳保护、签名校验与 mapping 归档，原始工程和证书始终留在你的 Mac。")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.72))
                            .frame(maxWidth: 650, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 10) {
                            Button {
                                model.selection = .source
                            } label: {
                                Label("保护 Android 工程", systemImage: "curlybraces.square")
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(WorkbenchTheme.accent)
                            .accessibilityIdentifier("dashboard.source")

                            Button {
                                model.selection = .apk
                            } label: {
                                Label("加固 APK", systemImage: "shippingbox")
                            }
                            .buttonStyle(.bordered)
                            .tint(.white)
                            .accessibilityIdentifier("dashboard.apk")
                        }
                    }
                    Spacer()
                }
                .padding(28)
            }
            .frame(minHeight: 290)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private var metrics: some View {
        HStack(spacing: 14) {
            metric(
                title: "基础工具",
                value: "\(model.toolchain.statuses.filter { $0.kind.isRequired && $0.availability == .available }.count)/4",
                detail: model.requiredToolsReady ? "可以执行标准流水线" : "仍有必需工具缺失",
                symbol: "wrench.and.screwdriver.fill",
                color: model.requiredToolsReady ? WorkbenchTheme.accent : WorkbenchTheme.warning,
                destination: .toolchain,
                identifier: "tools"
            )
            metric(
                title: "成功任务",
                value: "\(model.history.filter { $0.status == .succeeded }.count)",
                detail: "最近保留 100 条记录",
                symbol: "checkmark.seal.fill",
                color: WorkbenchTheme.cyan,
                destination: .history,
                identifier: "history"
            )
            metric(
                title: "APK 引擎",
                value: model.toolchain.mocikaShield == nil ? "异常" : "已内置",
                detail: "Mocika Shield 1.3.0",
                symbol: "lock.shield.fill",
                color: WorkbenchTheme.violet,
                destination: .toolchain,
                identifier: "apk-engine"
            )
        }
    }

    private func metric(
        title: String,
        value: String,
        detail: String,
        symbol: String,
        color: Color,
        destination: AppSection,
        identifier: String
    ) -> some View {
        Button {
            model.selection = destination
        } label: {
            WorkbenchCard {
                HStack(spacing: 14) {
                    Image(systemName: symbol)
                        .font(.system(size: 20))
                        .foregroundStyle(color)
                        .frame(width: 42, height: 42)
                        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(value)
                            .font(.title3.bold())
                            .foregroundStyle(.primary)
                        Text(detail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption.bold())
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("dashboard.metric.\(identifier)")
    }

    private var capabilityGrid: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeading(title: "保护能力", subtitle: "每一层都可以独立审查与关闭")
            LazyVGrid(columns: columns, spacing: 14) {
                capability("源码与资源", "内置生成 · R8 · 引用同步改名", "curlybraces", WorkbenchTheme.accent, .source, "source")
                capability("Native 工具链", "Pass 实编译 · ndkPath 强制接线 · ELF/元数据复核", "cpu", WorkbenchTheme.violet, .source, "native")
                capability("APK 壳保护", "内置 Shield · DEX 加密 · 重签", "shippingbox.fill", WorkbenchTheme.cyan, .apk, "apk")
                capability("发布后诊断", "mapping.txt 堆栈还原", "waveform.path.ecg.rectangle", WorkbenchTheme.warning, .retrace, "retrace")
            }
        }
    }

    private func capability(
        _ title: String,
        _ detail: String,
        _ symbol: String,
        _ color: Color,
        _ section: AppSection,
        _ identifier: String
    ) -> some View {
        Button {
            model.selection = section
        } label: {
            WorkbenchCard {
                VStack(alignment: .leading, spacing: 12) {
                    Image(systemName: symbol)
                        .font(.system(size: 20))
                        .foregroundStyle(color)
                        .frame(width: 40, height: 40)
                        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))
                    Text(title)
                        .font(.headline)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Text("打开")
                            .font(.caption.weight(.semibold))
                        Spacer()
                        Image(systemName: "arrow.right")
                    }
                    .foregroundStyle(color)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityIdentifier("dashboard.capability.\(identifier)")
    }

    @ViewBuilder
    private var recentJobs: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionHeading(title: "最近任务", subtitle: "本机历史，不包含密码或私钥")
                Spacer()
                if !model.history.isEmpty {
                    Button("查看全部") { model.selection = .history }
                        .buttonStyle(.link)
                }
            }

            WorkbenchCard {
                if model.history.isEmpty {
                    HStack(spacing: 13) {
                        Image(systemName: "clock.badge.questionmark")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("还没有任务记录")
                                .font(.subheadline.weight(.medium))
                            Text("选择一个 Android 工程或 APK 开始。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(model.history.prefix(4).enumerated()), id: \.element.id) { index, job in
                            Button {
                                model.selection = .history
                            } label: {
                                JobHistoryRow(job: job)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            if index < min(model.history.count, 4) - 1 { Divider().padding(.vertical, 8) }
                        }
                    }
                }
            }
        }
    }
}

struct JobHistoryRow: View {
    let job: JobRecord

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: job.kind == .source ? "curlybraces.square" : "shippingbox")
                .foregroundStyle(job.status.color)
                .frame(width: 34, height: 34)
                .background(job.status.color.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 2) {
                Text(job.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(job.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            StatusPill(text: job.status.displayTitle, symbol: job.status.symbol, color: job.status.color)
        }
    }
}
