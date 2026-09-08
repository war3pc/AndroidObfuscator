import XCTest
@testable import AndroidObfuscatorCore

final class PipelineExecutorTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PipelineExecutorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testSourcePipelineBuildsOnlyInCopyAndCollectsArtifacts() async throws {
        let project = root.appendingPathComponent("Demo", isDirectory: true)
        let output = root.appendingPathComponent("Output", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try makeExecutable(
            at: project.appendingPathComponent("gradlew"),
            contents: """
            #!/bin/sh
            mkdir -p app/build/outputs/apk/release
            mkdir -p app/build/outputs/mapping/release
            printf 'apk' > app/build/outputs/apk/release/app-release.apk
            printf 'mapping' > app/build/outputs/mapping/release/mapping.txt
            exit 0
            """
        )
        try "include(\":app\")".write(to: project.appendingPathComponent("settings.gradle"), atomically: true, encoding: .utf8)
        let java = try fakeJava()
        let toolchain = ToolchainLocator.locate(paths: ToolPaths(javaExecutable: java.path), environment: [:])
        let options = SourceProtectionOptions(
            projectURL: project,
            outputDirectory: output,
            enableResourceShrinking: false,
            installR8HardeningRules: false
        )
        let plan = try PipelinePlanner.sourcePlan(options: options, toolchain: toolchain)

        try await PipelineExecutor().execute(plan) { _ in }

        XCTAssertFalse(FileManager.default.fileExists(atPath: project.appendingPathComponent("app/build").path))
        let artifactNames = try FileManager.default.contentsOfDirectory(atPath: plan.finalOutput!.path)
        XCTAssertTrue(artifactNames.contains { $0.hasSuffix("app-release.apk") })
        XCTAssertTrue(artifactNames.contains { $0.hasSuffix("mapping.txt") })
    }

    func testAPKPipelineSignsFromStandardInputAndPublishesOutput() async throws {
        let sdk = root.appendingPathComponent("sdk", isDirectory: true)
        let tools = sdk.appendingPathComponent("build-tools/35.0.0", isDirectory: true)
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        try makeExecutable(
            at: tools.appendingPathComponent("apksigner"),
            contents: """
            #!/bin/sh
            if [ "$1" = "verify" ]; then
              printf 'Verified\n'
              exit 0
            fi
            if [ "$1" = "sign" ]; then
              IFS= read -r password
              previous=""
              output=""
              last=""
              for argument in "$@"; do
                if [ "$previous" = "--out" ]; then output="$argument"; fi
                previous="$argument"
                last="$argument"
              done
              cp "$last" "$output"
              exit 0
            fi
            exit 2
            """
        )
        try makeExecutable(
            at: tools.appendingPathComponent("zipalign"),
            contents: """
            #!/bin/sh
            if [ "$1" = "-c" ]; then exit 0; fi
            previous=""
            penultimate=""
            for argument in "$@"; do
              penultimate="$previous"
              previous="$argument"
            done
            cp "$penultimate" "$previous"
            """
        )
        let input = root.appendingPathComponent("demo.apk")
        let keystore = root.appendingPathComponent("release.jks")
        try Data("unsigned-apk".utf8).write(to: input)
        try Data("keystore".utf8).write(to: keystore)
        let toolchain = ToolchainLocator.locate(
            paths: ToolPaths(androidSDK: sdk.path, javaExecutable: try fakeJava().path),
            environment: [:]
        )
        let options = APKProtectionOptions(
            inputAPK: input,
            outputDirectory: root,
            outputName: "ready.apk",
            keystoreURL: keystore,
            keyAlias: "release",
            keystorePassword: "secret"
        )
        let plan = try PipelinePlanner.apkPlan(options: options, toolchain: toolchain)

        try await PipelineExecutor().execute(plan) { _ in }

        XCTAssertEqual(try Data(contentsOf: plan.finalOutput!), Data("unsigned-apk".utf8))
    }

    func testWritesIsolatedGradleScriptAndReportsNativeArtifacts() async throws {
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        let ndk = root.appendingPathComponent("custom-ndk", isDirectory: true)
        let nativeDirectory = workspace.appendingPathComponent(
            "app/build/intermediates/cxx/Release/abc/obj/arm64-v8a",
            isDirectory: true
        )
        let metadata = workspace.appendingPathComponent(
            "app/.cxx/Release/abc/arm64-v8a/build.ninja"
        )
        try FileManager.default.createDirectory(at: nativeDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: metadata.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0x7F, 0x45, 0x4C, 0x46]).write(to: nativeDirectory.appendingPathComponent("libdemo.so"))
        try "command = \(ndk.path)/toolchains/llvm/bin/clang -mllvm -enable-cffobf\n".write(
            to: metadata,
            atomically: true,
            encoding: .utf8
        )

