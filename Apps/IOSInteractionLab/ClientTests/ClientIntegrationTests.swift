import XCTest

final class ClientIntegrationTests: XCTestCase {
    func testClientOpensSharedPracticeAndCommitsChineseWithoutConnecting() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--offline-interaction-review"]
        app.launch()
        XCTAssertTrue(app.buttons["practiceKeyboard"].waitForExistence(timeout: 10))
        let surface = app.otherElements["viewportGestureSurface"]
        surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.staticTexts["practiceStatus"].label.hasPrefix("点击 · "))
        surface.pinch(withScale: 2, velocity: 1)
        app.buttons["practiceFit"].tap()
        let start = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.6, thenDragTo: surface.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.55)))
        XCTAssertEqual(app.staticTexts["practiceStatus"].label, "拖拽已释放")
        app.buttons["practiceKeyboard"].tap()
        app.textViews["textDraft"].tap()
        for key in ["n", "i", "h", "a", "o"] { app.keys[key].tap() }
        XCTAssertFalse(app.buttons["commitText"].isEnabled)
        let candidate = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "你好")).firstMatch
        XCTAssertTrue(candidate.waitForExistence(timeout: 5)); candidate.tap()
        app.buttons["commitText"].tap()
        XCTAssertEqual(app.staticTexts["practiceCommitted"].label, "你好")
        let evidence = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        evidence.name = "client-shared-chinese-input"; evidence.lifetime = .keepAlways; add(evidence)
        app.buttons["完成"].tap()
        XCTAssertTrue(app.buttons["连接主机"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["未连接"].exists)
    }
}
