import SwiftUI
import AndroidObfuscatorCore

struct APKProtectionView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(
                    title: "APK 加固",
                    subtitle: "校验 → 可选 DEX 壳保护 → ZIP 对齐 → 签名 → 复核",
                    symbol: "shippingbox.fill"
                ) {
                    Button {
                        model.startAPKJob()
                    } label: {
                        Label("开始加固", systemImage: "play.fill")
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
                        protectionCard
                        signingCard
                    }
                    .frame(maxWidth: .infinity)

                    VStack(spacing: 18) {
                        readinessCard
                        planCard
                        compatibilityCard
                    }
                    .frame(width: 390)
                }
            }
            .padding(28)
            .frame(maxWidth: 1280)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .accessibilityIdentifier("page.apk")
    }

    private var inputCard: some View {
        WorkbenchCard {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeading(title: "输入与输出", subtitle: "只支持单个 APK；AAB 需要走 Gradle / Play Signing 流程")
                PathSelectionRow(
                    title: "输入 APK",
                    subtitle: "选择已构建的 .apk 文件",
                    url: model.apkOptions.inputAPK,
                    buttonTitle: "选择",
                    symbol: "doc.zipper",
                    action: model.chooseAPK
                )
                Divider()
                PathSelectionRow(
                    title: "输出目录",
                    subtitle: "最终 APK 与中间产物的父目录",
                    url: model.apkOptions.outputDirectory,
                    buttonTitle: "更改",
                    symbol: "externaldrive.badge.plus",
                    action: model.chooseAPKOutput
                )
                Divider()
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("最终文件名")
                            .font(.subheadline.weight(.medium))
                        Text("系统会移除路径分隔符，并自动补充 .apk")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    TextField("protected.apk", text: $model.apkOptions.outputName)
                        .frame(width: 230)
                }
            }
        }
    }

    private var profileCard: some View {
        WorkbenchCard {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeading(title: "加固档位", subtitle: "高强度档位仅在已配置 Shield CLI 时启用 DEX 保护")
                ProfilePicker(selected: model.apkOptions.profile, onSelect: model.applyAPKProfile)
            }
        }
    }

    private var protectionCard: some View {
        WorkbenchCard {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeading(title: "保护步骤", subtitle: "所有中间文件位于独立任务目录")
                OptionRow(
                    title: "加固前签名校验",
                    detail: model.apkOptions.useMocikaShield ? "Shield 证书绑定必须锁定输入 APK 的全部证书 SHA-256 摘要" : "使用 apksigner 验证输入 APK 并输出证书摘要",
                    symbol: "checkmark.seal",
                    isOn: $model.apkOptions.verifyBefore,
                    badge: model.apkOptions.useMocikaShield ? "必选" : nil,
                    enabled: !model.apkOptions.useMocikaShield
                )
                Divider()
                OptionRow(
                    title: "Mocika Shield DEX 保护",
                    detail: "内置 v1.3.0：Zstd 压缩、ChaCha20-Poly1305 加密并注入四 ABI 运行时壳；要求输入 APK 已签名",
                    symbol: "lock.shield.fill",
                    isOn: $model.apkOptions.useMocikaShield,
                    badge: "内置",
                    enabled: model.toolchain.mocikaShield != nil
                )
                .onChange(of: model.apkOptions.useMocikaShield) { _, enabled in
                    if enabled {
                        model.apkOptions.verifyBefore = true
                        model.apkOptions.signOutput = true
                        model.apkOptions.verifyAfter = true
                    }
                }
                Divider()
                OptionRow(
                    title: "严格运行环境保护",
                    detail: "除反调试外，还会在高置信 Root 或注入环境中拒绝启动；仅建议部署到受控设备",
                    symbol: "exclamationmark.lock.fill",
                    isOn: $model.apkOptions.strictEnvironmentProtection,
                    badge: "严格",
                    enabled: model.apkOptions.useMocikaShield && model.toolchain.mocikaShield != nil
                )
                Divider()
                OptionRow(
                    title: "ZIP 对齐",
                    detail: model.apkOptions.useMocikaShield ? "Shield 已完成 4 KB / 16 KB 对齐，本步骤自动跳过重复处理" : "签名前执行；Build Tools 35+ 使用 16 KB page alignment",
                    symbol: "square.grid.3x3.topleft.filled",
                    isOn: $model.apkOptions.zipalign,
                    enabled: !model.apkOptions.useMocikaShield
                )
                Divider()
                OptionRow(
                    title: "最终签名校验",
                    detail: model.apkOptions.useMocikaShield ? "强制比较输入与最终 APK 的全部证书 SHA-256 摘要，完全一致后才发布" : "校验证书、签名方案和 ZIP 对齐，确保签名后未改包",
                    symbol: "checkmark.shield.fill",
                    isOn: $model.apkOptions.verifyAfter,
                    badge: model.apkOptions.useMocikaShield ? "必选" : nil,
                    enabled: model.apkOptions.signOutput && !model.apkOptions.useMocikaShield
                )
            }
        }
    }

    private var signingCard: some View {
        WorkbenchCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    SectionHeading(title: "Android 签名", subtitle: "密码只在内存中保存，并通过标准输入传递")
                    Spacer()
                    Toggle("签名", isOn: $model.apkOptions.signOutput)
                        .toggleStyle(.switch)
                        .disabled(model.apkOptions.useMocikaShield)
                        .onChange(of: model.apkOptions.signOutput) { _, enabled in
                            if !enabled { model.apkOptions.verifyAfter = false }
                        }
                }

                Group {
                    PathSelectionRow(
                        title: "Keystore",
                        subtitle: "选择 .jks 或 .keystore",
                        url: model.apkOptions.keystoreURL,
                        buttonTitle: "选择",
                        symbol: "key.horizontal.fill",
                        action: model.chooseKeystore
                    )
                    Divider()
                    HStack(spacing: 14) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Alias")
                                .font(.caption.weight(.medium))
                            TextField("release", text: $model.apkOptions.keyAlias)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Keystore 密码")
                                .font(.caption.weight(.medium))
                            SecureField("必填", text: $model.apkOptions.keystorePassword)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Key 密码")
                                .font(.caption.weight(.medium))
                            SecureField("留空则使用同一密码", text: $model.apkOptions.keyPassword)
                        }
                    }
                }
                .disabled(!model.apkOptions.signOutput)
                .opacity(model.apkOptions.signOutput ? 1 : 0.5)
            }
        }
    }

    private var readinessCard: some View {
        WorkbenchCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeading(title: "环境就绪度", subtitle: "来自同一 Android SDK Build Tools 版本")
                readiness("apksigner", available: model.toolchain.apksigner != nil, path: model.toolchain.apksigner?.path)
                readiness("zipalign", available: model.toolchain.zipalign != nil, path: model.toolchain.zipalign?.path)
                readiness("Mocika Shield", available: model.toolchain.mocikaShield != nil, path: model.toolchain.mocikaShield?.path, optional: true)
                if !model.requiredToolsReady {
                    Button("打开工具链设置") { model.selection = .toolchain }
                        .buttonStyle(.link)
                }
            }
        }
    }

    private var planCard: some View {
        WorkbenchCard {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeading(title: "执行预览", subtitle: "密码和标准输入不会出现在预览中")
                PlanPreview(result: model.apkPreview())
            }
        }
    }

    private var compatibilityCard: some View {
        WorkbenchCard {
            VStack(alignment: .leading, spacing: 10) {
                Label("Shield 证书绑定", systemImage: "person.badge.key.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(model.apkOptions.useMocikaShield ? WorkbenchTheme.warning : Color.secondary)
                Text("Mocika Shield 会把输入 APK 的签名证书指纹参与密钥派生。最终 APK 必须用相同证书重签，否则运行时无法解密。它不适用于 AAB、APKS 或已经二次加固的包。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func readiness(_ title: String, available: Bool, path: String?, optional: Bool = false) -> some View {
        HStack(spacing: 9) {
            Image(systemName: available ? "checkmark.circle.fill" : (optional ? "minus.circle" : "xmark.circle.fill"))
                .foregroundStyle(available ? WorkbenchTheme.accent : (optional ? Color.secondary : WorkbenchTheme.warning))
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.subheadline)
                if let path {
                    Text(path)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer()
        }
    }

    private var previewIsValid: Bool {
        if case .success = model.apkPreview() { return true }
        return false
    }
}
