import XCTest
@testable import LingyueCore

final class URLTemplateTests: XCTestCase {
    func testUTF8Default() throws {
        let out = try URLTemplate.expand(
            "https://example.test/s?q={query}",
            query: "斗破苍穹"
        )
        // UTF-8 bytes for "斗破苍穹": E6 96 97 E7 A0 B4 E8 8B 8D E7 A9 B9
        XCTAssertEqual(
            out,
            "https://example.test/s?q=%E6%96%97%E7%A0%B4%E8%8B%8D%E7%A9%B9"
        )
    }

    func testExplicitUTF8MatchesDefault() throws {
        let q = "斗破苍穹"
        let a = try URLTemplate.expand("q={query}", query: q)
        let b = try URLTemplate.expand("q={query}", query: q, encoding: .utf8)
        XCTAssertEqual(a, b)
    }

    func testGB18030PercentEncodesInTargetCharset() throws {
        // GB18030 bytes for "斗破" are D6 7E DC C6 / well-known fixture:
        // 斗 = D5 B7, 破 = C6 C6, 苍 = B2 D4, 穹 = F1 B7
        let out = try URLTemplate.expand(
            "q={query}",
            query: "斗破苍穹",
            encoding: .gb18030
        )
        XCTAssertEqual(out, "q=%B6%B7%C6%C6%B2%D4%F1%B7")
    }

    func testGB18030AsciiPreserved() throws {
        let out = try URLTemplate.expand(
            "q={query}",
            query: "abc 123",
            encoding: .gb18030
        )
        // Space is not in urlQueryAllowed, so it should be percent-encoded.
        XCTAssertEqual(out, "q=abc%20123")
    }

    func testUnknownPlaceholderThrows() {
        XCTAssertThrowsError(try URLTemplate.expand("q={page}", query: "x"))
    }
}
