import Foundation

public enum PipelinePlanner {
    public static func sourcePlan(
        options: SourceProtectionOptions,
        toolchain: LocatedToolchain,
        now: Date = Date(),
        id: UUID = UUID()
    ) throws -> PipelinePlan {
        guard let project = options.projectURL else {
            throw PipelineError.invalidConfiguration("请选择 Android 工程目录。")
        }
        guard let outputDirectory = options.outputDirectory else {
            throw PipelineError.invalidConfiguration("请选择输出目录。")
        }
        guard FileManager.default.fileExists(atPath: project.appendingPathComponent("gradlew").path) else {
            throw PipelineError.invalidConfiguration("所选目录中没有 gradlew。")
        }
        guard toolchain.java != nil else {
            throw PipelineError.missingTool("Java Runtime")
        }
        guard options.createSafeCopy else {
            throw PipelineError.invalidConfiguration("会修改资源或源码的任务必须在安全工作副本中运行。")
        }
        guard !isDescendant(outputDirectory, of: project) else {
            throw PipelineError.invalidConfiguration("输出目录不能位于 Android 工程内部，避免递归复制。")
        }
        if options.runExternalGenerator && toolchain.codeGenerator == nil {
            throw PipelineError.missingTool("代码生成器")
        }
        if options.enableResourceShrinking || options.runClassRename || options.runResourceRename {
            let analysis = ProjectAnalyzer.analyze(projectURL: project)
            if options.enableResourceShrinking && !analysis.hasResourceShrinking {
                throw PipelineError.invalidConfiguration(
                    "已启用资源压缩预检，但工程脚本中未检测到 shrinkResources = true。请为发布构建配置资源压缩，或关闭该预检后继续。"
                )
            }
            if (options.runClassRename || options.runResourceRename) && !analysis.hasClassResGuard {
                throw PipelineError.invalidConfiguration(
                    "工程中未检测到 ClassResGuard 插件，不能执行 renameClass / renameRes。"
                )
            }
        }
        let nativeInspection: NativeToolchainInspection?
        let nativeFlags: [String]
        if options.nativeToolchain != .none {
            guard let ndk = toolchain.protectedNDK else {
                throw PipelineError.missingTool("定制 NDK / LLVM")
            }
            nativeInspection = try NativeToolchainInspector.inspect(ndk: ndk)
            nativeFlags = try NativeToolchainInspector.protectionFlags(
                kind: options.nativeToolchain,
                customFlags: options.customNativeFlags
            )
        } else {
            nativeInspection = nil
            nativeFlags = []
        }

        let runRoot = outputDirectory
            .appendingPathComponent("AndroidObfuscator", isDirectory: true)
            .appendingPathComponent(runFolderName(now: now, id: id), isDirectory: true)
        let workspace = runRoot.appendingPathComponent("workspace", isDirectory: true)
        let artifacts = runRoot.appendingPathComponent("artifacts", isDirectory: true)
        let nativeGradleInitScript = nativeInspection.map { _ in
            runRoot.appendingPathComponent(NativeGradleWiring.scriptFileName)
        }
        var steps: [PipelineStep] = [
            PipelineStep(title: "创建隔离工作区", detail: "原始 Android 工程保持不变", operation: .createDirectory(runRoot)),
            PipelineStep(title: "复制安全工作副本", detail: "忽略 Git、Gradle、IDE 缓存和旧构建目录", operation: .copyProject(source: project, destination: workspace))
        ]

        if let nativeInspection {
            let probeDirectory = runRoot.appendingPathComponent("native-toolchain-probe", isDirectory: true)
            let probeObject = probeDirectory.appendingPathComponent("probe.o")
            steps.append(PipelineStep(
                title: "准备 Native 工具链探针",
                detail: "探针只写入单次任务目录",
                operation: .createDirectory(probeDirectory)
            ))
            steps.append(PipelineStep(
                title: "验证 Native 混淆 Pass",
                detail: "用 aarch64 Android 目标实际编译；参数未被定制 clang 接受时立即停止",
                operation: .command(CommandSpec(
                    executable: nativeInspection.clang,
                    arguments: [
                        "--target=aarch64-linux-android21",
                        "-O1", "-fPIC"
                    ] + nativeFlags + [
                        "-x", "c", "-c", "-", "-o", probeObject.path
                    ],
                    workingDirectory: probeDirectory,
                    standardInput: NativeToolchainInspector.probeSource
                ))
            ))
            if let nativeGradleInitScript {
                steps.append(PipelineStep(
                    title: "接线定制 NDK 到 Gradle",
                    detail: "生成单次任务专属 init script；直接设置并复核各 Android 模块的 android.ndkPath",
                    operation: .writeFile(
                        destination: nativeGradleInitScript,
                        contents: NativeGradleWiring.initScript
                    )
                ))
            }
        }

        if options.generateJunkCode || options.installR8HardeningRules || options.renameFileResources {
            let configuration = BuiltInSourceProtectionConfiguration(
                moduleName: options.moduleName,
                generateCodeAndResources: options.generateJunkCode,
                installR8Rules: options.installR8HardeningRules,
                renameFileResources: options.renameFileResources,
                seed: stableSeed(id)
            )
            steps.append(PipelineStep(
                title: "执行内置源码保护",
                detail: "生成可编译代码/资源、R8 规则与可回滚资源映射",
                operation: .protectSource(project: workspace, configuration: configuration)
            ))
        }

        if options.runExternalGenerator, let generator = toolchain.codeGenerator {
            steps.append(PipelineStep(
                title: "生成辅助代码与资源",
                detail: "以工作副本为当前目录运行；外部进程仍继承当前用户权限，请只选择可信工具",
                operation: .command(CommandSpec(
                    executable: generator,
                    arguments: [workspace.path],
                    workingDirectory: workspace
                ))
            ))
        }

        var mutationTasks: [String] = []
        if options.runClassRename { mutationTasks.append("renameClass") }
        if options.runResourceRename { mutationTasks.append("renameRes") }
        mutationTasks.append(contentsOf: parseGradleTasks(options.customGradleTasks))
        if !mutationTasks.isEmpty {
            steps.append(PipelineStep(
                title: "执行源码与资源处理",
                detail: mutationTasks.joined(separator: " · "),
                operation: .command(gradleCommand(
                    tasks: mutationTasks,
                    workspace: workspace,
                    options: options,
                    toolchain: toolchain,
                    nativeFlags: nativeFlags,
                    nativeGradleInitScript: nativeGradleInitScript
                ))
            ))
        }

        if options.enableR8Build {
            var buildTasks: [String] = []
            let module = normalizedModule(options.moduleName)
            if options.runClean { buildTasks.append("\(module):clean") }
            buildTasks.append("\(module):assemble\(normalizedVariant(options.variantName))")
            steps.append(PipelineStep(
                title: "执行 Release 混淆构建",
                detail: "使用工程自身的 Gradle Wrapper 与 R8/ProGuard 配置",
                operation: .command(gradleCommand(
                    tasks: buildTasks,
                    workspace: workspace,
                    options: options,
                    toolchain: toolchain,
                    nativeFlags: nativeFlags,
                    nativeGradleInitScript: nativeGradleInitScript
                ))
            ))
        }

        if let nativeInspection, !mutationTasks.isEmpty || options.enableR8Build {
            steps.append(PipelineStep(
                title: "复核 Native 构建产物",
                detail: "统计本次工作副本生成的 .so，并从 CMake/ndk-build 元数据核对所选 NDK 与保护参数",
                operation: .verifyNativeArtifacts(
                    project: workspace,
                    selectedNDK: nativeInspection.root,
                    expectedFlags: nativeFlags
                )
            ))
        }

        if options.collectArtifacts {
            steps.append(PipelineStep(
                title: "归档构建产物",
                detail: "收集 APK、AAB、mapping、usage、seeds、R.txt 与 configuration",
                operation: .collectArtifacts(project: workspace, destination: artifacts)
            ))
        }

        return PipelinePlan(
            id: id,
            kind: .source,
            name: project.lastPathComponent,
            rootDirectory: runRoot,
            finalOutput: options.collectArtifacts ? artifacts : runRoot,
            steps: steps
        )
    }

