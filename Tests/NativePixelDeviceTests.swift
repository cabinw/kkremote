// Physical-device communication quality regression; use in a standalone UI-test target.
// Reuses saved connection preferences and an already-running owned fixture/Host.
import XCTest
final class NativePixelTests:XCTestCase {
 let app=XCUIApplication()
 func state()->[String:Any] { guard let s=app.otherElements["viewerState"].value as? String,let d=s.data(using:.utf8) else{return [:]};return (try? JSONSerialization.jsonObject(with:d)) as? [String:Any] ?? [:] }
 func wait(_ check:@escaping()->Bool) { XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:NSPredicate{_,_ in check()},object:nil)],timeout:40),.completed) }
 func snapshot(_ name:String) {let a=XCTAttachment(screenshot:app.screenshot());a.name=name;a.lifetime = .keepAlways;add(a);let b=XCTAttachment(data:try! JSONSerialization.data(withJSONObject:state(),options:[.prettyPrinted,.sortedKeys]),uniformTypeIdentifier:"public.json");b.name=name+"-state";b.lifetime = .keepAlways;add(b)}
 func testNativePixels() {
  continueAfterFailure=false;XCUIDevice.shared.orientation = .portrait;app.launchArguments=["--viewer-ui-review","--media-diagnostics-run","native-pixels40"];app.launch()
  app.buttons["phoneConnect"].tap();wait{self.state()["supported"] as? Bool == true}
  app.buttons["phoneChooseWindow"].tap();let search=app.searchFields.firstMatch;XCTAssertTrue(search.waitForExistence(timeout:8));search.tap();search.typeText("KKRemote Native Quality Fixture")
  let row=app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@","remoteWindowRow-")).firstMatch;XCTAssertTrue(row.waitForExistence(timeout:15));wait{row.isEnabled};row.tap()
  wait{self.state()["ready"] as? Bool == true};let before=self.state()["displayEnqueued"] as? Int ?? 0;wait{(self.state()["displayEnqueued"] as? Int ?? 0)>before+120};snapshot("quality-portrait")
  XCTAssertEqual(state()["displayFailures"] as? Int,0)
  XCTAssertEqual(state()["width"] as? Int,1290);XCTAssertEqual(state()["height"] as? Int,2620)
  XCTAssertEqual(state()["sourceWidth"] as? Double,645);XCTAssertEqual(state()["sourceHeight"] as? Double,1310)
  XCTAssertEqual(state()["layoutWarning"] as? String,"")
  sleep(10);snapshot("native-portrait")
  XCUIDevice.shared.orientation = .landscapeLeft
  wait{(self.state()["width"] as? Int ?? 0)>2000 && (self.state()["sourceWidth"] as? Double ?? 0)>1000}
  snapshot("native-landscape")
  XCTAssertEqual(state()["width"] as? Int,2442);XCTAssertEqual(state()["height"] as? Int,1290)
  XCUIDevice.shared.orientation = .portrait
  wait{self.state()["width"] as? Int == 1290 && self.state()["height"] as? Int == 2620}
  sleep(5);snapshot("native-portrait-restored");app.buttons["phoneMenu"].tap();let disconnect=app.buttons["断开连接"];XCTAssertTrue(disconnect.waitForExistence(timeout:5));disconnect.tap();wait{self.state()["running"] as? Bool == false}
 }
}
