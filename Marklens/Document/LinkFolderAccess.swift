import Foundation
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Reaches the files a document points at — sibling documents it links to, and
/// the images it embeds — despite the app sandbox.
///
/// A sandboxed app is handed the one file the user opened and nothing else. Not
/// the folder, not the siblings, not `design/icon.svg`. Marklens is a viewer for
/// documents it didn't write, referencing files it has never been shown, so it
/// has no prior claim on any of them.
///
/// The way out is the one every sandboxed editor uses: the user points at a
/// *folder* once, and we keep that grant as a security-scoped bookmark. Grants
/// are checked by walking a file's ancestors, so one folder covers everything
/// beneath it — every document, image, and link in the tree, on every later
/// launch. Two ways in:
///
/// - `addFolder` — the user volunteers one ("here's where my documents live").
///   Reads as configuration rather than a permission demand, and it's the only
///   flow that works well on iOS.
/// - `withAccess` — the lazy fallback, when a document needs something we can't
///   read yet and there's no grant to lean on.
///
/// The plumbing differs by platform: macOS uses `NSOpenPanel` and
/// `.withSecurityScope` bookmarks (hence the
/// `com.apple.security.files.bookmarks.app-scope` entitlement), while iOS uses
/// `UIDocumentPickerViewController` and plain bookmarks — `.withSecurityScope`
/// is unavailable there, and scope is implicit for picker-provided URLs.
@MainActor
final class LinkFolderAccess: NSObject, ObservableObject {
    static let shared = LinkFolderAccess()

    private static let defaultsKey = "linkFolderBookmarks"

    /// Folders whose security scope is active this launch, keyed by path. Held
    /// for the app's lifetime — the set stays small.
    private var active: [String: URL] = [:]

    private override init() {}

    /// Runs `action` once `target` is readable, asking the user to grant its
    /// folder first if we don't already hold a grant. Does nothing if the user
    /// declines.
    func withAccess(to target: URL, perform action: @escaping @MainActor () -> Void) {
        let folder = target.deletingLastPathComponent().standardizedFileURL
        if ensureAccess(to: folder) || FileManager.default.isReadableFile(atPath: target.path) {
            action()
            return
        }
        requestAccess(to: folder, for: target) { [weak self] in
            guard let self, self.ensureAccess(to: folder) else { return }
            action()
        }
    }

    /// Whether `target` is readable *right now* — i.e. `withAccess` would run
    /// straight through without prompting. Lets callers that can't prompt (a
    /// menu being built) choose a different shape up front.
    func canAccess(_ target: URL) -> Bool {
        ensureAccess(to: target.deletingLastPathComponent().standardizedFileURL)
            || FileManager.default.isReadableFile(atPath: target.path)
    }

    /// Whether we can read files inside `folder` itself.
    func canAccessFolder(_ folder: URL) -> Bool {
        ensureAccess(to: folder.standardizedFileURL)
    }

    /// The user adding a folder outright — "here's where my documents live" —
    /// rather than being asked for one mid-task.
    ///
    /// This is the flow we steer people toward: it's the only one that reads as
    /// configuration instead of a permission demand, and it's the only one that
    /// works well on iOS, where the picker can't be pointed at a folder we have
    /// no access to (so there's nothing to point it at — the user just browses).
    /// A folder grant covers everything beneath it, so one well-chosen folder
    /// ends the prompting for good.
    ///
    /// `startingAt` seeds the panel on macOS, where a directory can be shown
    /// before it's readable. Ignored on iOS, which refuses to reveal one.
    func addFolder(startingAt suggestion: URL? = nil,
                   then completion: (@MainActor (URL) -> Void)? = nil) {
        presentFolderChooser(startingAt: suggestion) { [weak self] granted in
            guard let self else { return }
            self.remember(granted)
            self.grantedFolders = self.storedFolderURLs()
            completion?(granted)
        }
    }

