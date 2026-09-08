import XCTest
@testable import AndroidObfuscatorCore

final class PipelinePlannerTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AndroidObfuscatorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    func testSourcePlanAlwaysUsesSafeCopyBeforeGradle() throws {
        let project = temporaryDirectory.appendingPathComponent("Demo", isDirectory: true)
        let output = temporaryDirectory.appendingPathComponent("Output", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(to: project.appendingPathComponent("gradlew"), atomically: true, encoding: .utf8)
        try "apply plugin: 'class-res-guard'\n".write(
            to: project.appendingPathComponent("build.gradle"),
            atomically: true,
            encoding: .utf8
        )

        var options = SourceProtectionOptions(projectURL: project, outputDirectory: output)
        options.enableResourceShrinking = false
        options.runClassRename = true
        let toolchain = ToolchainLocator.locate(paths: ToolPaths(javaExecutable: try makeJava().path), environment: [:])
        let plan = try PipelinePlanner.sourcePlan(
            options: options,
            toolchain: toolchain,
            now: Date(timeIntervalSince1970: 0),
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        )

        XCTAssertGreaterThanOrEqual(plan.steps.count, 4)
        if case .copyProject(let source, _) = plan.steps[1].operation {
            XCTAssertEqual(source, project)
        } else {
            XCTFail("Second step must create a safe project copy")
        }
        XCTAssertTrue(plan.steps.contains { $0.preview.contains("renameClass") })
        XCTAssertFalse(plan.steps.compactMap { step -> URL? in
            if case .command(let command) = step.operation { return command.workingDirectory }
            return nil
        }.contains(project))
    }

