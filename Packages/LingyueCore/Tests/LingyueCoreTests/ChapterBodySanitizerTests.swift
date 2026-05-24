import XCTest
@testable import LingyueCore

/// Verifies the universal chapter-body sanitizer used by both
/// `RuleBasedBookSource.fetchChapter` and `JSONAPIBookSource.decodeChapter`.
final class ChapterBodySanitizerTests: XCTestCase {

    // MARK: - Title echoes

    func testStripsExactLeadingTitleEcho() {
        let result = ChapterBodySanitizer.sanitize(
            paragraphs: ["第51章 暗杀！", "正文第一段", "正文第二段"],
            title: "第51章 暗杀！"
        )
        XCTAssertEqual(result, ["正文第一段", "正文第二段"])
    }

    func testStripsTitleWithPaginationSuffix() {
        // A couple of sources stamp `(1/2)` on the duplicate title that
        // sits at the top of every page.
        let result = ChapterBodySanitizer.sanitize(
            paragraphs: ["第51章 暗杀！(1/2)", "正文第一段"],
            title: "第51章 暗杀！"
        )
        XCTAssertEqual(result, ["正文第一段"])
    }

    func testStripsGenericChapterHeadingEvenWhenTitleEmpty() {
        // Title-less rule shouldn't matter — the generic "第N章 …"
        // shape is enough to flag a leading header.
        let result = ChapterBodySanitizer.sanitize(
            paragraphs: ["第3回 山雨欲来", "正文…"],
            title: nil
        )
        XCTAssertEqual(result, ["正文…"])
    }

    func testKeepsTitleShapedSentenceMidProse() {
        // Sentence happens to start with "第" but it's not a heading.
        let body = ["第一次见到他时，我没有多想。", "故事开始了。"]
        let result = ChapterBodySanitizer.sanitize(paragraphs: body, title: "第一章 序")
        XCTAssertEqual(result, body)
    }

    // MARK: - Author bylines

    func testStripsLeadingAuthorByline() {
        let result = ChapterBodySanitizer.sanitize(
            paragraphs: ["作者：吃奶的小猪", "正文…"],
            title: "第1节"
        )
        XCTAssertEqual(result, ["正文…"])
    }

    func testStripsLeadingTitleAndAuthorComposite() {
        // Some source templates stamp "<book title> 作者：<name>" as the
        // first paragraph inside `read_chapterDetail`.
        let result = ChapterBodySanitizer.sanitize(
            paragraphs: [
                "综漫轮回：我杀穿了主神空间！ 作者：爱晒太阳的橘猫",
                "白羽穿越到综漫世界…"
            ],
            title: "第1章"
        )
        XCTAssertEqual(result, ["白羽穿越到综漫世界…"])
    }

    func testKeepsLongParagraphMentioningAuthor() {
        // Inline author mention in a long sentence shouldn't be dropped.
        let long = String(repeating: "这本书的作者：佚名 — 但故事比作者更重要，", count: 5)
        let result = ChapterBodySanitizer.sanitize(paragraphs: [long, "next"], title: nil)
        XCTAssertEqual(result, [long, "next"])
    }

    // MARK: - Pagination markers

    func testStripsBarePaginationMarker() {
        let result = ChapterBodySanitizer.sanitize(
            paragraphs: ["正文…", "(1/2)", "更多正文…"],
            title: nil
        )
        XCTAssertEqual(result, ["正文…", "更多正文…"])
    }

    // MARK: - Boilerplate

    func testStripsKnownBoilerplate() {
        let result = ChapterBodySanitizer.sanitize(
            paragraphs: ["正文…", "请收藏本站，方便下次阅读。", "更多正文…"],
            title: nil
        )
        XCTAssertEqual(result, ["正文…", "更多正文…"])
    }

    func testEmptyInputReturnsEmpty() {
        XCTAssertEqual(
            ChapterBodySanitizer.sanitize(paragraphs: [], title: "anything"),
            []
        )
    }
}