    /// Folders the user has granted, for display. Republished so views can
    /// react when a new grant lands.
    @Published private(set) var grantedFolders: [URL] = []

    /// Forget a folder — the grant is dropped and its bookmark deleted.
    func removeFolder(_ folder: URL) {
        let key = folder.standardizedFileURL.path
        if let active = active[key] {
            active.stopAccessingSecurityScopedResource()
        }
        active[key] = nil
        var s = stored
        s[key] = nil
        stored = s
        grantedFolders = storedFolderURLs()
    }

    /// Resolves stored bookmarks to URLs without activating them.
    private func storedFolderURLs() -> [URL] {
        stored.keys.sorted().map { URL(fileURLWithPath: $0) }
    }

    /// Call once at startup so the granted list is populated for the UI.
    func loadGrantedFolders() {
        grantedFolders = storedFolderURLs()
    }

    // MARK: Grant lookup

    /// True if `folder` (or any ancestor) has an active or stored grant.
    ///
    /// Has side effects — reads UserDefaults, resolves bookmarks, opens security
    /// scopes — so call it from actions, never from a SwiftUI `body`.
    ///
    /// The walk terminates at the root, but it's bounded anyway: a URL that
    /// never converges (a relative or empty path makes `deletingLastPathComponent`
    /// prepend `../` forever) would otherwise spin a core with no way out.
    private func ensureAccess(to folder: URL) -> Bool {
        var candidate = folder
        for _ in 0..<64 {
            let path = candidate.path
            if active[path] != nil { return true }
            if let data = stored[path], activate(bookmark: data, storedAt: path) {
                return true
            }
            let parent = candidate.deletingLastPathComponent()
            if parent.path == candidate.path { return false }  // hit the root
            candidate = parent
        }
        return false
    }

