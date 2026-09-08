import Foundation

public enum ProtectionProfile: String, CaseIterable, Codable, Sendable, Identifiable {
    case compatible
    case balanced
    case hardened
    case custom

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .compatible: return "兼容优先"
        case .balanced: return "均衡保护"
        case .hardened: return "高强度"
        case .custom: return "自定义"
        }
    }

    public var summary: String {
        switch self {
        case .compatible: return "只启用成熟、低风险的构建步骤"
        case .balanced: return "代码、资源与签名校验的推荐组合"
        case .hardened: return "加入 Native/DEX 外部保护，需充分回归"
        case .custom: return "逐项控制流水线"
        }
    }
}

public enum NativeToolchainKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case none
    case allvm
    case hikari
    case custom

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .none: return "系统 NDK"
        case .allvm: return "ALLVM"
        case .hikari: return "Hikari OLLVM"
        case .custom: return "自定义 NDK"
        }
    }
}

public struct SourceProtectionOptions: Sendable {
    public var projectURL: URL?
    public var outputDirectory: URL?
    public var moduleName: String
    public var variantName: String
    public var profile: ProtectionProfile
    public var createSafeCopy: Bool
    public var runClean: Bool
    public var enableR8Build: Bool
    public var enableResourceShrinking: Bool
    public var installR8HardeningRules: Bool
    public var runClassRename: Bool
    public var runResourceRename: Bool
    public var renameFileResources: Bool
    public var generateJunkCode: Bool
    public var runExternalGenerator: Bool
    public var nativeToolchain: NativeToolchainKind
    public var customNativeFlags: String
    public var collectArtifacts: Bool
    public var customGradleTasks: String

    public init(
        projectURL: URL? = nil,
        outputDirectory: URL? = nil,
        moduleName: String = "app",
        variantName: String = "Release",
        profile: ProtectionProfile = .balanced,
        createSafeCopy: Bool = true,
        runClean: Bool = false,
        enableR8Build: Bool = true,
        enableResourceShrinking: Bool = true,
        installR8HardeningRules: Bool = true,
        runClassRename: Bool = false,
        runResourceRename: Bool = false,
        renameFileResources: Bool = false,
        generateJunkCode: Bool = false,
        runExternalGenerator: Bool = false,
        nativeToolchain: NativeToolchainKind = .none,
        customNativeFlags: String = "",
        collectArtifacts: Bool = true,
        customGradleTasks: String = ""
    ) {
        self.projectURL = projectURL
        self.outputDirectory = outputDirectory
        self.moduleName = moduleName
        self.variantName = variantName
        self.profile = profile
        self.createSafeCopy = createSafeCopy
        self.runClean = runClean
        self.enableR8Build = enableR8Build
        self.enableResourceShrinking = enableResourceShrinking
        self.installR8HardeningRules = installR8HardeningRules
        self.runClassRename = runClassRename
        self.runResourceRename = runResourceRename
        self.renameFileResources = renameFileResources
        self.generateJunkCode = generateJunkCode
        self.runExternalGenerator = runExternalGenerator
        self.nativeToolchain = nativeToolchain
        self.customNativeFlags = customNativeFlags
        self.collectArtifacts = collectArtifacts
        self.customGradleTasks = customGradleTasks
    }
}

public struct APKProtectionOptions: Sendable {
    public var inputAPK: URL?
    public var outputDirectory: URL?
    public var outputName: String
    public var profile: ProtectionProfile
    public var verifyBefore: Bool
    public var useMocikaShield: Bool
    public var strictEnvironmentProtection: Bool
    public var zipalign: Bool
    public var signOutput: Bool
    public var verifyAfter: Bool
    public var keystoreURL: URL?
    public var keyAlias: String
    public var keystorePassword: String
    public var keyPassword: String

    public init(
        inputAPK: URL? = nil,
        outputDirectory: URL? = nil,
        outputName: String = "protected.apk",
        profile: ProtectionProfile = .balanced,
        verifyBefore: Bool = true,
        useMocikaShield: Bool = false,
        strictEnvironmentProtection: Bool = false,
        zipalign: Bool = true,
        signOutput: Bool = true,
        verifyAfter: Bool = true,
        keystoreURL: URL? = nil,
        keyAlias: String = "",
        keystorePassword: String = "",
        keyPassword: String = ""
    ) {
        self.inputAPK = inputAPK
        self.outputDirectory = outputDirectory
        self.outputName = outputName
        self.profile = profile
        self.verifyBefore = verifyBefore
        self.useMocikaShield = useMocikaShield
        self.strictEnvironmentProtection = strictEnvironmentProtection
        self.zipalign = zipalign
        self.signOutput = signOutput
        self.verifyAfter = verifyAfter
        self.keystoreURL = keystoreURL
        self.keyAlias = keyAlias
        self.keystorePassword = keystorePassword
        self.keyPassword = keyPassword
    }
}

