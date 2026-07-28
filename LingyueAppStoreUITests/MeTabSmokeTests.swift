import XCTest

final class MeTabSmokeTests: XCTestCase {
    func testScreenshotFixtureOpensCleanMeTab() {
        let app = XCUIApplication()
        app.launchArguments = ["--screenshot-me", "--screenshot-fixture"]
        app.launch()

        XCTAssertTrue(app.navigationBars["我"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["红楼梦"].exists)
        XCTAssertTrue(app.staticTexts["阅读偏好"].exists)
        XCTAssertFalse(app.staticTexts["已读"].exists)
        XCTAssertFalse(app.staticTexts["正在读"].exists)
        XCTAssertFalse(app.staticTexts["已读字数"].exists)
    }
}
