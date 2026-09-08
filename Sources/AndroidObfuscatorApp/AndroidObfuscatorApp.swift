import SwiftUI

@main
struct AndroidObfuscatorApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 1120, minHeight: 720)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1320, height: 860)
        .commands {
            CommandGroup(after: .newItem) {
                Button("运行当前方案") {
                    if model.selection == .source {
                        model.startSourceJob()
                    } else if model.selection == .apk {
                        model.startAPKJob()
                    }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(model.isRunning || (model.selection != .source && model.selection != .apk))
            }
        }
    }
}