    func testSourcePlanRejectsOutputInsideProject() throws {
        let project = temporaryDirectory.appendingPathComponent("Demo", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(to: project.appendingPathComponent("gradlew"), atomically: true, encoding: .utf8)
        let output = project.appendingPathComponent("protected", isDirectory: true)
        let options = SourceProtectionOptions(projectURL: project, outputDirectory: output)

        XCTAssertThrowsError(try PipelinePlanner.sourcePlan(
            options: options,
            toolchain: ToolchainLocator.locate(paths: ToolPaths(), environment: [:])
        ))
    }

    func testResourceShrinkingPreflightCanBlockOrBeExplicitlyDisabled() throws {
        let project = temporaryDirectory.appendingPathComponent("NoShrinking", isDirectory: true)
        let output = temporaryDirectory.appendingPathComponent("Output", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(to: project.appendingPathComponent("gradlew"), atomically: true, encoding: .utf8)
        let toolchain = ToolchainLocator.locate(
            paths: ToolPaths(javaExecutable: try makeJava().path),
            environment: [:]
        )
        var options = SourceProtectionOptions(projectURL: project, outputDirectory: output)

        XCTAssertThrowsError(try PipelinePlanner.sourcePlan(options: options, toolchain: toolchain)) { error in
            XCTAssertTrue(error.localizedDescription.contains("shrinkResources"))
        }

        options.enableResourceShrinking = false
        XCTAssertNoThrow(try PipelinePlanner.sourcePlan(options: options, toolchain: toolchain))
    }

    func testSourcePlanProbesNativePassesAndInjectsSameFlagsIntoGradle() throws {
        let project = temporaryDirectory.appendingPathComponent("NativeDemo", isDirectory: true)
        let output = temporaryDirectory.appendingPathComponent("Output", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(to: project.appendingPathComponent("gradlew"), atomically: true, encoding: .utf8)

        let ndk = try makeNDK()
        let paths = ToolPaths(javaExecutable: try makeJava().path, protectedNDK: ndk.path)
        let toolchain = ToolchainLocator.locate(paths: paths, environment: [:])
        var options = SourceProtectionOptions(projectURL: project, outputDirectory: output)
        options.installR8HardeningRules = false
        options.enableResourceShrinking = false
        options.nativeToolchain = .hikari

        let plan = try PipelinePlanner.sourcePlan(options: options, toolchain: toolchain)
        let nativeProbe = try XCTUnwrap(plan.steps.compactMap { step -> CommandSpec? in
            guard step.title == "验证 Native 混淆 Pass",
                  case .command(let command) = step.operation else { return nil }
            return command
        }.first)
        XCTAssertTrue(nativeProbe.arguments.contains("-enable-cffobf"))
        XCTAssertNotNil(nativeProbe.standardInput)

        let wiring = try XCTUnwrap(plan.steps.compactMap { step -> (URL, Data)? in
            guard step.title == "接线定制 NDK 到 Gradle",
                  case .writeFile(let destination, let contents) = step.operation else { return nil }
            return (destination, contents)
        }.first)
        XCTAssertEqual(wiring.0.lastPathComponent, NativeGradleWiring.scriptFileName)
        let initScript = try XCTUnwrap(String(data: wiring.1, encoding: .utf8))
        XCTAssertTrue(initScript.contains("android.ndkPath = selectedNdk.absolutePath"))
        XCTAssertTrue(initScript.contains("gradle.projectsEvaluated"))
        XCTAssertTrue(initScript.contains("拒绝使用 AGP 默认 NDK"))
        XCTAssertFalse(initScript.contains(ndk.path), "NDK 路径应从任务环境读取，不能插值进 Groovy 源码")

        let gradle = try XCTUnwrap(plan.steps.compactMap { step -> CommandSpec? in
            guard case .command(let command) = step.operation,
                  command.executable.path == "/bin/sh" else { return nil }
            return command
        }.first)
        XCTAssertEqual(gradle.environment["ANDROID_NDK_HOME"], ndk.path)
        XCTAssertEqual(gradle.environment[NativeGradleWiring.ndkPathEnvironmentKey], ndk.path)
        XCTAssertTrue(gradle.environment["CFLAGS"]?.contains("-enable-cffobf") == true)
        XCTAssertTrue(gradle.environment["CXXFLAGS"]?.contains("-enable-subobf") == true)
        XCTAssertEqual(
            gradle.environment["ANDROID_OBFUSCATOR_NATIVE_FLAGS"],
            "-mllvm -enable-cffobf -mllvm -enable-subobf"
        )
        XCTAssertTrue(gradle.arguments.contains("--init-script"))
        XCTAssertTrue(gradle.arguments.contains(wiring.0.path))
        XCTAssertTrue(gradle.arguments.contains("-Dorg.gradle.configuration-cache=false"))

        let verificationIndex = try XCTUnwrap(plan.steps.firstIndex { step in
            if case .verifyNativeArtifacts(let project, let selectedNDK, let expectedFlags) = step.operation {
                return project.lastPathComponent == "workspace"
                    && selectedNDK == ndk
                    && expectedFlags.contains("-enable-subobf")
            }
            return false
        })
        let collectionIndex = try XCTUnwrap(plan.steps.firstIndex { step in
            if case .collectArtifacts = step.operation { return true }
            return false
        })
        XCTAssertLessThan(verificationIndex, collectionIndex)
    }

    func testAPKPlanNeverDisplaysPasswords() throws {
        let sdk = try makeSDK(version: "35.0.0")
        let apk = temporaryDirectory.appendingPathComponent("input.apk")
        let keystore = temporaryDirectory.appendingPathComponent("release.jks")
        try Data("apk".utf8).write(to: apk)
        try Data("key".utf8).write(to: keystore)
        let paths = ToolPaths(androidSDK: sdk.path, javaExecutable: try makeJava().path)
        let toolchain = ToolchainLocator.locate(paths: paths, environment: [:])
        let options = APKProtectionOptions(
            inputAPK: apk,
            outputDirectory: temporaryDirectory,
            outputName: "release.apk",
            keystoreURL: keystore,
            keyAlias: "release",
            keystorePassword: "top-secret-password",
            keyPassword: "key-secret-password"
        )

        let plan = try PipelinePlanner.apkPlan(options: options, toolchain: toolchain)
        let preview = plan.steps.map(\.preview).joined(separator: "\n")
        XCTAssertFalse(preview.contains("top-secret-password"))
        XCTAssertFalse(preview.contains("key-secret-password"))
        XCTAssertTrue(preview.contains("--ks-pass stdin"))
        let redacted = plan.redactedForDisplay()
        let redactedInputs = redacted.steps.compactMap { step -> Data? in
            if case .command(let command) = step.operation { return command.standardInput }
            return nil
        }
        XCTAssertTrue(redactedInputs.isEmpty)
        XCTAssertLessThan(
            plan.steps.firstIndex { $0.title.contains("对齐") }!,
            plan.steps.firstIndex { $0.title.contains("签名加固") }!
        )
    }

    func testToolchainSelectsLatestBuildTools() throws {
        let sdk = try makeSDK(version: "34.0.0")
        _ = try makeBuildTools(in: sdk, version: "35.0.1")
        let located = ToolchainLocator.locate(paths: ToolPaths(androidSDK: sdk.path), environment: [:])
        XCTAssertEqual(located.apksigner?.deletingLastPathComponent().lastPathComponent, "35.0.1")
        XCTAssertEqual(located.zipalign?.deletingLastPathComponent().lastPathComponent, "35.0.1")
    }

    func testMocikaPlanUsesIsolatedApktoolFrameworkAndStrictPolicy() throws {
        let sdk = try makeSDK(version: "35.0.0")
        let platformJar = try makeAndroidPlatform(in: sdk, version: "android-35")
        let apk = temporaryDirectory.appendingPathComponent("input.apk")
        let keystore = temporaryDirectory.appendingPathComponent("release.jks")
        try Data("signed-apk-placeholder".utf8).write(to: apk)
        try Data("keystore-placeholder".utf8).write(to: keystore)

        let shield = temporaryDirectory.appendingPathComponent("MocikaShield/bin/shield")
        let resources = temporaryDirectory.appendingPathComponent("MocikaShield/resources/resources.zip")
        try FileManager.default.createDirectory(at: shield.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: resources.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\nexit 0\n".write(to: shield, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shield.path)
        try Data("runtime".utf8).write(to: resources)

        let paths = ToolPaths(
            androidSDK: sdk.path,
            javaExecutable: try makeJava().path,
            mocikaShieldCLI: shield.path
        )
        let toolchain = ToolchainLocator.locate(paths: paths, environment: [:])
        let options = APKProtectionOptions(
            inputAPK: apk,
            outputDirectory: temporaryDirectory,
            useMocikaShield: true,
            strictEnvironmentProtection: true,
            keystoreURL: keystore,
            keyAlias: "release",
            keystorePassword: "secret"
        )

        let plan = try PipelinePlanner.apkPlan(options: options, toolchain: toolchain)
        let frameworkCopies = plan.steps.compactMap { step -> (URL, URL)? in
            guard case .copyItem(let source, let destination) = step.operation,
                  destination.lastPathComponent == "1.apk" else { return nil }
            return (source, destination)
        }
        XCTAssertEqual(frameworkCopies.count, 1)
        XCTAssertEqual(
            frameworkCopies.first?.0.resolvingSymlinksInPath().path,
            platformJar.resolvingSymlinksInPath().path
        )
        XCTAssertTrue(frameworkCopies.first?.1.path.contains(".mocika-java-home/Library/apktool/framework/1.apk") == true)

        let shieldCommand = try XCTUnwrap(plan.steps.compactMap { step -> CommandSpec? in
            guard case .command(let command) = step.operation,
                  command.executable == shield else { return nil }
            return command
        }.first)
        XCTAssertTrue(shieldCommand.arguments.contains("strict"))
        XCTAssertTrue(shieldCommand.arguments.contains("--resources"))
        XCTAssertTrue(shieldCommand.arguments.contains(resources.path))
        XCTAssertTrue(shieldCommand.arguments.contains("--json-progress"))
        XCTAssertTrue(shieldCommand.environment["JAVA_TOOL_OPTIONS"]?.contains(".mocika-java-home") == true)
        XCTAssertFalse(plan.steps.contains { $0.title == "执行 ZIP 对齐" })

        let recordIndex = try XCTUnwrap(plan.steps.firstIndex { step in
            if case .recordAPKCertificate = step.operation { return true }
            return false
        })
        let compareIndex = try XCTUnwrap(plan.steps.firstIndex { step in
            if case .compareAPKCertificate = step.operation { return true }
            return false
        })
        let publishIndex = try XCTUnwrap(plan.steps.firstIndex { $0.title == "发布证书校验通过的 APK" })
        XCTAssertLessThan(recordIndex, compareIndex)
        XCTAssertLessThan(compareIndex, publishIndex)
        if case .copyItem(let source, let destination) = plan.steps[publishIndex].operation {
            XCTAssertTrue(source.path.contains(".certificate-guard/signed.apk"))
            XCTAssertEqual(destination, plan.finalOutput)
        } else {
            XCTFail("Mocika 最终产物必须在证书校验通过后发布")
        }
    }

    func testMocikaPlanCannotDisableMandatoryCertificateChecksOrSigning() throws {
        let sdk = try makeSDK(version: "35.0.0")
        _ = try makeAndroidPlatform(in: sdk, version: "android-35")
        let apk = temporaryDirectory.appendingPathComponent("input.apk")
        try Data("signed-apk-placeholder".utf8).write(to: apk)
        let shield = temporaryDirectory.appendingPathComponent("MocikaShield/bin/shield")
        try FileManager.default.createDirectory(at: shield.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\nexit 0\n".write(to: shield, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shield.path)
        let toolchain = ToolchainLocator.locate(
            paths: ToolPaths(
                androidSDK: sdk.path,
                javaExecutable: try makeJava().path,
                mocikaShieldCLI: shield.path
            ),
            environment: [:]
        )

        for options in [
            APKProtectionOptions(
                inputAPK: apk,
                outputDirectory: temporaryDirectory,
                verifyBefore: false,
                useMocikaShield: true
            ),
            APKProtectionOptions(
                inputAPK: apk,
                outputDirectory: temporaryDirectory,
                useMocikaShield: true,
                signOutput: false,
                verifyAfter: false
            ),
            APKProtectionOptions(
                inputAPK: apk,
                outputDirectory: temporaryDirectory,
                useMocikaShield: true,
                verifyAfter: false
            )
        ] {
            XCTAssertThrowsError(try PipelinePlanner.apkPlan(options: options, toolchain: toolchain)) { error in
                guard case .invalidConfiguration = error as? PipelineError else {
                    return XCTFail("应拒绝关闭 Mocika 的强制证书保护：\(error)")
                }
            }
        }
    }

    private func makeSDK(version: String) throws -> URL {
        let sdk = temporaryDirectory.appendingPathComponent("sdk", isDirectory: true)
        try FileManager.default.createDirectory(at: sdk, withIntermediateDirectories: true)
        _ = try makeBuildTools(in: sdk, version: version)
        return sdk
    }

    private func makeJava() throws -> URL {
        let java = temporaryDirectory.appendingPathComponent("fake-jdk/bin/java")
        try FileManager.default.createDirectory(at: java.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\nexit 0\n".write(to: java, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: java.path)
        return java
    }

    private func makeNDK() throws -> URL {
        let ndk = temporaryDirectory.appendingPathComponent("protected-ndk", isDirectory: true)
        let bin = ndk.appendingPathComponent("toolchains/llvm/prebuilt/darwin-arm64/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: ndk.appendingPathComponent("build/cmake"), withIntermediateDirectories: true)
        try "Pkg.Revision = 28.0.0\n".write(
            to: ndk.appendingPathComponent("source.properties"),
            atomically: true,
            encoding: .utf8
        )
        try "# toolchain\n".write(
            to: ndk.appendingPathComponent("build/cmake/android.toolchain.cmake"),
            atomically: true,
            encoding: .utf8
        )
        for name in ["clang", "clang++"] {
            let executable = bin.appendingPathComponent(name)
            try "#!/bin/sh\nexit 0\n".write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        }
        return ndk
    }

    @discardableResult
    private func makeAndroidPlatform(in sdk: URL, version: String) throws -> URL {
        let jar = sdk.appendingPathComponent("platforms/\(version)/android.jar")
        try FileManager.default.createDirectory(at: jar.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("framework".utf8).write(to: jar)
        return jar
    }

    @discardableResult
    private func makeBuildTools(in sdk: URL, version: String) throws -> URL {
        let directory = sdk.appendingPathComponent("build-tools/\(version)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in ["apksigner", "zipalign"] {
            let file = directory.appendingPathComponent(name)
            try "#!/bin/sh\nexit 0\n".write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        return directory
    }
}
