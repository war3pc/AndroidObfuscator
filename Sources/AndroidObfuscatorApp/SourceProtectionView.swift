import SwiftUI
import AndroidObfuscatorCore

struct SourceProtectionView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(
                    title: "源码保护",
                    subtitle: "在隔离副本中编排 Gradle、R8、资源改名与 Native 工具链",
                    symbol: "curlybraces.square.fill"
                ) {
                    Button {
                        model.startSourceJob()
                    } label: {
                        Label("运行保护流水线", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(WorkbenchTheme.accent)
                    .disabled(model.isRunning || !previewIsValid)
                }

                HStack(alignment: .top, spacing: 18) {
                    VStack(spacing: 18) {
                        inputCard
                        profileCard
                        processingCard
                        buildCard
                    }
                    .frame(maxWidth: .infinity)

                    VStack(spacing: 18) {
                        analysisCard
                        planCard
                        safetyCard
                    }
                    .frame(width: 390)
                }
            }
            .padding(28)
            .frame(maxWidth: 1280)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .accessibilityIdentifier("page.source")
    }

    private var inputCard: some View {
        WorkbenchCard {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeading(title: "输入与输出", subtitle: "工程必须包含 Gradle Wrapper")
                PathSelectionRow(
                    title: "Android 工程",
                    subtitle: "选择包含 gradlew 的目录",
                    url: model.sourceOptions.projectURL,
                    buttonTitle: "选择",
                    symbol: "folder.badge.gearshape",
                    action: model.chooseSourceProject
                )
                Divider()
                PathSelectionRow(
                    title: "输出目录",
                    subtitle: "任务工作区与归档产物的父目录",
                    url: model.sourceOptions.outputDirectory,
                    buttonTitle: "更改",
                    symbol: "externaldrive.badge.plus",
                    action: model.chooseSourceOutput
                )
            }
        }
    }

    private var profileCard: some View {
        WorkbenchCard {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeading(title: "保护档位", subtitle: "档位只调整本页开关，不会下载或改写工具")
                ProfilePicker(selected: model.sourceOptions.profile, onSelect: model.applySourceProfile)
            }
        }
    }

    private var processingCard: some View {
        WorkbenchCard {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeading(title: "代码与资源处理", subtitle: "内置引擎直接执行；第三方插件作为可选增强")

                OptionRow(
                    title: "安全工作副本",
                    detail: "自动忽略 .git、.gradle、IDE 缓存与已有 build 目录；此项不可关闭",
                    symbol: "doc.on.doc.fill",
                    isOn: $model.sourceOptions.createSafeCopy,
                    badge: "必选",
                    enabled: false
                )
                Divider()
                OptionRow(
                    title: "写入内置 R8 加固规则",
                    detail: "保留内置锚点并允许 R8 混淆，同时重命名源码调试属性；规则带标记且可审计",
                    symbol: "checklist.checked",
                    isOn: $model.sourceOptions.installR8HardeningRules,
                    badge: "内置"
                )
                Divider()
                OptionRow(
                    title: "生成可编译变体代码与资源",
                    detail: "生成 Java 类、字符串、颜色与 Drawable，并建立真实 R 引用防止资源压缩移除",
                    symbol: "curlybraces.square.fill",
                    isOn: $model.sourceOptions.generateJunkCode,
                    badge: "内置"
                )
                Divider()
                OptionRow(
                    title: "资源文件改名与引用同步",
                    detail: "改名 layout/drawable 等文件并同步 XML、R 引用与 ViewBinding 类名；动态查找和 public.xml 项自动跳过",
                    symbol: "arrow.triangle.2.circlepath",
                    isOn: $model.sourceOptions.renameFileResources,
                    badge: "需回归"
                )
                Divider()
                OptionRow(
                    title: "ClassResGuard 类名处理",
                    detail: "执行 renameClass；要求工程已集成 class-res-guard 插件",
                    symbol: "character.cursor.ibeam",
                    isOn: $model.sourceOptions.runClassRename,
                    badge: "Gradle",
                    enabled: model.sourceAnalysis?.hasClassResGuard == true
                )
                Divider()
                OptionRow(
                    title: "资源与引用同步改名",
                    detail: "执行 renameRes，并由插件同步更新 Binding 和引用",
                    symbol: "photo.stack",
                    isOn: $model.sourceOptions.runResourceRename,
                    badge: "Gradle",
                    enabled: model.sourceAnalysis?.hasClassResGuard == true
                )
                Divider()
                OptionRow(
                    title: "运行外部代码生成器",
                    detail: "把安全副本路径作为唯一参数；外部进程仍继承当前用户权限，只运行你信任的工具",
                    symbol: "wand.and.stars",
                    isOn: $model.sourceOptions.runExternalGenerator,
                    badge: "外部",
                    enabled: model.toolchain.codeGenerator != nil
                )
            }
        }
    }

    private var buildCard: some View {
        WorkbenchCard {
            VStack(alignment: .leading, spacing: 15) {
                SectionHeading(title: "构建配置", subtitle: "应用不会用正则改写 build.gradle")
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("应用模块")
                            .font(.caption.weight(.medium))
                        if let modules = model.sourceAnalysis?.modules, !modules.isEmpty {
                            Picker("应用模块", selection: $model.sourceOptions.moduleName) {
                                ForEach(modules, id: \.self) { Text($0).tag($0) }
                            }
                            .labelsHidden()
                        } else {
                            TextField("app", text: $model.sourceOptions.moduleName)
                        }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("构建 Variant")
                            .font(.caption.weight(.medium))
                        TextField("Release", text: $model.sourceOptions.variantName)
                    }
                }
                Divider()
                OptionRow(
                    title: "执行 R8 / ProGuard 构建",
                    detail: "运行 assemble<Variant>；是否真正混淆由工程的 minifyEnabled 与规则决定",
                    symbol: "hammer.fill",
                    isOn: $model.sourceOptions.enableR8Build
                )
                Divider()
                OptionRow(
                    title: "要求资源压缩配置",
                    detail: "静态预检 shrinkResources = true；未检测到时停止计划，不会静默修改 Gradle 配置",
                    symbol: "arrow.down.right.and.arrow.up.left",
                    isOn: $model.sourceOptions.enableResourceShrinking
                )
                Divider()
                OptionRow(
                    title: "构建前 clean",
                    detail: "更可靠但会明显增加构建耗时",
                    symbol: "eraser.fill",
                    isOn: $model.sourceOptions.runClean
                )
                Divider()
                OptionRow(
                    title: "归档发布产物",
                    detail: "收集 APK、AAB、mapping、usage、seeds、R.txt 与 configuration",
                    symbol: "archivebox.fill",
                    isOn: $model.sourceOptions.collectArtifacts
                )

                Divider()
                VStack(alignment: .leading, spacing: 7) {
                    Text("Native 编译工具链")
                        .font(.caption.weight(.medium))
                    Picker("Native 编译工具链", selection: $model.sourceOptions.nativeToolchain) {
                        ForEach(NativeToolchainKind.allCases) { kind in
                            Text(kind.title).tag(kind)
                        }
                    }
                    .labelsHidden()
                    Text(nativeToolchainHint)
                        .font(.caption)
                        .foregroundStyle(model.sourceOptions.nativeToolchain == .none || model.toolchain.protectedNDK != nil ? Color.secondary : WorkbenchTheme.warning)
                        .fixedSize(horizontal: false, vertical: true)

                    if model.sourceOptions.nativeToolchain == .custom {
                        TextField(
                            "例如 -mllvm -fla -mllvm -sub",
                            text: $model.sourceOptions.customNativeFlags
                        )
                        .textFieldStyle(.roundedBorder)
                        Text("参数逐项传给 clang，不经过 shell；目标、输入和输出参数由应用固定。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else if !nativeProtectionFlags.isEmpty {
                        Text(nativeProtectionFlags.joined(separator: " "))
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }

                Divider()
                VStack(alignment: .leading, spacing: 7) {
                    Text("额外 Gradle 任务")
                        .font(.caption.weight(.medium))
                    TextField("例如 :app:testReleaseUnitTest", text: $model.sourceOptions.customGradleTasks)
                    Text("用空格、逗号或换行分隔。任务会作为独立参数传给 Gradle，不经过命令字符串解析。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var analysisCard: some View {
        WorkbenchCard {
            VStack(alignment: .leading, spacing: 13) {
                HStack {
                    SectionHeading(title: "工程预检", subtitle: "选择工程后自动扫描关键配置")
                    Spacer()
                    if model.sourceAnalysis != nil {
                        Button {
                            if let url = model.sourceOptions.projectURL {
                                model.sourceAnalysis = ProjectAnalyzer.analyze(projectURL: url)
                            }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.borderless)
                    }
                }

                if let analysis = model.sourceAnalysis {
                    analysisRow("Gradle Wrapper", ready: analysis.hasGradleWrapper)
                    analysisRow("R8 / minifyEnabled", ready: analysis.hasR8Configuration)
                    analysisRow("shrinkResources", ready: analysis.hasResourceShrinking)
                    analysisRow("ClassResGuard", ready: analysis.hasClassResGuard, optional: true)
                    analysisRow("Native C/C++", ready: analysis.hasNativeCode, optional: true)
                    analysisRow("Unity IL2CPP", ready: analysis.hasUnityIL2CPP, optional: true)

                    if !analysis.warnings.isEmpty {
                        Divider()
                        ForEach(analysis.warnings, id: \.self) { warning in
                            Label(warning, systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                } else {
                    ContentUnavailableView(
                        "尚未选择工程",
                        systemImage: "folder.badge.questionmark",
                        description: Text("选择后会检查 Gradle、R8、资源与 Native 配置。")
                    )
                    .frame(minHeight: 180)
                }
            }
        }
    }

    private var planCard: some View {
        WorkbenchCard {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeading(title: "执行预览", subtitle: "实际参数会逐项传递，不执行拼接后的 shell 命令")
                PlanPreview(result: model.sourcePreview())
            }
        }
    }

    private var safetyCard: some View {
        WorkbenchCard {
            VStack(alignment: .leading, spacing: 10) {
                Label("运行 Gradle 即执行项目代码", systemImage: "exclamationmark.shield.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(WorkbenchTheme.warning)
                Text("只对你信任的工程运行流水线。建议先提交当前改动，并在发布前覆盖启动、登录、支付、推送、动态加载、各 ABI 与旧版本升级场景。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func analysisRow(_ title: String, ready: Bool, optional: Bool = false) -> some View {
        HStack {
            Image(systemName: ready ? "checkmark.circle.fill" : (optional ? "minus.circle" : "xmark.circle.fill"))
                .foregroundStyle(ready ? WorkbenchTheme.accent : (optional ? Color.secondary : WorkbenchTheme.warning))
            Text(title)
                .font(.subheadline)
            Spacer()
            Text(ready ? "已检测" : (optional ? "未使用" : "需配置"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var previewIsValid: Bool {
        if case .success = model.sourcePreview() { return true }
        return false
    }

    private var nativeToolchainHint: String {
        if model.sourceOptions.nativeToolchain == .none {
            return "使用 Android 工程原本配置的 NDK。"
        }
        if let path = model.toolchain.protectedNDK?.path {
            return "先实编译探针，再通过单次任务脚本强制 Gradle 使用该 NDK，并复核 .so/构建元数据：\(path)"
        }
        return "请先在“工具链”中选择包含可执行 clang 与 CMake 工具链的完整定制 NDK。"
    }

    private var nativeProtectionFlags: [String] {
        (try? NativeToolchainInspector.protectionFlags(
            kind: model.sourceOptions.nativeToolchain,
            customFlags: model.sourceOptions.customNativeFlags
        )) ?? []
    }
}