        let script = root.appendingPathComponent("run/native.init.gradle")
        let plan = PipelinePlan(
            kind: .source,
            name: "NativeDemo",
            rootDirectory: root,
            finalOutput: workspace,
            steps: [
                PipelineStep(
                    title: "接线定制 NDK 到 Gradle",
                    detail: "test",
                    operation: .writeFile(destination: script, contents: Data("init".utf8))
                ),
                PipelineStep(
                    title: "复核 Native 构建产物",
                    detail: "test",
                    operation: .verifyNativeArtifacts(
                        project: workspace,
                        selectedNDK: ndk,
                        expectedFlags: ["-mllvm", "-enable-cffobf"]
                    )
                )
            ]
        )
        let logs = LockedLogBuffer()

        try await PipelineExecutor().execute(plan) { event in
            if case .log(let message) = event { logs.append(message) }
        }

        XCTAssertEqual(try String(contentsOf: script, encoding: .utf8), "init")
        XCTAssertTrue(logs.value.contains("发现本次生成的 Native 库 1 个"))
        XCTAssertTrue(logs.value.contains("arm64-v8a"))
        XCTAssertTrue(logs.value.contains("构建元数据中已找到全部选定参数"))
    }

    func testNativeVerificationRejectsArtifactsWithoutSelectedFlags() async throws {
        let workspace = root.appendingPathComponent("native-unverified", isDirectory: true)
        let ndk = root.appendingPathComponent("selected-ndk", isDirectory: true)
        let nativeDirectory = workspace.appendingPathComponent("app/build/intermediates/cxx/Release/obj/arm64-v8a")
        let metadata = workspace.appendingPathComponent("app/.cxx/Release/arm64-v8a/build.ninja")
        try FileManager.default.createDirectory(at: nativeDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: metadata.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0x7F, 0x45, 0x4C, 0x46]).write(to: nativeDirectory.appendingPathComponent("libdemo.so"))
        try "command = \(ndk.path)/toolchains/llvm/bin/clang -O2\n".write(
            to: metadata,
            atomically: true,
            encoding: .utf8
        )
        let plan = PipelinePlan(
            kind: .source,
            name: "UnverifiedNative",
            rootDirectory: root,
            finalOutput: workspace,
            steps: [PipelineStep(
                title: "复核 Native 构建产物",
                detail: "test",
                operation: .verifyNativeArtifacts(
                    project: workspace,
                    selectedNDK: ndk,
                    expectedFlags: ["-mllvm", "-enable-cffobf"]
                )
            )]
        )

        do {
            try await PipelineExecutor().execute(plan) { _ in }
            XCTFail("缺少保护参数的 Native 构建不应通过")
        } catch let error as PipelineError {
            XCTAssertTrue(error.localizedDescription.contains("未找到全部保护参数"))
        }
    }

    func testCollectArtifactsIncludesHiddenSourceReports() async throws {
        let workspace = root.appendingPathComponent("report-workspace", isDirectory: true)
        let reportDirectory = workspace.appendingPathComponent(".android-obfuscator", isDirectory: true)
        let artifacts = root.appendingPathComponent("report-artifacts", isDirectory: true)
        try FileManager.default.createDirectory(at: reportDirectory, withIntermediateDirectories: true)
        try Data("report".utf8).write(
            to: reportDirectory.appendingPathComponent("android-obfuscator-source-report.json")
        )
        try Data("mapping".utf8).write(
            to: reportDirectory.appendingPathComponent("android-obfuscator-resource-mapping.json")
        )
        let plan = PipelinePlan(
            kind: .source,
            name: "Reports",
            rootDirectory: root,
            finalOutput: artifacts,
            steps: [PipelineStep(
                title: "归档",
                detail: "test",
                operation: .collectArtifacts(project: workspace, destination: artifacts)
            )]
        )

        try await PipelineExecutor().execute(plan) { _ in }

        XCTAssertEqual(
            try Data(contentsOf: artifacts.appendingPathComponent("android-obfuscator-source-report.json")),
            Data("report".utf8)
        )
        XCTAssertEqual(
            try Data(contentsOf: artifacts.appendingPathComponent("android-obfuscator-resource-mapping.json")),
            Data("mapping".utf8)
        )
    }

    func testCertificateGuardRejectsDifferentSignerAndDoesNotPublish() async throws {
        let signer = root.appendingPathComponent("apksigner")
        try makeExecutable(
            at: signer,
            contents: """
            #!/bin/sh
            last=""
            for argument in "$@"; do last="$argument"; done
            if [ "$(basename "$last")" = "input.apk" ]; then
              printf 'Signer #1 certificate SHA-256 digest: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n'
            else
              printf 'Signer #1 certificate SHA-256 digest: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n'
            fi
            """
        )
        let runRoot = root.appendingPathComponent("run", isDirectory: true)
        let input = runRoot.appendingPathComponent("input.apk")
        let signed = runRoot.appendingPathComponent("signed.apk")
        let published = runRoot.appendingPathComponent("published.apk")
        let fingerprints = runRoot.appendingPathComponent("input-sha256.txt")
        try FileManager.default.createDirectory(at: runRoot, withIntermediateDirectories: true)
        try Data("input".utf8).write(to: input)
        try Data("signed".utf8).write(to: signed)
        let verifyInput = CommandSpec(executable: signer, arguments: ["verify", "--print-certs", input.path])
        let verifySigned = CommandSpec(executable: signer, arguments: ["verify", "--print-certs", signed.path])
        let plan = PipelinePlan(
            kind: .apk,
            name: "guard-test",
            rootDirectory: runRoot,
            finalOutput: published,
            steps: [
                PipelineStep(
                    title: "记录",
                    detail: "",
                    operation: .recordAPKCertificate(command: verifyInput, destination: fingerprints)
                ),
                PipelineStep(
                    title: "比较",
                    detail: "",
                    operation: .compareAPKCertificate(command: verifySigned, expectedFingerprints: fingerprints)
                ),
                PipelineStep(
                    title: "发布",
                    detail: "",
                    operation: .copyItem(source: signed, destination: published)
                )
            ]
        )
        let log = SynchronizedTestLog()

        do {
            try await PipelineExecutor().execute(plan) { event in
                if case .log(let chunk) = event { log.append(chunk) }
            }
            XCTFail("证书不一致时任务必须失败")
        } catch let error as PipelineError {
            guard case .certificateMismatch(let expected, let actual) = error else {
                return XCTFail("错误类型不正确：\(error)")
            }
            XCTAssertEqual(expected, [String(repeating: "A", count: 64)])
            XCTAssertEqual(actual, [String(repeating: "B", count: 64)])
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: published.path))
        XCTAssertTrue(log.value.contains("证书一致性校验失败"))
    }

    func testCertificateGuardAcceptsSameSignerAndNormalizesDigest() async throws {
        let signer = root.appendingPathComponent("apksigner")
        let colonDigest = stride(from: 0, to: 64, by: 2)
            .map { _ in "ab" }
            .joined(separator: ":")
        try makeExecutable(
            at: signer,
            contents: "#!/bin/sh\nprintf 'Signer #1 certificate SHA-256 digest: \(colonDigest)\\n'\n"
        )
        let runRoot = root.appendingPathComponent("matching-run", isDirectory: true)
        let input = runRoot.appendingPathComponent("input.apk")
        let signed = runRoot.appendingPathComponent("signed.apk")
        let fingerprints = runRoot.appendingPathComponent("input-sha256.txt")
        try FileManager.default.createDirectory(at: runRoot, withIntermediateDirectories: true)
        try Data().write(to: input)
        try Data().write(to: signed)
        let plan = PipelinePlan(
            kind: .apk,
            name: "matching-guard-test",
            rootDirectory: runRoot,
            finalOutput: signed,
            steps: [
                PipelineStep(
                    title: "记录",
                    detail: "",
                    operation: .recordAPKCertificate(
                        command: CommandSpec(executable: signer, arguments: ["verify", "--print-certs", input.path]),
                        destination: fingerprints
                    )
                ),
                PipelineStep(
                    title: "比较",
                    detail: "",
                    operation: .compareAPKCertificate(
                        command: CommandSpec(executable: signer, arguments: ["verify", "--print-certs", signed.path]),
                        expectedFingerprints: fingerprints
                    )
                )
            ]
        )

        try await PipelineExecutor().execute(plan) { _ in }

        XCTAssertEqual(
            try String(contentsOf: fingerprints, encoding: .utf8),
            String(repeating: "AB", count: 32) + "\n"
        )
    }

    private func fakeJava() throws -> URL {
        let java = root.appendingPathComponent("fake-jdk/bin/java")
        try FileManager.default.createDirectory(at: java.deletingLastPathComponent(), withIntermediateDirectories: true)
        try makeExecutable(at: java, contents: "#!/bin/sh\nexit 0\n")
        return java
    }

    private func makeExecutable(at url: URL, contents: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}

private final class LockedLogBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = ""

    func append(_ text: String) {
        lock.lock()
        storage.append(text)
        lock.unlock()
    }

    var value: String {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private final class SynchronizedTestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = ""

    func append(_ chunk: String) {
        lock.lock()
        storage.append(chunk)
        lock.unlock()
    }

    var value: String {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
