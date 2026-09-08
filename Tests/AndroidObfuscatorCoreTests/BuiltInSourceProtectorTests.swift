import XCTest
@testable import AndroidObfuscatorCore

final class BuiltInSourceProtectorTests: XCTestCase {
    private var root: URL!
    private var project: URL!
    private var module: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BuiltInSourceProtectorTests-\(UUID().uuidString)", isDirectory: true)
        project = root.appendingPathComponent("Demo", isDirectory: true)
        module = project.appendingPathComponent("app", isDirectory: true)
        try FileManager.default.createDirectory(
            at: module.appendingPathComponent("src/main/res", isDirectory: true),
            withIntermediateDirectories: true
        )
        try """
        plugins { id("com.android.application") }
        android {
            namespace = "com.example.demo"
            buildTypes { release { proguardFiles("proguard-rules.pro") } }
        }
        """.write(to: module.appendingPathComponent("build.gradle.kts"), atomically: true, encoding: .utf8)
        try "<manifest xmlns:android=\"http://schemas.android.com/apk/res/android\" />\n"
            .write(to: module.appendingPathComponent("src/main/AndroidManifest.xml"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testGeneratesCompilableSourcesResourcesRulesAndReport() throws {
        let configuration = BuiltInSourceProtectionConfiguration(
            moduleName: "app",
            generateCodeAndResources: true,
            installR8Rules: true,
            renameFileResources: false,
            generatedClassCount: 3,
            methodsPerClass: 2,
            seed: 42
        )

        let report = try BuiltInSourceProtector.apply(project: project, configuration: configuration)

        XCTAssertEqual(report.namespace, "com.example.demo")
        XCTAssertEqual(report.generatedSourceFiles, 4)
        XCTAssertEqual(report.generatedResourceFiles, 4)
        XCTAssertTrue(report.r8RulesInstalled)
        let generated = module.appendingPathComponent(
            "src/main/java/com/example/demo/aog/generated/AndroidObfuscatorAnchor.java"
        )
        let anchor = try String(contentsOf: generated, encoding: .utf8)
        XCTAssertTrue(anchor.contains("import com.example.demo.R;"))
        XCTAssertTrue(anchor.contains("R.drawable."))
        let rules = try String(contentsOf: module.appendingPathComponent("proguard-rules.pro"), encoding: .utf8)
        XCTAssertTrue(rules.contains("com.example.demo.aog.generated.**"))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: project.appendingPathComponent(".android-obfuscator/android-obfuscator-source-report.json").path
        ))

        let rulesOnly = BuiltInSourceProtectionConfiguration(
            moduleName: "app",
            generateCodeAndResources: false,
            installR8Rules: true,
            renameFileResources: false,
            seed: 42
        )
        XCTAssertFalse(try BuiltInSourceProtector.apply(project: project, configuration: rulesOnly).r8RulesInstalled)
    }

    func testGeneratedSourcesCompileWithRealJavacWhenAvailable() throws {
        let javacCandidates = [
            ProcessInfo.processInfo.environment["JAVA_HOME"].map { URL(fileURLWithPath: $0).appendingPathComponent("bin/javac") },
            URL(fileURLWithPath: "/Applications/Android Studio.app/Contents/jbr/Contents/Home/bin/javac")
        ].compactMap { $0 }
        guard let javac = javacCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            throw XCTSkip("本机没有可用 javac，跳过真实 Java 编译集成检查。")
        }

        let configuration = BuiltInSourceProtectionConfiguration(
            moduleName: "app",
            generateCodeAndResources: true,
            installR8Rules: false,
            renameFileResources: false,
            generatedClassCount: 2,
            methodsPerClass: 2,
            seed: 7
        )
        _ = try BuiltInSourceProtector.apply(project: project, configuration: configuration)

        let generatedDirectory = module.appendingPathComponent("src/main/java/com/example/demo/aog/generated")
        let anchorURL = generatedDirectory.appendingPathComponent("AndroidObfuscatorAnchor.java")
        let anchor = try String(contentsOf: anchorURL, encoding: .utf8)
        let pattern = #"R\.(string|color|drawable)\.([A-Za-z_][A-Za-z0-9_]*)"#
        let regex = try NSRegularExpression(pattern: pattern)
        var fields: [String: Set<String>] = [:]
        for match in regex.matches(in: anchor, range: NSRange(anchor.startIndex..., in: anchor)) {
            guard let typeRange = Range(match.range(at: 1), in: anchor),
                  let nameRange = Range(match.range(at: 2), in: anchor) else { continue }
            fields[String(anchor[typeRange]), default: []].insert(String(anchor[nameRange]))
        }

        let stubDirectory = root.appendingPathComponent("java-stub/com/example/demo", isDirectory: true)
        let classesDirectory = root.appendingPathComponent("java-classes", isDirectory: true)
        try FileManager.default.createDirectory(at: stubDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: classesDirectory, withIntermediateDirectories: true)
        var rSource = "package com.example.demo;\npublic final class R {\n"
        var resourceID = 1
        for type in ["string", "color", "drawable"] {
            rSource += "  public static final class \(type) {\n"
            for name in fields[type, default: []].sorted() {
                rSource += "    public static final int \(name) = \(resourceID);\n"
                resourceID += 1
            }
            rSource += "  }\n"
        }
        rSource += "}\n"
        let rURL = stubDirectory.appendingPathComponent("R.java")
        try rSource.write(to: rURL, atomically: true, encoding: .utf8)

