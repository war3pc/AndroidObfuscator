import Foundation

public struct BuiltInSourceProtectionConfiguration: Sendable, Equatable {
    public var moduleName: String
    public var generateCodeAndResources: Bool
    public var installR8Rules: Bool
    public var renameFileResources: Bool
    public var generatedClassCount: Int
    public var methodsPerClass: Int
    public var seed: UInt64

    public init(
        moduleName: String,
        generateCodeAndResources: Bool,
        installR8Rules: Bool,
        renameFileResources: Bool,
        generatedClassCount: Int = 8,
        methodsPerClass: Int = 6,
        seed: UInt64
    ) {
        self.moduleName = moduleName
        self.generateCodeAndResources = generateCodeAndResources
        self.installR8Rules = installR8Rules
        self.renameFileResources = renameFileResources
        self.generatedClassCount = max(1, min(generatedClassCount, 64))
        self.methodsPerClass = max(1, min(methodsPerClass, 32))
        self.seed = seed
    }

    public var preview: String {
        var parts: [String] = []
        if generateCodeAndResources { parts.append("生成代码/资源") }
        if installR8Rules { parts.append("写入 R8 规则") }
        if renameFileResources { parts.append("资源文件改名并同步引用") }
        return parts.isEmpty ? "不执行内置变换" : parts.joined(separator: " · ")
    }
}

public struct ResourceRenameRecord: Codable, Sendable, Equatable {
    public let type: String
    public let originalName: String
    public let protectedName: String
}

public struct BuiltInSourceProtectionReport: Codable, Sendable, Equatable {
    public let namespace: String
    public let generatedSourceFiles: Int
    public let generatedResourceFiles: Int
    public let renamedResources: Int
    public let r8RulesInstalled: Bool
    public let resourceMapping: [ResourceRenameRecord]
    public let warnings: [String]
}

public enum BuiltInSourceProtector {
    private static let markerStart = "# BEGIN AndroidObfuscator built-in protection"
    private static let markerEnd = "# END AndroidObfuscator built-in protection"

    public static func apply(
        project: URL,
        configuration: BuiltInSourceProtectionConfiguration,
        fileManager: FileManager = .default
    ) throws -> BuiltInSourceProtectionReport {
        let module = moduleURL(project: project, name: configuration.moduleName)
        guard fileManager.fileExists(atPath: module.path) else {
            throw PipelineError.fileOperation("找不到应用模块：\(module.path)")
        }
        let main = module.appendingPathComponent("src/main", isDirectory: true)
        guard fileManager.fileExists(atPath: main.path) else {
            throw PipelineError.fileOperation("模块中缺少 src/main：\(module.path)")
        }
        guard let namespace = discoverNamespace(module: module, main: main), isValidPackage(namespace) else {
            throw PipelineError.invalidConfiguration("无法从 namespace、applicationId 或 AndroidManifest.xml 确定有效包名。")
        }

        var warnings: [String] = []
        var mapping: [ResourceRenameRecord] = []
        if configuration.renameFileResources {
            mapping = try renameResources(
                project: project,
                module: module,
                main: main,
                seed: configuration.seed,
                fileManager: fileManager,
                warnings: &warnings
            )
        }

        var generatedSources = 0
        var generatedResources = 0
        if configuration.generateCodeAndResources {
            let result = try generateCodeAndResources(
                main: main,
                namespace: namespace,
                classCount: configuration.generatedClassCount,
                methodsPerClass: configuration.methodsPerClass,
                seed: configuration.seed,
                fileManager: fileManager
            )
            generatedSources = result.sources
            generatedResources = result.resources
        }

        var rulesInstalled = false
        if configuration.installR8Rules {
            rulesInstalled = try installR8Rules(module: module, namespace: namespace, fileManager: fileManager)
            if !buildScripts(in: module).contains(where: { ($0.text ?? "").contains("proguard-rules.pro") }) {
                warnings.append("已生成 proguard-rules.pro，但模块构建脚本未明确引用它；请确认 release 的 proguardFiles 配置。")
            }
        }

        let report = BuiltInSourceProtectionReport(
            namespace: namespace,
            generatedSourceFiles: generatedSources,
            generatedResourceFiles: generatedResources,
            renamedResources: mapping.count,
            r8RulesInstalled: rulesInstalled,
            resourceMapping: mapping,
            warnings: warnings
        )
        try writeReports(report, project: project, fileManager: fileManager)
        return report
    }

