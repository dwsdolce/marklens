import SwiftUI
import MarklensCore

struct ContentView: View {
    let document: MarkdownDocument
    let fileURL: URL?

    @Environment(\.colorScheme) private var colorScheme
    @State private var rendered: RenderedDocument?
    @StateObject private var webController = WebViewController()
    @StateObject private var findController = FindController()
    @StateObject private var reloader: DocumentReloader
    @StateObject private var navigator = DocumentNavigator()
    /// Set when the user waves off the images banner for this document.
    @State private var imageBannerDismissed = false
    /// Bumped after a folder grant so the page re-fetches its images.
    @State private var webReloadToken = 0

    init(document: MarkdownDocument, fileURL: URL?) {
        self.document = document
        self.fileURL = fileURL
        _reloader = StateObject(wrappedValue: DocumentReloader(initialSource: document.source))
    }

    /// The file on screen. Same as `fileURL` on macOS; on iOS it changes as
    /// links are followed in place.
    private var shownURL: URL? { navigator.current ?? fileURL }

    /// Whether the document points at local images we can't read — computed when
    /// the document renders and after a grant, never in `body`.
    ///
    /// This *must not* be a computed property. Answering it means reading
    /// UserDefaults, resolving security-scoped bookmarks, and caching the
    /// activated scope — real work with real side effects. Doing that inside
    /// `body` mutates an ObservableObject during a view update, which feeds
    /// SwiftUI's next update, which calls `body` again: the app pinned a core at
    /// 100% and never drew a window.
    @State private var imagesBlocked = false

    private var showImageBanner: Bool { imagesBlocked && !imageBannerDismissed }

    /// Recomputes `imagesBlocked`. Cheap to call, but only from actions and
    /// tasks — never from `body`.
    @MainActor
    private func refreshImageAccess() {
        guard let rendered, rendered.referencesLocalImages, let shownURL else {
            imagesBlocked = false
            return
        }
        let folder = shownURL.deletingLastPathComponent()
        imagesBlocked = !LinkFolderAccess.shared.canAccessFolder(folder)
    }

    /// Find bar, or the images-need-access banner — never both. Kept out of
    /// `body` so the type checker isn't asked to infer the whole thing at once.
    @ViewBuilder
    private var topOverlay: some View {
        if findController.isActive {
            FindBar(controller: findController)
                .transition(.move(edge: .top).combined(with: .opacity))
        } else if showImageBanner, let folder = shownURL?.deletingLastPathComponent() {
            ImageAccessBanner(
                folderName: folder.lastPathComponent,
                allow: { allowImages(in: folder) },
                dismiss: { imageBannerDismissed = true }
            )
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    /// Ask for the document's folder, pointing the panel straight at it — one
    /// click to Allow, or navigate up to cover a whole project tree.
    private func allowImages(in folder: URL) {
        LinkFolderAccess.shared.addFolder(startingAt: folder) { _ in
            refreshImageAccess()
            // The markup hasn't changed — only our right to read what it points
            // at — so nudge the web view to load again and re-request the images.
            webReloadToken += 1
        }
    }

    var body: some View {
        Group {
            if let rendered {
                MarkdownWebView(
                    rendered: rendered,
                    dark: colorScheme == .dark,
                    baseURL: WebResources.bundleURL,
                    fileURL: shownURL,
                    controller: webController,
                    onNavigate: { navigator.push($0) },
                    reloadToken: webReloadToken
                )
            } else {
                Color.clear
            }
        }
        .overlay(alignment: .top) { topOverlay }
        .animation(.easeOut(duration: 0.18), value: findController.isActive)
        .animation(.easeOut(duration: 0.18), value: showImageBanner)
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 360)
        #endif
        .navigationTitle(shownURL?.deletingPathExtension().lastPathComponent ?? "Markdown")
        #if os(iOS)
        // DocumentGroup hangs a title menu (Rename / Duplicate / Move) off the
        // navigation title. Marklens is a read-only viewer, so it shouldn't
        // advertise those to begin with — and the menu acts on the *scene's*
        // document, while the title now names whatever file a link navigated
        // us to, so a rename here would hit a file other than the one on
        // screen. Empty content leaves nothing to show.
        .toolbarTitleMenu { EmptyView() }
        #endif
        .toolbar {
            Toolbar(
                fileURL: shownURL,
                controller: webController,
                findController: findController,
                reloader: reloader,
                navigator: navigator
            )
        }
        .focusedSceneValue(\.findController, findController)
        .focusedSceneValue(\.documentReloader, reloader)
        .task {
            LinkFolderAccess.shared.loadGrantedFolders()
        }
        .task(id: fileURL) {
            navigator.setRoot(fileURL)
        }
        .task(id: navigator.current) {
            reloader.show(navigator.current)
        }
        .task(id: reloader.source) {
            findController.hide()
            await render()
        }
        .onChange(of: webController.isReady) { _, ready in
            if ready { findController.webView = webController.webView }
        }
    }

    @MainActor
    private func render() async {
        let source = reloader.source
        webController.isReady = false
        let result = await Task.detached(priority: .userInitiated) {
            MarkdownRenderer().renderHTML(from: source)
        }.value
        self.rendered = result
        refreshImageAccess()
    }
}