        let generatedSources = try FileManager.default.contentsOfDirectory(
            at: generatedDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "java" }
        let process = Process()
        let output = Pipe()
        process.executableURL = javac
        process.arguments = ["-source", "8", "-target", "8", "-d", classesDirectory.path, rURL.path]
            + generatedSources.map(\.path)
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let compilerOutput = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, compilerOutput)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: classesDirectory.appendingPathComponent("com/example/demo/aog/generated/AndroidObfuscatorAnchor.class").path
        ))
    }

    func testRenamesResourcesUpdatesReferencesAndSkipsDynamicNames() throws {
        let layoutDirectory = module.appendingPathComponent("src/main/res/layout", isDirectory: true)
        let drawableDirectory = module.appendingPathComponent("src/main/res/drawable", isDirectory: true)
        let valuesDirectory = module.appendingPathComponent("src/main/res/values", isDirectory: true)
        let javaDirectory = module.appendingPathComponent("src/main/java/com/example/demo", isDirectory: true)
        for directory in [layoutDirectory, drawableDirectory, valuesDirectory, javaDirectory] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try """
        <FrameLayout xmlns:android="http://schemas.android.com/apk/res/android"
            android:background="@drawable/background_panel" />
        """.write(to: layoutDirectory.appendingPathComponent("main_screen.xml"), atomically: true, encoding: .utf8)
        try "<shape xmlns:android=\"http://schemas.android.com/apk/res/android\" />\n"
            .write(to: drawableDirectory.appendingPathComponent("background_panel.xml"), atomically: true, encoding: .utf8)
        try "<shape xmlns:android=\"http://schemas.android.com/apk/res/android\" />\n"
            .write(to: drawableDirectory.appendingPathComponent("dynamic_logo.xml"), atomically: true, encoding: .utf8)
        try "<resources><public type=\"drawable\" name=\"dynamic_logo\" id=\"0x7f010001\" /></resources>\n"
            .write(to: valuesDirectory.appendingPathComponent("public.xml"), atomically: true, encoding: .utf8)
        let sourceURL = javaDirectory.appendingPathComponent("Screen.kt")
        try """
        val layout = R.layout.main_screen
        val background = R.drawable.background_panel
        lateinit var binding: MainScreenBinding
        """.write(to: sourceURL, atomically: true, encoding: .utf8)

        let configuration = BuiltInSourceProtectionConfiguration(
            moduleName: "app",
            generateCodeAndResources: false,
            installR8Rules: false,
            renameFileResources: true,
            seed: 99
        )
        let report = try BuiltInSourceProtector.apply(project: project, configuration: configuration)

        XCTAssertEqual(report.renamedResources, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: drawableDirectory.appendingPathComponent("dynamic_logo.xml").path))
        let layout = try XCTUnwrap(report.resourceMapping.first { $0.type == "layout" })
        let drawable = try XCTUnwrap(report.resourceMapping.first { $0.type == "drawable" })
        XCTAssertTrue(FileManager.default.fileExists(atPath: layoutDirectory.appendingPathComponent(layout.protectedName + ".xml").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: drawableDirectory.appendingPathComponent(drawable.protectedName + ".xml").path))
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        XCTAssertTrue(source.contains("R.layout.\(layout.protectedName)"))
        XCTAssertTrue(source.contains("R.drawable.\(drawable.protectedName)"))
        XCTAssertTrue(source.contains(bindingName(layout.protectedName) + "Binding"))
    }

    func testResourceRenameDoesNotRewriteSiblingModuleWithSameResourceName() throws {
        let appLayout = module.appendingPathComponent("src/main/res/layout", isDirectory: true)
        let appSource = module.appendingPathComponent("src/main/java/com/example/demo", isDirectory: true)
        let library = project.appendingPathComponent("feature", isDirectory: true)
        let libraryLayout = library.appendingPathComponent("src/main/res/layout", isDirectory: true)
        let librarySource = library.appendingPathComponent("src/main/java/com/example/feature", isDirectory: true)
        for directory in [appLayout, appSource, libraryLayout, librarySource] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        try "<FrameLayout />\n".write(
            to: appLayout.appendingPathComponent("shared_screen.xml"),
            atomically: true,
            encoding: .utf8
        )
        let appSourceURL = appSource.appendingPathComponent("AppScreen.kt")
        try "val screen = R.layout.shared_screen\n".write(to: appSourceURL, atomically: true, encoding: .utf8)

        try "<FrameLayout />\n".write(
            to: libraryLayout.appendingPathComponent("shared_screen.xml"),
            atomically: true,
            encoding: .utf8
        )
        let librarySourceURL = librarySource.appendingPathComponent("FeatureScreen.kt")
        let originalLibrarySource = "val screen = R.layout.shared_screen\n"
        try originalLibrarySource.write(to: librarySourceURL, atomically: true, encoding: .utf8)

        let configuration = BuiltInSourceProtectionConfiguration(
            moduleName: "app",
            generateCodeAndResources: false,
            installR8Rules: false,
            renameFileResources: true,
            seed: 123
        )
        let report = try BuiltInSourceProtector.apply(project: project, configuration: configuration)
        let layout = try XCTUnwrap(report.resourceMapping.first { $0.type == "layout" })

        XCTAssertTrue(try String(contentsOf: appSourceURL).contains("R.layout.\(layout.protectedName)"))
        XCTAssertEqual(try String(contentsOf: librarySourceURL), originalLibrarySource)
        XCTAssertTrue(FileManager.default.fileExists(atPath: libraryLayout.appendingPathComponent("shared_screen.xml").path))
    }

    private func bindingName(_ value: String) -> String {
        value.split(separator: "_").map { part in
            part.prefix(1).uppercased() + part.dropFirst()
        }.joined()
    }
}