    private static func moduleURL(project: URL, name: String) -> URL {
        let cleaned = name
            .trimmingCharacters(in: CharacterSet(charactersIn: " :\n\t"))
            .replacingOccurrences(of: ":", with: "/")
        return project.appendingPathComponent(cleaned.isEmpty ? "app" : cleaned, isDirectory: true)
    }

    private static func discoverNamespace(module: URL, main: URL) -> String? {
        let patterns = [
            #"\bnamespace\s*(?:=\s*)?[\"']([^\"']+)[\"']"#,
            #"\bapplicationId\s*(?:=\s*)?[\"']([^\"']+)[\"']"#
        ]
        for script in buildScripts(in: module) {
            guard let text = script.text else { continue }
            for pattern in patterns {
                if let value = firstCapture(pattern: pattern, text: text) { return value }
            }
        }
        let manifest = main.appendingPathComponent("AndroidManifest.xml")
        if let text = try? String(contentsOf: manifest, encoding: .utf8) {
            return firstCapture(pattern: #"\bpackage\s*=\s*[\"']([^\"']+)[\"']"#, text: text)
        }
        return nil
    }

    private static func buildScripts(in module: URL) -> [(url: URL, text: String?)] {
        ["build.gradle.kts", "build.gradle"].map { name in
            let url = module.appendingPathComponent(name)
            return (url, try? String(contentsOf: url, encoding: .utf8))
        }
    }

    private static func firstCapture(pattern: String, text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    private static func isValidPackage(_ value: String) -> Bool {
        let pattern = #"^[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)+$"#
        return value.range(of: pattern, options: .regularExpression) != nil
    }

    private static func generateCodeAndResources(
        main: URL,
        namespace: String,
        classCount: Int,
        methodsPerClass: Int,
        seed: UInt64,
        fileManager: FileManager
    ) throws -> (sources: Int, resources: Int) {
        var generator = StableGenerator(seed: seed)
        let generatedPackage = namespace + ".aog.generated"
        let javaDirectory = main
            .appendingPathComponent("java", isDirectory: true)
            .appendingPathComponent(generatedPackage.replacingOccurrences(of: ".", with: "/"), isDirectory: true)
        let valuesDirectory = main.appendingPathComponent("res/values", isDirectory: true)
        let drawableDirectory = main.appendingPathComponent("res/drawable", isDirectory: true)
        try fileManager.createDirectory(at: javaDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: valuesDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: drawableDirectory, withIntermediateDirectories: true)

        var classNames: [String] = []
        var resourceNames: [String] = []
        for index in 0..<classCount {
            let token = generator.identifier(length: 9)
            let className = "Aog" + token.prefix(1).uppercased() + token.dropFirst() + "\(index)"
            let resourceName = "aog_\(token.lowercased())_\(index)"
            classNames.append(className)
            resourceNames.append(resourceName)
            let source = javaClass(
                package: generatedPackage,
                className: className,
                methods: methodsPerClass,
                generator: &generator
            )
            try writeNew(source, to: javaDirectory.appendingPathComponent(className + ".java"), fileManager: fileManager)
        }

        let anchor = javaAnchor(
            package: generatedPackage,
            namespace: namespace,
            classNames: classNames,
            resourceNames: resourceNames
        )
        try writeNew(anchor, to: javaDirectory.appendingPathComponent("AndroidObfuscatorAnchor.java"), fileManager: fileManager)

        var values = "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<resources>\n"
        for (index, name) in resourceNames.enumerated() {
            values += "    <string name=\"\(name)_text\" translatable=\"false\">guard-\(generator.hex(length: 18))-\(index)</string>\n"
            values += "    <color name=\"\(name)_color\">#\(generator.hex(length: 8).uppercased())</color>\n"
        }
        values += "</resources>\n"
        try writeNew(values, to: valuesDirectory.appendingPathComponent("aog_generated_values.xml"), fileManager: fileManager)

        for name in resourceNames {
            let drawable = """
            <?xml version="1.0" encoding="utf-8"?>
            <shape xmlns:android="http://schemas.android.com/apk/res/android" android:shape="rectangle">
                <corners android:radius="\(generator.nextInt(in: 2...18))dp" />
                <solid android:color="@color/\(name)_color" />
                <size android:width="1dp" android:height="1dp" />
            </shape>
            """ + "\n"
            try writeNew(drawable, to: drawableDirectory.appendingPathComponent(name + "_shape.xml"), fileManager: fileManager)
        }
        return (classNames.count + 1, resourceNames.count + 1)
    }

    private static func javaClass(
        package: String,
        className: String,
        methods: Int,
        generator: inout StableGenerator
    ) -> String {
        var body = "package \(package);\n\npublic final class \(className) {\n"
        body += "    private \(className)() {}\n\n"
        for index in 0..<methods {
            let constantA = generator.nextInt(in: 1_000...2_000_000_000)
            let constantB = generator.nextInt(in: 1_000...2_000_000_000)
            let rotation = generator.nextInt(in: 3...27)
            body += """
                public static int fold\(index)(int input) {
                    int value = input ^ \(constantA);
                    value = Integer.rotateLeft(value + \(constantB), \(rotation));
                    value ^= (value >>> \(generator.nextInt(in: 2...13)));
                    return value;
                }

            """
        }
        body += "    public static String marker() { return Integer.toHexString(fold0(\(generator.nextInt(in: 1...Int(Int32.max))))); }\n"
        body += "}\n"
        return body
    }

    private static func javaAnchor(
        package: String,
        namespace: String,
        classNames: [String],
        resourceNames: [String]
    ) -> String {
        var body = "package \(package);\n\nimport \(namespace).R;\n\n"
        body += "public final class AndroidObfuscatorAnchor {\n    private AndroidObfuscatorAnchor() {}\n\n"
        body += "    public static int touch() {\n        int value = 0;\n"
        for (index, item) in classNames.enumerated() {
            body += "        value ^= \(item).fold0(R.string.\(resourceNames[index])_text);\n"
            body += "        value ^= R.color.\(resourceNames[index])_color;\n"
            body += "        value ^= R.drawable.\(resourceNames[index])_shape;\n"
        }
        body += "        return value;\n    }\n\n"
        body += "    public static String marker() { return \(classNames.map { "\($0).marker()" }.joined(separator: " + ")) ; }\n"
        body += "}\n"
        return body
    }

    private static func installR8Rules(module: URL, namespace: String, fileManager: FileManager) throws -> Bool {
        let url = module.appendingPathComponent("proguard-rules.pro")
        var contents = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        if contents.contains(markerStart), contents.contains(markerEnd) { return false }
        if !contents.isEmpty, !contents.hasSuffix("\n") { contents += "\n" }
        contents += """
        \(markerStart)
        -keep,allowoptimization,allowobfuscation class \(namespace).aog.generated.** { *; }
        -keepattributes SourceFile,LineNumberTable
        -renamesourcefileattribute SourceFile
        \(markerEnd)
        """ + "\n"
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return true
    }

    private static func renameResources(
        project: URL,
        module: URL,
        main: URL,
        seed: UInt64,
        fileManager: FileManager,
        warnings: inout [String]
    ) throws -> [ResourceRenameRecord] {
        let res = main.appendingPathComponent("res", isDirectory: true)
        guard fileManager.fileExists(atPath: res.path) else {
            warnings.append("模块没有 src/main/res，跳过资源文件改名。")
            return []
        }
        let supportedTypes: Set<String> = [
            "anim", "animator", "color", "drawable", "font", "interpolator", "layout",
            "menu", "mipmap", "navigation", "raw", "transition", "xml"
        ]
        // Dynamic name lookups may live in a sibling library, so audit the whole
        // project before renaming.  Actual reference rewrites must stay inside
        // the selected module: two Android modules may legally define resources
        // with the same type/name and use distinct generated R classes.
        let auditTextFiles = loadTextFiles(root: project, fileManager: fileManager)
        let moduleTextFiles = loadTextFiles(root: module, fileManager: fileManager)
        var groups: [String: (type: String, name: String, files: [(url: URL, suffix: String)])] = [:]
        let keys: [URLResourceKey] = [.isRegularFileKey]
        if let enumerator = fileManager.enumerator(at: res, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) {
            for case let url as URL in enumerator {
                guard (try? url.resourceValues(forKeys: Set(keys)).isRegularFile) == true else { continue }
                let directoryName = url.deletingLastPathComponent().lastPathComponent
                guard let type = directoryName.split(separator: "-").first.map(String.init), supportedTypes.contains(type),
                      let parts = resourceFileParts(url), !parts.name.hasPrefix("aog_") else { continue }
                let key = type + "\u{0}" + parts.name
                if groups[key] == nil { groups[key] = (type, parts.name, []) }
                groups[key]?.files.append((url, parts.suffix))
            }
        }

        var used: [String: Set<String>] = [:]
        var plans: [(record: ResourceRenameRecord, files: [(source: URL, destination: URL)])] = []
        for key in groups.keys.sorted() {
            guard let group = groups[key] else { continue }
            if hasDynamicReference(type: group.type, name: group.name, textFiles: auditTextFiles) {
                warnings.append("资源 \(group.type)/\(group.name) 存在 getIdentifier 或 public.xml 固定名称，已跳过。")
                continue
            }
            var protectedName = "aog_" + stableHex("\(seed):\(group.type):\(group.name)", length: 10)
            var suffixNumber = 2
            while used[group.type, default: []].contains(protectedName) {
                protectedName = "aog_" + stableHex("\(seed):\(group.type):\(group.name):\(suffixNumber)", length: 10)
                suffixNumber += 1
            }
            used[group.type, default: []].insert(protectedName)
            let destinations = group.files.map { item in
                (item.url, item.url.deletingLastPathComponent().appendingPathComponent(protectedName + item.suffix))
            }
            for pair in destinations where fileManager.fileExists(atPath: pair.1.path) {
                throw PipelineError.fileOperation("资源改名目标已存在：\(pair.1.path)")
            }
            plans.append((
                ResourceRenameRecord(type: group.type, originalName: group.name, protectedName: protectedName),
                destinations
            ))
        }

        let records = plans.map(\.record)
        var changedTexts: [(url: URL, original: String)] = []
        var moved: [(source: URL, destination: URL)] = []
        do {
            for item in moduleTextFiles {
                let updated = replaceReferences(in: item.text, records: records)
                guard updated != item.text else { continue }
                try updated.write(to: item.url, atomically: true, encoding: .utf8)
                changedTexts.append((item.url, item.text))
            }
            for plan in plans {
                for pair in plan.files {
                    try fileManager.moveItem(at: pair.source, to: pair.destination)
                    moved.append(pair)
                }
            }
        } catch {
            for pair in moved.reversed() { try? fileManager.moveItem(at: pair.destination, to: pair.source) }
            for item in changedTexts { try? item.original.write(to: item.url, atomically: true, encoding: .utf8) }
            throw error
        }
        return records
    }

    private static func resourceFileParts(_ url: URL) -> (name: String, suffix: String)? {
        let filename = url.lastPathComponent
        if filename.hasSuffix(".9.png") {
            return (String(filename.dropLast(6)), ".9.png")
        }
        guard let dot = filename.lastIndex(of: "."), dot != filename.startIndex else { return nil }
        return (String(filename[..<dot]), String(filename[dot...]))
    }

    private static func loadTextFiles(root: URL, fileManager: FileManager) -> [(url: URL, text: String)] {
        let extensions: Set<String> = ["java", "kt", "kts", "xml", "gradle", "pro", "txt", "properties"]
        let excluded: Set<String> = [".git", ".gradle", ".idea", ".kotlin", "build", "DerivedData", "node_modules"]
        guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return []
        }
        var result: [(URL, String)] = []
        for case let url as URL in enumerator {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            if isDirectory, excluded.contains(url.lastPathComponent) {
                enumerator.skipDescendants()
                continue
            }
            guard !isDirectory, extensions.contains(url.pathExtension.lowercased()),
                  let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            result.append((url, text))
        }
        return result
    }

    private static func hasDynamicReference(
        type: String,
        name: String,
        textFiles: [(url: URL, text: String)]
    ) -> Bool {
        for item in textFiles {
            if item.text.contains("getIdentifier(\"\(name)\"") || item.text.contains("getIdentifier('\(name)'") {
                return true
            }
            if item.url.lastPathComponent == "public.xml",
               item.text.contains("type=\"\(type)\""), item.text.contains("name=\"\(name)\"") {
                return true
            }
        }
        return false
    }

    private static func replaceReferences(in text: String, records: [ResourceRenameRecord]) -> String {
        var result = text
        for record in records {
            let old = NSRegularExpression.escapedPattern(for: record.originalName)
            let type = NSRegularExpression.escapedPattern(for: record.type)
            result = replacing(pattern: "(@\\+?\(type)/)\(old)(?![A-Za-z0-9_])", in: result, template: "$1\(record.protectedName)")
            result = replacing(pattern: "(\\bR\\.\(type)\\.)\(old)(?![A-Za-z0-9_])", in: result, template: "$1\(record.protectedName)")
            if record.type == "layout" {
                let oldBinding = NSRegularExpression.escapedPattern(for: pascalCase(record.originalName) + "Binding")
                result = replacing(
                    pattern: "\\b\(oldBinding)\\b",
                    in: result,
                    template: pascalCase(record.protectedName) + "Binding"
                )
            }
        }
        return result
    }

    private static func replacing(pattern: String, in text: String, template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        return regex.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: template
        )
    }

