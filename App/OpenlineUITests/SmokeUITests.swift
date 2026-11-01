import XCTest

final class SmokeUITests: XCTestCase {
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["OPENLINE_TEST_PROFILE"] = UUID().uuidString
        app.launch()
        return app
    }

    func testFirstLaunchShowsWelcome() {
        let app = launch()
        XCTAssertTrue(app.buttons["Add SIP Account"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["Configure Later"].exists)
        app.buttons["Configure Later"].click()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))
        app.terminate()
    }

    /// Needs the Asterisk rig; Tests/Integration/run_app.py places the call.
    func testIncomingCallWithMainWindowClosed() throws {
        let marker = URL(fileURLWithPath: "/tmp/openline-ui-rig")
        guard FileManager.default.fileExists(atPath: marker.path) else { throw XCTSkip("Integration rig not running") }
        let app = launch()
        XCTAssertTrue(app.buttons["Add SIP Account"].waitForExistence(timeout: 20))
        let server = app.textFields["account.server"]
        // A click during the sheet's entrance animation can be lost.
        for _ in 0..<4 where !server.exists {
            if app.buttons["Add SIP Account"].exists { app.buttons["Add SIP Account"].click() }
            _ = server.waitForExistence(timeout: 3)
        }
        XCTAssertTrue(server.exists, app.debugDescription)
        server.click()
        server.typeText("127.0.0.1")
        let user = app.textFields["account.username"]
        user.click()
        user.typeText("1006")
        // The plain field can be read back, unlike a SecureField.
        let password = app.textFields["account.password"]
        for _ in 0..<4 where !password.exists {
            if app.buttons["Show password"].exists { app.buttons["Show password"].click() }
            _ = password.waitForExistence(timeout: 2)
        }
        XCTAssertTrue(password.exists)
        password.click()
        Thread.sleep(forTimeInterval: 1)
        password.typeText("1006-1006")
        XCTAssertEqual(server.value as? String, "127.0.0.1")
        XCTAssertEqual(user.value as? String, "1006")
        XCTAssertEqual(password.value as? String, "1006-1006")
        app.buttons["Save & Connect"].click()

        let registered = app.staticTexts.containing(NSPredicate(format: "value CONTAINS 'Registered' OR label CONTAINS 'Registered'")).firstMatch
        XCTAssertTrue(registered.waitForExistence(timeout: 20), "Not registered: \(app.debugDescription)")

        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(app.state == .runningForeground || app.state == .runningBackground)

        let decline = app.buttons["Decline"]
        XCTAssertTrue(decline.waitForExistence(timeout: 150), "No incoming panel with the main window closed")
        let caller = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS '1002' OR value CONTAINS '1002'"))
        XCTAssertGreaterThan(caller.count, 0, "Caller not shown")
        decline.click()
        XCTAssertTrue(decline.waitForNonExistence(timeout: 10))
        app.terminate()
    }
}
