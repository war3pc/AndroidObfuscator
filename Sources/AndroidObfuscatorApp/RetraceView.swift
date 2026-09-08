import AppKit
import SwiftUI
import UniformTypeIdentifiers
import AndroidObfuscatorCore

struct RetraceView: View {
    @State private var mappingURL: URL?
    @State private var mappingText = ""
    @State private var stackTrace = ""
    @State private var output = ""
    @State private var statistics = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeader(
                title: "堆栈还原",
                subtitle: "使用 R8 / ProGuard mapping.txt 在本机还原混淆崩溃堆栈",
                symbol: "text.magnifyingglass"
            ) {
                Button {
                    runRetrace()
                } label: {
                    Label("还原堆栈", systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(WorkbenchTheme.accent)
                .disabled(mappingText.isEmpty || stackTrace.isEmpty)
            }

            WorkbenchCard {
                PathSelectionRow(
                    title: "R8 / ProGuard Mapping",
                    subtitle: "选择构建产物中的 mapping.txt",
                    url: mappingURL,
                    buttonTitle: "选择",
                    symbol: "doc.text.magnifyingglass",
                    action: chooseMapping
                )
            }

            HSplitView {
                editor(
                    title: "混淆堆栈",
                    subtitle: "粘贴 Logcat、Crashlytics 或控制台中的 Java/Kotlin 堆栈",
                    text: $stackTrace,
                    placeholder: "java.lang.RuntimeException\n    at a.b.c(Unknown Source:12)",
                    copyEnabled: false
                )
                editor(
                    title: "还原结果",
                    subtitle: statistics.isEmpty ? "结果不会上传或保存" : statistics,
                    text: $output,
                    placeholder: "还原后的类名与方法名会显示在这里",
                    copyEnabled: !output.isEmpty
                )
            }

            HStack(spacing: 10) {
                Label("该解析器还原类名和方法名；精确行号仍以官方 R8 Retrace 为准。", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("清空") {
                    stackTrace = ""
                    output = ""
                    statistics = ""
                    errorMessage = nil
                }
                .buttonStyle(.borderless)
            }
        }
        .accessibilityIdentifier("page.retrace")
        .padding(28)
        .frame(maxWidth: 1280, maxHeight: .infinity, alignment: .top)
        .frame(maxWidth: .infinity)
        .alert("无法还原", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("知道了", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func editor(
        title: String,
        subtitle: String,
        text: Binding<String>,
        placeholder: String,
        copyEnabled: Bool
    ) -> some View {
        WorkbenchCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    SectionHeading(title: title, subtitle: subtitle)
                    Spacer()
                    if copyEnabled {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(text.wrappedValue, forType: .string)
                        } label: {
                            Label("复制", systemImage: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                ZStack(alignment: .topLeading) {
                    TextEditor(text: text)
                        .font(.system(size: 12.5, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(8)
                    if text.wrappedValue.isEmpty {
                        Text(placeholder)
                            .font(.system(size: 12.5, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 16)
                            .allowsHitTesting(false)
                    }
                }
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.primary.opacity(0.07))
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(minWidth: 390, maxWidth: .infinity, maxHeight: .infinity)
    }

    private func chooseMapping() {
        let panel = NSOpenPanel()
        panel.title = "选择 mapping.txt"
        panel.prompt = "选择 Mapping"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            mappingText = try String(contentsOf: url, encoding: .utf8)
            mappingURL = url
            output = ""
            statistics = ""
        } catch {
            errorMessage = "无法读取 mapping.txt：\(error.localizedDescription)"
        }
    }

    private func runRetrace() {
        do {
            let result = try StackRetracer.retrace(mappingText: mappingText, stackTrace: stackTrace)
            output = result.text
            statistics = "已索引 \(result.indexedClasses) 个类，还原 \(result.replacedFrames) 个堆栈帧"
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