    private static func pascalCase(_ value: String) -> String {
        value.split(separator: "_").map { part in
            guard let first = part.first else { return "" }
            return first.uppercased() + part.dropFirst()
        }.joined()
    }

    private static func writeReports(
        _ report: BuiltInSourceProtectionReport,
        project: URL,
        fileManager: FileManager
    ) throws {
        let directory = project.appendingPathComponent(".android-obfuscator", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: directory.appendingPathComponent("android-obfuscator-source-report.json"), options: .atomic)
        try encoder.encode(report.resourceMapping).write(to: directory.appendingPathComponent("android-obfuscator-resource-mapping.json"), options: .atomic)
    }

    private static func writeNew(_ text: String, to url: URL, fileManager: FileManager) throws {
        guard !fileManager.fileExists(atPath: url.path) else {
            throw PipelineError.fileOperation("拒绝覆盖已有文件：\(url.path)")
        }
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func stableHex(_ value: String, length: Int) -> String {
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in value.utf8 {
            hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211
        }
        let raw = String(hash, radix: 16)
        return String((raw + String(repeating: "0", count: length)).prefix(length))
    }
}

private struct StableGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0x9E3779B97F4A7C15 : seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
        value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
        return value ^ (value >> 31)
    }

    mutating func nextInt(in range: ClosedRange<Int>) -> Int {
        let width = UInt64(range.upperBound - range.lowerBound + 1)
        return range.lowerBound + Int(next() % width)
    }

    mutating func identifier(length: Int) -> String {
        let first = Array("abcdefghijklmnopqrstuvwxyz")
        let remaining = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        var result = String(first[Int(next() % UInt64(first.count))])
        for _ in 1..<max(1, length) {
            result.append(remaining[Int(next() % UInt64(remaining.count))])
        }
        return result
    }

    mutating func hex(length: Int) -> String {
        let characters = Array("0123456789abcdef")
        var result = ""
        for _ in 0..<length { result.append(characters[Int(next() % 16)]) }
        return result
    }
}
