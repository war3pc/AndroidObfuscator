import Foundation

public struct LocatedToolchain: Sendable {
    public let statuses: [ToolStatus]
    public let java: URL?
    public let androidSDK: URL?
    public let apksigner: URL?
    public let zipalign: URL?
    public let adb: URL?
    public let mocikaShield: URL?
    public let codeGenerator: URL?
    public let protectedNDK: URL?

    public init(
        statuses: [ToolStatus],
        java: URL?,
        androidSDK: URL?,
        apksigner: URL?,
        zipalign: URL?,
        adb: URL?,
        mocikaShield: URL?,
        codeGenerator: URL?,
        protectedNDK: URL?
    ) {
        self.statuses = statuses
        self.java = java
        self.androidSDK = androidSDK
        self.apksigner = apksigner
        self.zipalign = zipalign
        self.adb = adb
        self.mocikaShield = mocikaShield
        self.codeGenerator = codeGenerator
        self.protectedNDK = protectedNDK
    }
}

public enum ToolchainLocator {
    public static func locate(paths: ToolPaths, environment: [String: String] = ProcessInfo.processInfo.environment) -> LocatedToolchain {
        let fileManager = FileManager.default

        let pathJava = executableInPath("java", environment: environment)
            .flatMap { $0.path == "/usr/bin/java" ? nil : $0 }
        let java = firstExecutable([
            nonEmptyURL(paths.javaExecutable),
            environment["JAVA_HOME"].map { URL(fileURLWithPath: $0).appendingPathComponent("bin/java") },
            installedJDKJava(),
            URL(fileURLWithPath: "/Applications/Android Studio.app/Contents/jbr/Contents/Home/bin/java"),
            URL(fileURLWithPath: "/Applications/Android Studio.app/Contents/jre/Contents/Home/bin/java"),
            pathJava
        ].compactMap { $0 })

        let sdkCandidates: [URL] = [
            nonEmptyURL(paths.androidSDK),
            environment["ANDROID_SDK_ROOT"].map(URL.init(fileURLWithPath:)),
            environment["ANDROID_HOME"].map(URL.init(fileURLWithPath:)),
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Android/sdk")
        ].compactMap { $0 }
        let sdk = sdkCandidates.first { isDirectory($0) }
        let buildToolsDirectory = sdk.flatMap(latestBuildToolsDirectory)
        let apksigner = buildToolsDirectory
            .map { $0.appendingPathComponent("apksigner") }
            .flatMap { isExecutable($0) ? $0 : nil }
        let zipalign = buildToolsDirectory
            .map { $0.appendingPathComponent("zipalign") }
            .flatMap { isExecutable($0) ? $0 : nil }
        let adb = sdk
            .map { $0.appendingPathComponent("platform-tools/adb") }
            .flatMap { isExecutable($0) ? $0 : nil }

        let mocika = firstExecutable([
            nonEmptyURL(paths.mocikaShieldCLI),
            bundledMocikaShield()
        ].compactMap { $0 })
        let generator = nonEmptyURL(paths.codeGeneratorExecutable).flatMap { isExecutable($0) ? $0 : nil }
        let ndkCandidate = nonEmptyURL(paths.protectedNDK).flatMap { isDirectory($0) ? $0 : nil }
        let ndkInspection = ndkCandidate.flatMap { try? NativeToolchainInspector.inspect(ndk: $0) }
        let ndk = ndkInspection?.root

        let statuses = [
            status(.java, java, found: "可用于 Gradle 与签名工具", missing: "请选择 JDK 的 java 可执行文件"),
            status(.androidSDK, sdk, found: "已发现本地 Android SDK", missing: "请选择 Android SDK 根目录", expectsDirectory: true),
            status(.apksigner, apksigner, found: buildToolsDetail(buildToolsDirectory), missing: "Android SDK Build Tools 中未找到 apksigner"),
            status(.zipalign, zipalign, found: buildToolsDetail(buildToolsDirectory), missing: "Android SDK Build Tools 中未找到 zipalign"),
            status(.adb, adb, found: "可用于后续真机验证", missing: "可选：安装 Android SDK Platform Tools"),
            status(
                .mocikaShield,
                mocika,
                found: isBundledMocikaShield(mocika) ? "内置 Mocika Shield 1.3.0（DEX 加密与壳保护）" : "已启用自定义 DEX 壳保护引擎",
                missing: "未找到内置引擎；也可选择源码编译得到的 shield CLI"
            ),
            status(.codeGenerator, generator, found: "以安全工作副本为当前目录执行；进程仍继承当前用户文件权限", missing: "可选：选择兼容的代码生成器"),
            status(
                .protectedNDK,
                ndk,
                found: ndkInspection?.revision.map { "NDK \($0)，clang 与 CMake 工具链结构有效" }
                    ?? "clang 与 CMake 工具链结构有效",
                missing: ndkCandidate == nil
                    ? "可选：选择 ALLVM/Hikari 等定制 NDK"
                    : "所选目录不是可执行的完整 Android NDK",
                expectsDirectory: true
            )
        ]

        return LocatedToolchain(
            statuses: statuses,
            java: java,
            androidSDK: sdk,
            apksigner: apksigner,
            zipalign: zipalign,
            adb: adb,
            mocikaShield: mocika,
            codeGenerator: generator,
            protectedNDK: ndk
        )
    }

