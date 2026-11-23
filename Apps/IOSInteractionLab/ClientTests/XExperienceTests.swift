import XCTest

final class XExperienceTests: XCTestCase {
    private let app = XCUIApplication()
    override func setUpWithError() throws {
        continueAfterFailure = false
        let root = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent(".build/ios-x-preview/bridge.json")
        guard let data = try? Data(contentsOf:url), let config = try JSONSerialization.jsonObject(with:data) as? [String:Any],
              let endpoint = config["url"] as? String, let token = config["token"] as? String else {
            throw XCTSkip("Start the isolated X browser preview adapter first")
        }
        app.terminate()
        var request = URLRequest(url:URL(string:endpoint)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)",forHTTPHeaderField:"Authorization")
        request.httpBody = Data(#"{"kind":"reset"}"#.utf8)
        let reset = expectation(description:"Reset isolated X preview")
        URLSession.shared.dataTask(with:request) { _,response,error in
            XCTAssertNil(error)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode,200)
            reset.fulfill()
        }.resume()
        wait(for:[reset],timeout:30)
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = ["--x-preview-url",endpoint,"--x-preview-token",token]
        app.launch()
        wait { self.snapshot()["sequence"] as? Int ?? 0 > 0 && self.snapshot()["pending"] as? Bool == false }
    }
    override func tearDown() { XCUIDevice.shared.orientation = .portrait }

    func testAdaptiveWindowAndSingleFingerScroll() {
        let before = snapshot()
        let surface = app.otherElements["viewportGestureSurface"]
        let width = before["width"] as! Double, height = before["height"] as! Double
        XCTAssertEqual(width / height, surface.frame.width / surface.frame.height, accuracy:0.005)
        XCTAssertFalse(app.buttons["phoneKeyboard"].exists)
        XCTAssertFalse(app.staticTexts["真实 x.com · 隔离预览"].exists)
        XCTAssertGreaterThan(surface.frame.height, app.frame.height * 0.85)
        capture("x-native-app")
        let sequence = before["sequence"] as! Int
        surface.swipeUp()
        wait { (self.snapshot()["sequence"] as? Int ?? 0) > sequence &&
            (self.snapshot()["scrollY"] as? Double ?? 0) > (before["scrollY"] as? Double ?? 0) + 20 }
        capture("x-iphone-scrolled")
        app.buttons["phoneMenu"].tap(); app.buttons["xToggleSizing"].tap()
        wait { self.snapshot()["width"] as? Int == 1280 && self.snapshot()["pending"] as? Bool == false }
        capture("x-iphone-desktop-ratio")
        app.buttons["phoneMenu"].tap(); app.buttons["xToggleSizing"].tap()
        wait { self.snapshot()["width"] as? Double == width && self.snapshot()["pending"] as? Bool == false }
        XCUIDevice.shared.orientation = .landscapeLeft
        wait { self.snapshot()["width"] as? Double ?? 0 > (self.snapshot()["height"] as? Double ?? 0) && self.snapshot()["pending"] as? Bool == false }
        let landscape = snapshot()
        XCTAssertEqual((landscape["width"] as! Double)/(landscape["height"] as! Double),
                       surface.frame.width/surface.frame.height,accuracy:0.01)
        capture("x-iphone-landscape")
    }

    func testChineseIntoRealXSearchWithoutSubmitting() {
        let surface = app.otherElements["viewportGestureSurface"]
        for _ in 0..<4 where (snapshot()["searchY"] as? Double ?? -1) < 0 {
            let sequence = snapshot()["sequence"] as? Int ?? 0
            surface.swipeDown()
            wait { (self.snapshot()["sequence"] as? Int ?? 0) > sequence }
        }
        let first = snapshot()
        XCTAssertGreaterThanOrEqual(first["searchY"] as! Double,0)
        let sx = (first["searchX"] as! Double) + (first["searchWidth"] as! Double)/2
        let sy = (first["searchY"] as! Double) + (first["searchHeight"] as! Double)/2
        surface.coordinate(withNormalizedOffset:CGVector(dx:sx/(first["width"] as! Double),dy:sy/(first["height"] as! Double))).tap()
        let editor = app.textViews["inlineSearchField"]
        XCTAssertTrue(editor.waitForExistence(timeout:5))
        for key in ["n","i","h","a","o"] { app.keys[key].tap() }
        XCTAssertFalse(app.buttons["commitText"].exists)
        XCTAssertEqual(snapshot()["value"] as? String, "")
        let candidate = app.descendants(matching:.any).matching(NSPredicate(format:"label == %@","你好")).firstMatch
        XCTAssertTrue(candidate.waitForExistence(timeout:5)); candidate.tap()
        wait { self.snapshot()["value"] as? String == "你好" }
        XCTAssertEqual(snapshot()["width"] as? Double,first["width"] as? Double)
        XCTAssertEqual(snapshot()["height"] as? Double,first["height"] as? Double)
        XCTAssertFalse(app.buttons["commitText"].exists)
        capture("x-native-inline-chinese")
        editor.typeText(XCUIKeyboardKey.delete.rawValue)
        wait { self.snapshot()["value"] as? String == "你" }
        app.buttons["Done"].tap()
        XCTAssertFalse(editor.exists)
        app.buttons["phoneMenu"].tap(); app.buttons["清空测试搜索文字"].tap()
        wait { self.snapshot()["value"] as? String == "" }
    }
    private func snapshot() -> [String:Any] {
        guard let value = app.otherElements["xPreviewStatus"].value as? String,
              let data = value.data(using:.utf8), let result = try? JSONSerialization.jsonObject(with:data) as? [String:Any] else { return [:] }
        return result
    }
    private func wait(_ condition: @escaping () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
        let predicate = NSPredicate { _,_ in condition() }
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:predicate,object:nil)],timeout:30),.completed,file:file,line:line)
    }
    private func capture(_ name: String) {
        let evidence = XCTAttachment(screenshot:XCUIScreen.main.screenshot()); evidence.name = name
        evidence.lifetime = .keepAlways; add(evidence)
    }
}
