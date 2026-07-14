import SwiftUI
import WebKit
import MarklensCore

#if os(macOS)
typealias PlatformViewRepresentable = NSViewRepresentable

/// WKWebView that hands its context menu to the coordinator for repair before
/// it's shown. Subclassing is the only hook AppKit offers here — WebKit's
/// `contextMenuConfigurationForElement` delegate method is UIKit-only.
final class MarklensWebView: WKWebView {
    weak var coordinator: MarkdownWebView.Coordinator?

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        coordinator?.repairLinkMenu(menu)
    }
}
#else
typealias PlatformViewRepresentable = UIViewRepresentable
#endif

struct MarkdownWebView: PlatformViewRepresentable {
    let rendered: RenderedDocument
    let dark: Bool
    let baseURL: URL?
    let fileURL: URL?
    let controller: WebViewController
    /// Show a linked file in this window. iOS only — on macOS a link opens its
    /// own document window instead.
    var onNavigate: ((URL) -> Void)?
    /// Bumped to force a reload when the content is unchanged but its *resources*
    /// have become readable — i.e. the user just granted the folder, and the
    /// images that failed a moment ago would now succeed.
    var reloadToken: Int = 0

    #if os(macOS)
    func makeNSView(context: Context) -> WKWebView { makeWebView(context: context) }
    func updateNSView(_ webView: WKWebView, context: Context) { update(webView, context: context) }
    #else
    func makeUIView(context: Context) -> WKWebView { makeWebView(context: context) }
    func updateUIView(_ webView: WKWebView, context: Context) { update(webView, context: context) }
    #endif

    func makeCoordinator() -> Coordinator { Coordinator() }

    private func makeWebView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs

        // Serves the document's own images. Must be registered before the web
        // view exists — the scheme can't be added to a live configuration.
        config.setURLSchemeHandler(
            context.coordinator.resourceHandler, forURLScheme: DocumentResources.scheme
        )