    private static func nonEmptyURL(_ path: String) -> URL? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : URL(fileURLWithPath: trimmed)
    }

    private static func firstExecutable(_ urls: [URL]) -> URL? {
        urls.first { $0.path != "/usr/bin/java" && isExecutable($0) }
    }

    private static func bundledMocikaShield() -> URL? {
        // The checked-in CLI is built for Apple Silicon.  Keeping the rest of
        // the app architecture-neutral lets Intel users select a compatible
        // custom CLI instead of surfacing a binary that cannot be launched.
        #if arch(arm64)
        Bundle.main.resourceURL?
            .appendingPathComponent("MocikaShield/bin/shield")
        #else
        nil
        #endif
    }

    private static func isBundledMocikaShield(_ url: URL?) -> Bool {
        guard let url, let resources = Bundle.main.resourceURL else { return false }
        return url.standardizedFileURL.path.hasPrefix(
            resources.appendingPathComponent("MocikaShield").standardizedFileURL.path + "/"
        )
    }

    private static func isExecutable(_ url: URL) -> Bool {
        FileManager.default.isExecutableFile(atPath: url.path)
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private static func executableInPath(_ name: String, environment: [String: String]) -> URL? {
        guard let path = environment["PATH"] else { return nil }
        return path.split(separator: ":")
            .map { URL(fileURLWithPath: String($0)).appendingPathComponent(name) }
            .first(where: isExecutable)
    }

    private static func installedJDKJava() -> URL? {
        let fileManager = FileManager.default
        let roots = [
            URL(fileURLWithPath: "/Library/Java/JavaVirtualMachines", isDirectory: true),
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Java/JavaVirtualMachines", isDirectory: true)
        ]
        for root in roots {
            guard let entries = try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for entry in entries.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) {
                let candidate = entry.appendingPathComponent("Contents/Home/bin/java")
                if isExecutable(candidate) { return candidate }
            }
        }
        return nil
    }

    private static func latestBuildToolsDirectory(sdk: URL) -> URL? {
        let root = sdk.appendingPathComponent("build-tools", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        return entries
            .filter(isDirectory)
            .sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending }
            .first
    }

    private static func buildToolsDetail(_ url: URL?) -> String {
        guard let url else { return "已发现 Android SDK Build Tools" }
        return "Build Tools \(url.lastPathComponent)"
    }

    private static func status(
        _ kind: ToolKind,
        _ url: URL?,
        found: String,
        missing: String,
        expectsDirectory: Bool = false
    ) -> ToolStatus {
        let availability: ToolAvailability = url == nil ? (kind.isRequired ? .missing : .optional) : .available
        return ToolStatus(kind: kind, availability: availability, path: url?.path, detail: url == nil ? missing : found)
    }
}
