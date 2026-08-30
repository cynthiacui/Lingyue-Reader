import XCTest

/// Every fixture launch pins both traditional-Chinese keys to NO through the
/// NSArgumentDomain (`-key value` launch arguments), because `xcodebuild test`
/// clones the host simulator's data container — if 繁体中文 was left enabled
/// there, every label these tests match ("阅读偏好", "书架"…) would render in
/// traditional script and the assertions would fail for reasons unrelated to
/// the code under test.
private let simplifiedChineseFixtureArguments = [
    "-app.usesTraditionalChineseInterface", "NO",
    "-reader.usesTraditionalChinese", "NO"
]

final class MeTabSmokeTests: XCTestCase {
    func testScreenshotFixtureOpensCleanMeTab() {
        let app = XCUIApplication()
        app.launchArguments = ["--screenshot-me", "--screenshot-fixture"]
            + simplifiedChineseFixtureArguments
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
            + simplifiedChineseFixtureArguments
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

final class CategoryReorderUITests: XCTestCase {
    private let firstCategoryID = "library.category.11111111-1111-4111-8111-111111111111"
    private let secondCategoryID = "library.category.22222222-2222-4222-8222-222222222222"
    private let thirdCategoryID = "library.category.33333333-3333-4333-8333-333333333333"
    private let sixthCategoryID = "library.category.66666666-6666-4666-8666-666666666666"

    func testLongPressWithoutMoveClearsCategorySelection() {
        let app = launchFixture()
        let firstCategory = category(firstCategoryID, in: app)

        XCTAssertTrue(firstCategory.waitForExistence(timeout: 5))
        firstCategory.press(forDuration: 0.8)

        XCTAssertTrue(waitUntil(timeout: 2) {
            (firstCategory.value as? String)?.hasSuffix("未拖动") == true
        })
    }

    func testDraggingCategoryReordersShelvesAndClearsSelection() {
        let app = launchFixture()
        let firstCategory = category(firstCategoryID, in: app)
        let secondCategory = category(secondCategoryID, in: app)
        let thirdCategory = category(thirdCategoryID, in: app)

        XCTAssertTrue(firstCategory.waitForExistence(timeout: 5))
        XCTAssertTrue(secondCategory.waitForExistence(timeout: 5))
        XCTAssertTrue(thirdCategory.waitForExistence(timeout: 5))
        XCTAssertTrue(firstCategory.isHittable)
        XCTAssertTrue(thirdCategory.isHittable)
        XCTAssertLessThan(firstCategory.frame.minY, secondCategory.frame.minY)
        XCTAssertLessThan(secondCategory.frame.minY, thirdCategory.frame.minY)

        firstCategory.press(
            forDuration: 0.8,
            thenDragTo: thirdCategory,
            withVelocity: .slow,
            thenHoldForDuration: 0.6
        )

        XCTAssertTrue(waitUntil(timeout: 3) {
            thirdCategory.frame.minY < firstCategory.frame.minY
        }, "Expected first category to move below third; first=\(firstCategory.frame), third=\(thirdCategory.frame)")
        XCTAssertTrue(waitUntil(timeout: 2) {
            (firstCategory.value as? String)?.hasSuffix("未拖动") == true
        }, "Expected drag selection to clear; value=\(String(describing: firstCategory.value))")
    }

    func testDraggingNearBottomAutoScrollsLongCategoryList() {
        let app = launchFixture(additionalArguments: ["--category-reorder-long-fixture"])
        let firstCategory = category(firstCategoryID, in: app)
        let sixthCategory = category(sixthCategoryID, in: app)

        XCTAssertTrue(firstCategory.waitForExistence(timeout: 5))
        XCTAssertFalse(sixthCategory.isHittable)

        let start = firstCategory.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
        )
        let lowerEdge = app.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.84)
        )
        start.press(
            forDuration: 0.8,
            thenDragTo: lowerEdge,
            withVelocity: .slow,
            thenHoldForDuration: 2
        )

        XCTAssertTrue(waitUntil(timeout: 3) {
            sixthCategory.exists && sixthCategory.isHittable
        }, "Expected the library to auto-scroll while dragging near its lower edge")
        XCTAssertTrue(waitUntil(timeout: 2) {
            (firstCategory.value as? String)?.hasSuffix("未拖动") == true
        })
        XCTAssertTrue(waitUntil(timeout: 2) {
            (firstCategory.value as? String)?.hasPrefix("第1个") == false
        }, "Expected the dragged category to be dropped at the newly revealed position")
    }

    private func launchFixture(additionalArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--screenshot-fixture", "--category-reorder-fixture"]
            + simplifiedChineseFixtureArguments
            + additionalArguments
        app.launch()
        return app
    }

    private func category(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    private func waitUntil(timeout: TimeInterval, condition: @escaping () -> Bool) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in condition() },
            object: nil
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }
}