    public static func apkPlan(
        options: APKProtectionOptions,
        toolchain: LocatedToolchain,
        now: Date = Date(),
        id: UUID = UUID()
    ) throws -> PipelinePlan {
        guard let input = options.inputAPK, input.pathExtension.lowercased() == "apk" else {
            throw PipelineError.invalidConfiguration("请选择有效的 APK 文件。")
        }
        guard let outputDirectory = options.outputDirectory else {
            throw PipelineError.invalidConfiguration("请选择输出目录。")
        }
        guard let apksigner = toolchain.apksigner else {
            throw PipelineError.missingTool("apksigner")
        }
        guard toolchain.java != nil else {
            throw PipelineError.missingTool("Java Runtime")
        }
        if options.zipalign && !options.useMocikaShield && toolchain.zipalign == nil {
            throw PipelineError.missingTool("zipalign")
        }
        if options.useMocikaShield && toolchain.mocikaShield == nil {
            throw PipelineError.missingTool("Mocika Shield CLI")
        }
        let androidFramework = options.useMocikaShield ? latestAndroidFramework(in: toolchain.androidSDK) : nil
        if options.useMocikaShield && androidFramework == nil {
            throw PipelineError.missingTool("Android SDK Platform android.jar")
        }
        if options.useMocikaShield {
            guard options.verifyBefore else {
                throw PipelineError.invalidConfiguration("Mocika Shield 必须启用加固前签名校验，以锁定输入 APK 的证书。")
            }
            guard options.signOutput else {
                throw PipelineError.invalidConfiguration("Mocika Shield 必须重新签名，并使用与输入 APK 相同的签名证书。")
            }
            guard options.verifyAfter else {
                throw PipelineError.invalidConfiguration("Mocika Shield 必须启用最终签名校验，以强制核对输入和输出证书。")
            }
        }
        if options.signOutput {
            guard let keystore = options.keystoreURL else {
                throw PipelineError.invalidConfiguration("签名已启用，请选择 keystore。")
            }
            guard FileManager.default.fileExists(atPath: keystore.path) else {
                throw PipelineError.invalidConfiguration("无法读取所选 keystore。")
            }
            guard !options.keyAlias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw PipelineError.invalidConfiguration("请输入签名 Alias。")
            }
            guard !options.keystorePassword.isEmpty else {
                throw PipelineError.invalidConfiguration("请输入 keystore 密码。")
            }
        }
        if options.verifyAfter && !options.signOutput {
            throw PipelineError.invalidConfiguration("签名后校验要求先启用签名。")
        }

