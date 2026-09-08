import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 218, ideal: 238, max: 275)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(WorkbenchTheme.pageGradient)
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    model.selection = .toolchain
                } label: {
                    StatusPill(
                        text: model.requiredToolsReady ? "基础工具就绪" : "工具链待配置",
                        symbol: model.requiredToolsReady ? "checkmark.shield.fill" : "exclamationmark.triangle.fill",
                        color: model.requiredToolsReady ? WorkbenchTheme.accent : WorkbenchTheme.warning
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .sheet(isPresented: $model.showJobPanel) {
            JobProgressView()
                .environmentObject(model)
                .interactiveDismissDisabled(model.isRunning)
        }
        .alert("无法开始任务", isPresented: Binding(
            get: { model.lastError != nil },
            set: { if !$0 { model.lastError = nil } }
        )) {
            Button("知道了", role: .cancel) { model.lastError = nil }
        } message: {
            Text(model.lastError ?? "")
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [WorkbenchTheme.accent, WorkbenchTheme.cyan],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    Image(systemName: "shield.lefthalf.filled")
                        .font(.system(size: 19, weight: .bold))
                        .foregroundStyle(.white)
                }
                .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 1) {
                    Text("守界 Android")
                        .font(.headline)
                    Text("本地保护工作台")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 12)

            List {
                ForEach(["工作台", "保护与验证", "管理"], id: \.self) { group in
                    Section(group) {
                        ForEach(AppSection.allCases.filter { $0.group == group }) { item in
                            Button {
                                model.selection = item
                            } label: {
                                HStack(spacing: 9) {
                                    Image(systemName: item.symbol)
                                        .frame(width: 18)
                                    Text(item.title)
                                    Spacer(minLength: 0)
                                }
                                .foregroundStyle(model.selection == item ? WorkbenchTheme.accent : Color.primary)
                                .padding(.vertical, 5)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(model.selection == item ? WorkbenchTheme.accent.opacity(0.14) : Color.clear)
                            )
                            .accessibilityIdentifier("sidebar.\(item.rawValue)")
                        }
                    }
                }
            }
            .listStyle(.sidebar)

            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: $model.authorizationAccepted) {
                    Text("我确认拥有处理权限")
                        .font(.caption.weight(.medium))
                }
                .toggleStyle(.checkbox)
                Text("所有文件仅在本机处理；外部工具仍需自行审查。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
            .padding(12)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch model.selection {
        case .overview: DashboardView()
        case .source: SourceProtectionView()
        case .apk: APKProtectionView()
        case .retrace: RetraceView()
        case .toolchain: ToolchainView()
        case .history: HistoryView()
        case .about: AboutView()
        }
    }
}
