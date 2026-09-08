import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers
import AndroidObfuscatorCore

enum AppSection: String, CaseIterable, Identifiable {
    case overview
    case source
    case apk
    case retrace
    case toolchain
    case history
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "总览"
        case .source: return "源码保护"
        case .apk: return "APK 加固"
        case .retrace: return "堆栈还原"
        case .toolchain: return "工具链"
        case .history: return "任务记录"
        case .about: return "参考与边界"
        }
    }

    var symbol: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .source: return "curlybraces.square"
        case .apk: return "shippingbox.fill"
        case .retrace: return "text.magnifyingglass"
        case .toolchain: return "wrench.and.screwdriver"
        case .history: return "clock.arrow.circlepath"
        case .about: return "info.circle"
        }
    }

    var group: String {
        switch self {
        case .overview: return "工作台"
        case .source, .apk, .retrace: return "保护与验证"
        case .toolchain, .history, .about: return "管理"
        }
    }
}

struct ActiveJobViewState: Identifiable {
    let id: UUID
    let plan: PipelinePlan
    var currentStepIndex: Int
    var currentStepTitle: String
    var completedSteps: Set<UUID>
    var log: String
    var status: JobStatus
    var errorMessage: String?

    var progress: Double {
        guard !plan.steps.isEmpty else { return 0 }
        if status == .succeeded { return 1 }
        return Double(completedSteps.count) / Double(plan.steps.count)
    }

    var isRunning: Bool { status == .running }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var selection: AppSection = .overview
    @Published var sourceOptions = SourceProtectionOptions()
    @Published var apkOptions = APKProtectionOptions()
    @Published var sourceAnalysis: ProjectAnalysis?
    @Published var toolPaths: ToolPaths
    @Published var toolchain: LocatedToolchain
    @Published var history: [JobRecord]
    @Published var activeJob: ActiveJobViewState?
    @Published var showJobPanel = false
    @Published var authorizationAccepted = false
    @Published var lastError: String?

    private let historyStore = HistoryStore()
    private let executor = PipelineExecutor()
    private var runningTask: Task<Void, Never>?
    private static let toolPathsKey = "toolPaths.v1"

    init() {
        let paths: ToolPaths
        if let data = UserDefaults.standard.data(forKey: Self.toolPathsKey),
           let decoded = try? JSONDecoder().decode(ToolPaths.self, from: data) {
            paths = decoded
        } else {
            paths = ToolPaths()
        }
        self.toolPaths = paths
        self.toolchain = ToolchainLocator.locate(paths: paths)
        self.history = historyStore.load()
        self.apkOptions.useMocikaShield = self.toolchain.mocikaShield != nil
    }

    var isRunning: Bool { activeJob?.isRunning == true }

    var requiredToolsReady: Bool {
        !toolchain.statuses.contains { $0.kind.isRequired && $0.availability == .missing }
    }

    func refreshToolchain() {
        toolchain = ToolchainLocator.locate(paths: toolPaths)
        if apkOptions.profile != .custom {
            applyAPKProfile(apkOptions.profile)
        }
    }

    func updateToolPath(_ keyPath: WritableKeyPath<ToolPaths, String>, to path: String) {
        toolPaths[keyPath: keyPath] = path
        if let data = try? JSONEncoder().encode(toolPaths) {
            UserDefaults.standard.set(data, forKey: Self.toolPathsKey)
        }
        refreshToolchain()
    }

    func chooseSourceProject() {
        guard let url = chooseDirectory(title: "选择 Android 工程", prompt: "选择工程") else { return }
        sourceOptions.projectURL = url
        sourceAnalysis = ProjectAnalyzer.analyze(projectURL: url)
        if let first = sourceAnalysis?.modules.first {
            sourceOptions.moduleName = first
        }
        if sourceOptions.outputDirectory == nil {
            sourceOptions.outputDirectory = url.deletingLastPathComponent()
        }
        let canRunClassResGuard = sourceAnalysis?.hasClassResGuard == true
            && sourceOptions.profile != .compatible
        sourceOptions.runClassRename = canRunClassResGuard
        sourceOptions.runResourceRename = canRunClassResGuard
    }

    func chooseSourceOutput() {
        sourceOptions.outputDirectory = chooseDirectory(title: "选择源码保护输出目录", prompt: "选择输出")
    }

    func chooseAPK() {
        guard let url = chooseFile(title: "选择 APK", prompt: "选择 APK", extensions: ["apk"]) else { return }
        apkOptions.inputAPK = url
        apkOptions.outputName = url.deletingPathExtension().lastPathComponent + "-protected.apk"
        if apkOptions.outputDirectory == nil {
            apkOptions.outputDirectory = url.deletingLastPathComponent()
        }
    }

