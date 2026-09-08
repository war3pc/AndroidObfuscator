import SwiftUI

struct AboutView: View {
    private let references: [(String, String, String, String)] = [
        ("ClassResGuard", "类名、资源名与垃圾资源 Gradle 任务", "MIT", "https://github.com/coolxinxin/ClassResGuard"),
        ("AIGenerateCode", "代码/资源生成与 ProGuard 思路", "Apache-2.0", "https://github.com/520CCC/AIGenerateCode"),
        ("Il2cppEncrtypt", "Unity IL2CPP 元数据保护流程参考", "未声明", "https://github.com/badApple001/Il2cppEncrtypt"),
        ("ALLVM", "LLVM 21 Android NDK 混淆工具链", "GPLv3 + LLVM", "https://github.com/abcdefgjh-li/ALLVM"),
        ("Hikari-OLLVM", "LLVM 19 / NDK r28 混淆工具链", "Apache-2.0 LLVM", "https://github.com/HaoZi11100/Hikari-OLLVM"),
        ("android_deobfuscator", "mapping.txt 堆栈还原体验参考", "许可待确认", "https://github.com/yhuang-aeomo/android_deobfuscator"),
        ("CollectProduct", "APK/AAB/mapping 等构建产物归档", "MIT", "https://github.com/angcyo/CollectProduct"),
        ("mocika-shield", "内置 DEX 壳保护、证书绑定与 CLI", "MIT", "https://github.com/mocikadev/mocika-shield")
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(
                    title: "参考与边界",
                    subtitle: "借鉴公开项目的流程设计，同时尊重许可证与现实兼容性",
                    symbol: "info.circle.fill"
                )

                HStack(alignment: .top, spacing: 18) {
                    VStack(spacing: 18) {
                        WorkbenchCard {
                            VStack(alignment: .leading, spacing: 14) {
                                SectionHeading(title: "能力来源", subtitle: "本应用没有复制未明确授权的实现代码")
                                ForEach(Array(references.enumerated()), id: \.offset) { index, item in
                                    referenceRow(name: item.0, detail: item.1, license: item.2, url: item.3)
                                    if index < references.count - 1 { Divider() }
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)

                    VStack(spacing: 18) {
                        boundaryCard
                        realityCard
                        releaseChecklist
                    }
                    .frame(width: 390)
                }
            }
            .padding(28)
            .frame(maxWidth: 1280)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .accessibilityIdentifier("page.about")
    }

    private func referenceRow(name: String, detail: String, license: String, url: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                .foregroundStyle(WorkbenchTheme.accent)
                .frame(width: 34, height: 34)
                .background(WorkbenchTheme.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 2) {
                Link(name, destination: URL(string: url)!)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(license)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(license.contains("未") || license.contains("待") ? WorkbenchTheme.warning : WorkbenchTheme.violet)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(Color.primary.opacity(0.05), in: Capsule())
        }
    }

    private var boundaryCard: some View {
        WorkbenchCard {
            VStack(alignment: .leading, spacing: 11) {
                Label("合法使用边界", systemImage: "checkmark.shield.fill")
                    .font(.headline)
                    .foregroundStyle(WorkbenchTheme.accent)
                Text("仅用于你拥有或获授权保护的 Android 应用。应用不提供第三方 APK 解包修改、签名绕过、平台审核规避或隐蔽恶意行为能力。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var realityCard: some View {
        WorkbenchCard {
            VStack(alignment: .leading, spacing: 10) {
                Label("保护不是绝对安全", systemImage: "shield.slash.fill")
                    .font(.headline)
                    .foregroundStyle(WorkbenchTheme.warning)
                Text("混淆和壳保护提高分析成本，但不能修复明文密钥、越权接口、弱鉴权或不安全更新机制。越激进的控制流和反调试也越容易带来性能、兼容与审核问题。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Divider()
                Text("Il2cppEncrtypt 未提供明确许可证，且 MetadataLoader 修改与 Unity 版本强绑定，因此本应用只检测 IL2CPP 工程，不复制或静默改写该实现。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var releaseChecklist: some View {
        WorkbenchCard {
            VStack(alignment: .leading, spacing: 9) {
                SectionHeading(title: "发布前最低检查")
                checklist("保存 mapping 与符号文件")
                checklist("确认签名证书 SHA-256")
                checklist("覆盖 Android 版本与全部 ABI")
                checklist("验证冷启动、升级与后台恢复")
                checklist("检查包体、启动耗时与崩溃率")
                checklist("按商店政策审查生成内容")
            }
        }
    }

    private func checklist(_ text: String) -> some View {
        Label(text, systemImage: "checkmark.circle")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}
