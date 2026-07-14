import XCTest
@testable import MarklensCore

final class DocumentResourcesTests: XCTestCase {

    // MARK: What counts as ours to resolve

    func testRelativePathsAreDocumentRelative() {
        XCTAssertTrue(DocumentResources.isDocumentRelative("design/icon.svg"))
        XCTAssertTrue(DocumentResources.isDocumentRelative("icon.png"))
        XCTAssertTrue(DocumentResources.isDocumentRelative("../shared/logo.svg"))
    }

    func testAbsoluteAndEmbeddedSourcesAreLeftAlone() {
        XCTAssertFalse(DocumentResources.isDocumentRelative("https://example.com/a.png"))
        XCTAssertFalse(DocumentResources.isDocumentRelative("http://example.com/a.png"))
        XCTAssertFalse(DocumentResources.isDocumentRelative("data:image/png;base64,AAAA"))
        XCTAssertFalse(DocumentResources.isDocumentRelative("file:///tmp/a.png"))
        XCTAssertFalse(DocumentResources.isDocumentRelative("//cdn.example.com/a.png"))
        XCTAssertFalse(DocumentResources.isDocumentRelative("/absolute/a.png"))
        XCTAssertFalse(DocumentResources.isDocumentRelative(""))
    }

    // MARK: Rewriting

    /// The exact case from the project README.
    func testRewritesRawHTMLImage() {
        let html = #"<p align="center">\#n  <img src="design/icon.svg" width="160" alt="Marklens icon"/>\#n</p>"#
        let out = DocumentResources.rewritingRelativeSources(in: html)
        XCTAssertTrue(out.contains(#"src="marklens-doc:///design/icon.svg""#), out)
        // Everything else about the tag survives.
        XCTAssertTrue(out.contains(#"width="160""#))
        XCTAssertTrue(out.contains(#"alt="Marklens icon""#))
    }

    func testRewritesMarkdownImage() {
        let html = #"<p><img src="design/icon.svg" /></p>"#
        let out = DocumentResources.rewritingRelativeSources(in: html)
        XCTAssertTrue(out.contains(#"src="marklens-doc:///design/icon.svg""#), out)
    }

    func testLeavesRemoteImagesUntouched() {
        let html = #"<img src="https://example.com/badge.svg">"#
        XCTAssertEqual(DocumentResources.rewritingRelativeSources(in: html), html)
    }

    func testLeavesDataURIsUntouched() {
        let html = #"<img src="data:image/png;base64,AAAA">"#
        XCTAssertEqual(DocumentResources.rewritingRelativeSources(in: html), html)
    }

    func testRewritesMultipleImagesInOnePass() {
        let html = #"<img src="a.png"><img src="https://x.com/b.png"><img src="sub/c.png">"#
        let out = DocumentResources.rewritingRelativeSources(in: html)
        XCTAssertTrue(out.contains(#"src="marklens-doc:///a.png""#), out)
        XCTAssertTrue(out.contains(#"src="https://x.com/b.png""#), out)
        XCTAssertTrue(out.contains(#"src="marklens-doc:///sub/c.png""#), out)
    }

    func testEncodesSpaces() {
        let html = #"<img src="my images/logo.png">"#
        let out = DocumentResources.rewritingRelativeSources(in: html)
        XCTAssertTrue(out.contains(#"src="marklens-doc:///my%20images/logo.png""#), out)
    }

    func testDoesNotDoubleEncode() {
        let html = #"<img src="my%20images/logo.png">"#
        let out = DocumentResources.rewritingRelativeSources(in: html)
        XCTAssertTrue(out.contains(#"src="marklens-doc:///my%20images/logo.png""#), out)
    }

    func testSingleQuotedSourceIsRewritten() {
        let html = "<img src='design/icon.svg'>"
        let out = DocumentResources.rewritingRelativeSources(in: html)
        XCTAssertTrue(out.contains("src='marklens-doc:///design/icon.svg'"), out)
    }

    // MARK: Serving

    func testRelativePathRoundTrips() {
        let url = URL(string: "marklens-doc:///design/icon.svg")!
        XCTAssertEqual(DocumentResources.relativePath(from: url), "design/icon.svg")
    }

    func testRelativePathDecodesPercentEscapes() {
        let url = URL(string: "marklens-doc:///my%20images/logo.png")!
        XCTAssertEqual(DocumentResources.relativePath(from: url), "my images/logo.png")
    }

    func testRelativePathRejectsForeignScheme() {
        let url = URL(string: "https://example.com/a.png")!
        XCTAssertNil(DocumentResources.relativePath(from: url))
    }
}