        let runRoot = outputDirectory
            .appendingPathComponent("AndroidObfuscator", isDirectory: true)
            .appendingPathComponent(runFolderName(now: now, id: id), isDirectory: true)
        let copiedInput = runRoot.appendingPathComponent("input.apk")
        let shielded = runRoot.appendingPathComponent("protected-unsigned.apk")
        let aligned = runRoot.appendingPathComponent("protected-aligned.apk")
        let finalName = sanitizedAPKName(options.outputName, fallback: input.deletingPathExtension().lastPathComponent + "-protected.apk")
        let finalOutput = runRoot.appendingPathComponent(finalName)
        let certificateGuardDirectory = runRoot.appendingPathComponent(".certificate-guard", isDirectory: true)
        let inputCertificateFingerprints = certificateGuardDirectory.appendingPathComponent("input-sha256.txt")
        let guardedSignedCandidate = certificateGuardDirectory.appendingPathComponent("signed.apk")
        let apktoolJavaHome = runRoot.appendingPathComponent(".mocika-java-home", isDirectory: true)
        let apktoolFramework = apktoolJavaHome
            .appendingPathComponent("Library/apktool/framework", isDirectory: true)
            .appendingPathComponent("1.apk")

        var steps: [PipelineStep] = [
            PipelineStep(title: "创建隔离工作区", detail: "所有中间产物均保存在单次任务目录", operation: .createDirectory(runRoot)),
            PipelineStep(title: "复制输入 APK", detail: "原 APK 不会被覆盖", operation: .copyItem(source: input, destination: copiedInput))
        ]

