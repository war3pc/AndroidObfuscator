import Foundation

public final class ProcessRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var currentProcess: Process?

    public init() {}

    public func run(_ command: CommandSpec, onOutput: @escaping @Sendable (String) -> Void) async throws {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = command.executable
        process.arguments = command.arguments
        process.currentDirectoryURL = command.workingDirectory
        process.standardOutput = stdout
        process.standardError = stderr
        process.environment = ProcessInfo.processInfo.environment.merging(command.environment) { _, new in new }

        let inputPipe: Pipe?
        if command.standardInput != nil {
            let pipe = Pipe()
            process.standardInput = pipe
            inputPipe = pipe
        } else {
            inputPipe = nil
        }

        let emit: @Sendable (FileHandle) -> Void = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            if let text = String(data: data, encoding: .utf8), !text.isEmpty {
                onOutput(text)
            }
        }
        stdout.fileHandleForReading.readabilityHandler = emit
        stderr.fileHandleForReading.readabilityHandler = emit

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { [weak self] finished in
                    stdout.fileHandleForReading.readabilityHandler = nil
                    stderr.fileHandleForReading.readabilityHandler = nil
                    self?.setCurrent(nil)
                    if finished.terminationStatus == 0 {
                        continuation.resume()
                    } else if Task.isCancelled {
                        continuation.resume(throwing: PipelineError.cancelled)
                    } else {
                        continuation.resume(throwing: PipelineError.commandFailed(
                            title: command.executable.lastPathComponent,
                            exitCode: finished.terminationStatus
                        ))
                    }
                }

                do {
                    try process.run()
                    setCurrent(process)
                    if let data = command.standardInput, let inputPipe {
                        inputPipe.fileHandleForWriting.write(data)
                        try? inputPipe.fileHandleForWriting.close()
                    }
                } catch {
                    stdout.fileHandleForReading.readabilityHandler = nil
                    stderr.fileHandleForReading.readabilityHandler = nil
                    setCurrent(nil)
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: { [weak self] in
            self?.cancel()
        }
    }

    public func runCapturing(
        _ command: CommandSpec,
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        let captured = SynchronizedTextBuffer()
        try await run(command) { chunk in
            captured.append(chunk)
            onOutput(chunk)
        }
        return captured.value
    }

    public func cancel() {
        lock.lock()
        let process = currentProcess
        lock.unlock()
        guard let process, process.isRunning else { return }
        process.interrupt()
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) {
            if process.isRunning { process.terminate() }
        }
    }

    private func setCurrent(_ process: Process?) {
        lock.lock()
        currentProcess = process
        lock.unlock()
    }
}

private final class SynchronizedTextBuffer: @unchecked Sendable {
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

public final class PipelineExecutor: @unchecked Sendable {
    private let processRunner: ProcessRunner
    private let fileManager: FileManager

    public init(processRunner: ProcessRunner = ProcessRunner(), fileManager: FileManager = .default) {
        self.processRunner = processRunner
        self.fileManager = fileManager
    }

    public func execute(
        _ plan: PipelinePlan,
        onEvent: @escaping @Sendable (PipelineEvent) -> Void
    ) async throws {
        do {
            for (offset, step) in plan.steps.enumerated() {
                try Task.checkCancellation()
                onEvent(.stepStarted(index: offset, total: plan.steps.count, step: step))
                onEvent(.log("\n▶︎ \(step.title)\n"))
                try await execute(step.operation, onEvent: onEvent)
                onEvent(.stepFinished(index: offset, step: step))
            }
            onEvent(.finished)
        } catch is CancellationError {
            throw PipelineError.cancelled
        }
    }

    public func cancel() {
        processRunner.cancel()
    }

