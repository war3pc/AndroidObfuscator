import Foundation

public enum ProjectAnalyzer {
    public static func analyze(projectURL: URL) -> ProjectAnalysis {
        let fileManager = FileManager.default
        let gradlew = projectURL.appendingPathComponent("gradlew")
        let hasGradleWrapper = fileManager.fileExists(atPath: gradlew.path)
        let modules = discoverModules(projectURL: projectURL)
        let gradleText = relevantBuildText(projectURL: projectURL, modules: modules)
        let normalized = normalizedBuildText(gradleText)

        let hasR8 = normalized.contains("minifyenabledtrue") || normalized.contains("isminifyenabled=true")
        let hasShrink = normalized.contains("shrinkresourcestrue") || normalized.contains("isshrinkresources=true")
        let hasGuard = gradleText.localizedCaseInsensitiveContains("class-res-guard") ||
            gradleText.localizedCaseInsensitiveContains("classResGuard")
        let hasNative = modules.contains { module in
            ["src/main/cpp", "src/main/jni", "src/main/jniLibs"].contains { relative in
                isDirectory(projectURL.appendingPathComponent(module).appendingPathComponent(relative))
            }
        }
        let hasUnity = modules.contains { module in
            fileManager.fileExists(
                atPath: projectURL
                    .appendingPathComponent(module)
                    .appendingPathComponent("src/main/assets/bin/Data/Managed/Metadata/global-metadata.dat")
                    .path
            )
        } || fileManager.fileExists(atPath: projectURL.appendingPathComponent("unityLibrary").path)

        var warnings: [String] = []
        if !hasGradleWrapper { warnings.append("未找到 gradlew，无法复现项目锁定的 Gradle 版本。") }
        if !hasR8 { warnings.append("未检测到 Release 的 minifyEnabled；执行构建不代表代码已经由 R8 混淆。") }
        if !hasShrink { warnings.append("未检测到 shrinkResources；未使用资源仍可能保留在产物中。") }
        if hasGuard { warnings.append("ClassResGuard 会重命名源码/资源，应用只会在安全工作副本中运行它。") }
        if hasNative { warnings.append("检测到 Native 模块；更换 NDK/LLVM 后必须覆盖所有 ABI 做真机回归。") }
        if hasUnity { warnings.append("检测到 Unity/IL2CPP；元数据保护必须与 Unity 运行时插件成对集成。") }

        return ProjectAnalysis(
            projectName: projectURL.lastPathComponent,
            hasGradleWrapper: hasGradleWrapper,
            modules: modules,
            hasR8Configuration: hasR8,
            hasResourceShrinking: hasShrink,
            hasClassResGuard: hasGuard,
            hasNativeCode: hasNative,
            hasUnityIL2CPP: hasUnity,
            warnings: warnings
        )
    }

    private static func discoverModules(projectURL: URL) -> [String] {
        let candidates = ["settings.gradle.kts", "settings.gradle"]
        var discovered: [String] = []

        for file in candidates {
            let url = projectURL.appendingPathComponent(file)
            guard let text = readSmallTextFile(url) else { continue }
            let pattern = #"[\"'](:[A-Za-z0-9_.:-]+)[\"']"#
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            regex.enumerateMatches(in: text, range: range) { match, _, _ in
                guard let match, let swiftRange = Range(match.range(at: 1), in: text) else { return }
                let modulePath = text[swiftRange]
                    .trimmingCharacters(in: CharacterSet(charactersIn: ":"))
                    .replacingOccurrences(of: ":", with: "/")
                if !modulePath.isEmpty { discovered.append(modulePath) }
            }
        }

        if discovered.isEmpty && isDirectory(projectURL.appendingPathComponent("app")) {
            discovered.append("app")
        }
        return Array(Set(discovered)).sorted()
    }

    private static func relevantBuildText(projectURL: URL, modules: [String]) -> String {
        let rootFiles = ["build.gradle", "build.gradle.kts", "gradle.properties"]
        let moduleFiles = modules.flatMap { module in
            ["build.gradle", "build.gradle.kts", "proguard-rules.pro"].map { "\(module)/\($0)" }
        }
        return (rootFiles + moduleFiles)
            .compactMap { readSmallTextFile(projectURL.appendingPathComponent($0)) }
            .joined(separator: "\n")
    }

    private static func normalizedBuildText(_ text: String) -> String {
        // This is a read-only preflight, not a Gradle source rewrite.  Ignore
        // commented examples and formatting differences so they do not count
        // as enabled release protection.
        var uncommented = text
        if let blockComments = try? NSRegularExpression(pattern: #"/\*[\s\S]*?\*/"#) {
            uncommented = blockComments.stringByReplacingMatches(
                in: uncommented,
                range: NSRange(uncommented.startIndex..., in: uncommented),
                withTemplate: ""
            )
        }
        uncommented = uncommented
            .components(separatedBy: .newlines)
            .map { line in
                guard let marker = line.range(of: "//") else { return line }
                return String(line[..<marker.lowerBound])
            }
            .joined(separator: "\n")
        return uncommented
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
            .lowercased()
    }

    private static func readSmallTextFile(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let data = try? handle.read(upToCount: 2_000_000)
        return data.flatMap { String(data: $0, encoding: .utf8) }
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var value: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &value) && value.boolValue
    }
}
