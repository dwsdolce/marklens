import Foundation

/// Tracks which file a window is actually *showing*.
///
/// On macOS a link opens the target as its own document window, so the shown
/// file is always the `DocumentGroup` document. On iOS there's no second window
/// to open on iPhone, so following a link swaps the content in place and this
/// keeps the history behind it — the shown file then differs from the document
/// the scene was opened with, and the title, toolbar, and reloader all follow
/// `current` rather than the `DocumentGroup` URL.
@MainActor
final class DocumentNavigator: ObservableObject {
    /// The file on screen right now.
    @Published private(set) var current: URL?
    @Published private(set) var canGoBack: Bool = false

    /// Files behind `current`, oldest first.
    private var history: [URL] = []

    /// Seeds the navigator with the document the window was opened with.
    func setRoot(_ url: URL?) {
        guard current == nil else { return }
        current = url
    }

    func push(_ url: URL) {
        guard url != current else { return }
        if let current { history.append(current) }
        current = url
        canGoBack = !history.isEmpty
    }

    func goBack() {
        guard let previous = history.popLast() else { return }
        current = previous
        canGoBack = !history.isEmpty
    }
}