        // Report the scroll position back to the coordinator so a reload can
        // restore it in place instead of snapping to the top. rAF-throttled to
        // keep scroll cheap.
        let scrollReporter = WKUserScript(
            source: """
            (function () {
                var ticking = false;
                function report() {
                    try { window.webkit.messageHandlers.marklensScroll.postMessage(window.scrollY); } catch (e) {}
                }
                window.addEventListener('scroll', function () {
                    if (ticking) return;
                    ticking = true;
                    requestAnimationFrame(function () { report(); ticking = false; });
                }, { passive: true });
            })();
            """,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(scrollReporter)
        config.userContentController.add(context.coordinator, name: "marklensScroll")

        // Intercept link interactions in-page and hand the RAW href to Swift.
        //
        // We can't use decidePolicyFor for this: in a sandboxed app WebKit
        // never delivers the policy callback for file:// link clicks (the web
        // process drops the navigation before consulting the client), so
        // clicks silently did nothing. Listening in the page sidesteps
        // navigation entirely — and the raw href (pre-resolution) is what we
        // want anyway, since WebKit would otherwise resolve it against the
        // bundled Web/ base URL. It also makes ../relative links work.
        //
        // The right-click menu is WebKit's own — we keep it and repair the
        // link items in `willOpenMenu` rather than replacing the menu. That
        // needs the href of the link under the pointer, but the menu is built
        // in the UI process where the DOM isn't reachable, so the page reports
        // hover changes up front. Posting on hover (not on right-click) means
        // Swift already knows the link well before the menu is constructed.
        let linkInterceptor = WKUserScript(
            source: """
            (function () {
                function hrefAt(node) {
                    var a = node && node.closest ? node.closest('a[href]') : null;
                    if (!a) return '';
                    var href = a.getAttribute('href');
                    if (!href || href.charAt(0) === '#') return '';  // in-page anchor
                    return href;
                }
                document.addEventListener('click', function (e) {
                    if (e.defaultPrevented) return;
                    var href = hrefAt(e.target);
                    if (!href) return;  // not a link: leave it to the page
                    e.preventDefault();
                    try { window.webkit.messageHandlers.marklensLink.postMessage(href); } catch (err) {}
                }, true);

                var current = '';
                function track(e) {
                    var href = hrefAt(e.target);
                    if (href === current) return;
                    current = href;
                    try { window.webkit.messageHandlers.marklensHoverLink.postMessage(href); } catch (err) {}
                }
                document.addEventListener('mouseover', track, true);
                // mousemove also covers content scrolling under a still cursor.
                document.addEventListener('mousemove', track, true);
                document.addEventListener('contextmenu', track, true);  // no preventDefault
                // iOS has no hover: a long-press menu is preceded by touchstart.
                document.addEventListener('touchstart', track, true);
            })();
            """,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(linkInterceptor)
        config.userContentController.add(context.coordinator, name: "marklensLink")
        config.userContentController.add(context.coordinator, name: "marklensHoverLink")

        #if os(macOS)
        let webView = MarklensWebView(frame: .zero, configuration: config)
        webView.coordinator = context.coordinator
        #else
        let webView = WKWebView(frame: .zero, configuration: config)
        // Long-press menu for links (the iOS counterpart of willOpenMenu).
        webView.uiDelegate = context.coordinator
        #endif
        webView.navigationDelegate = context.coordinator
        context.coordinator.controller = controller
        controller.webView = webView
        // Enable Web Inspector (Cmd+Opt+I) so devs can debug the rendered page.
        if webView.responds(to: Selector(("setInspectable:"))) {
            webView.perform(Selector(("setInspectable:")), with: true)
        }
        #if os(macOS)
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsMagnification = true  // trackpad pinch-to-zoom
        #else
        webView.isOpaque = false
        webView.backgroundColor = .clear
        // Stop UIScrollView from auto-adjusting content insets for the safe
        // area / status bar — that's the SwiftUI parent's job. With
        // .automatic we sometimes saw a small horizontal scroll offset on
        // iPhone that made content look cropped on the left.
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        #endif
        return webView
    }

    private func update(_ webView: WKWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.documentURL = fileURL
        coordinator.resourceHandler.documentURL = fileURL
        coordinator.onNavigate = onNavigate
        let html = HTMLTemplate.page(
            // Point the document's own images at our scheme handler; left as
            // written, they'd resolve against the bundle and come up empty.
            body: DocumentResources.rewritingRelativeSources(in: rendered.body),
            containsMermaid: rendered.containsMermaid,
            dark: dark
        )
        // Only reload if the rendered content changed; theme-only changes are pushed via JS.
        if coordinator.lastBody != rendered.body
            || coordinator.lastMermaid != rendered.containsMermaid
            || coordinator.lastReloadToken != reloadToken {
            coordinator.lastReloadToken = reloadToken
            let isSameFile = coordinator.lastFileURL == fileURL
            if !coordinator.lastBody.isEmpty {
                if isSameFile {
                    // Same file, new content (a reload) — hold the scroll offset
                    // so didFinish restores it: an in-place refresh, not a jump
                    // to the top.
                    coordinator.pendingScrollY = coordinator.lastScrollY
                } else {
                    // Navigated to a different file. Remember where we were in
                    // the old one so going Back lands where we left off, and
                    // open the new one at wherever we last were in it (top, if
                    // this is the first visit).
                    if let previous = coordinator.lastFileURL {
                        coordinator.scrollMemory[previous] = coordinator.lastScrollY
                    }
                    coordinator.pendingScrollY = fileURL.flatMap { coordinator.scrollMemory[$0] }
                }
            }
            coordinator.lastFileURL = fileURL
            coordinator.lastScrollY = 0
            webView.loadHTMLString(html, baseURL: baseURL)
            coordinator.lastBody = rendered.body
            coordinator.lastMermaid = rendered.containsMermaid
            coordinator.lastDark = dark
        } else if coordinator.lastDark != dark {
            let theme = dark ? "dark" : "light"
            let hljsHref = dark ? "hljs-dark.css" : "hljs-light.css"
            let js = """
            (function(){
                document.documentElement.dataset.theme = '\(theme)';
                var link = document.getElementById('hljs-theme');
                if (link) link.href = '\(hljsHref)';
                if (window.mermaid) {
                    document.querySelectorAll('.mermaid').forEach(function(el){ el.removeAttribute('data-processed'); });
                    window.mermaid.initialize({ startOnLoad: false, securityLevel: 'strict', theme: '\(theme)' });
                    window.mermaid.run({ querySelector: '.mermaid' });
                }
            })();
            """
            webView.evaluateJavaScript(js, completionHandler: nil)
            coordinator.lastDark = dark
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler, WKUIDelegate {
        var lastBody: String = ""
        var lastMermaid: Bool = false
        var lastDark: Bool = false
        /// Latest scroll offset reported by the page (CSS px).
        var lastScrollY: Double = 0
        /// Scroll offset to restore once the reloaded page finishes loading.
        var pendingScrollY: Double?
        /// Where we last were in each file we've shown, so Back returns you to
        /// your place rather than the top.
        var scrollMemory: [URL: Double] = [:]
        /// The file whose content is currently loaded.
        var lastFileURL: URL?
        var lastReloadToken: Int = 0
        /// URL of the markdown file on disk; relative links resolve against
        /// its folder.
        var documentURL: URL?
        /// Serves the document's own images over the `marklens-doc:` scheme.
        let resourceHandler = DocumentResourceHandler()
        /// href of the link under the pointer (macOS hover) or finger (iOS
        /// touch), reported by the page. Empty when it isn't a link.
        var hoveredLinkHref: String = ""
        /// Show a linked file in this window (iOS in-place navigation).
        var onNavigate: ((URL) -> Void)?
        weak var controller: WebViewController?
        #if os(macOS)
        /// Keeps the share picker backing the context menu's Share submenu alive
        /// for as long as the menu can be used.
        private var shareMenuPicker: NSSharingServicePicker?
        #endif

        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            if message.name == "marklensScroll", let y = message.body as? NSNumber {
                lastScrollY = y.doubleValue
            } else if message.name == "marklensLink", let href = message.body as? String {
                handleLink(href: href)
            } else if message.name == "marklensHoverLink", let href = message.body as? String {
                hoveredLinkHref = href
            }
        }

        /// Follows a clicked href. Absolute schemes go to the system handler.
        /// A document-relative reference opens as its own window on macOS, and
        /// swaps into this one on iOS, where there's no second window to open.
        private func handleLink(href: String) {
            if let external = externalURL(for: href) {
                #if os(macOS)
                NSWorkspace.shared.open(external)
                #else
                UIApplication.shared.open(external)
                #endif
                return
            }
            guard let target = documentRelativeURL(for: href) else { return }
            #if os(macOS)
            Task { @MainActor in LinkFolderAccess.shared.open(target) }
            #else
            Task { @MainActor in
                LinkFolderAccess.shared.open(target) { [weak self] url in
                    self?.onNavigate?(url)
                }
            }
            #endif
        }

        /// A non-file absolute URL (https, mailto, …), or nil if `href` is a
        /// document-relative reference.
        private func externalURL(for href: String) -> URL? {
            LinkResolver.externalURL(for: href)
        }

        /// Resolves a relative href against the open document's folder.
        private func documentRelativeURL(for href: String) -> URL? {
            guard let documentURL else { return nil }
            return LinkResolver.documentRelativeURL(for: href, from: documentURL)
        }

        #if os(macOS)
        /// Repairs WebKit's own context menu in place, called from
        /// `willOpenMenu`. Every link item WebKit builds points at the URL it
        /// resolved against the bundled `Web/` base — a path that doesn't
        /// exist — and its navigation-based actions are dropped by the sandbox
        /// besides. So we retarget them at the real file. Everything we don't
        /// name here (Services, Inspect Element, and any menu raised somewhere
        /// other than a link) is left exactly as WebKit built it.
        func repairLinkMenu(_ menu: NSMenu) {
            let href = hoveredLinkHref
            guard !href.isEmpty else { return }  // not over a link: leave it alone
            let target = documentRelativeURL(for: href)
            let isLocalFile = externalURL(for: href) == nil

            for item in menu.items {
                switch item.identifier?.rawValue {
                case MenuID.openLink:
                    item.target = self
                    item.action = #selector(openLinkFromMenu(_:))
                    item.representedObject = href

                case MenuID.copyLink:
                    item.target = self
                    item.action = #selector(copyLinkFromMenu(_:))
                    item.representedObject = href

                case MenuID.downloadLinkedFile where isLocalFile:
                    // The "download" of a file that's already on disk is a
                    // copy; ask where to put it (the save panel also gives us
                    // the sandbox write grant).
                    item.target = self
                    item.action = #selector(downloadLinkedFileFromMenu(_:))
                    item.representedObject = href

                case MenuID.shareMenu where isLocalFile:
                    if let target { replaceShareItem(item, in: menu, for: target) }

                default:
                    break  // Services, Inspect Element, … — WebKit's, untouched
                }
            }

            // Every link opens as its own document window, so "Open Link in
            // New Window" would be a second name for "Open Link".
            menu.items.removeAll { $0.identifier?.rawValue == MenuID.openLinkInNewWindow }
        }

        private enum MenuID {
            static let openLink = "WKMenuItemIdentifierOpenLink"
            static let openLinkInNewWindow = "WKMenuItemIdentifierOpenLinkInNewWindow"
            static let downloadLinkedFile = "WKMenuItemIdentifierDownloadLinkedFile"
            static let copyLink = "WKMenuItemIdentifierCopyLink"
            static let shareMenu = "WKMenuItemIdentifierShareMenu"
        }

        @objc private func openLinkFromMenu(_ sender: NSMenuItem) {
            guard let href = sender.representedObject as? String else { return }
            handleLink(href: href)
        }

        /// Copies what the link actually points at — for a relative link the
        /// resolved path on disk, not the bundle URL WebKit would report.
        @objc private func copyLinkFromMenu(_ sender: NSMenuItem) {
            guard let href = sender.representedObject as? String else { return }
            let text = externalURL(for: href)?.absoluteString
                ?? documentRelativeURL(for: href)?.path
            guard let text else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }

        @objc private func downloadLinkedFileFromMenu(_ sender: NSMenuItem) {
            guard let href = sender.representedObject as? String,
                  let target = documentRelativeURL(for: href) else { return }
            Task { @MainActor in
                LinkFolderAccess.shared.withAccess(to: target) {
                    let panel = NSSavePanel()
                    panel.nameFieldStringValue = target.lastPathComponent
                    panel.canCreateDirectories = true
                    panel.begin { response in
                        guard response == .OK, let dst = panel.url else { return }
                        try? FileManager.default.removeItem(at: dst)  // panel already confirmed overwrite
                        try? FileManager.default.copyItem(at: target, to: dst)
                    }
                }
            }
        }

        /// WebKit built the Share submenu around the bogus bundle URL, so it has
        /// to be rebuilt around the real file.
        ///
        /// Two shapes, because the sandbox forces a choice. If we can already
        /// read the file, `standardShareMenuItem` gives us the system's own
        /// submenu — identical to what WebKit would have shown, just aimed at a
        /// file that exists. If we *can't* read it yet, that submenu would list
        /// services that all fail on open, and a submenu gives us no moment to
        /// ask for the folder first — so the item becomes a plain "Share…" that
        /// requests access on click and then raises the same system picker.
        private func replaceShareItem(_ item: NSMenuItem, in menu: NSMenu, for target: URL) {
            guard let index = menu.items.firstIndex(of: item) else { return }

            if LinkFolderAccess.shared.canAccess(target) {
                // Hold the picker: the menu item it vends doesn't retain it, and
                // a released picker leaves the submenu inert.
                let picker = NSSharingServicePicker(items: [target])
                shareMenuPicker = picker
                let share = picker.standardShareMenuItem
                share.title = item.title
                menu.removeItem(at: index)
                menu.insertItem(share, at: index)
            } else {
                item.submenu = nil
                item.target = self
                item.action = #selector(shareFromMenu(_:))
                item.representedObject = target
            }
        }

        /// Only reached when we don't hold a grant yet: ask for the folder, then
        /// raise the system share picker on the now-readable file.
        @objc private func shareFromMenu(_ sender: NSMenuItem) {
            guard let target = sender.representedObject as? URL else { return }
            Task { @MainActor in
                LinkFolderAccess.shared.withAccess(to: target) {
                    guard let window = NSApp.keyWindow ?? NSApp.mainWindow,
                          let view = window.contentView
                    else { return }
                    let picker = NSSharingServicePicker(items: [target])
                    let inWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
                    let point = view.convert(inWindow, from: nil)
                    picker.show(
                        relativeTo: NSRect(origin: point, size: .zero),
                        of: view,
                        preferredEdge: .minY
                    )
                }
            }
        }
        #endif

        // MARK: iOS long-press menu

        #if os(iOS)
        /// The iOS counterpart of macOS's `willOpenMenu`. Here WebKit hands us
        /// the element up front, so there's no menu to repair — we just build
        /// the right one. Only relative links need us: for external links we
        /// return nil and WebKit's own menu (Open in Safari, Add to Reading
        /// List, …) is shown untouched.
        func webView(_ webView: WKWebView,
                     contextMenuConfigurationForElement elementInfo: WKContextMenuElementInfo,
                     completionHandler: @escaping (UIContextMenuConfiguration?) -> Void) {
            let href = hoveredLinkHref
            guard !href.isEmpty, externalURL(for: href) == nil,
                  let target = documentRelativeURL(for: href)
            else {
                completionHandler(nil)
                return
            }

            let config = UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
                let open = UIAction(
                    title: "Open", image: UIImage(systemName: "doc.text")
                ) { [weak self] _ in
                    LinkFolderAccess.shared.open(target) { url in
                        self?.onNavigate?(url)
                    }
                }
                let copy = UIAction(
                    title: "Copy Link", image: UIImage(systemName: "doc.on.doc")
                ) { _ in
                    UIPasteboard.general.string = target.path
                }
                let share = UIAction(
                    title: "Share…", image: UIImage(systemName: "square.and.arrow.up")
                ) { _ in
                    LinkFolderAccess.shared.withAccess(to: target) {
                        IOSPresenter.share(target)
                    }
                }
                return UIMenu(title: target.lastPathComponent, children: [open, copy, share])
            }
            completionHandler(config)
        }
        #endif

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if let y = pendingScrollY {
                pendingScrollY = nil
                if y > 0 {
                    webView.evaluateJavaScript("window.scrollTo(0, \(y));", completionHandler: nil)
                }
            }
            Task { @MainActor in self.controller?.isReady = true }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow); return
            }
            // Allow the initial loadHTMLString navigation (about:blank or file://).
            if navigationAction.navigationType == .other,
               url.scheme == "about" || url.isFileURL {
                decisionHandler(.allow); return
            }
            // Link clicks are handled in-page by the injected interceptor,
            // which posts the raw href to `handleLink` and cancels the DOM
            // navigation. Anything still arriving here (a stray link that
            // slipped past JS, a JS-driven location change) must not be
            // allowed to navigate the web view away from the document.
            if navigationAction.navigationType == .linkActivated {
                decisionHandler(.cancel); return
            }
            decisionHandler(.allow)
        }
    }
}