    private func execute(
        _ operation: PipelineOperation,
        onEvent: @escaping @Sendable (PipelineEvent) -> Void
    ) async throws {
        switch operation {
        case .createDirectory(let url):
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            onEvent(.log("已创建：\(url.path)\n"))

        case .copyItem(let source, let destination):
            try Task.checkCancellation()
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: destination.path) {
                throw PipelineError.fileOperation("目标已存在，拒绝覆盖：\(destination.path)")
            }
            try fileManager.copyItem(at: source, to: destination)
            onEvent(.log("已复制：\(source.lastPathComponent)\n"))

        case .copyProject(let source, let destination):
            try copyProject(source: source, destination: destination, onEvent: onEvent)

        case .writeFile(let destination, let contents):
            try Task.checkCancellation()
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            guard !fileManager.fileExists(atPath: destination.path) else {
                throw PipelineError.fileOperation("目标已存在，拒绝覆盖：\(destination.path)")
            }
            try contents.write(to: destination, options: .atomic)
            onEvent(.log("已写入单次任务文件：\(destination.path)\n"))

        case .protectSource(let project, let configuration):
            let report = try BuiltInSourceProtector.apply(
                project: project,
                configuration: configuration,
                fileManager: fileManager
            )
            onEvent(.log("内置保护完成：生成 \(report.generatedSourceFiles) 个源码、\(report.generatedResourceFiles) 个资源，改名 \(report.renamedResources) 项。\n"))
            for warning in report.warnings {
                onEvent(.log("提示：\(warning)\n"))
            }

        case .command(let command):
            onEvent(.log("$ \(command.displayText)\n"))
            try await processRunner.run(command) { chunk in
                onEvent(.log(chunk))
            }

        case .recordAPKCertificate(let command, let destination):
            onEvent(.log("$ \(command.displayText)\n"))
            let output = try await processRunner.runCapturing(command) { chunk in
                onEvent(.log(chunk))
            }
            let fingerprints = try APKCertificateIdentity.fingerprints(fromAPKSigOutput: output)
            try APKCertificateIdentity.writeFingerprints(fingerprints, to: destination)
            onEvent(.log("已锁定输入 APK 证书 SHA-256：\(APKCertificateIdentity.display(fingerprints))\n"))

        case .compareAPKCertificate(let command, let expectedFingerprints):
            onEvent(.log("$ \(command.displayText)\n"))
            let output = try await processRunner.runCapturing(command) { chunk in
                onEvent(.log(chunk))
            }
            let expected = try APKCertificateIdentity.readFingerprints(from: expectedFingerprints)
            let actual = try APKCertificateIdentity.fingerprints(fromAPKSigOutput: output)
            guard expected == actual else {
                onEvent(.log("证书一致性校验失败。输入：\(APKCertificateIdentity.display(expected))；最终：\(APKCertificateIdentity.display(actual))\n"))
                throw PipelineError.certificateMismatch(expected: expected, actual: actual)
            }
            onEvent(.log("证书一致性校验通过：\(APKCertificateIdentity.display(actual))\n"))

        case .verifyNativeArtifacts(let project, let selectedNDK, let expectedFlags):
            try verifyNativeArtifacts(
                project: project,
                selectedNDK: selectedNDK,
                expectedFlags: expectedFlags,
                onEvent: onEvent
            )

        case .collectArtifacts(let project, let destination):
            try collectArtifacts(project: project, destination: destination, onEvent: onEvent)
        }
    }

    private func verifyNativeArtifacts(
        project: URL,
        selectedNDK: URL,
        expectedFlags: [String],
        onEvent: @escaping @Sendable (PipelineEvent) -> Void
    ) throws {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey]
        guard let enumerator = fileManager.enumerator(
            at: project,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: { url, error in
                onEvent(.log("跳过无法读取的 Native 构建路径：\(url.path)（\(error.localizedDescription)）\n"))
                return true
            }
        ) else {
            throw PipelineError.fileOperation("无法扫描 Native 构建产物。")
        }

        let skippedDirectories: Set<String> = [".git", ".gradle", ".idea", "node_modules"]
        let metadataNames: Set<String> = [
            "build.ninja", "compile_commands.json", "android_gradle_build.json",
            "build_model.json", "build_command.txt", "configure_command.txt",
            "metadata_generation_command.txt"
        ]
        let knownABIs: Set<String> = [
            "arm64-v8a", "armeabi-v7a", "x86", "x86_64", "riscv64"
        ]
        let canonicalNDK = selectedNDK.standardizedFileURL.resolvingSymlinksInPath().path
        let configuredNDK = selectedNDK.standardizedFileURL.path

