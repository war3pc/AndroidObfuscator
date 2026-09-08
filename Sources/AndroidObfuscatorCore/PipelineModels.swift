import Foundation

public struct CommandSpec: Sendable {
    public let executable: URL
    public let arguments: [String]
    public let workingDirectory: URL?
    public let environment: [String: String]
    public let standardInput: Data?

    public init(
        executable: URL,
        arguments: [String],
        workingDirectory: URL? = nil,
        environment: [String: String] = [:],
        standardInput: Data? = nil
    ) {
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.standardInput = standardInput
    }

    public var displayText: String {
        ([executable.lastPathComponent] + arguments).map(Self.quoteForDisplay).joined(separator: " ")
    }

    private static func quoteForDisplay(_ value: String) -> String {
        guard value.contains(where: { $0.isWhitespace || "'\"\\".contains($0) }) else { return value }
        return "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

public enum PipelineOperation: Sendable {
    case createDirectory(URL)
    case copyItem(source: URL, destination: URL)
    case copyProject(source: URL, destination: URL)
    case writeFile(destination: URL, contents: Data)
    case protectSource(project: URL, configuration: BuiltInSourceProtectionConfiguration)
    case command(CommandSpec)
    case recordAPKCertificate(command: CommandSpec, destination: URL)
    case compareAPKCertificate(command: CommandSpec, expectedFingerprints: URL)
    case verifyNativeArtifacts(project: URL, selectedNDK: URL, expectedFlags: [String])
    case collectArtifacts(project: URL, destination: URL)
}

public struct PipelineStep: Identifiable, Sendable {
    public let id: UUID
    public let title: String
    public let detail: String
    public let operation: PipelineOperation

    public init(id: UUID = UUID(), title: String, detail: String, operation: PipelineOperation) {
        self.id = id
        self.title = title
        self.detail = detail
        self.operation = operation
    }

    public var preview: String {
        switch operation {
        case .createDirectory(let url): return "创建 \(url.path)"
        case .copyItem(let source, let destination): return "复制 \(source.lastPathComponent) → \(destination.lastPathComponent)"
        case .copyProject(let source, let destination): return "安全复制 \(source.lastPathComponent) → \(destination.lastPathComponent)"
        case .writeFile(let destination, _): return "写入任务文件 → \(destination.path)"
        case .protectSource(_, let configuration): return configuration.preview
        case .command(let command): return command.displayText
        case .recordAPKCertificate(let command, let destination):
            return "\(command.displayText)；保存摘要 → \(destination.lastPathComponent)"
        case .compareAPKCertificate(let command, let expectedFingerprints):
            return "\(command.displayText)；对比 \(expectedFingerprints.lastPathComponent)"
        case .verifyNativeArtifacts(_, let selectedNDK, _):
            return "核对 .so / Native 构建元数据 → \(selectedNDK.path)"
        case .collectArtifacts(_, let destination): return "归档 APK / AAB / mapping → \(destination.path)"
        }
    }
}

public struct PipelinePlan: Sendable {
    public let id: UUID
    public let kind: JobKind
    public let name: String
    public let rootDirectory: URL
    public let finalOutput: URL?
    public let steps: [PipelineStep]

    public init(
        id: UUID = UUID(),
        kind: JobKind,
        name: String,
        rootDirectory: URL,
        finalOutput: URL?,
        steps: [PipelineStep]
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.rootDirectory = rootDirectory
        self.finalOutput = finalOutput
        self.steps = steps
    }

    public func redactedForDisplay() -> PipelinePlan {
        let safeSteps = steps.map { step -> PipelineStep in
            guard case .command(let command) = step.operation else { return step }
            let safeCommand = CommandSpec(
                executable: command.executable,
                arguments: command.arguments,
                workingDirectory: command.workingDirectory,
                environment: command.environment,
                standardInput: nil
            )
            return PipelineStep(
                id: step.id,
                title: step.title,
                detail: step.detail,
                operation: .command(safeCommand)
            )
        }
        return PipelinePlan(
            id: id,
            kind: kind,
            name: name,
            rootDirectory: rootDirectory,
            finalOutput: finalOutput,
            steps: safeSteps
        )
    }
}

public enum PipelineEvent: Sendable {
    case stepStarted(index: Int, total: Int, step: PipelineStep)
    case log(String)
    case stepFinished(index: Int, step: PipelineStep)
    case finished
}