public struct ToolPaths: Codable, Equatable, Sendable {
    public var androidSDK: String
    public var javaExecutable: String
    public var mocikaShieldCLI: String
    public var codeGeneratorExecutable: String
    public var protectedNDK: String

    public init(
        androidSDK: String = "",
        javaExecutable: String = "",
        mocikaShieldCLI: String = "",
        codeGeneratorExecutable: String = "",
        protectedNDK: String = ""
    ) {
        self.androidSDK = androidSDK
        self.javaExecutable = javaExecutable
        self.mocikaShieldCLI = mocikaShieldCLI
        self.codeGeneratorExecutable = codeGeneratorExecutable
        self.protectedNDK = protectedNDK
    }
}

public enum ToolAvailability: String, Codable, Sendable {
    case available
    case missing
    case optional
}

public enum ToolKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case java
    case androidSDK
    case apksigner
    case zipalign
    case adb
    case mocikaShield
    case codeGenerator
    case protectedNDK

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .java: return "Java Runtime"
        case .androidSDK: return "Android SDK"
        case .apksigner: return "APK Signer"
        case .zipalign: return "ZIP Align"
        case .adb: return "Android Debug Bridge"
        case .mocikaShield: return "Mocika Shield CLI"
        case .codeGenerator: return "代码生成器"
        case .protectedNDK: return "定制 NDK / LLVM"
        }
    }

    public var isRequired: Bool {
        switch self {
        case .java, .androidSDK, .apksigner, .zipalign: return true
        default: return false
        }
    }
}

public struct ToolStatus: Identifiable, Codable, Sendable {
    public let kind: ToolKind
    public let availability: ToolAvailability
    public let path: String?
    public let detail: String

    public var id: String { kind.id }

    public init(kind: ToolKind, availability: ToolAvailability, path: String?, detail: String) {
        self.kind = kind
        self.availability = availability
        self.path = path
        self.detail = detail
    }
}

public struct ProjectAnalysis: Sendable, Equatable {
    public var projectName: String
    public var hasGradleWrapper: Bool
    public var modules: [String]
    public var hasR8Configuration: Bool
    public var hasResourceShrinking: Bool
    public var hasClassResGuard: Bool
    public var hasNativeCode: Bool
    public var hasUnityIL2CPP: Bool
    public var warnings: [String]

    public init(
        projectName: String,
        hasGradleWrapper: Bool,
        modules: [String],
        hasR8Configuration: Bool,
        hasResourceShrinking: Bool,
        hasClassResGuard: Bool,
        hasNativeCode: Bool,
        hasUnityIL2CPP: Bool,
        warnings: [String]
    ) {
        self.projectName = projectName
        self.hasGradleWrapper = hasGradleWrapper
        self.modules = modules
        self.hasR8Configuration = hasR8Configuration
        self.hasResourceShrinking = hasResourceShrinking
        self.hasClassResGuard = hasClassResGuard
        self.hasNativeCode = hasNativeCode
        self.hasUnityIL2CPP = hasUnityIL2CPP
        self.warnings = warnings
    }
}

public enum JobKind: String, Codable, Sendable {
    case source
    case apk

    public var title: String { self == .source ? "源码保护" : "APK 加固" }
}

public enum JobStatus: String, Codable, Sendable {
    case running
    case succeeded
    case failed
    case cancelled
}

public struct JobRecord: Identifiable, Codable, Sendable {
    public let id: UUID
    public let kind: JobKind
    public let name: String
    public let startedAt: Date
    public var finishedAt: Date?
    public var status: JobStatus
    public var outputPath: String?
    public var summary: String

    public init(
        id: UUID = UUID(),
        kind: JobKind,
        name: String,
        startedAt: Date = Date(),
        finishedAt: Date? = nil,
        status: JobStatus = .running,
        outputPath: String? = nil,
        summary: String = ""
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.status = status
        self.outputPath = outputPath
        self.summary = summary
    }
}

public enum PipelineError: LocalizedError, Equatable {
    case invalidConfiguration(String)
    case missingTool(String)
    case commandFailed(title: String, exitCode: Int32)
    case certificateFingerprintMissing(String)
    case certificateMismatch(expected: [String], actual: [String])
    case cancelled
    case fileOperation(String)

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message): return message
        case .missingTool(let tool): return "缺少所需工具：\(tool)"
        case .commandFailed(let title, let code): return "\(title) 执行失败（退出码 \(code)）"
        case .certificateFingerprintMissing(let message): return message
        case .certificateMismatch(let expected, let actual):
            return "最终 APK 签名证书与输入 APK 不一致。期望 SHA-256：\(APKCertificateIdentity.display(expected))；实际：\(APKCertificateIdentity.display(actual))。已拒绝发布产物。"
        case .cancelled: return "任务已取消"
        case .fileOperation(let message): return message
        }
    }
}