    private func activate(bookmark data: Data, storedAt path: String) -> Bool {
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: Self.bookmarkResolutionOptions,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ), url.startAccessingSecurityScopedResource() else {
            var s = stored
            s[path] = nil  // dead bookmark (folder deleted?) — drop it
            stored = s
            return false
        }
        active[url.path] = url
        if isStale, let fresh = try? Self.makeBookmark(for: url) {
            var s = stored
            s[path] = nil
            s[url.path] = fresh
            stored = s
        }
        return true
    }

    /// Records a folder the user just granted us.
    ///
    /// `scopeAlreadyOpen` is for callers that had to open the security scope to
    /// inspect the URL before accepting it — starting it twice would leave an
    /// unbalanced retain on the scope.
    private func remember(_ granted: URL, scopeAlreadyOpen: Bool = false) {
        let key = granted.standardizedFileURL.path
        // Picker/panel URLs are already usable this launch; the bookmark is
        // what carries the grant into later launches.
        if !scopeAlreadyOpen { _ = granted.startAccessingSecurityScopedResource() }
        active[key] = granted
        if let data = try? Self.makeBookmark(for: granted) {
            var s = stored
            s[key] = data
            stored = s
        }
    }

    /// True when `granted` is the folder holding `target`, or an ancestor of it.
    private static func folder(_ granted: URL, covers target: URL) -> Bool {
        let g = granted.standardizedFileURL.path
        let t = target.standardizedFileURL.path
        return t == g || t.hasPrefix(g.hasSuffix("/") ? g : g + "/")
    }

    // MARK: Persistence

    private var stored: [String: Data] {
        get { (UserDefaults.standard.dictionary(forKey: Self.defaultsKey) as? [String: Data]) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: Self.defaultsKey) }
    }

    private static func makeBookmark(for url: URL) throws -> Data {
        try url.bookmarkData(
            options: bookmarkCreationOptions,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    private static var bookmarkCreationOptions: URL.BookmarkCreationOptions {
        #if os(macOS)
        [.withSecurityScope]
        #else
        []  // .withSecurityScope is unavailable on iOS; scope is implicit
        #endif
    }

    private static var bookmarkResolutionOptions: URL.BookmarkResolutionOptions {
        #if os(macOS)
        [.withSecurityScope]
        #else
        []
        #endif
    }

    // MARK: - macOS

    #if os(macOS)
    /// Follow a link: ensure access, then open the file in its own window.
    func open(_ target: URL) {
        withAccess(to: target) { [weak self] in
            self?.openTarget(target)
        }
    }

    private func openTarget(_ target: URL) {
        guard FileManager.default.fileExists(atPath: target.path) else {
            let alert = NSAlert()
            alert.messageText = "File Not Found"
            alert.informativeText =
                "The linked file “\(target.lastPathComponent)” doesn't exist."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }
        NSDocumentController.shared.openDocument(
            withContentsOf: target, display: true
        ) { _, _, error in
            if error != nil {
                // Not a type Marklens can view (image, PDF, …) — hand it to
                // the default app. Works because we hold folder access.
                NSWorkspace.shared.open(target)
            }
        }
    }

    private func requestAccess(to folder: URL, for target: URL,
                               then completion: @escaping @MainActor () -> Void) {
        presentFolderChooser(
            startingAt: folder,
            message: "To open “\(target.lastPathComponent)”, allow Marklens to read files in "
                + "this folder. Choosing a parent folder covers everything inside it, so you "
                + "won't be asked again."
        ) { [weak self] granted in
            self?.remember(granted)
            self?.grantedFolders = self?.storedFolderURLs() ?? []
            completion()
        }
    }

    /// The one place a folder grant is actually obtained on macOS. `NSOpenPanel`
    /// will happily *display* a directory we can't yet read — PowerBox brokers
    /// the grant — so we can point it straight at the folder in question and
    /// leave the user with a single "Allow" click.
    private func presentFolderChooser(
        startingAt suggestion: URL?,
        message: String = "Choose a folder Marklens may read. Everything inside it — documents, "
            + "images, and the links between them — will open without asking again.",
        then completion: @escaping @MainActor (URL) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = suggestion
        panel.message = message
        panel.prompt = "Allow"
        panel.begin { response in
            Task { @MainActor in
                guard response == .OK, let granted = panel.url else { return }
                completion(granted)
            }
        }
    }
    #endif

    // MARK: - iOS

    #if os(iOS)
    /// Follow a link: ensure access, then hand the file back to `navigate` so
    /// the current window can show it in place. Files Marklens can't render go
    /// to the share sheet instead, which is iOS's way of handing off.
    func open(_ target: URL, navigate: @escaping @MainActor (URL) -> Void) {
        withAccess(to: target) {
            guard FileManager.default.fileExists(atPath: target.path) else {
                IOSPresenter.alert(
                    title: "File Not Found",
                    message: "The linked file “\(target.lastPathComponent)” doesn't exist."
                )
                return
            }
            if Self.isReadableAsText(target) {
                navigate(target)
            } else {
                IOSPresenter.share(target)
            }
        }
    }

    /// Markdown and plain text render; anything else (image, PDF, …) doesn't.
    private static func isReadableAsText(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else {
            return false
        }
        return type.conforms(to: .text) || type.conforms(to: .plainText)
    }

    /// The picker is a one-at-a-time modal, so a single slot covers both flows:
    /// a lazy request (which knows the file it's for, and validates the pick
    /// against it) and a volunteered folder (which takes whatever is chosen).
    private struct PendingGrant {
        let folder: URL?
        let target: URL?
        let completion: (@MainActor () -> Void)?
        let volunteered: (@MainActor (URL) -> Void)?
    }

    private var pendingGrant: PendingGrant?

    /// iOS can't show the picker already pointed at the folder: revealing a
    /// directory needs a sandbox extension, and the directory we're asking
    /// about is precisely the one we have no extension for. Setting
    /// `picker.directoryURL` therefore does nothing (and in a cloud provider it
    /// fails loudly — "couldn't issue sandbox extension … CloudStorage"), so
    /// the picker opens wherever it last was and the user has to navigate.
    ///
    /// We can't name the folder for them either: in a File Provider its path
    /// component is an opaque UUID, and its human name is a display name we'd
    /// need access to the folder to read — the same access we're asking for.
    /// So we name the *file*, whose name is real, and let that identify the
    /// folder. Granting a parent covers everything under it, so this is worth
    /// doing once, high up.
    ///
    /// macOS has none of these problems: `NSOpenPanel` displays a directory it
    /// can't yet read, because PowerBox brokers the grant.
    private func requestAccess(to folder: URL, for target: URL,
                               then completion: @escaping @MainActor () -> Void) {
        guard let presenter = IOSPresenter.top() else { return }
        let alert = UIAlertController(
            title: "Allow Folder Access",
            message: "To open “\(target.lastPathComponent)”, Marklens needs permission to "
                + "read the folder it's in — the same folder as the document you're "
                + "reading.\n\nChoose that folder on the next screen. Picking a folder "
                + "above it covers everything inside, so you're only asked once.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Choose Folder", style: .default) { _ in
            Task { @MainActor in
                self.presentLazyFolderPicker(for: folder, target: target, then: completion)
            }
        })
        presenter.present(alert, animated: true)
    }

    private func presentLazyFolderPicker(for folder: URL, target: URL,
                                         then completion: @escaping @MainActor () -> Void) {
        guard let presenter = IOSPresenter.top() else { return }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
        picker.allowsMultipleSelection = false
        picker.delegate = self
        pendingGrant = PendingGrant(
            folder: folder, target: target, completion: completion, volunteered: nil
        )
        presenter.present(picker, animated: true)
    }

    /// The user volunteering a folder. Nothing to validate against and nothing
    /// to pre-point at — they browse to whatever they like, which is exactly
    /// why this flow works on iOS where the lazy one is awkward.
    private func presentFolderChooser(startingAt suggestion: URL?,
                                      then completion: @escaping @MainActor (URL) -> Void) {
        guard let presenter = IOSPresenter.top() else { return }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
        picker.allowsMultipleSelection = false
        picker.delegate = self
        pendingGrant = PendingGrant(folder: nil, target: nil, completion: nil, volunteered: completion)
        presenter.present(picker, animated: true)
    }
    #endif
}

