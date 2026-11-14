import XCTest

final class WPSExperienceTests:XCTestCase {
    private let app=XCUIApplication()
    override func setUpWithError() throws {
        continueAfterFailure=false
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments=["--wps-interactive-review"]
        app.launch()
        wait { self.state()["ready"] as? Bool == true }
    }
    override func tearDown() { XCUIDevice.shared.orientation = .portrait }
    func testActualDesktopResizeTouchAndChinese() {
        let before=state()
        let w=before["width"] as! Double,h=before["height"] as! Double
        assertFilledSurface()
        let formulaBottom=(before["formulaY"] as! Double)+(before["formulaHeight"] as! Double)
        tapSource(CGPoint(x:143,y:formulaBottom+32+6*19+9.5))
        wait { self.state()["cell"] as? String == "B7" }
        // WPS's actual grid at its unchanged 100% zoom: C8 center, below the formula bar.
        tapSource(CGPoint(x:212,y:formulaBottom+32+7*19+9.5))
        wait { self.state()["cell"] as? String == "C8" }
        capture("wps-native-selected-cell")
        let original=state()["value"] as? String ?? ""
        app.buttons["wpsEdit"].tap()
        let editor=app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout:5))
        if !original.isEmpty { editor.tap();editor.typeText(String(repeating:XCUIKeyboardKey.delete.rawValue,count:original.count)) }
        for key in ["n","i","h","a","o"] { app.keys[key].tap() }
        XCTAssertFalse(app.buttons["wpsDone"].isEnabled)
        XCTAssertEqual(state()["value"] as? String,original)
        let candidate=app.descendants(matching:.any).matching(NSPredicate(format:"label == %@","你好")).firstMatch
        XCTAssertTrue(candidate.waitForExistence(timeout:5));candidate.tap()
        XCTAssertEqual(state()["width"] as? Double,w)
        XCTAssertEqual(state()["height"] as? Double,h)
        capture("wps-native-chinese-keyboard")
        app.buttons["wpsDone"].tap()
        wait { self.state()["value"] as? String == "你好" && self.state()["pending"] as? Bool == false }
        XCTAssertEqual(state()["cell"] as? String,"C8")
        capture("wps-confirmed-chinese-cell")
        app.buttons["wpsEdit"].tap()
        XCTAssertTrue(editor.waitForExistence(timeout:5))
        XCTAssertEqual(editor.value as? String,"你好")
        editor.typeText(XCUIKeyboardKey.delete.rawValue)
        app.buttons["wpsDone"].tap()
        wait { self.state()["value"] as? String == "你" }
        app.buttons["wpsEdit"].tap()
        editor.typeText(XCUIKeyboardKey.delete.rawValue)
        app.buttons["wpsDone"].tap()
        wait { self.state()["value"] as? String == "" }
    }
    func testRotationResizesDesktopAndCancelsComposition() {
        let initial=state(),version=initial["version"] as! Int
        XCUIDevice.shared.orientation = .landscapeLeft
        wait { (self.state()["version"] as? Int ?? 0)>version && self.state()["ready"] as? Bool == true }
        let wide=state()
        XCTAssertGreaterThan(wide["width"] as! Double,wide["height"] as! Double)
        assertFilledSurface()
        capture("wps-native-landscape")
        XCUIDevice.shared.orientation = .portrait
        wait { (self.state()["height"] as? Double ?? 0)>(self.state()["width"] as? Double ?? 0) && self.state()["ready"] as? Bool == true }
        let original=state()["value"] as? String
        app.buttons["wpsEdit"].tap();app.keys["n"].tap()
        app.buttons["wpsCancel"].tap()
        XCTAssertEqual(state()["value"] as? String,original)
        XCTAssertFalse(app.textViews.firstMatch.exists)
    }
    func testSwipeScrollsActualWorksheet() {
        let before=state(),surface=app.otherElements["viewportGestureSurface"]
        let y=(before["formulaY"] as! Double)+(before["formulaHeight"] as! Double)+32+7*19+9.5
        tapSource(CGPoint(x:212,y:y))
        wait { self.state()["cell"] as? String == "C8" }
        let operation=state()["operations"] as! Int
        let start=surface.coordinate(withNormalizedOffset:CGVector(dx:0.7,dy:0.7))
        let end=surface.coordinate(withNormalizedOffset:CGVector(dx:0.7,dy:0.4))
        start.press(forDuration:0.05,thenDragTo:end)
        wait { (self.state()["operations"] as? Int ?? 0)>operation }
        tapSource(CGPoint(x:212,y:y))
        wait { let cell=self.state()["cell"] as? String ?? "";return cell.hasPrefix("C") && (Int(cell.dropFirst()) ?? 0)>8 }
        capture("wps-native-scrolled-worksheet")
        let after=state()["operations"] as! Int
        end.press(forDuration:0.05,thenDragTo:start)
        wait { (self.state()["operations"] as? Int ?? 0)>after }
    }
    func testWindowColorAutomaticallyFillsSafeArea() {
        wait { self.state()["edgeColorReady"] as? Bool == true }
        let s=state(),r=s["edgeRed"] as! Double,g=s["edgeGreen"] as! Double,b=s["edgeBlue"] as! Double
        // The live WPS test window has a neutral light-gray top edge, not a white safe area.
        XCTAssertGreaterThan(r,0.75);XCTAssertLessThan(r,0.98)
        XCTAssertEqual(r,g,accuracy:0.04);XCTAssertEqual(g,b,accuracy:0.04)
        assertFilledSurface()
        capture("wps-automatic-window-edge-color")
    }
    func testFullscreenFloatingToolsAndCompleteWindowOption() {
        assertFilledSurface()
        let surface=app.otherElements["viewportGestureSurface"]
        XCTAssertEqual(surface.frame.maxY,app.frame.maxY,accuracy:1)
        XCTAssertLessThan(surface.frame.minY,100)
        let keyboard=app.buttons["wpsEdit"]
        XCTAssertTrue(surface.frame.contains(keyboard.frame))
        capture("wps-fullscreen-floating-tools")
        let operations=state()["operations"] as! Int
        let oldFrame=keyboard.frame
        let start=keyboard.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5))
        start.press(forDuration:0.05,thenDragTo:start.withOffset(CGVector(dx:-100,dy:-130)))
        XCTAssertLessThan(keyboard.frame.midY,oldFrame.midY-80)
        XCTAssertFalse(app.textViews.firstMatch.exists)
        XCTAssertEqual(state()["operations"] as? Int,operations)
        app.buttons["wpsTools"].tap();app.buttons["wpsFit"].tap()
        wait { self.state()["fillsViewport"] as? Bool == false }
        app.buttons["wpsTools"].tap();app.buttons["wpsFill"].tap()
        wait { self.state()["fillsViewport"] as? Bool == true }
        assertFilledSurface()
    }
    private func assertFilledSurface(file:StaticString=#filePath,line:UInt=#line) {
        let s=state(),surface=app.otherElements["viewportGestureSurface"].frame
        XCTAssertEqual(s["fillsViewport"] as? Bool,true,file:file,line:line)
        let x=s["contentX"] as! Double,y=s["contentY"] as! Double
        XCTAssertLessThanOrEqual(x,0.01,file:file,line:line)
        XCTAssertLessThanOrEqual(y,0.01,file:file,line:line)
        XCTAssertGreaterThanOrEqual(x+(s["contentWidth"] as! Double),surface.width-0.01,file:file,line:line)
        XCTAssertGreaterThanOrEqual(y+(s["contentHeight"] as! Double),surface.height-0.01,file:file,line:line)
    }
    private func tapSource(_ point:CGPoint) {
        let value=state(),surface=app.otherElements["viewportGestureSurface"]
        let scale=value["scale"] as! Double
        surface.coordinate(withNormalizedOffset:.zero).withOffset(CGVector(dx:(value["contentX"] as! Double)+point.x*scale,dy:(value["contentY"] as! Double)+point.y*scale)).tap()
    }
    private func state()->[String:Any] {
        guard let value=app.otherElements["wpsState"].value as? String,let data=value.data(using:.utf8),let object=try? JSONSerialization.jsonObject(with:data) as? [String:Any] else { return [:] };return object
    }
    private func wait(_ condition:@escaping()->Bool,file:StaticString=#filePath,line:UInt=#line) {
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:NSPredicate { _,_ in condition() },object:nil)],timeout:35),.completed,file:file,line:line)
    }
    private func capture(_ name:String) { let item=XCTAttachment(screenshot:XCUIScreen.main.screenshot());item.name=name;item.lifetime = .keepAlways;add(item) }
}
