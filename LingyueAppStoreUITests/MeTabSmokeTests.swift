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

    func testReadingPreferenceLabelsMatchReaderPanel() {
        let app = XCUIApplication()
        app.launchArguments = ["--screenshot-me", "--screenshot-fixture"]
        app.launch()

        let settingsLink = app.staticTexts["阅读偏好"].firstMatch
        XCTAssertTrue(settingsLink.waitForExistence(timeout: 5))
        settingsLink.tap()
        XCTAssertTrue(app.navigationBars["阅读偏好"].waitForExistence(timeout: 5))

        let labels = ["字号", "行距", "段距"]
        let settingsHeights = labels.map { label -> CGFloat in
            let element = app.staticTexts[label].firstMatch
            XCTAssertTrue(element.waitForExistence(timeout: 2))
            return element.frame.height
        }

        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.tabBars.buttons["书架"].tap()

        let book = app.staticTexts["红楼梦"].firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 5))
        book.tap()

        let readerHelpButton = app.buttons["开始阅读"].firstMatch
        if readerHelpButton.waitForExistence(timeout: 2) {
            readerHelpButton.tap()
        }

        let readerPreferences = app.buttons["阅读偏好"].firstMatch
        if !readerPreferences.waitForExistence(timeout: 1) {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        XCTAssertTrue(readerPreferences.waitForExistence(timeout: 5))
        readerPreferences.tap()

        for (index, label) in labels.enumerated() {
            let element = app.staticTexts[label].firstMatch
            XCTAssertTrue(element.waitForExistence(timeout: 2))
            XCTAssertEqual(
                element.frame.height,
                settingsHeights[index],
                accuracy: 0.5,
                "\(label) should use the same label size in both preference surfaces"
            )
        }
    }
}