        if options.useMocikaShield {
            steps.append(PipelineStep(
                title: "锁定原始签名证书",
                detail: "验证输入 APK，并保存全部签名证书的 SHA-256 摘要供最终强制比对",
                operation: .recordAPKCertificate(
                    command: CommandSpec(
                        executable: apksigner,
                        arguments: ["verify", "--verbose", "--print-certs", copiedInput.path],
                        workingDirectory: runRoot,
                        environment: javaEnvironment(toolchain)
                    ),
                    destination: inputCertificateFingerprints
                )
            ))
        } else if options.verifyBefore {
            steps.append(PipelineStep(
                title: "校验原始签名",
                detail: "读取签名证书并检查 APK 签名结构",
                operation: .command(CommandSpec(
                    executable: apksigner,
                    arguments: ["verify", "--verbose", "--print-certs", copiedInput.path],
                    workingDirectory: runRoot,
                    environment: javaEnvironment(toolchain)
                ))
            ))
        }

        var candidate = copiedInput
        if options.useMocikaShield, let shield = toolchain.mocikaShield, let androidFramework {
            steps.append(PipelineStep(
                title: "准备 APK 解包框架",
                detail: "从已安装 Android Platform 隔离复制 framework；不修改用户全局 Apktool 缓存",
                operation: .copyItem(source: androidFramework, destination: apktoolFramework)
            ))
            var shieldArguments = ["protect", "-i", copiedInput.path, "-o", shielded.path]
            let bundledResources = shield
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("resources/resources.zip")
            if FileManager.default.fileExists(atPath: bundledResources.path) {
                shieldArguments += ["--resources", bundledResources.path]
            }
            shieldArguments += [
                "--environment-policy", options.strictEnvironmentProtection ? "strict" : "compatible",
                "--json-progress"
            ]
            steps.append(PipelineStep(
                title: "执行 DEX 壳保护",
                detail: "调用 Mocika Shield；加固后必须使用与原 APK 相同的证书签名",
                operation: .command(CommandSpec(
                    executable: shield,
                    arguments: shieldArguments,
                    workingDirectory: runRoot,
                    environment: mocikaEnvironment(toolchain, apktoolJavaHome: apktoolJavaHome)
                ))
            ))
            candidate = shielded
        }

        if options.zipalign, !options.useMocikaShield, let zipalign = toolchain.zipalign {
            steps.append(PipelineStep(
                title: "执行 ZIP 对齐",
                detail: "对齐必须发生在 APK 签名之前",
                operation: .command(CommandSpec(
                    executable: zipalign,
                    arguments: zipalignArguments(tool: zipalign, checkOnly: false, input: candidate, output: aligned),
                    workingDirectory: runRoot
                ))
            ))
            candidate = aligned
        }

        if options.signOutput, let keystore = options.keystoreURL {
            let signedOutput = options.useMocikaShield ? guardedSignedCandidate : finalOutput
            var arguments = [
                "sign", "--ks", keystore.path,
                "--ks-key-alias", options.keyAlias,
                "--ks-pass", "stdin"
            ]
            var secretLines = options.keystorePassword + "\n"
            if !options.keyPassword.isEmpty {
                arguments += ["--key-pass", "stdin"]
                secretLines += options.keyPassword + "\n"
            }
            arguments += ["--out", signedOutput.path, candidate.path]
            steps.append(PipelineStep(
                title: "签名加固 APK",
                detail: "密码仅通过标准输入传递，不写入命令、设置或日志",
                operation: .command(CommandSpec(
                    executable: apksigner,
                    arguments: arguments,
                    workingDirectory: runRoot,
                    environment: javaEnvironment(toolchain),
                    standardInput: secretLines.data(using: .utf8)
                ))
            ))
            candidate = signedOutput
        } else if candidate != finalOutput {
            steps.append(PipelineStep(
                title: "发布未签名 APK",
                detail: "产物尚未签名，不可直接安装或发布",
                operation: .copyItem(source: candidate, destination: finalOutput)
            ))
            candidate = finalOutput
        }

