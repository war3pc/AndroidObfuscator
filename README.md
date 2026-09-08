# 守界 Android

使用 SwiftUI 编写的 macOS 本地 Android 保护工作台。源码、APK、证书与密码均留在本机；会修改内容的源码任务始终在隔离副本中执行。

## 真正内置的能力

### 源码与资源

- 生成可编译的 Java 变体类、字符串、颜色和 Drawable，并建立真实 `R` 引用。
- 写入带边界标记、可重复执行的 R8 加固规则。
- 对 `layout`、`drawable`、`mipmap` 等文件资源改名，并同步 XML、`R.type.name` 与 ViewBinding 类名引用。
- 自动跳过 `Resources.getIdentifier` 动态名称和 `public.xml` 公共资源；资源移动或引用同步失败时回滚该改名阶段。整个流程始终只修改隔离副本，后续构建失败时会保留任务目录供诊断。
- 输出源码处理报告与资源映射 JSON，随后可运行项目自己的 R8/ClassResGuard/Gradle 构建并归档 APK、AAB、mapping 等产物。

### APK 加固

- App 在 Apple 芯片 Mac 上内置固定版本的 Mocika Shield 1.3.0 CLI、四 ABI Android runtime、Apktool 与 Apksigner 依赖；Intel Mac 仍可使用其他功能，并可在工具链页选择自行构建的兼容 CLI。
- 对 DEX 执行 Zstd 压缩、ChaCha20-Poly1305 加密、签名证书绑定、壳注入与 4 KB/16 KB 对齐。
- 从本机 Android SDK 隔离复制 Apktool framework 到单次任务目录，不依赖或污染用户全局缓存。
- 支持加固前验签、同证书重签、加固后 v1/v2/v3 签名复核和最终对齐检查；Shield 模式会精确比较输入与输出的全部证书 SHA-256 集合，不一致时不会发布最终 APK。
- 密码只在当前进程内存中存在，通过标准输入传给 `apksigner`，不会进入命令预览、设置或历史记录。

### Native 工具链

- 检查定制 NDK 的 `source.properties`、CMake toolchain 与当前 Mac 可执行的 `clang/clang++`。
- ALLVM 使用 `-irobf`/`-irobf-fla`，Hikari 使用 `-enable-cffobf`/`-enable-subobf`；自定义工具链可填写逐项参数。
- 在 Gradle 前使用 aarch64 Android 目标实际编译探针。定制 Pass 不存在或参数无效时任务立即失败，不会假装已启用。
- 通过单次任务专属 Gradle init script 为每个 Android 模块直接设置并复核 `android.ndkPath`，同时注入同一组已验证参数；不改原工程、`local.properties` 或系统 NDK。
- 构建后必须发现真实 ELF `.so`，并在 CMake/ndk-build 元数据中同时确认所选 NDK 路径和全部保护参数；缺少任一证据就停止任务。

### 诊断与审计

- Android 工程预检、命令预览、实时日志、取消、任务历史和产物归档。
- 可选的资源压缩门禁会静态检查 `shrinkResources = true`；未检测到时拒绝启动，用户可修复发布配置或明确关闭该门禁。
- 使用 `mapping.txt` 还原混淆堆栈。
- 对动态资源引用、Unity IL2CPP、Native ABI 和高风险保护项给出明确提示。
- 可选外部代码生成器以安全工作副本为当前目录运行，但不是系统级沙箱；它仍继承当前用户的文件权限，只应选择已审查且可信的程序。

## 尚未伪装成“已实现”的部分

- ClassResGuard 任务只有在目标工程已经集成插件时才会启用。
- ALLVM/Hikari 是完整 LLVM/NDK 工具链，体积巨大；应用不随包复制它们，用户需选择自己构建并审查过的完整 NDK。应用负责结构检查、Pass 实编译验证和构建注入。
- `Il2cppEncrtypt` 未声明明确许可证，而且 `MetadataLoader.cpp` 修改与 Unity 版本强绑定。本应用会检测 IL2CPP 工程，但不会复制该实现或对 Unity Runtime 做未经验证的自动补丁。
- 不提供平台审核规避、签名绕过、第三方 APK 偷改或隐蔽恶意行为功能。

## 构建与测试

需要 Xcode 与 XcodeGen：

```bash
xcodegen generate
open AndroidObfuscator.xcodeproj
```

Swift 回归测试：

```bash
xcodebuild -project AndroidObfuscator.xcodeproj \
  -scheme AndroidObfuscator \
  -destination 'platform=macOS' test
```

真实 APK 加固回归会现场生成 DEX、打包并签名一个最小 APK，再执行 Shield、同证书重签、签名/对齐/壳结构检查：

```bash
Scripts/run_mocika_e2e.sh
```

该脚本会自动选择本机最高版本的 Android SDK Build Tools 与 Platform，并优先使用 `JAVA_HOME` 或 Android Studio JDK。可通过 `ANDROID_SDK_ROOT`、`ANDROID_HOME`、`JAVA_HOME`、`ANDROID_BUILD_TOOLS_VERSION` 和 `ANDROID_PLATFORM_VERSION` 覆盖；失败时会自动删除包含临时测试密钥的目录。

## 安全边界

仅用于你拥有或获授权保护的 Android 应用。混淆与壳保护只能提高分析成本，不能替代服务端鉴权、密钥管理、更新签名、漏洞修复和完整发布回归。发布前至少覆盖全部 ABI、目标 Android 版本、冷启动、升级、后台恢复、性能、崩溃符号化与 Play App Signing 流程。

## 参考项目

- [ClassResGuard](https://github.com/coolxinxin/ClassResGuard) — 类名与资源处理 Gradle 任务
- [AIGenerateCode](https://github.com/520CCC/AIGenerateCode) — 代码、资源与规则生成思路；本项目不实现审核规避用途
- [Il2cppEncrtypt](https://github.com/badApple001/Il2cppEncrtypt) — Unity IL2CPP 元数据保护流程参考，不复制未明确授权代码
- [ALLVM](https://github.com/abcdefgjh-li/ALLVM) / [Hikari-OLLVM](https://github.com/HaoZi11100/Hikari-OLLVM) — Android NDK 定制 LLVM 工具链
- [android_deobfuscator](https://github.com/yhuang-aeomo/android_deobfuscator) — 混淆结果审计视角
- [CollectProduct](https://github.com/angcyo/CollectProduct) — 构建产物归档思路
- [mocika-shield](https://github.com/mocikadev/mocika-shield) — 内置 DEX 加密与壳保护核心

第三方版本、校验值与许可证见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
