import Foundation

enum NativeGradleWiring {
    static let ndkPathEnvironmentKey = "ANDROID_OBFUSCATOR_NDK_PATH"
    static let nativeFlagsEnvironmentKey = "ANDROID_OBFUSCATOR_NATIVE_FLAGS"
    static let scriptFileName = "android-obfuscator-native.init.gradle"

    static var initScript: Data {
        Data(
            #"""
            import org.gradle.api.GradleException

            def selectedNdkValue = System.getenv("ANDROID_OBFUSCATOR_NDK_PATH")
            if (selectedNdkValue == null || selectedNdkValue.trim().isEmpty()) {
                throw new GradleException("[AndroidObfuscator] 缺少 ANDROID_OBFUSCATOR_NDK_PATH，拒绝回退到系统 NDK。")
            }

            def selectedNdk = new File(selectedNdkValue).canonicalFile
            def requiredNdkFiles = [
                new File(selectedNdk, "source.properties"),
                new File(selectedNdk, "build/cmake/android.toolchain.cmake")
            ]
            def missingNdkFile = requiredNdkFiles.find { !it.isFile() }
            if (missingNdkFile != null) {
                throw new GradleException("[AndroidObfuscator] 定制 NDK 在 Gradle 启动前已失效，缺少：${missingNdkFile}")
            }

            def androidPluginIds = [
                "com.android.application",
                "com.android.library",
                "com.android.dynamic-feature",
                "com.android.test"
            ]
            def wiredProjects = new LinkedHashMap<String, Object>()

            def wireSelectedNdk = { project ->
                if (wiredProjects.containsKey(project.path)) {
                    return
                }
                def android = project.extensions.findByName("android")
                if (android == null) {
                    throw new GradleException("[AndroidObfuscator] ${project.path} 已应用 Android 插件，但找不到 android 扩展。")
                }
                try {
                    android.ndkPath = selectedNdk.absolutePath
                } catch (Throwable failure) {
                    throw new GradleException(
                        "[AndroidObfuscator] 无法设置 ${project.path} 的 android.ndkPath；定制 NDK 要求 Android Gradle Plugin 4.1 或更高版本。",
                        failure
                    )
                }
                wiredProjects.put(project.path, project)
                project.logger.lifecycle("[AndroidObfuscator] 已接线 ${project.path}: android.ndkPath=${selectedNdk}")
            }

            gradle.beforeProject { project ->
                androidPluginIds.each { pluginId ->
                    project.pluginManager.withPlugin(pluginId) {
                        wireSelectedNdk(project)
                    }
                }
            }

            gradle.projectsEvaluated {
                if (wiredProjects.isEmpty()) {
                    throw new GradleException("[AndroidObfuscator] 没有发现 Android application/library/dynamic-feature/test 模块，无法验证定制 NDK 接线。")
                }
                wiredProjects.each { projectPath, project ->
                    def android = project.extensions.findByName("android")
                    def actualValue
                    try {
                        actualValue = android.ndkPath
                    } catch (Throwable failure) {
                        throw new GradleException("[AndroidObfuscator] 无法读取 ${projectPath} 的 android.ndkPath。", failure)
                    }
                    if (actualValue == null || actualValue.toString().trim().isEmpty()) {
                        throw new GradleException("[AndroidObfuscator] ${projectPath} 的 android.ndkPath 为空；拒绝使用 AGP 默认 NDK。")
                    }
                    def actualNdk = new File(actualValue.toString()).canonicalFile
                    if (actualNdk != selectedNdk) {
                        throw new GradleException(
                            "[AndroidObfuscator] ${projectPath} 在配置阶段覆盖了定制 NDK：${actualNdk}；期望：${selectedNdk}"
                        )
                    }
                    project.logger.lifecycle("[AndroidObfuscator] 已验证 ${projectPath} 使用选定 NDK：${actualNdk}")
                }
            }
            """#.utf8
        )
    }
}
