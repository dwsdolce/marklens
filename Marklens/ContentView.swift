import SwiftUI
import MarklensCore

struct ContentView: View {
    let document: MarkdownDocument
    let fileURL: URL?

    @Environment(\.colorScheme) private var colorScheme
    @State private var rendered: RenderedDocument?
    @StateObject private var exportController = ExportController()

    var body: some View {
        Group {
            if let rendered {
                MarkdownWebView(
                    rendered: rendered,
                    dark: colorScheme == .dark,
                    baseURL: WebResources.bundleURL,
                    exportController: exportController
                )
            } else {
                Color.clear
            }
        }
        .frame(minWidth: 480, minHeight: 360)
        .navigationTitle(fileURL?.deletingPathExtension().lastPathComponent ?? "Markdown")
        .toolbar { Toolbar(fileURL: fileURL, exportController: exportController) }
        .task(id: document.source) {
            await render()
        }
    }

    @MainActor
    private func render() async {
        let source = document.source
        exportController.isReady = false
        let result = await Task.detached(priority: .userInitiated) {
            MarkdownRenderer().renderHTML(from: source)
        }.value
        self.rendered = result
    }
}
