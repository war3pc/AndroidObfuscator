import Foundation

public struct RetraceResult: Sendable, Equatable {
    public let text: String
    public let replacedFrames: Int
    public let indexedClasses: Int

    public init(text: String, replacedFrames: Int, indexedClasses: Int) {
        self.text = text
        self.replacedFrames = replacedFrames
        self.indexedClasses = indexedClasses
    }
}

public enum StackRetracer {
    private struct ClassMapping {
        var original: String
        var methods: [String: [String]]
    }

    public static func retrace(mappingText: String, stackTrace: String) throws -> RetraceResult {
        let mappings = parse(mappingText)
        guard !mappings.isEmpty else {
            throw PipelineError.invalidConfiguration("mapping.txt 中没有找到有效的类映射。")
        }

        var replacements = 0
        let lines = stackTrace.components(separatedBy: .newlines).map { line -> String in
            guard let frame = parseFrame(line), let mapping = mappings[frame.className] else { return line }
            var restoredMethod = frame.methodName
            if let candidates = mapping.methods[frame.methodName], let first = candidates.first {
                restoredMethod = first
            }
            replacements += 1
            return frame.prefix + mapping.original + "." + restoredMethod + frame.suffix
        }

        return RetraceResult(
            text: lines.joined(separator: "\n"),
            replacedFrames: replacements,
            indexedClasses: mappings.count
        )
    }

    private static func parse(_ text: String) -> [String: ClassMapping] {
        var result: [String: ClassMapping] = [:]
        var currentObfuscatedClass: String?

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }

            if !rawLine.first.map({ $0.isWhitespace })! && line.hasSuffix(":") && line.contains(" -> ") {
                let body = String(line.dropLast())
                let parts = body.components(separatedBy: " -> ")
                guard parts.count == 2 else { continue }
                let original = parts[0].trimmingCharacters(in: .whitespaces)
                let obfuscated = parts[1].trimmingCharacters(in: .whitespaces)
                guard !original.isEmpty, !obfuscated.isEmpty else { continue }
                currentObfuscatedClass = obfuscated
                result[obfuscated] = ClassMapping(original: original, methods: [:])
                continue
            }

            guard let currentObfuscatedClass, line.contains(" -> ") else { continue }
            let parts = line.components(separatedBy: " -> ")
            guard parts.count == 2 else { continue }
            let obfuscatedMember = parts[1].trimmingCharacters(in: .whitespaces)
            let left = parts[0]
            guard left.contains("("), left.contains(")") else { continue }
            guard let open = left.firstIndex(of: "(") else { continue }
            let beforeParameters = left[..<open]
            guard let token = beforeParameters.split(whereSeparator: { $0.isWhitespace }).last else { continue }
            let withoutLeadingLines = token.split(separator: ":").last.map(String.init) ?? String(token)
            let originalMember = withoutLeadingLines.split(separator: ".").last.map(String.init) ?? withoutLeadingLines
            guard !originalMember.isEmpty, !obfuscatedMember.isEmpty else { continue }
            result[currentObfuscatedClass]?.methods[obfuscatedMember, default: []].append(originalMember)
        }
        return result
    }

    private static func parseFrame(_ line: String) -> (prefix: String, className: String, methodName: String, suffix: String)? {
        guard let atRange = line.range(of: "at ") else { return nil }
        let contentStart = atRange.upperBound
        guard let openParen = line[contentStart...].firstIndex(of: "(") else { return nil }
        let symbol = String(line[contentStart..<openParen])
        guard let dot = symbol.lastIndex(of: ".") else { return nil }
        let className = String(symbol[..<dot])
        let methodName = String(symbol[symbol.index(after: dot)...])
        guard !className.isEmpty, !methodName.isEmpty else { return nil }
        return (
            String(line[..<contentStart]),
            className,
            methodName,
            String(line[openParen...])
        )
    }
}

