import XCTest
@testable import MarklensCore

final class LinkResolverTests: XCTestCase {
    private let doc = URL(fileURLWithPath: "/Users/x/Development/STATUS.md")

    // MARK: External links

    func testHTTPSIsExternal() {
        XCTAssertEqual(
            LinkResolver.externalURL(for: "https://example.com/a")?.absoluteString,
            "https://example.com/a"
        )
    }

    func testMailtoIsExternal() {
        XCTAssertNotNil(LinkResolver.externalURL(for: "mailto:a@b.com"))
    }

    func testRelativePathIsNotExternal() {
        XCTAssertNil(LinkResolver.externalURL(for: "OTHER.md"))
        XCTAssertNil(LinkResolver.externalURL(for: "sub/OTHER.md"))
        XCTAssertNil(LinkResolver.externalURL(for: "../UP.md"))
    }

    // MARK: Relative resolution

    func testSiblingResolvesNextToDocument() {
        XCTAssertEqual(
            LinkResolver.documentRelativeURL(for: "INVENTORY.md", from: doc)?.path,
            "/Users/x/Development/INVENTORY.md"
        )
    }

    func testSubdirectory() {
        XCTAssertEqual(
            LinkResolver.documentRelativeURL(for: "notes/DEEP.md", from: doc)?.path,
            "/Users/x/Development/notes/DEEP.md"
        )
    }

    /// The old bundle-URL remapping couldn't express these at all.
    func testParentTraversal() {
        XCTAssertEqual(
            LinkResolver.documentRelativeURL(for: "../README.md", from: doc)?.path,
            "/Users/x/README.md"
        )
    }

    func testDoubleParentTraversal() {
        XCTAssertEqual(
            LinkResolver.documentRelativeURL(for: "../../top.md", from: doc)?.path,
            "/Users/top.md"
        )
    }

    func testFragmentIsStripped() {
        XCTAssertEqual(
            LinkResolver.documentRelativeURL(for: "OTHER.md#section", from: doc)?.path,
            "/Users/x/Development/OTHER.md"
        )
    }

    func testPercentEncodedSpace() {
        XCTAssertEqual(
            LinkResolver.documentRelativeURL(for: "My%20Doc.md", from: doc)?.path,
            "/Users/x/Development/My Doc.md"
        )
    }

    /// Markdown in the wild often has raw spaces, which `URL(string:)` rejects.
    func testRawSpaceFallsBackToPathAppend() {
        XCTAssertEqual(
            LinkResolver.documentRelativeURL(for: "My Doc.md", from: doc)?.path,
            "/Users/x/Development/My Doc.md"
        )
    }

    func testBareFragmentResolvesToNothing() {
        XCTAssertNil(LinkResolver.documentRelativeURL(for: "#heading", from: doc))
    }

    func testEmptyHrefResolvesToNothing() {
        XCTAssertNil(LinkResolver.documentRelativeURL(for: "", from: doc))
    }
}