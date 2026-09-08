import Foundation

public final class HistoryStore: @unchecked Sendable {
    private let fileURL: URL
    private let queue = DispatchQueue(label: "dev.androidobfuscator.history")

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("AndroidObfuscator", isDirectory: true)
            self.fileURL = base.appendingPathComponent("history.json")
        }
    }

    public func load() -> [JobRecord] {
        queue.sync {
            guard let data = try? Data(contentsOf: fileURL),
                  let records = try? JSONDecoder.configured.decode([JobRecord].self, from: data) else {
                return []
            }
            return records.sorted { $0.startedAt > $1.startedAt }
        }
    }

    public func save(_ records: [JobRecord]) throws {
        try queue.sync {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let trimmed = Array(records.sorted { $0.startedAt > $1.startedAt }.prefix(100))
            let data = try JSONEncoder.configured.encode(trimmed)
            try data.write(to: fileURL, options: .atomic)
        }
    }
}

private extension JSONEncoder {
    static var configured: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var configured: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

