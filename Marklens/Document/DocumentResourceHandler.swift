import Foundation
import WebKit
import UniformTypeIdentifiers
import MarklensCore

/// Serves the local files a document points at — the images in
/// `<img src="design/icon.svg">` and friends.
///
/// Rendered pages rewrite relative sources to the `marklens-doc:` scheme (see
/// `DocumentResources`), and this hands back the bytes, read from the folder
/// the document lives in. Going through a scheme handler rather than plain
/// `file:` URLs buys two things: the page's base URL can stay pointed at the
/// bundled `Web/` assets, and WebKit's cross-directory file restrictions never
/// enter into it.
///
/// Reads only succeed inside a folder the user has granted us — a sandboxed app
/// is handed the document and nothing else. A denied read fails the request,
/// leaving a broken image, which `ContentView` notices and offers to fix.
final class DocumentResourceHandler: NSObject, WKURLSchemeHandler {
    /// The document being displayed; sources resolve against its folder.
    var documentURL: URL?

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url,
              let relative = DocumentResources.relativePath(from: url),
              let documentURL
        else {
            task.didFailWithError(ResourceError.notFound)
            return
        }

        let target = documentURL.deletingLastPathComponent()
            .appendingPathComponent(relative)
            .standardizedFileURL

        guard let data = try? Data(contentsOf: target) else {
            // Either it isn't there, or the sandbox won't let us read it
            // without a folder grant. Both mean "no image".
            task.didFailWithError(ResourceError.unreadable)
            return
        }

        let mime = UTType(filenameExtension: target.pathExtension)?.preferredMIMEType
            ?? "application/octet-stream"
        let response = URLResponse(
            url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: nil
        )
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}

    enum ResourceError: Error {
        case notFound
        case unreadable
    }
}