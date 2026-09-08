import XCTest
@testable import AndroidObfuscatorCore

final class HistoryStoreTests: XCTestCase {
    func testRoundTripAndSort() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("HistoryStoreTests-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = HistoryStore(fileURL: url)
        let old = JobRecord(kind: .source, name: "old", startedAt: Date(timeIntervalSince1970: 1), status: .succeeded)
        let new = JobRecord(kind: .apk, name: "new", startedAt: Date(timeIntervalSince1970: 2), status: .failed)
        try store.save([old, new])
        XCTAssertEqual(store.load().map(\.name), ["new", "old"])
    }
}

