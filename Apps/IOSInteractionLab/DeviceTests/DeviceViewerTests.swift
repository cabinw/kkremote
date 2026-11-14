import XCTest

/// Explicit USB experience check. Uses saved credentials and the already running Host.
/// Input review edits only the named blank Excel test workbook via the independent Host.
final class DeviceViewerTests:XCTestCase {
    private let app = XCUIApplication()
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = ["--viewer-ui-review"]
        app.launch()
    }
    override func tearDown() { XCUIDevice.shared.orientation = .portrait }

    func testDesktopColorPresentation() {
        app.terminate()
        app.launchArguments = ["--viewer-ui-review"]
        app.launch()
        app.buttons["phoneConnect"].tap()
        wait { self.state()["supported"] as? Bool == true }
        choose("Agentail")
        wait { self.state()["ready"] as? Bool == true && self.state()["nativeEdgeReady"] as? Bool == true }
        XCTAssertEqual(state()["desktopColors"] as? Bool,true)
        let previous=state()["displayEnqueued"] as? Int ?? 0
        wait { (self.state()["displayEnqueued"] as? Int ?? 0)>previous+60 }
        XCTAssertEqual(state()["displayFailures"] as? Int,0)
        capture("agentail-desktop-colors")
    }

    func testRealWindowViewingLifecycle() {
        app.buttons["phoneConnect"].tap()
        wait { self.state()["supported"] as? Bool == true }
        choose("KKRemote-WPS-Test-")
        wait { self.state()["ready"] as? Bool == true && self.state()["edgeReady"] as? Bool == true }
        XCTAssertTrue((state()["codec"] as? String ?? "").lowercased().contains("h265"))
        XCTAssertEqual(state()["transfer"] as? String,"SMPTE_ST_2084_PQ")
        wait { self.state()["nativeEdgeReady"] as? Bool == true }
        assertWholeWindow()
        capture("device-wps-whole-window")
        let surface = app.otherElements["viewportGestureSurface"]
        surface.pinch(withScale:1.5,velocity:1)
        surface.coordinate(withNormalizedOffset:CGVector(dx:0.8,dy:0.5))
            .press(forDuration:0.05,thenDragTo:surface.coordinate(withNormalizedOffset:CGVector(dx:0.3,dy:0.5)))
        assertWholeWindow()

        XCUIDevice.shared.orientation = .landscapeLeft
        wait { surface.frame.width>surface.frame.height }
        capture("device-wps-landscape")
        XCUIDevice.shared.orientation = .portrait
        wait { surface.frame.height>surface.frame.width }

        choose("KKRemote Repeatable Load Fixture")
        wait { self.state()["ready"] as? Bool == true && !(self.state()["selected"] as? String ?? "").hasPrefix("KKRemote-WPS-Test-") }
        capture("device-second-real-window")
        choose("KKRemote-WPS-Test-")
        wait { self.state()["ready"] as? Bool == true }
        let oldID = state()["selectedID"] as? String
        XCUIDevice.shared.press(.home)
        app.activate()
        wait { self.state()["ready"] as? Bool == true && (self.state()["selected"] as? String ?? "").hasPrefix("KKRemote-WPS-Test-") && self.state()["selectedID"] as? String != oldID }
        capture("device-foreground-fresh-selection")
        menu("phoneStopViewing")
        wait { self.state()["busy"] as? Bool == false && self.state()["ready"] as? Bool == false }
        XCTAssertEqual(state()["supported"] as? Bool,true)
        choose("KKRemote-WPS-Test-")
        wait { self.state()["ready"] as? Bool == true }
        capture("device-reselected-wps")
    }
    func testExcelAutomaticWindowLayout() {
        // These saved ports belong exclusively to the isolated layout Host.
        app.buttons["连接设置"].tap()
        for (label,value) in [("信令端口","46090"),("媒体端口","46091")] {
            let field=app.textFields[label]
            XCTAssertTrue(field.waitForExistence(timeout:5))
            field.coordinate(withNormalizedOffset:CGVector(dx:0.97,dy:0.5)).tap()
            let old=field.value as? String ?? ""
            field.typeText(String(repeating:XCUIKeyboardKey.delete.rawValue,count:old.count)+value)
            XCTAssertEqual(field.value as? String,value)
        }
        app.buttons["完成"].tap()
        app.buttons["phoneConnect"].tap()
        wait { self.state()["layoutSupported"] as? Bool == true }
        choose("Microsoft Excel")
        wait { self.state()["ready"] as? Bool == true && self.state()["edgeReady"] as? Bool == true }
        XCTAssertEqual(state()["layoutWarning"] as? String,"")
        assertWholeWindow()
        let portraitWidth=state()["sourceWidth"] as? Double ?? 0
        let portraitHeight=state()["sourceHeight"] as? Double ?? 0
        XCTAssertGreaterThan(portraitHeight,portraitWidth)
        XCTAssertEqual(state()["contentHeight"] as? Double ?? 0,state()["viewportHeight"] as? Double ?? 0,accuracy:2)
        capture("excel-portrait-auto-layout")
        let surface=app.otherElements["viewportGestureSurface"]
        surface.pinch(withScale:1.8,velocity:1)
        surface.coordinate(withNormalizedOffset:CGVector(dx:0.85,dy:0.5))
            .press(forDuration:0.05,thenDragTo:surface.coordinate(withNormalizedOffset:CGVector(dx:0.15,dy:0.5)))
        assertWholeWindow()
        capture("excel-width-locked-after-gestures")
        XCUIDevice.shared.orientation = .landscapeLeft
        wait { self.state()["ready"] as? Bool == true && (self.state()["sourceWidth"] as? Double ?? 0) > (self.state()["sourceHeight"] as? Double ?? 1) }
        assertWholeWindow()
        XCTAssertEqual(state()["layoutWarning"] as? String,"")
        XCTAssertEqual(state()["contentWidth"] as? Double ?? 0,state()["viewportWidth"] as? Double ?? 0,accuracy:2)
        capture("excel-landscape-auto-layout")
        XCUIDevice.shared.orientation = .portrait
        wait { self.state()["ready"] as? Bool == true && (self.state()["sourceHeight"] as? Double ?? 0) > (self.state()["sourceWidth"] as? Double ?? 1) }
        choose("Agentail")
        wait { self.state()["ready"] as? Bool == true }
        assertWholeWindow()
        XCTAssertEqual(state()["layoutWarning"] as? String,"")
        capture("new-window-auto-layout")
        choose("Microsoft Excel")
        wait { self.state()["ready"] as? Bool == true }
        assertWholeWindow()
        XCTAssertEqual(state()["layoutWarning"] as? String,"")
        capture("excel-reselected-auto-layout")
    }
    func testDirectRemoteKeyboard() {
        app.buttons["phoneConnect"].tap()
        wait { self.state()["supported"] as? Bool == true }
        choose("KKRemote-Excel-Control-Test-20261114")
        wait { self.state()["controllable"] as? Bool == true && self.state()["keyboardSupported"] as? Bool == true }
        let beforeClick=state()["inputAcknowledged"] as? Int ?? 0
        sourceTap(x:205,y:280)
        wait { (self.state()["inputAcknowledged"] as? Int ?? 0)>beforeClick }
        exerciseDirectKeyboard("excel")
    }
    func testTextEditDirectRemoteKeyboard() {
        app.buttons["phoneConnect"].tap()
        wait { self.state()["supported"] as? Bool == true }
        choose("KKRemote-Generic-Input-Test-20261114")
        wait { self.state()["controllable"] as? Bool == true && self.state()["keyboardSupported"] as? Bool == true }
        let beforeClick=state()["inputAcknowledged"] as? Int ?? 0
        sourceTap(x:110,y:140)
        wait { (self.state()["inputAcknowledged"] as? Int ?? 0)>beforeClick }
        exerciseDirectKeyboard("textedit")
    }
    func testPinyinImmediateCandidate() {
        app.buttons["phoneConnect"].tap()
        wait { self.state()["supported"] as? Bool == true }
        choose("KKRemote-Generic-Input-Test-20261114")
        wait { self.state()["controllable"] as? Bool == true }
        sourceTap(x:110,y:140)
        wait { self.state()["keyboardFocusReady"] as? Bool == true }
        app.buttons["phoneKeyboard"].tap()
        wait { self.state()["keyboardFocused"] as? Bool == true && self.state()["inputQueueCount"] as? Int == 0 }
        capture("pinyin-keyboard-start")
        let count=state()["inputAcknowledged"] as? Int ?? 0
        // Coordinates are from the observed iPhone 15 Pro Max system keyboard.
        // Device-side taps avoid Device Hub stealing the desktop focus per key.
        func tap(_ x:Double,_ y:Double) {
            app.coordinate(withNormalizedOffset:CGVector(dx:x/430,dy:y/932)).tap()
        }
        for (x,y) in [(87.0,779.0),(258,721),(365,665),(301,779),(215,721),(66,665),(109,665),(301,779)] { tap(x,y) }
        capture("pinyin-composing")
        XCTAssertEqual(state()["inputAcknowledged"] as? Int,count,"Marked pinyin must not reach the desktop")
        tap(36,610)
        wait { (self.state()["inputAcknowledged"] as? Int ?? 0)>count && self.state()["inputQueueCount"] as? Int == 0 }
        XCTAssertEqual(state()["controlError"] as? String,"")
        capture("pinyin-candidate-immediately-dispatched")
        app.buttons["phoneKeyboard"].tap()
    }
    private func exerciseDirectKeyboard(_ name:String) {
        let before=state()
        app.buttons["phoneKeyboard"].tap()
        wait { self.state()["keyboardWidthLocked"] as? Bool == true && self.state()["keyboardFocusReady"] as? Bool == true && self.state()["inputQueueCount"] as? Int == 0 && (self.state()["viewportHeight"] as? Double ?? 9999)<600 }
        XCTAssertFalse(app.textViews["textDraft"].exists)
        XCTAssertFalse(app.buttons["commitText"].exists)
        XCTAssertFalse(app.buttons["cancelText"].exists)
        XCTAssertEqual(state()["contentWidth"] as! Double,before["contentWidth"] as! Double,accuracy:0.5)
        XCTAssertEqual(state()["contentWidth"] as! Double,state()["viewportWidth"] as! Double,accuracy:0.5)
        XCTAssertEqual(state()["selectedID"] as? String,before["selectedID"] as? String)
        let count=state()["inputAcknowledged"] as? Int ?? 0
        // The transparent first responder already owns the system keyboard.
        let expected="Remote36-\(Int(Date().timeIntervalSince1970))中文🙂!"
        let expectedAttachment=XCTAttachment(string:expected)
        expectedAttachment.name=name+"-expected-desktop-text";expectedAttachment.lifetime = .keepAlways;add(expectedAttachment)
        app.typeText(String(expected.dropLast())+"Z"+XCUIKeyboardKey.delete.rawValue+"!\n")
        wait { (self.state()["inputAcknowledged"] as? Int ?? 0)>count && self.state()["inputQueueCount"] as? Int == 0 }
        XCTAssertEqual(state()["controlError"] as? String,"")
        capture(name+"-direct-keyboard-dispatched")
        app.buttons["phoneKeyboard"].tap()
        wait { self.state()["keyboardWidthLocked"] as? Bool == false }
        assertWholeWindow()
        XCTAssertEqual(state()["displayFailures"] as? Int,0)
        capture(name+"-direct-keyboard-hidden")
    }
    private func sourceTap(x:Double,y:Double) {
        let s=state(),scale=(s["contentWidth"] as! Double)/(s["sourceWidth"] as! Double)
        let dx=((s["x"] as! Double)+x*scale)/(s["viewportWidth"] as! Double)
        let dy=((s["y"] as! Double)+y*scale)/(s["viewportHeight"] as! Double)
        app.otherElements["viewportGestureSurface"].coordinate(withNormalizedOffset:CGVector(dx:dx,dy:dy)).tap()
    }
    private func assertWholeWindow() {
        let s=state()
        XCTAssertEqual(s["locked"] as? Bool,true)
        XCTAssertEqual(s["fill"] as? Bool,false)
        XCTAssertEqual(s["zoom"] as? Double,1)
        let x=s["x"] as? Double ?? -100,y=s["y"] as? Double ?? -100
        XCTAssertGreaterThanOrEqual(x,-0.5);XCTAssertGreaterThanOrEqual(y,-0.5)
        XCTAssertLessThanOrEqual(x+(s["contentWidth"] as? Double ?? 1e6),(s["viewportWidth"] as? Double ?? 0)+0.5)
        XCTAssertLessThanOrEqual(y+(s["contentHeight"] as? Double ?? 1e6),(s["viewportHeight"] as? Double ?? 0)+0.5)
    }
    private func choose(_ text:String) {
        app.buttons["phoneChooseWindow"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout:10));search.tap();search.typeText(text)
        let row = app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@","remoteWindowRow-")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout:15))
        wait { row.isEnabled };row.tap()
    }
    private func menu(_ id:String) {
        app.buttons["phoneMenu"].tap()
        // iOS 27's system menu may omit identifiers for Section children.
        let labels = ["phoneFit":"显示完整窗口","phoneFill":"自动铺满","phoneStopViewing":"停止观看，保留连接"]
        let identified = app.buttons[id]
        let item = identified.exists ? identified : app.buttons[labels[id] ?? id]
        XCTAssertTrue(item.waitForExistence(timeout:5));item.tap()
    }
    private func state()->[String:Any] {
        guard let value = app.otherElements["viewerState"].value as? String,
              let data = value.data(using:.utf8),let result = try? JSONSerialization.jsonObject(with:data) as? [String:Any] else { return [:] }
        return result
    }
    private func wait(_ predicate:@escaping()->Bool) {
        let result=XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:NSPredicate { _,_ in predicate() },object:nil)],timeout:45)
        if result != .completed { capture("failed-wait") }
        XCTAssertEqual(result,.completed,"State: \(state())")
    }
    private func capture(_ name:String) {
        let shot = XCTAttachment(screenshot:app.screenshot());shot.name = name;shot.lifetime = .keepAlways;add(shot)
        let data = try! JSONSerialization.data(withJSONObject:state(),options:[.sortedKeys])
        let metadata = XCTAttachment(string:String(data:data,encoding:.utf8)!);metadata.name = name+"-metadata";metadata.lifetime = .keepAlways;add(metadata)
    }
}
