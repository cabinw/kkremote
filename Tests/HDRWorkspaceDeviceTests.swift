import XCTest
final class HDRWorkspaceTests:XCTestCase {
 let app=XCUIApplication()
 func state()->[String:Any] {guard let s=app.otherElements["viewerState"].value as? String,let d=s.data(using:.utf8) else{return [:]};return (try? JSONSerialization.jsonObject(with:d)) as? [String:Any] ?? [:]}
 func wait(_ check:@escaping()->Bool){XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:NSPredicate{_,_ in check()},object:nil)],timeout:45),.completed)}
 func shot(_ name:String){let a=XCTAttachment(screenshot:app.screenshot());a.name=name;a.lifetime = .keepAlways;add(a);let b=XCTAttachment(data:try! JSONSerialization.data(withJSONObject:state(),options:[.prettyPrinted,.sortedKeys]),uniformTypeIdentifier:"public.json");b.name=name+"-state";b.lifetime = .keepAlways;add(b)}
 func runFixture(title:String,run:String){
  continueAfterFailure=false;XCUIDevice.shared.orientation = .portrait
  app.launchArguments=["--viewer-ui-review","--media-diagnostics-run",run,"-viewerDesktopColors","NO"];app.launch()
  app.buttons["phoneConnect"].tap();wait{self.state()["supported"] as? Bool == true}
  app.buttons["phoneChooseWindow"].tap();let search=app.searchFields.firstMatch;XCTAssertTrue(search.waitForExistence(timeout:8));search.tap();search.typeText(title)
  let row=app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@","remoteWindowRow-")).firstMatch;XCTAssertTrue(row.waitForExistence(timeout:15));wait{row.isEnabled};row.tap()
  wait{self.state()["ready"] as? Bool == true && (self.state()["displayEnqueued"] as? Int ?? 0)>120}
  XCTAssertEqual(state()["desktopColors"] as? Bool,false);XCTAssertEqual(state()["width"] as? Int,1290);XCTAssertEqual(state()["height"] as? Int,2618);XCTAssertEqual(state()["displayFailures"] as? Int,0)
  wait{self.state()["pixelExact"] as? Bool == true && self.state()["displayOneToOne"] as? Bool == true}
  XCTAssertEqual(state()["surfacePixelWidth"] as? Double,1290);XCTAssertEqual(state()["surfacePixelHeight"] as? Double ?? 0,2618,accuracy:0.001)
  print("KK_FIXTURE_READY \(run)");shot(run+"-initial")
  sleep(20);shot(run+"-phase1");print("KK_FIXTURE_PHASE2 \(run)")
  sleep(25);shot(run+"-phase2")
  XCTAssertEqual(state()["displayFailures"] as? Int,0);app.buttons["phoneMenu"].tap();let stop=app.buttons["断开连接"];XCTAssertTrue(stop.waitForExistence(timeout:5));stop.tap();wait{self.state()["running"] as? Bool == false}
 }
 func testBrowserHDR(){runFixture(title:"HDR Workspace Browser",run:"pixel-exact-browser42")}
 func testOfficeHDR(){runFixture(title:"KKRemote-Office-Native-HDR-20261115",run:"pixel-exact-office42")}

 func choose(_ title:String){
  app.buttons["phoneChooseWindow"].tap();let search=app.searchFields.firstMatch;XCTAssertTrue(search.waitForExistence(timeout:8));search.tap();search.typeText(title)
  let row=app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@","remoteWindowRow-")).firstMatch;XCTAssertTrue(row.waitForExistence(timeout:15));wait{row.isEnabled};row.tap()
 }
 func exact(_ width:Int,_ height:Int){wait{self.state()["width"] as? Int == width && self.state()["height"] as? Int == height && self.state()["pixelExact"] as? Bool == true && self.state()["displayOneToOne"] as? Bool == true && self.state()["ready"] as? Bool == true}}
 func disconnect(){app.buttons["phoneMenu"].tap();app.buttons["断开连接"].tap();wait{self.state()["running"] as? Bool == false}}
 func testBrowserFilmRotateReconnect(){
  continueAfterFailure=false;XCUIDevice.shared.orientation = .portrait
  app.launchArguments=["--viewer-ui-review","--media-diagnostics-run","pixel-exact-motion42b","-viewerDesktopColors","NO"];app.launch()
  app.buttons["phoneConnect"].tap();wait{self.state()["supported"] as? Bool == true};choose("HDR Workspace Browser");exact(1290,2618)
  app.coordinate(withNormalizedOffset:.zero).withOffset(CGVector(dx:111,dy:74)).tap();sleep(2)
  // Coordinates inside this app's received owned fixture. Exercise production input mapping.
  let ack=state()["inputAcknowledged"] as? Int ?? 0
  app.coordinate(withNormalizedOffset:.zero).withOffset(CGVector(dx:170,dy:165)).tap()
  app.coordinate(withNormalizedOffset:.zero).withOffset(CGVector(dx:232,dy:165)).tap()
  wait{(self.state()["inputAcknowledged"] as? Int ?? 0)>ack};sleep(20);shot("motion-portrait")
  XCUIDevice.shared.orientation = .landscapeLeft;exact(2442,1290);sleep(3);shot("motion-landscape")
  XCUIDevice.shared.orientation = .portrait;exact(1290,2618);sleep(3);shot("motion-portrait-return")
  choose("KKRemote-Office-Native-HDR-20261115");exact(1290,2618);shot("switch-office")
  choose("HDR Workspace Browser");exact(1290,2618);shot("switch-browser")
  // Put the owned browser back on its gray chart and stop its fixture scrolling.
  app.coordinate(withNormalizedOffset:.zero).withOffset(CGVector(dx:90,dy:165)).tap()
  app.coordinate(withNormalizedOffset:.zero).withOffset(CGVector(dx:232,dy:165)).tap()
  disconnect();sleep(2);app.terminate()
  app.launchArguments=["--viewer-ui-review","--media-diagnostics-run","pixel-exact-reconnect42","-viewerDesktopColors","NO"];app.launch()
  app.buttons["phoneConnect"].tap();wait{self.state()["supported"] as? Bool == true};choose("HDR Workspace Browser");exact(1290,2618);shot("reconnected")
  XCTAssertEqual(state()["displayFailures"] as? Int,0);disconnect()
 }
}
