import XCTest

/// Run against the local physical Host and a centered DuoClickFixture.
final class DuoWorkspaceTests: XCTestCase {
    private let app = XCUIApplication(bundleIdentifier: "com.cabinw.kkremote.lab")
    private let fixture = "KKRemote Duo Click Fixture"

    private func state() -> [String: Any] {
        guard let value = app.otherElements["viewerState"].value as? String else { return [:] }
        return (try? JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any]) ?? [:]
    }

    private func observe(_ description: String, until condition: ([String: Any]) -> Bool) {
        let end = Date().addingTimeInterval(35)
        repeat {
            if condition(state()) { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        } while Date() < end
        XCTFail(description)
    }

    private func expectPicture(desktop: Bool) {
        observe("Expected fresh frames from the selected source") { state in
            state["isDesktop"] as? Bool == desktop
                && state["selected"] as? String == (desktop ? "主显示器" : self.fixture)
                && state["ready"] as? Bool == true && state["controllable"] as? Bool == true
                && (state["displayEnqueued"] as? Int ?? 0) > 1
        }
        let snapshot = state()
        XCTAssertEqual(snapshot["displayFailures"] as? Int, 0)
        print("DUO_FRAMES desktop=\(desktop) decoded=\(snapshot["frames"] ?? 0) presentedQueue=\(snapshot["displayEnqueued"] ?? 0) width=\(snapshot["width"] ?? 0) height=\(snapshot["height"] ?? 0) codec=\(snapshot["codec"] ?? "") transfer=\(snapshot["transfer"] ?? "")")
    }

    private func tapTrackpad() {
        let before = state()["inputAcknowledged"] as? Int ?? 0
        let pad = app.descendants(matching: .any).matching(identifier: "duoTrackpad").firstMatch
        XCTAssertTrue(pad.isHittable)
        pad.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5)).tap()
        observe("Missing Host click acknowledgement") { ($0["inputAcknowledged"] as? Int ?? 0) == before + 1 }
    }

    func testPhysicalWindowAndDesktop() throws {
        continueAfterFailure = false
        app.launchArguments = ["--viewer-ui-review"]
        app.launch()
        XCTAssertTrue(app.buttons["phoneConnect"].waitForExistence(timeout: 12))
        try XCTSkipUnless(state()["duoLayout"] as? Bool == true, "Requires the Duo workspace")
        app.buttons["phoneConnect"].tap()
        observe("Host catalog unavailable") { $0["supported"] as? Bool == true }
        app.buttons["phoneChooseWindow"].tap()
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
                                                  "remoteWindowRow-", fixture)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Start DuoClickFixture on the physical main display")
        for _ in 0..<12 where !row.isHittable { app.swipeUp() }
        row.tap()
        expectPicture(desktop: false)
        tapTrackpad()
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Duo-Fixture-Workspace"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.buttons["duoDesktop"].tap()
        app.buttons["显示完整桌面"].tap()
        expectPicture(desktop: true)
        tapTrackpad()
        let card = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", fixture)).firstMatch
        XCTAssertTrue(card.isHittable)
        card.tap()
        expectPicture(desktop: false)
    }
}
