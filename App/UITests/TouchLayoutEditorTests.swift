import XCTest

/// End to end for issue #115: a button dragged in the layout editor is where
/// the player left it in the next engine session, after the app has been
/// relaunched; Reset puts it back. The editor and the session overlay share
/// `TouchOverlayLayout`, so the in-game frame is compared against the frame
/// the editor showed after the drag, not against a number.
final class TouchLayoutEditorTests: XCTestCase {

    /// Everything this test persists is wiped before it starts and after it
    /// ends, so a failure mid-way cannot leave a moved FIRE button for the
    /// rest of the suite.
    private func launchClean() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["WADDLE_RESET_STORE"] = "1"
        app.launch()
        return app
    }

    @MainActor
    private func openLayoutEditor(_ app: XCUIApplication) {
        let gear = app.buttons["touchSchemeMenu"]
        XCTAssertTrue(gear.waitForExistence(timeout: 10), "gear missing from the shelf")
        gear.tap()
        let controlFeel = app.buttons["controlFeelButton"]
        XCTAssertTrue(controlFeel.waitForExistence(timeout: 10), "Control Feel row missing")
        controlFeel.tap()
        let edit = app.buttons["editLayoutButton"]
        XCTAssertTrue(edit.waitForExistence(timeout: 10), "Edit Layout button missing from Control Feel")
        edit.tap()
        XCTAssertTrue(app.buttons["layoutEditor.fireButton"].waitForExistence(timeout: 10),
                      "the layout editor never showed FIRE")
    }

    @MainActor
    func testDraggedButtonSurvivesRelaunchAndResetRestoresIt() throws {
        var app = launchClean()
        addTeardownBlock {
            // Wipe the persisted layout whatever happened above.
            let cleanup = XCUIApplication()
            cleanup.launchEnvironment["WADDLE_RESET_STORE"] = "1"
            cleanup.launch()
            cleanup.terminate()
        }

        openLayoutEditor(app)
        let editorFire = app.buttons["layoutEditor.fireButton"]
        let before = editorFire.frame

        // Drag FIRE up and to the left by a distance no layout jitter could
        // explain. Coordinates, not the element: the editor's buttons pass
        // touches to the canvas underneath, which owns the drag.
        let from = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: before.midX, dy: before.midY))
        let to = from.withOffset(CGVector(dx: -120, dy: -160))
        from.press(forDuration: 0.3, thenDragTo: to)

        let after = editorFire.frame
        XCTAssertEqual(after.midX, before.midX - 120, accuracy: 24, "FIRE did not follow the drag horizontally")
        XCTAssertEqual(after.midY, before.midY - 160, accuracy: 24, "FIRE did not follow the drag vertically")

        app.buttons["layoutEditorDoneButton"].tap()
        XCTAssertTrue(app.buttons["controlFeelDoneButton"].waitForExistence(timeout: 5))
        app.buttons["controlFeelDoneButton"].tap()

        // Relaunch (no reset) and start a session: the overlay installs with
        // the persisted layout.
        app.terminate()
        app = XCUIApplication()
        app.launchEnvironment["WADDLE_AUTOQUIT_SECONDS"] = "12"
        app.launchEnvironment["WADDLE_FORCE_TOUCH_OVERLAY"] = "1"
        app.launch()
        let play = app.buttons["playFreedoom1"]
        XCTAssertTrue(play.waitForExistence(timeout: 10))
        play.tap()
        let fire = app.buttons["fireButton"]
        XCTAssertTrue(fire.waitForExistence(timeout: 20), "overlay never installed")
        let inGame = fire.frame
        XCTAssertEqual(inGame.midX, after.midX, accuracy: 24,
                       "in-game FIRE is not where the editor left it: \(inGame) vs \(after)")
        XCTAssertEqual(inGame.midY, after.midY, accuracy: 24,
                       "in-game FIRE is not where the editor left it: \(inGame) vs \(after)")
        XCTAssertGreaterThan(hypot(inGame.midX - before.midX, inGame.midY - before.midY), 80,
                             "in-game FIRE is still at its default position")
        let exit = app.staticTexts["engineExitLabel"]
        XCTAssertTrue(exit.waitForExistence(timeout: 90), "session did not end")

        // Reset in the editor restores the default position, live.
        openLayoutEditor(app)
        let movedStill = editorFire.frame
        XCTAssertEqual(movedStill.midX, after.midX, accuracy: 24, "the editor forgot the saved layout")
        app.buttons["layoutEditorResetButton"].tap()
        let restored = editorFire.frame
        XCTAssertEqual(restored.midX, before.midX, accuracy: 24, "Reset did not restore FIRE horizontally")
        XCTAssertEqual(restored.midY, before.midY, accuracy: 24, "Reset did not restore FIRE vertically")
        app.buttons["layoutEditorDoneButton"].tap()
    }

    /// Cancel discards the drag: the next editor opening shows the saved
    /// layout, not the abandoned one.
    @MainActor
    func testCancelDiscardsTheDrag() throws {
        let app = launchClean()
        addTeardownBlock {
            let cleanup = XCUIApplication()
            cleanup.launchEnvironment["WADDLE_RESET_STORE"] = "1"
            cleanup.launch()
            cleanup.terminate()
        }
        openLayoutEditor(app)
        let editorUse = app.buttons["layoutEditor.useButton"]
        let before = editorUse.frame
        let from = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: before.midX, dy: before.midY))
        from.press(forDuration: 0.3, thenDragTo: from.withOffset(CGVector(dx: -100, dy: -120)))
        XCTAssertLessThan(editorUse.frame.midY, before.midY - 60, "USE did not move in the editor")
        app.buttons["layoutEditorCancelButton"].tap()

        XCTAssertTrue(app.buttons["editLayoutButton"].waitForExistence(timeout: 5))
        app.buttons["editLayoutButton"].tap()
        XCTAssertTrue(editorUse.waitForExistence(timeout: 10))
        XCTAssertEqual(editorUse.frame.midX, before.midX, accuracy: 4, "Cancel kept the abandoned drag")
        XCTAssertEqual(editorUse.frame.midY, before.midY, accuracy: 4, "Cancel kept the abandoned drag")
        app.buttons["layoutEditorCancelButton"].tap()
    }
}
