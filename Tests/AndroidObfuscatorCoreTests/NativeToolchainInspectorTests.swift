import XCTest
@testable import AndroidObfuscatorCore

final class NativeToolchainInspectorTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NativeToolchainInspectorTests-\(UUID().uuidString)")
        let bin = root.appendingPathComponent("toolchains/llvm/prebuilt/darwin-arm64/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("build/cmake"),
            withIntermediateDirectories: true
        )
        try "Pkg.Desc = Android NDK\nPkg.Revision = 28.2.13676358\n"
            .write(to: root.appendingPathComponent("source.properties"), atomically: true, encoding: .utf8)
        try "# toolchain\n".write(
            to: root.appendingPathComponent("build/cmake/android.toolchain.cmake"),
            atomically: true,
            encoding: .utf8
        )
        for name in ["clang", "clang++"] {
            let executable = bin.appendingPathComponent(name)
            try "#!/bin/sh\nexit 0\n".write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        }
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testInspectsCompleteNDKAndReadsRevision() throws {
        let inspection = try NativeToolchainInspector.inspect(ndk: root)
        XCTAssertEqual(inspection.revision, "28.2.13676358")
        XCTAssertEqual(inspection.clang.lastPathComponent, "clang")
        XCTAssertTrue(inspection.clang.path.contains("darwin-arm64"))
    }

    func testProvidesKnownPassFlagsAndRejectsOutputOverride() throws {
        XCTAssertEqual(
            try NativeToolchainInspector.protectionFlags(kind: .allvm, customFlags: ""),
            ["-mllvm", "-irobf", "-mllvm", "-irobf-fla", "-mllvm", "-level-fla=2"]
        )
        XCTAssertEqual(
            try NativeToolchainInspector.protectionFlags(kind: .hikari, customFlags: ""),
            ["-mllvm", "-enable-cffobf", "-mllvm", "-enable-subobf"]
        )
        XCTAssertThrowsError(
            try NativeToolchainInspector.protectionFlags(kind: .custom, customFlags: "-o stolen.o")
        )
        for bypass in ["-o/tmp/stolen.o", "-o=stolen.o", "--target=x86_64-apple-macos", "-target=x86_64", "@flags.rsp"] {
            XCTAssertThrowsError(
                try NativeToolchainInspector.protectionFlags(kind: .custom, customFlags: bypass),
                "应拒绝组合形式的保留参数：\(bypass)"
            )
        }
    }
}