        if options.useMocikaShield {
            steps.append(PipelineStep(
                title: "强制核对最终签名证书",
                detail: "最终 APK 的全部证书 SHA-256 摘要必须与输入 APK 完全一致，否则任务失败且不发布产物",
                operation: .compareAPKCertificate(
                    command: CommandSpec(
                        executable: apksigner,
                        arguments: ["verify", "--verbose", "--print-certs", candidate.path],
                        workingDirectory: runRoot,
                        environment: javaEnvironment(toolchain)
                    ),
                    expectedFingerprints: inputCertificateFingerprints
                )
            ))
        } else if options.verifyAfter {
            steps.append(PipelineStep(
                title: "校验最终 APK",
                detail: "验证签名证书、签名方案和 ZIP 对齐",
                operation: .command(CommandSpec(
                    executable: apksigner,
                    arguments: ["verify", "--verbose", "--print-certs", candidate.path],
                    workingDirectory: runRoot,
                    environment: javaEnvironment(toolchain)
                ))
            ))
        }
        if options.verifyAfter {
            if let zipalign = toolchain.zipalign {
                steps.append(PipelineStep(
                    title: "复核最终对齐",
                    detail: "确保签名后未再修改 APK",
                    operation: .command(CommandSpec(
                        executable: zipalign,
                        arguments: zipalignArguments(tool: zipalign, checkOnly: true, input: candidate, output: nil),
                        workingDirectory: runRoot
                    ))
                ))
            }
        }

        if options.useMocikaShield {
            steps.append(PipelineStep(
                title: "发布证书校验通过的 APK",
                detail: "仅在签名、证书一致性和 ZIP 对齐全部通过后创建最终产物",
                operation: .copyItem(source: candidate, destination: finalOutput)
            ))
            candidate = finalOutput
        }

