import Foundation

/// Works out what a link in a markdown document actually points at.
///
/// The rendered page is loaded with the bundled `Web/` directory as its base
/// URL (so `styles.css` and friends resolve), which means WebKit resolves a
/// link like `[x](OTHER.md)` against the *app bundle* — a path that doesn't
/// exist. So Marklens intercepts clicks in the page and resolves the raw href
/// itself, against the folder of the file being viewed.
public enum LinkResolver {
    /// An absolute non-file URL (https, mailto, …) that belongs to the system
    /// handler, or nil when `href` is a document-relative reference.
    public static func externalURL(for href: String) -> URL? {
        guard let url = URL(string: href), let scheme = url.scheme,
              !scheme.isEmpty, !url.isFileURL
        else { return nil }
        return url
    }

    /// Resolves a document-relative href against the folder holding
    /// `documentURL`. Returns nil for hrefs with nothing to resolve (empty, or
    /// a bare `#fragment`).
    ///
    /// Any fragment is dropped — Marklens can't yet deep-link to a heading in
    /// another file.
    public static func documentRelativeURL(for href: String, from documentURL: URL) -> URL? {
        // omittingEmptySubsequences must stay off: a bare "#heading" has an
        // empty path part, and dropping it would resolve the fragment itself
        // as a filename.
        let pathPart = href
            .split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? ""
        guard !pathPart.isEmpty else { return nil }

        let folder = documentURL.deletingLastPathComponent()
        // An href may be percent-encoded ("My%20Doc.md") or raw ("My Doc.md").
        // URL(string:) handles the former and rejects the latter, so fall back
        // to appending the path verbatim.
        return URL(string: pathPart, relativeTo: folder)?.standardizedFileURL
            ?? folder.appendingPathComponent(pathPart).standardizedFileURL
    }
}