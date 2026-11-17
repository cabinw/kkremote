import XCTest

final class IPhoneWorkspaceTests: XCTestCase {
    private let app = XCUIApplication()
    override func setUp() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = ["--iphone-workspace-review"]; app.launch()
        XCTAssertTrue(app.buttons["phoneMenu"].waitForExistence(timeout:10))
        XCTAssertEqual(app.buttons["phoneMenu"].value as? String,"旅行计划")
    }
    override func tearDown() { XCUIDevice.shared.orientation = .portrait }
    private func tool(_ identifier: String) {
        let menu = app.buttons["phoneMenu"]
        let ready = NSPredicate { _,_ in menu.isHittable }
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:ready,object:nil)],timeout:5),.completed)
        menu.tap()
        XCTAssertTrue(app.buttons[identifier].waitForExistence(timeout:3))
        app.buttons[identifier].tap()
    }

    func testContentFirstLayoutAndWindowSwitch() {
        let surface = app.otherElements["viewportGestureSurface"]
        XCTAssertGreaterThan(surface.frame.height,app.frame.height*0.85)
        XCTAssertFalse(app.buttons["phoneWindows"].exists)
        XCTAssertFalse(app.staticTexts["phoneWindowTitle"].exists)
        let checkbox = app.images["circle"]
        surface.coordinate(withNormalizedOffset:.zero).withOffset(CGVector(dx:checkbox.frame.midX-surface.frame.minX,
            dy:checkbox.frame.midY-surface.frame.minY)).tap()
        XCTAssertEqual(app.otherElements["phoneDocument"].value as? String,"已勾选")
        surface.pinch(withScale:2,velocity:1)
        tool("phoneFit")
        tool("phoneInputMode")
        XCUIDevice.shared.orientation = .landscapeLeft
        let wide = NSPredicate { [self] _,_ in self.app.frame.width > self.app.frame.height && self.app.buttons["phoneMenu"].isHittable }
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:wide,object:nil)],timeout:5),.completed)
        tool("phoneWindows"); app.buttons["phoneWindow-1"].tap()
        XCTAssertEqual(app.buttons["phoneMenu"].value as? String,"阅读清单")
        XCUIDevice.shared.orientation = .portrait
        capture("native-workspace")
    }
    func testFallbackComposerCancelsOnBackground() {
        tool("phoneKeyboard")
        let editor = app.textViews["textDraft"]
        XCTAssertTrue(editor.waitForExistence(timeout:5)); editor.tap()
        app.keys["n"].tap()
        XCUIDevice.shared.press(.home); app.activate()
        XCTAssertFalse(editor.exists)
        tool("phoneKeyboard")
        XCTAssertTrue(editor.waitForExistence(timeout:5)); XCTAssertEqual(editor.value as? String,"")
        app.buttons["cancelText"].tap()
        XCTAssertTrue(app.buttons["phoneMenu"].exists)
    }
    func testChineseFallbackAndWindowIsolation() {
        tool("phoneKeyboard")
        for key in ["n","i","h","a","o"] { app.keys[key].tap() }
        XCTAssertFalse(app.buttons["commitText"].isEnabled)
        let candidate = app.descendants(matching:.any).matching(NSPredicate(format:"label == %@","你好")).firstMatch
        XCTAssertTrue(candidate.waitForExistence(timeout:5)); candidate.tap(); app.buttons["commitText"].tap()
        XCTAssertEqual(app.otherElements["phoneDocument"].label,"你好")
        app.buttons["cancelText"].tap()
        tool("phoneWindows"); app.buttons["phoneWindow-1"].tap()
        XCTAssertEqual(app.otherElements["phoneDocument"].label,"尚未输入")
        tool("phoneWindows"); app.buttons["phoneWindow-0"].tap()
        XCTAssertEqual(app.otherElements["phoneDocument"].label,"你好")
    }
    func testActualClientControlsRemainReadonly() {
        tool("结束预览")
        XCTAssertTrue(app.buttons["连接主机"].waitForExistence(timeout:5))
        app.buttons["phoneMenu"].tap()
        XCTAssertFalse(app.buttons["phoneKeyboard"].isEnabled)
        XCTAssertFalse(app.buttons["phoneInputMode"].isEnabled)
        app.buttons["phoneConnectionSettingsMenu"].tap()
        XCTAssertTrue(app.textFields["主机地址"].exists)
        app.buttons["完成"].tap()
        tool("详细数据")
        XCTAssertTrue(app.staticTexts["接收帧率"].exists)
        app.buttons["完成"].tap()
    }
    private func capture(_ name:String) {
        let item = XCTAttachment(screenshot:XCUIScreen.main.screenshot());item.name = name;item.lifetime = .keepAlways;add(item)
    }
}
