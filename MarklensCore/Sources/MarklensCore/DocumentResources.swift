import Foundation

/// Local files a document points at — images, mostly.
///
/// The page is loaded with the bundled `Web/` folder as its base URL (so
/// `styles.css` resolves), which means a relative `<img src="design/icon.svg">`
/// would resolve inside the app bundle and come up empty. And even pointed at
/// the right path, the sandbox won't let us read a file next to the document
/// without a folder grant.
///
/// So relative sources are rewritten to a private scheme that the app serves
/// itself, resolving each request against the document's folder and reading it
/// through whatever folder grant the user has given.
public enum DocumentResources {
    public static let scheme = "marklens-doc"

    /// Whether the document points at any image beside itself — which is the
    /// only case that needs a folder grant to display.
    public static func referencesRelativeSources(in html: String) -> Bool {
        rewritingRelativeSources(in: html) != html
    }

    /// Rewrites relative `src` attributes to `marklens-doc:///<path>`.
    ///
    /// Absolute URLs (`https:`, `data:`, `file:`) and root-relative paths are
    /// left alone — they either work already or aren't ours to resolve.
    public static func rewritingRelativeSources(in html: String) -> String {
        let pattern = #"(<(?:img|source)\b[^>]*?\bsrc\s*=\s*)(["'])([^"']+)\2"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        else { return html }

        let full = NSRange(html.startIndex..<html.endIndex, in: html)
        var result = html

        // Right to left, so earlier matches' ranges stay valid as we splice.
        for match in regex.matches(in: html, range: full).reversed() {
            guard match.numberOfRanges == 4,
                  let srcRange = Range(match.range(at: 3), in: result),
                  let quoteRange = Range(match.range(at: 2), in: result)
            else { continue }

            let src = String(result[srcRange])
            guard isDocumentRelative(src), let rewritten = resourceURL(for: src) else { continue }

            let quote = String(result[quoteRange])
            result.replaceSubrange(srcRange, with: rewritten)
            _ = quote  // quoting is preserved by only replacing the value
        }
        return result
    }

    /// True when `src` points at a file alongside the document, rather than at
    /// the network or an embedded blob.
    static func isDocumentRelative(_ src: String) -> Bool {
        let value = src.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return false }
        if value.hasPrefix("/") { return false }        // root-relative: not ours
        if value.hasPrefix("#") { return false }        // fragment
        if value.hasPrefix("//") { return false }       // protocol-relative
        // Any explicit scheme (https:, data:, file:, mailto:) is already absolute.
        if let colon = value.firstIndex(of: ":") {
            let scheme = value[value.startIndex..<colon]
            if !scheme.isEmpty, scheme.allSatisfy({ $0.isLetter || $0.isNumber || "+-.".contains($0) }) {
                return false
            }
        }
        return true
    }

    /// `design/icon.svg` → `marklens-doc:///design/icon.svg`
    static func resourceURL(for src: String) -> String? {
        // Leave existing percent-encoding intact; encode only if it isn't already.
        let encoded = src.contains("%")
            ? src
            : (src.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? src)
        return "\(scheme):///\(encoded)"
    }

    /// The path a `marklens-doc:` request is asking for, relative to the
    /// document's folder. Nil if it escapes into nonsense.
    public static func relativePath(from url: URL) -> String? {
        guard url.scheme == scheme else { return nil }
        let path = url.path
        guard !path.isEmpty, path != "/" else { return nil }
        return String(path.dropFirst())  // strip the leading "/"
    }
}