        var libraries: [URL] = []
        var abis: Set<String> = []
        var metadataCount = 0
        var metadataWithSelectedNDK = 0
        var metadataWithAllFlags = 0

        for case let item as URL in enumerator {
            if Task.isCancelled { throw PipelineError.cancelled }
            guard let values = try? item.resourceValues(forKeys: keys) else { continue }
            if values.isDirectory == true {
                if skippedDirectories.contains(item.lastPathComponent) {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard values.isRegularFile == true else { continue }

            let relativeComponents = item.standardizedFileURL.pathComponents
                .dropFirst(project.standardizedFileURL.pathComponents.count)
            let isGeneratedPath = relativeComponents.contains("build")
                || relativeComponents.contains(".cxx")
                || relativeComponents.contains(".externalNativeBuild")
            guard isGeneratedPath else { continue }

            if item.pathExtension.lowercased() == "so" {
                guard isELFSharedObject(item) else {
                    onEvent(.log("忽略非 ELF 的 .so 文件：\(item.path)\n"))
                    continue
                }
                libraries.append(item)
                if let abi = relativeComponents.first(where: { knownABIs.contains($0) }) {
                    abis.insert(abi)
                }
                continue
            }

            guard metadataNames.contains(item.lastPathComponent),
                  (values.fileSize ?? 0) <= 16 * 1_024 * 1_024,
                  let data = try? Data(contentsOf: item, options: .mappedIfSafe),
                  let text = String(data: data, encoding: .utf8) else { continue }
            metadataCount += 1
            if text.contains(configuredNDK) || text.contains(canonicalNDK) {
                metadataWithSelectedNDK += 1
            }
            if !expectedFlags.isEmpty && expectedFlags.allSatisfy({ text.contains($0) }) {
                metadataWithAllFlags += 1
            }
        }

        onEvent(.log("Gradle NDK 接线已通过：每个 Android 模块的 android.ndkPath 在任务图创建前均与所选目录一致。\n"))
        guard !libraries.isEmpty else {
            throw PipelineError.fileOperation(
                "已选择 Native 保护，但本次 build/.cxx 中没有生成任何 .so。拒绝把仅通过编译器探针的任务标记为成功。"
            )
        }
        let abiText = abis.isEmpty ? "ABI 未从路径识别" : abis.sorted().joined(separator: "、")
        onEvent(.log("发现本次生成的 Native 库 \(libraries.count) 个（\(abiText)）。\n"))
        for library in libraries.prefix(8) {
            let relative = library.path.replacingOccurrences(of: project.path + "/", with: "")
            onEvent(.log("Native 产物：\(relative)\n"))
        }
        if libraries.count > 8 {
            onEvent(.log("另有 \(libraries.count - 8) 个 Native 产物未展开显示。\n"))
        }

        guard metadataWithSelectedNDK > 0 else {
            throw PipelineError.fileOperation(
                "发现 Native 产物，但无法从 CMake/ndk-build 元数据确认它们使用了所选 NDK；拒绝发布未经证明的 Native 保护结果。"
            )
        }
        onEvent(.log("Native 构建元数据核验：\(metadataWithSelectedNDK)/\(metadataCount) 个文件含所选 NDK 路径。\n"))

        if !expectedFlags.isEmpty {
            guard metadataWithAllFlags > 0 else {
                throw PipelineError.fileOperation(
                    "Native 构建元数据中未找到全部保护参数；工程可能覆盖了 CFLAGS/CXXFLAGS/NDK_APP_CFLAGS，任务已停止。"
                )
            }
            onEvent(.log("保护参数核验：Native 构建元数据中已找到全部选定参数。\n"))
        }
    }

    private func isELFSharedObject(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 4)) == Data([0x7F, 0x45, 0x4C, 0x46])
    }

    private func copyProject(
        source: URL,
        destination: URL,
        onEvent: @escaping @Sendable (PipelineEvent) -> Void
    ) throws {
        if fileManager.fileExists(atPath: destination.path) {
            throw PipelineError.fileOperation("安全工作副本目录已存在：\(destination.path)")
        }
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

        let excludedDirectories: Set<String> = [
            ".git", ".gradle", ".idea", ".kotlin", "build", "DerivedData", "node_modules"
        ]
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let enumerator = fileManager.enumerator(
            at: source,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles],
            errorHandler: { url, error in
                onEvent(.log("跳过无法读取的路径：\(url.path)（\(error.localizedDescription)）\n"))
                return true
            }
        ) else {
            throw PipelineError.fileOperation("无法遍历 Android 工程。")
        }

        var copiedCount = 0
        for case let item as URL in enumerator {
            if Task.isCancelled { throw PipelineError.cancelled }
            let values = try item.resourceValues(forKeys: Set(keys))
            if values.isDirectory == true && excludedDirectories.contains(item.lastPathComponent) {
                enumerator.skipDescendants()
                continue
            }
            let relativeComponents = item.standardizedFileURL.pathComponents.dropFirst(source.standardizedFileURL.pathComponents.count)
            let target = relativeComponents.reduce(destination) { partial, component in
                partial.appendingPathComponent(component)
            }
            if values.isDirectory == true {
                try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
            } else {
                try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fileManager.copyItem(at: item, to: target)
                copiedCount += 1
                if copiedCount.isMultiple(of: 250) {
                    onEvent(.log("已复制 \(copiedCount) 个文件…\n"))
                }
            }
        }
        onEvent(.log("安全工作副本完成，共复制 \(copiedCount) 个文件。\n"))
    }

    private func collectArtifacts(
        project: URL,
        destination: URL,
        onEvent: @escaping @Sendable (PipelineEvent) -> Void
    ) throws {
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        let allowedNames: Set<String> = [
            "mapping.txt", "usage.txt", "seeds.txt", "R.txt", "configuration.txt",
            "android-obfuscator-resource-mapping.json", "android-obfuscator-source-report.json"
        ]
        let allowedExtensions: Set<String> = ["apk", "aab"]
        var count = 0

        func archive(_ item: URL, relative: String) throws {
            var target = destination.appendingPathComponent(relative)
            var suffix = 2
            while fileManager.fileExists(atPath: target.path) {
                let extensionSuffix = item.pathExtension.isEmpty ? "" : ".\(item.pathExtension)"
                target = destination.appendingPathComponent(
                    "\(item.deletingPathExtension().lastPathComponent)-\(suffix)\(extensionSuffix)"
                )
                suffix += 1
            }
            try fileManager.copyItem(at: item, to: target)
            count += 1
            onEvent(.log("归档：\(relative)\n"))
        }

        // The reports intentionally live in a hidden task directory, while the
        // general artifact scan skips hidden Gradle caches.  Copy the two known
        // reports explicitly so they are not lost from the final archive.
        let reportDirectory = project.appendingPathComponent(".android-obfuscator", isDirectory: true)
        for name in ["android-obfuscator-resource-mapping.json", "android-obfuscator-source-report.json"] {
            let report = reportDirectory.appendingPathComponent(name)
            if fileManager.fileExists(atPath: report.path) {
                try archive(report, relative: name)
            }
        }

        guard let enumerator = fileManager.enumerator(
            at: project,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { throw PipelineError.fileOperation("无法扫描构建产物。") }

        for case let item as URL in enumerator {
            if Task.isCancelled { throw PipelineError.cancelled }
            let isArtifact = allowedExtensions.contains(item.pathExtension.lowercased()) || allowedNames.contains(item.lastPathComponent)
            guard isArtifact else { continue }
            let relative = item.path.replacingOccurrences(of: project.path + "/", with: "")
                .replacingOccurrences(of: "/", with: "__")
            try archive(item, relative: relative)
        }
        onEvent(.log("产物归档完成，共 \(count) 个文件。\n"))
    }
}
