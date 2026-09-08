# 第三方组件说明

## Mocika Shield 1.3.0

- 上游项目：<https://github.com/mocikadev/mocika-shield>
- 标签：`v1.3.0`
- 固定提交：`7d5f8f9cbe91fbc8979e7a0bcdb041b0d6029555`
- 许可证：MIT
- 内置 CLI SHA-256：`0ab2f218c8b575b492e675a6fd5335ed2b547e64ba121a545939d23e09df163d`
- 内置 runtime resources SHA-256：`26bd309a6376f4c07745475feb649409729e24b24dc2938124df690c2e5bacc1`

`shield` CLI 由上述固定源码在本机以锁定依赖构建。`resources.zip`、`apktool.jar` 与 `apksigner.jar` 来自官方 v1.3.0 macOS universal 发布包；下载的 DMG 已通过 `hdiutil verify`。

随 App 分发：

- `Resources/MocikaShield/licenses/LICENSE-MIT`
- `Resources/MocikaShield/licenses/APACHE-2.0.txt`
- `Resources/MocikaShield/licenses/APKTOOL-NOTICE.txt`
- `Resources/MocikaShield/ENGINE-METADATA.json`

Apktool 及其归档内依赖采用 Apache License 2.0 等相应开源许可；原始 LICENSE/NOTICE 已保留。内置 Apksigner 依赖随 Mocika 官方发布包取得；应用实际签名流程优先调用用户 Android SDK Build Tools 中的 `apksigner`。

## Android SDK / JDK

应用调用用户已安装 Android SDK 中的 Platform `android.jar`、`apksigner`、`zipalign` 与可选 `adb`，并调用用户 JDK。除单次任务中隔离复制 `android.jar` 作为 Apktool framework 外，这些工具不会复制进项目或覆盖全局安装；许可与版本由用户安装的 SDK/JDK 决定。

## ClassResGuard、ALLVM 与 Hikari-OLLVM

这些项目不随 App 打包。ClassResGuard 仅在目标工程已集成插件时调用相应 Gradle 任务。ALLVM/Hikari 由用户提供已构建 NDK；应用只检查工具链结构、实际探测上游公开的 Pass 参数并注入本次隔离构建。用户需自行确认所选版本的许可证和分发义务。

## Il2cppEncrtypt

上游仓库当前没有明确许可证文件，因此本项目仅将其作为流程参考，不复制源码、UnityPackage 或二进制，也不声称已内置其 Unity Runtime 修改。
