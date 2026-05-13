import XCTest
@testable import LingyueInternalSources

final class LingyueInternalSourcesTests: XCTestCase {
    func testBundledSourcesIsEmptyInPhase0() {
        XCTAssertTrue(LingyueInternalSources.bundledSources().isEmpty)
    }
}
