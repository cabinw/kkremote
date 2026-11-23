import XCTest

final class InteractionUITests: XCTestCase {
    private var app: XCUIApplication!
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["chooseWindow"].waitForExistence(timeout: 10))
    }
    override func tearDownWithError() throws { XCUIDevice.shared.orientation = .portrait }

    private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    private func selectDocument() {
        app.buttons["chooseWindow"].tap()
        app.buttons["window-文档"].tap()
        XCTAssertTrue(app.buttons["chooseWindow"].label.contains("文档"))
    }
    func testLetterboxAndSourceCoordinates() {
        let surface = app.otherElements["viewportGestureSurface"]
        XCTAssertTrue(surface.waitForExistence(timeout: 5))
        surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let status = app.staticTexts["coordinateStatus"].label
        XCTAssertTrue(status.hasPrefix("点击 · "))
        let coordinates = status.components(separatedBy: " · ").last!.components(separatedBy: ", ").compactMap(Double.init)
        XCTAssertEqual(coordinates.count, 2)
        // XCTest quantizes its injected screen location; allow two source points
        // at phone aspect-fit scale. Pure geometry is checked to 1e-6 separately.
        XCTAssertEqual(coordinates[0], 640, accuracy: 2)
        XCTAssertEqual(coordinates[1], 360, accuracy: 2)
        surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.02)).tap()
        XCTAssertEqual(app.staticTexts["coordinateStatus"].label, "画面外 · 已忽略")
        screenshot("portrait-fit")
    }
    func testZoomWindowSwitchAndRotation() {
        app.buttons["zoomIn"].tap()
        XCTAssertEqual(app.staticTexts["zoomValue"].label, "150%")
        app.buttons["fitWindow"].tap()
        XCTAssertEqual(app.staticTexts["zoomValue"].label, "100%")
        app.buttons["zoomIn"].tap()
        selectDocument()
        XCTAssertEqual(app.staticTexts["zoomValue"].label, "100%")
        screenshot("portrait-document")
        app.buttons["zoomIn"].tap()
        XCUIDevice.shared.orientation = .landscapeLeft
        let reset = NSPredicate(format: "label == %@", "100%")
        expectation(for: reset, evaluatedWith: app.staticTexts["zoomValue"])
        waitForExpectations(timeout: 5)
        let landscape = NSPredicate { _, _ in self.app.frame.width > self.app.frame.height }
        expectation(for: landscape, evaluatedWith: app)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(app.buttons["toggleKeyboard"].isHittable)
        // Perform a post-rotation interaction so the screenshot is captured after
        // the interface orientation animation, not during the compositor transition.
        app.buttons["fitWindow"].tap()
        let surface = app.otherElements["viewportGestureSurface"]
        surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.staticTexts["coordinateStatus"].label.hasPrefix("点击 · "))
        screenshot("landscape-document")
    }
    func testLocalKeyboardAndModeSwitch() {
        app.buttons["inputMode"].tap()
        XCTAssertTrue(app.buttons["inputMode"].label.contains("触控板"))
        app.buttons["toggleKeyboard"].tap()
        let field = app.textViews["textDraft"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap(); field.typeText("Hello iPad 123")
        XCTAssertTrue(app.buttons["commitText"].isHittable)
        screenshot("keyboard-local-draft")
        app.buttons["commitText"].tap()
        XCTAssertEqual(app.staticTexts["coordinateStatus"].label, "已提交至本地预览")
        XCTAssertFalse(app.buttons["commitText"].isEnabled)
        selectDocument()
        XCTAssertFalse(app.textViews["textDraft"].exists)
    }
    func testPinchAndRelativePointer() {
        let surface = app.otherElements["viewportGestureSurface"]
        surface.pinch(withScale: 2, velocity: 1)
        XCTAssertNotEqual(app.staticTexts["zoomValue"].label, "100%")
        app.buttons["fitWindow"].tap()
        surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.7)
        XCTAssertTrue(app.staticTexts["coordinateStatus"].label.hasPrefix("右键预览"))
        app.buttons["inputMode"].tap()
        surface.swipeLeft(velocity: .slow)
        XCTAssertTrue(app.staticTexts["coordinateStatus"].label.hasPrefix("指针"))
        screenshot("relative-pointer")
    }
    func testHoldDragReleases() {
        let surface = app.otherElements["viewportGestureSurface"]
        let start = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.55))
        start.press(forDuration: 0.6, thenDragTo: end)
        XCTAssertEqual(app.staticTexts["coordinateStatus"].label, "拖拽已释放")
        screenshot("drag-released")
    }
    func testChinesePinyinCandidateAndCancel() {
        app.buttons["toggleKeyboard"].tap()
        let field = app.textViews["textDraft"]
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap()
        for letter in ["n", "i", "h", "a", "o"] { app.keys[letter].tap() }
        XCTAssertEqual(app.staticTexts["compositionStatus"].label, "选择候选词后再发送")
        XCTAssertFalse(app.buttons["commitText"].isEnabled)
        let candidate = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "你好")).firstMatch
        if !candidate.waitForExistence(timeout: 5) {
            print(app.debugDescription)
            screenshot("chinese-candidate-missing")
            XCTFail("Chinese Pinyin candidate 你好 is not available on this simulator")
            return
        }
        candidate.tap()
        XCTAssertTrue(app.buttons["commitText"].isEnabled)
        screenshot("chinese-confirmed")
        app.buttons["commitText"].tap()
        XCTAssertEqual(app.staticTexts["committedText"].label, "你好")
        XCTAssertFalse(app.buttons["commitText"].isEnabled)
        field.tap()
        for letter in ["z", "h", "o", "n", "g"] { app.keys[letter].tap() }
        app.buttons["cancelText"].tap()
        XCTAssertEqual(field.value as? String, "")
        XCTAssertEqual(app.staticTexts["committedText"].label, "你好")
    }
    func testBackgroundCancelsDraft() {
        app.buttons["toggleKeyboard"].tap()
        let field = app.textViews["textDraft"]
        field.tap(); field.typeText("unsubmitted")
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, "")
        XCTAssertEqual(app.staticTexts["committedText"].label, "尚未发送文字")
    }

}