        return PipelinePlan(
            id: id,
            kind: .apk,
            name: input.lastPathComponent,
            rootDirectory: runRoot,
            finalOutput: finalOutput,
            steps: steps
        )
    }

    private static func gradleCommand(
        tasks: [String],
        workspace: URL,
        options: SourceProtectionOptions,
        toolchain: LocatedToolchain,
        nativeFlags: [String],
        nativeGradleInitScript: URL?
    ) -> CommandSpec {
        var environment: [String: String] = [:]
        environment.merge(javaEnvironment(toolchain)) { _, new in new }
        if let sdk = toolchain.androidSDK {
            environment["ANDROID_SDK_ROOT"] = sdk.path
            environment["ANDROID_HOME"] = sdk.path
        }
        if options.nativeToolchain != .none, let ndk = toolchain.protectedNDK {
            environment["ANDROID_NDK_HOME"] = ndk.path
            environment["ANDROID_NDK_ROOT"] = ndk.path
            environment[NativeGradleWiring.ndkPathEnvironmentKey] = ndk.path
            let joinedFlags = nativeFlags.joined(separator: " ")
            for key in ["CFLAGS", "CXXFLAGS", "CPPFLAGS", "NDK_APP_CFLAGS"] {
                let inherited = ProcessInfo.processInfo.environment[key]?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                environment[key] = [inherited, joinedFlags]
                    .compactMap { value in
                        guard let value, !value.isEmpty else { return nil }
                        return value
                    }
                    .joined(separator: " ")
            }
            environment[NativeGradleWiring.nativeFlagsEnvironmentKey] = joinedFlags
        }
        let wrapper = workspace.appendingPathComponent("gradlew")
        var arguments = [wrapper.path]
        if let nativeGradleInitScript {
            arguments += [
                "--init-script", nativeGradleInitScript.path,
                "-Dorg.gradle.configuration-cache=false"
            ]
        }
        arguments += tasks + ["--no-daemon", "--console=plain", "--stacktrace"]
        return CommandSpec(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: arguments,
            workingDirectory: workspace,
            environment: environment
        )
    }

    private static func javaEnvironment(_ toolchain: LocatedToolchain) -> [String: String] {
        guard let java = toolchain.java else { return [:] }
        let javaHome = java.deletingLastPathComponent().deletingLastPathComponent()
        let inheritedPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        return [
            "JAVA_HOME": javaHome.path,
            "PATH": java.deletingLastPathComponent().path + ":" + inheritedPath
        ]
    }

    private static func mocikaEnvironment(
        _ toolchain: LocatedToolchain,
        apktoolJavaHome: URL
    ) -> [String: String] {
        var environment = javaEnvironment(toolchain)
        let escapedPath = apktoolJavaHome.path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let isolatedHome = "-Duser.home=\"\(escapedPath)\""
        let inheritedOptions = ProcessInfo.processInfo.environment["JAVA_TOOL_OPTIONS"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        environment["JAVA_TOOL_OPTIONS"] = [inheritedOptions, isolatedHome]
            .compactMap { value in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
            .joined(separator: " ")
        return environment
    }

    private static func latestAndroidFramework(in sdk: URL?) -> URL? {
        guard let sdk else { return nil }
        let platforms = sdk.appendingPathComponent("platforms", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: platforms,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        return entries
            .sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending }
            .map { $0.appendingPathComponent("android.jar") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static func parseGradleTasks(_ raw: String) -> [String] {
        raw.components(separatedBy: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",")))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func normalizedModule(_ value: String) -> String {
        let cleaned = value.trimmingCharacters(in: CharacterSet(charactersIn: " :\n\t"))
            .replacingOccurrences(of: "/", with: ":")
        return ":" + (cleaned.isEmpty ? "app" : cleaned)
    }

    private static func normalizedVariant(_ value: String) -> String {
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = cleaned.first else { return "Release" }
        return first.uppercased() + cleaned.dropFirst()
    }

    private static func runFolderName(now: Date, id: UUID) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "\(formatter.string(from: now))-\(id.uuidString.prefix(8))"
    }

    private static func stableSeed(_ id: UUID) -> UInt64 {
        id.uuidString.utf8.reduce(1_469_598_103_934_665_603) { value, byte in
            (value ^ UInt64(byte)) &* 1_099_511_628_211
        }
    }

    private static func sanitizedAPKName(_ value: String, fallback: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:\0").union(.newlines)
        let cleaned = value.components(separatedBy: invalid).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let name = cleaned.isEmpty ? fallback : cleaned
        return name.lowercased().hasSuffix(".apk") ? name : name + ".apk"
    }

    private static func isDescendant(_ candidate: URL, of parent: URL) -> Bool {
        let candidatePath = candidate.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        let parentPath = parent.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        return candidatePath.hasPrefix(parentPath)
    }

    private static func zipalignArguments(tool: URL, checkOnly: Bool, input: URL, output: URL?) -> [String] {
        let major = Int(tool.deletingLastPathComponent().lastPathComponent.split(separator: ".").first ?? "0") ?? 0
        var arguments: [String] = []
        if checkOnly {
            arguments.append("-c")
        } else {
            arguments.append("-f")
        }
        if major >= 35 {
            arguments += ["-P", "16"]
        } else {
            arguments.append("-p")
        }
        arguments.append("-v")
        arguments.append("4")
        arguments.append(input.path)
        if let output { arguments.append(output.path) }
        return arguments
    }
}
