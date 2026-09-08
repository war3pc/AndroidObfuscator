import SwiftUI
import AndroidObfuscatorCore

struct ToolchainView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(
                    title: "工具链",
                    subtitle: "发现 Android SDK/JDK，验证内置 APK 引擎与定制 Native 编译器",
                    symbol: "wrench.and.screwdriver.fill"
                ) {
                    Button {
                        model.refreshToolchain()
                    } label: {
                        Label("重新检测", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }

                HStack(alignment: .top, spacing: 18) {
                    VStack(spacing: 18) {
                        statusCard
                        pathsCard
                    }
                    .frame(maxWidth: .infinity)

                    VStack(spacing: 18) {
                        executionBoundaryCard
                        distributionCard
                    }
                    .frame(width: 390)
                }
            }
            .padding(28)
            .frame(maxWidth: 1280)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .accessibilityIdentifier("page.toolchain")
    }

    private var statusCard: some View {
        WorkbenchCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    SectionHeading(title: "检测结果", subtitle: "不会联网下载或静默执行版本脚本")
                    Spacer()
                    StatusPill(
                        text: model.requiredToolsReady ? "基础能力就绪" : "需要处理",
                        symbol: model.requiredToolsReady ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                        color: model.requiredToolsReady ? WorkbenchTheme.accent : WorkbenchTheme.warning
                    )
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12)], spacing: 12) {
                    ForEach(model.toolchain.statuses) { status in
                        toolStatus(status)
                    }
                }
            }
        }
    }

    private func toolStatus(_ status: ToolStatus) -> some View {
        let color: Color = status.availability == .available
            ? WorkbenchTheme.accent
            : (status.kind.isRequired ? WorkbenchTheme.warning : .secondary)
        return VStack(alignment: .leading, spacing: 9) {
            HStack {
                Image(systemName: status.availability == .available ? "checkmark.circle.fill" : "circle.dashed")
                    .foregroundStyle(color)
                Text(status.kind.title)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(status.kind.isRequired ? "必需" : "可选")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(status.kind.isRequired ? WorkbenchTheme.cyan : Color.secondary)
            }
            Text(status.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let path = status.path {
                Text(path)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 11))
        .overlay {
            RoundedRectangle(cornerRadius: 11)
                .strokeBorder(color.opacity(0.14))
                .allowsHitTesting(false)
        }
    }

    private var pathsCard: some View {
        WorkbenchCard {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeading(title: "工具位置", subtitle: "仅保存路径，不保存密码、令牌或私钥")
                configRow(
                    title: "Android SDK",
                    detail: "自动选择最高版本 build-tools",
                    path: model.toolchain.androidSDK?.path,
                    symbol: "folder.fill.badge.gearshape",
                    choose: model.chooseAndroidSDK,
                    clear: { model.updateToolPath(\ToolPaths.androidSDK, to: "") }
                )
                Divider()
                configRow(
                    title: "Java",
                    detail: "Gradle、keytool 和 apksigner 的运行环境",
                    path: model.toolchain.java?.path,
                    symbol: "cup.and.saucer.fill",
                    choose: model.chooseJava,
                    clear: { model.updateToolPath(\ToolPaths.javaExecutable, to: "") }
                )
                Divider()
                configRow(
                    title: "Mocika Shield CLI",
                    detail: "默认使用 App 内置 1.3.0；选择文件可覆盖为自定义版本",
                    path: model.toolchain.mocikaShield?.path,
                    symbol: "lock.shield.fill",
                    choose: model.chooseMocikaShield,
                    clear: { model.updateToolPath(\ToolPaths.mocikaShieldCLI, to: "") }
                )
                Divider()
                configRow(
                    title: "代码生成器",
                    detail: "约定：唯一参数为 Android 安全副本目录",
                    path: model.toolchain.codeGenerator?.path,
                    symbol: "wand.and.stars",
                    choose: model.chooseCodeGenerator,
                    clear: { model.updateToolPath(\ToolPaths.codeGeneratorExecutable, to: "") }
                )
                Divider()
                configRow(
                    title: "定制 NDK / LLVM",
                    detail: "要求完整 NDK 结构与当前 Mac 可执行的 clang/clang++",
                    path: model.toolchain.protectedNDK?.path,
                    symbol: "cpu.fill",
                    choose: model.chooseProtectedNDK,
                    clear: { model.updateToolPath(\ToolPaths.protectedNDK, to: "") }
                )
            }
        }
    }

    private func configRow(
        title: String,
        detail: String,
        path: String?,
        symbol: String,
        choose: @escaping () -> Void,
        clear: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(path == nil ? Color.secondary : WorkbenchTheme.accent)
                .frame(width: 36, height: 36)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                Text(path ?? detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if path != nil {
                Button("清除", action: clear)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
            Button(path == nil ? "选择" : "更改", action: choose)
                .buttonStyle(.bordered)
        }
    }

    private var executionBoundaryCard: some View {
        WorkbenchCard {
            VStack(alignment: .leading, spacing: 12) {
                Label("核心与扩展边界", systemImage: "puzzlepiece.extension.fill")
                    .font(.headline)
                    .foregroundStyle(WorkbenchTheme.violet)
                Text("源码/R8/资源处理由 Swift 核心直接执行，Mocika Shield 1.3.0 随 Apple 芯片版 App 内置。ALLVM/Hikari 仍需提供已构建 NDK；应用会实编译探针、强制 Gradle 使用所选 ndkPath，并从 ELF 产物和构建元数据复核参数。Unity Runtime 源码修改暂不自动执行。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Divider()
                boundaryRow("内置引擎固定版本与校验值", "checkmark.seal")
                boundaryRow("不覆盖系统 NDK", "externaldrive.badge.checkmark")
                boundaryRow("不向外部保护工具提供签名密码", "key.slash")
                boundaryRow("不静默下载任何二进制", "icloud.slash")
            }
        }
    }

    private var distributionCard: some View {
        WorkbenchCard {
            VStack(alignment: .leading, spacing: 10) {
                Label("macOS 分发提示", systemImage: "macbook")
                    .font(.subheadline.weight(.semibold))
                Text("调用用户安装的 JDK、SDK、Gradle 和自定义编译器与 Mac App Store 沙盒存在天然冲突。正式分发更适合 Developer ID 签名和公证，并让用户明确授权每个工具路径。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func boundaryRow(_ text: String, _ symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}
