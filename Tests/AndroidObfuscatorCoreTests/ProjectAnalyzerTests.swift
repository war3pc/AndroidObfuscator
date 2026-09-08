import XCTest
@testable import AndroidObfuscatorCore

final class ProjectAnalyzerTests: XCTestCase {
    func testDetectsKotlinGradleProtectionConfiguration() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnalyzerTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("app/src/main/cpp"), withIntermediateDirectories: true)
        try "".write(to: root.appendingPathComponent("gradlew"), atomically: true, encoding: .utf8)
        try "include(\":app\")".write(to: root.appendingPathComponent("settings.gradle.kts"), atomically: true, encoding: .utf8)
        try """
        plugins { id("com.android.application") }
        android { buildTypes { release { isMinifyEnabled = true; isShrinkResources = true } } }
        apply(plugin = "class-res-guard")
        """.write(to: root.appendingPathComponent("app/build.gradle.kts"), atomically: true, encoding: .utf8)

        let result = ProjectAnalyzer.analyze(projectURL: root)
        XCTAssertEqual(result.modules, ["app"])
        XCTAssertTrue(result.hasGradleWrapper)
        XCTAssertTrue(result.hasR8Configuration)
        XCTAssertTrue(result.hasResourceShrinking)
        XCTAssertTrue(result.hasClassResGuard)
        XCTAssertTrue(result.hasNativeCode)
    }

    func testIgnoresCommentedProtectionExamplesAndAcceptsLineBreaks() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnalyzerCommentsTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("app"), withIntermediateDirectories: true)
        try "include(\":app\")".write(to: root.appendingPathComponent("settings.gradle"), atomically: true, encoding: .utf8)
        try """
        android {
          // minifyEnabled true
          /* shrinkResources true */
          buildTypes {
            release {
              isMinifyEnabled =
                true
              isShrinkResources =
                true
            }
          }
        }
        """.write(to: root.appendingPathComponent("app/build.gradle.kts"), atomically: true, encoding: .utf8)

        let enabled = ProjectAnalyzer.analyze(projectURL: root)
        XCTAssertTrue(enabled.hasR8Configuration)
        XCTAssertTrue(enabled.hasResourceShrinking)

        try "// minifyEnabled true\n/* shrinkResources true */\n".write(
            to: root.appendingPathComponent("app/build.gradle.kts"),
            atomically: true,
            encoding: .utf8
        )
        let commentsOnly = ProjectAnalyzer.analyze(projectURL: root)
        XCTAssertFalse(commentsOnly.hasR8Configuration)
        XCTAssertFalse(commentsOnly.hasResourceShrinking)
    }
}