#if os(iOS)
extension LinkFolderAccess: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController,
                        didPickDocumentsAt urls: [URL]) {
        guard let pending = pendingGrant else { return }
        pendingGrant = nil
        guard let picked = urls.first else { return }

        // Inspecting the URL needs its scope open; keep it open only if we end
        // up keeping the grant.
        let scopeOpened = picked.startAccessingSecurityScopedResource()

        // Whatever the flow, it has to be a directory — storing a file would
        // leave a grant the folder lookup can never match, so the request would
        // look like it succeeded and then quietly do nothing.
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: picked.path, isDirectory: &isDirectory
        )
        guard exists, isDirectory.boolValue else {
            if scopeOpened { picked.stopAccessingSecurityScopedResource() }
            IOSPresenter.alert(
                title: "Not a Folder",
                message: "Choose a folder, not a file. Marklens will then be able to read "
                    + "everything inside it."
            )
            return
        }

        // A lazy request was made *for* a particular file, so the folder chosen
        // has to actually contain it. A volunteered folder has nothing to prove.
        if let neededFolder = pending.folder, let target = pending.target {
            guard Self.folder(picked, covers: neededFolder) else {
                if scopeOpened { picked.stopAccessingSecurityScopedResource() }
                IOSPresenter.alert(
                    title: "Wrong Folder",
                    message: "That folder doesn't contain “\(target.lastPathComponent)”. "
                        + "Choose the folder holding the document you're reading — or any "
                        + "folder above it."
                )
                return
            }
        }

        remember(picked, scopeAlreadyOpen: scopeOpened)
        grantedFolders = storedFolderURLs()
        pending.completion?()
        pending.volunteered?(picked)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        pendingGrant = nil
    }
}
#endif