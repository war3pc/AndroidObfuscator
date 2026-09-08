import Foundation

enum APKCertificateIdentity {
    private static let digestMarker = "certificate sha-256 digest:"

    static func fingerprints(fromAPKSigOutput output: String) throws -> [String] {
        let fingerprints = Set(output.components(separatedBy: .newlines).compactMap { line -> String? in
            guard let markerRange = line.range(of: digestMarker, options: .caseInsensitive) else { return nil }
            return normalizeDigest(String(line[markerRange.upperBound...]))
        })
        let sorted = fingerprints.sorted()
        guard !sorted.isEmpty else {
            throw PipelineError.certificateFingerprintMissing(
                "apksigner 没有返回可识别的证书 SHA-256 摘要；输入 APK 可能未签名或工具输出格式不受支持。"
            )
        }
        return sorted
    }

    static func readFingerprints(from url: URL) throws -> [String] {
        let contents: String
        do {
            contents = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw PipelineError.certificateFingerprintMissing("无法读取已锁定的输入证书摘要：\(url.path)")
        }
        let fingerprints = contents.components(separatedBy: .newlines)
            .compactMap(normalizeDigest)
        guard !fingerprints.isEmpty else {
            throw PipelineError.certificateFingerprintMissing("已锁定的输入证书摘要为空或格式无效：\(url.path)")
        }
        return Array(Set(fingerprints)).sorted()
    }

    static func writeFingerprints(_ fingerprints: [String], to url: URL) throws {
        let normalized = Array(Set(fingerprints.compactMap(normalizeDigest))).sorted()
        guard !normalized.isEmpty else {
            throw PipelineError.certificateFingerprintMissing("没有可保存的输入证书 SHA-256 摘要。")
        }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try (normalized.joined(separator: "\n") + "\n").write(
                to: url,
                atomically: true,
                encoding: .utf8
            )
        } catch {
            throw PipelineError.fileOperation("无法保存输入证书摘要：\(error.localizedDescription)")
        }
    }

    static func display(_ fingerprints: [String]) -> String {
        fingerprints.map { digest in
            stride(from: 0, to: digest.count, by: 2).map { offset -> String in
                let start = digest.index(digest.startIndex, offsetBy: offset)
                let end = digest.index(start, offsetBy: min(2, digest.distance(from: start, to: digest.endIndex)))
                return String(digest[start..<end])
            }.joined(separator: ":")
        }.joined(separator: ", ")
    }

    private static func normalizeDigest(_ value: String) -> String? {
        let digest = value.uppercased().filter { "0123456789ABCDEF".contains($0) }
        guard digest.count == 64 else { return nil }
        return digest
    }
}