    func chooseAPKOutput() {
        apkOptions.outputDirectory = chooseDirectory(title: "选择 APK 输出目录", prompt: "选择输出")
    }

    func chooseKeystore() {
        apkOptions.keystoreURL = chooseFile(
            title: "选择 Android Keystore",
            prompt: "选择证书",
            extensions: ["jks", "keystore", "p12", "pfx"]
        )
    }

    func chooseAndroidSDK() {
        guard let url = chooseDirectory(title: "选择 Android SDK 根目录", prompt: "选择 SDK") else { return }
        updateToolPath(\ToolPaths.androidSDK, to: url.path)
    }

    func chooseJava() {
        guard let url = chooseFile(title: "选择 java 可执行文件", prompt: "选择 Java") else { return }
        updateToolPath(\ToolPaths.javaExecutable, to: url.path)
    }

    func chooseMocikaShield() {
        guard let url = chooseFile(title: "选择 Mocika Shield CLI", prompt: "选择 shield") else { return }
        updateToolPath(\ToolPaths.mocikaShieldCLI, to: url.path)
    }

    func chooseCodeGenerator() {
        guard let url = chooseFile(title: "选择代码生成器", prompt: "选择工具") else { return }
        updateToolPath(\ToolPaths.codeGeneratorExecutable, to: url.path)
    }

    func chooseProtectedNDK() {
        guard let url = chooseDirectory(title: "选择定制 NDK 根目录", prompt: "选择 NDK") else { return }
        updateToolPath(\ToolPaths.protectedNDK, to: url.path)
    }

