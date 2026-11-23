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

    private func chooseFixtureFromDock() {
        let dock = app.buttons["duoDock"]
        XCTAssertTrue(dock.waitForExistence(timeout: 8))
        dock.tap()
        let apps = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS[c] %@",
                                                    "duoDockApp-", "Fixture"))
        let icon = apps.firstMatch
        XCTAssertTrue(icon.waitForExistence(timeout: 10), "Start the Duo click fixture on the Mac")
        XCTAssertEqual(apps.count, 1, "Dock should group the application's windows under one icon")
        let scrollArea = app.scrollViews.containing(.button, identifier: icon.identifier).firstMatch
        for _ in 0..<8 where !icon.isHittable && scrollArea.exists { scrollArea.swipeUp() }
        observe("Host did not send app icons") { ($0["dockIconCount"] as? Int ?? 0) > 0 }
        if (state()["selected"] as? String ?? "").isEmpty {
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "Duo-Dock-Applications"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        XCTAssertTrue(icon.isEnabled)
        icon.tap()
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@",
                                                  "remoteWindowRow-", fixture)).firstMatch
        if row.waitForExistence(timeout: 1) { row.tap(); print("DUO_DOCK multiple windows") }
        else { print("DUO_DOCK direct window") }
    }

    private func returnViaRecentIcon() {
        let icon = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS[c] %@",
                                                    "duoRecentApp-", "Fixture")).firstMatch
        XCTAssertTrue(icon.isHittable)
        if state()["hingeClosed"] as? Bool == true, app.frame.height > app.frame.width {
            let pad = app.descendants(matching: .any).matching(identifier: "duoTrackpad").firstMatch
            XCTAssertGreaterThan(icon.frame.midX, pad.frame.maxX)
        }
        icon.tap()
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@",
                                                  "remoteWindowRow-", fixture)).firstMatch
        if row.waitForExistence(timeout: 1) { row.tap() }
    }

    private func checkOuterBar() {
        let pad = app.descendants(matching: .any).matching(identifier: "duoTrackpad").firstMatch
        guard state()["hingeClosed"] as? Bool == true, app.frame.height > app.frame.width else { return }
        for id in ["duoDock", "duoDesktop", "phoneKeyboard", "phoneMenu", "duoSettings"] {
            let button = app.buttons[id]
            XCTAssertTrue(button.isHittable, "Missing outer-display control: \(id)")
            XCTAssertGreaterThan(button.frame.midX, pad.frame.maxX, "Expected \(id) on the right system bar")
        }
        print("DUO_DOCK all five controls on right")
    }

    func testPhysicalWindowAndDesktop() throws {
        continueAfterFailure = false
        app.launchArguments = ["--viewer-ui-review"]
        app.launch()
        XCTAssertTrue(app.buttons["phoneConnect"].waitForExistence(timeout: 12))
        try XCTSkipUnless(state()["duoLayout"] as? Bool == true, "Requires the Duo workspace")
        app.buttons["phoneConnect"].tap()
        observe("Host catalog unavailable") { $0["supported"] as? Bool == true }
        chooseFixtureFromDock()
        expectPicture(desktop: false)
        tapTrackpad()
        checkOuterBar()
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Duo-Fixture-Workspace"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.buttons["duoDesktop"].tap()
        app.buttons["显示完整桌面"].tap()
        expectPicture(desktop: true)
        tapTrackpad()
        returnViaRecentIcon()
        expectPicture(desktop: false)
    }
}
