import Foundation

public struct NativeToolchainInspection: Sendable, Equatable {
    public let root: URL
    public let clang: URL
    public let clangPlusPlus: URL
    public let cmakeToolchain: URL
    public let revision: String?

    public init(
        root: URL,
        clang: URL,
        clangPlusPlus: URL,
        cmakeToolchain: URL,
        revision: String?
    ) {
        self.root = root
        self.clang = clang
        self.clangPlusPlus = clangPlusPlus
        self.cmakeToolchain = cmakeToolchain
        self.revision = revision
    }
}

public enum NativeToolchainInspector {
    public static func inspect(
        ndk root: URL,
        fileManager: FileManager = .default
    ) throws -> NativeToolchainInspection {
        let sourceProperties = root.appendingPathComponent("source.properties")
        guard fileManager.fileExists(atPath: sourceProperties.path) else {
            throw PipelineError.invalidConfiguration("定制 NDK 缺少 source.properties。")
        }

        let cmakeToolchain = root.appendingPathComponent("build/cmake/android.toolchain.cmake")
        guard fileManager.fileExists(atPath: cmakeToolchain.path) else {
            throw PipelineError.invalidConfiguration("定制 NDK 缺少 build/cmake/android.toolchain.cmake。")
        }

        let prebuiltRoot = root.appendingPathComponent("toolchains/llvm/prebuilt", isDirectory: true)
        guard let hosts = try? fileManager.contentsOfDirectory(
            at: prebuiltRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw PipelineError.invalidConfiguration("定制 NDK 缺少 LLVM prebuilt 工具链。")
        }

        let host = hosts
            .sorted { lhs, rhs in
                let lhsDarwin = lhs.lastPathComponent.localizedCaseInsensitiveContains("darwin")
                let rhsDarwin = rhs.lastPathComponent.localizedCaseInsensitiveContains("darwin")
                if lhsDarwin != rhsDarwin { return lhsDarwin }
                return lhs.lastPathComponent < rhs.lastPathComponent
            }
            .first { candidate in
                fileManager.isExecutableFile(atPath: candidate.appendingPathComponent("bin/clang").path)
                    && fileManager.isExecutableFile(atPath: candidate.appendingPathComponent("bin/clang++").path)
            }
        guard let host else {
            throw PipelineError.invalidConfiguration("定制 NDK 中没有可在当前 Mac 执行的 clang / clang++。")
        }

        let revision = (try? String(contentsOf: sourceProperties, encoding: .utf8))?
            .split(whereSeparator: { $0.isNewline })
            .first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("Pkg.Revision") }?
            .split(separator: "=", maxSplits: 1)
            .last
            .map { String($0).trimmingCharacters(in: .whitespaces) }

        return NativeToolchainInspection(
            root: root,
            clang: host.appendingPathComponent("bin/clang"),
            clangPlusPlus: host.appendingPathComponent("bin/clang++"),
            cmakeToolchain: cmakeToolchain,
            revision: revision
        )
    }

    public static func protectionFlags(
        kind: NativeToolchainKind,
        customFlags: String
    ) throws -> [String] {
        switch kind {
        case .none:
            return []
        case .allvm:
            return [
                "-mllvm", "-irobf",
                "-mllvm", "-irobf-fla",
                "-mllvm", "-level-fla=2"
            ]
        case .hikari:
            return [
                "-mllvm", "-enable-cffobf",
                "-mllvm", "-enable-subobf"
            ]
        case .custom:
            let flags = customFlags
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
            guard !flags.isEmpty else {
                throw PipelineError.invalidConfiguration("自定义 NDK 需要填写实际编译保护参数。")
            }
            guard flags.allSatisfy({ !isReservedCustomFlag($0) }) else {
                throw PipelineError.invalidConfiguration("自定义 Native 参数不能覆盖目标、输入或输出参数。")
            }
            return flags
        }
    }

    private static func isReservedCustomFlag(_ flag: String) -> Bool {
        if flag == "-" || flag.hasPrefix("@") { return true }
        if ["-o", "-c", "-x", "-target", "--target", "--output"].contains(flag) { return true }

        // Clang accepts both split and joined/equal forms.  Reject those forms
        // as well so the fixed probe target and object destination cannot be
        // silently replaced (for example `-o/tmp/file` or `--target=x86_64`).
        let reservedPrefixes = [
            "-o/", "-o.", "-o=",
            "-x=", "-xc", "-xc++", "-xobjective-c",
            "-target=", "--target=", "--output="
        ]
        return reservedPrefixes.contains { flag.hasPrefix($0) }
    }

    public static var probeSource: Data {
        Data(
            """
            static volatile int native_probe_guard = 7;

            __attribute__((noinline, visibility("default")))
            int android_obfuscator_native_probe(int value) {
                int mixed = value ^ native_probe_guard;
                if ((mixed & 1) == 0) {
                    mixed = mixed * 17 + 3;
                } else {
                    mixed = mixed * 11 - 5;
                }
                return mixed ^ 0x5a5a;
            }
            """.utf8
        )
    }
}