    func applySourceProfile(_ profile: ProtectionProfile) {
        sourceOptions.profile = profile
        switch profile {
        case .compatible:
            sourceOptions.enableR8Build = true
            sourceOptions.installR8HardeningRules = false
            sourceOptions.renameFileResources = false
            sourceOptions.runClassRename = false
            sourceOptions.runResourceRename = false
            sourceOptions.generateJunkCode = false
            sourceOptions.runExternalGenerator = false
            sourceOptions.nativeToolchain = .none
            sourceOptions.customNativeFlags = ""
        case .balanced:
            sourceOptions.enableR8Build = true
            sourceOptions.installR8HardeningRules = true
            sourceOptions.renameFileResources = false
            sourceOptions.runClassRename = sourceAnalysis?.hasClassResGuard == true
            sourceOptions.runResourceRename = sourceAnalysis?.hasClassResGuard == true
            sourceOptions.generateJunkCode = false
            sourceOptions.runExternalGenerator = false
            sourceOptions.nativeToolchain = .none
        case .hardened:
            sourceOptions.enableR8Build = true
            sourceOptions.installR8HardeningRules = true
            sourceOptions.renameFileResources = true
            sourceOptions.runClassRename = sourceAnalysis?.hasClassResGuard == true
            sourceOptions.runResourceRename = sourceAnalysis?.hasClassResGuard == true
            sourceOptions.generateJunkCode = true
            sourceOptions.runExternalGenerator = toolchain.codeGenerator != nil
            sourceOptions.nativeToolchain = toolchain.protectedNDK == nil ? .none : .custom
            if sourceOptions.nativeToolchain == .custom,
               sourceOptions.customNativeFlags.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                sourceOptions.customNativeFlags = "-mllvm -fla -mllvm -sub"
            }
        case .custom:
            break
        }
    }

    func applyAPKProfile(_ profile: ProtectionProfile) {
        apkOptions.profile = profile
        switch profile {
        case .compatible:
            apkOptions.verifyBefore = true
            apkOptions.useMocikaShield = false
            apkOptions.strictEnvironmentProtection = false
            apkOptions.zipalign = true
            apkOptions.signOutput = true
            apkOptions.verifyAfter = true
        case .balanced:
            apkOptions.verifyBefore = true
            apkOptions.useMocikaShield = toolchain.mocikaShield != nil
            apkOptions.strictEnvironmentProtection = false
            apkOptions.zipalign = true
            apkOptions.signOutput = true
            apkOptions.verifyAfter = true
        case .hardened:
            apkOptions.verifyBefore = true
            apkOptions.useMocikaShield = toolchain.mocikaShield != nil
            apkOptions.strictEnvironmentProtection = true
            apkOptions.zipalign = true
            apkOptions.signOutput = true
            apkOptions.verifyAfter = true
        case .custom:
            break
        }
    }

    func sourcePreview() -> Result<PipelinePlan, Error> {
        Result { try PipelinePlanner.sourcePlan(options: sourceOptions, toolchain: toolchain).redactedForDisplay() }
    }

    func apkPreview() -> Result<PipelinePlan, Error> {
        Result { try PipelinePlanner.apkPlan(options: apkOptions, toolchain: toolchain).redactedForDisplay() }
    }

    func startSourceJob() {
        guard ensureAuthorized() else { return }
        do {
            run(try PipelinePlanner.sourcePlan(options: sourceOptions, toolchain: toolchain))
        } catch {
            lastError = error.localizedDescription
        }
    }

    func startAPKJob() {
        guard ensureAuthorized() else { return }
        do {
            run(try PipelinePlanner.apkPlan(options: apkOptions, toolchain: toolchain))
        } catch {
            lastError = error.localizedDescription
        }
    }

    func cancelJob() {
        runningTask?.cancel()
        executor.cancel()
    }

    func revealOutput() {
        guard let path = activeJob?.plan.finalOutput?.path else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func clearFinishedJobPanel() {
        guard activeJob?.isRunning != true else { return }
        showJobPanel = false
    }

    private func ensureAuthorized() -> Bool {
        guard authorizationAccepted else {
            lastError = "请先确认你拥有所选 Android 工程或 APK 的合法处理权限。"
            return false
        }
        guard !isRunning else {
            lastError = "已有任务正在运行。"
            return false
        }
        return true
    }

    private func run(_ plan: PipelinePlan) {
        activeJob = ActiveJobViewState(
            id: plan.id,
            plan: plan.redactedForDisplay(),
            currentStepIndex: 0,
            currentStepTitle: "准备开始",
            completedSteps: [],
            log: "任务目录：\(plan.rootDirectory.path)\n",
            status: .running,
            errorMessage: nil
        )
        showJobPanel = true

        var record = JobRecord(
            id: plan.id,
            kind: plan.kind,
            name: plan.name,
            status: .running,
            outputPath: plan.finalOutput?.path
        )
        history.insert(record, at: 0)
        persistHistory()

        runningTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if plan.kind == .apk {
                    apkOptions.keystorePassword = ""
                    apkOptions.keyPassword = ""
                }
            }
            do {
                try await executor.execute(plan) { [weak self] event in
                    Task { @MainActor [weak self] in self?.handle(event) }
                }
                record.status = .succeeded
                record.finishedAt = Date()
                record.summary = "完成 \(plan.steps.count) 个步骤"
                finish(record: record, error: nil)
            } catch {
                let cancelled = error as? PipelineError == .cancelled || Task.isCancelled
                record.status = cancelled ? .cancelled : .failed
                record.finishedAt = Date()
                record.summary = cancelled ? "用户取消" : error.localizedDescription
                finish(record: record, error: cancelled ? nil : error.localizedDescription)
            }
        }
    }

    private func handle(_ event: PipelineEvent) {
        guard activeJob?.isRunning == true else { return }
        switch event {
        case .stepStarted(let index, _, let step):
            activeJob?.currentStepIndex = index
            activeJob?.currentStepTitle = step.title
        case .log(let chunk):
            activeJob?.log.append(chunk)
            if let count = activeJob?.log.count, count > 300_000 {
                activeJob?.log.removeFirst(count - 250_000)
                activeJob?.log.insert(contentsOf: "…较早日志已折叠…\n", at: activeJob!.log.startIndex)
            }
        case .stepFinished(_, let step):
            activeJob?.completedSteps.insert(step.id)
        case .finished:
            break
        }
    }

    private func finish(record: JobRecord, error: String?) {
        guard let index = history.firstIndex(where: { $0.id == record.id }) else { return }
        history[index] = record
        activeJob?.status = record.status
        activeJob?.errorMessage = error
        if record.status == .succeeded {
            activeJob?.completedSteps = Set(activeJob?.plan.steps.map(\PipelineStep.id) ?? [])
            activeJob?.currentStepTitle = "处理完成"
        } else if record.status == .cancelled {
            activeJob?.currentStepTitle = "任务已取消"
        } else {
            activeJob?.currentStepTitle = "任务失败"
        }
        persistHistory()
        runningTask = nil
    }

    private func persistHistory() {
        try? historyStore.save(history)
    }

    private func chooseDirectory(title: String, prompt: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = prompt
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func chooseFile(title: String, prompt: String, extensions: [String] = []) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = prompt
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if !extensions.isEmpty {
            panel.allowedContentTypes = extensions.compactMap { UTType(filenameExtension: $0) }
        }
        return panel.runModal() == .OK ? panel.url : nil
    }
}
