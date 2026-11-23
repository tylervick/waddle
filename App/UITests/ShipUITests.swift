import XCTest

/// Smoke test for the About & licenses screen (Plan 4 GPL compliance
/// surface): gear menu -> About sheet shows the license list and build info.
final class ShipUITests: XCTestCase {

    @MainActor
    func testAboutScreenShowsLicensesAndBuild() {
        let app = XCUIApplication()
        app.launch()

        // The gear menu trigger in PlayView's toolbar.
        let menu = app.buttons["touchSchemeMenu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        menu.tap()

        let about = app.buttons["aboutButton"]
        XCTAssertTrue(about.waitForExistence(timeout: 5))
        about.tap()

        // AboutView is a List; its identifier lands on the collection view
        // (verified via the accessibility snapshot), not an otherElement.
        let aboutList = app.collectionViews["aboutView"]
        XCTAssertTrue(aboutList.waitForExistence(timeout: 5))

        // The Licenses section may start below the fold (guaranteed in
        // landscape, possible in portrait), and List rows are lazy -- they
        // don't exist in the hierarchy until scrolled on-screen.
        // GPL-3.0, not 2.0, since 35a4561: the Apache-2.0 SONiVOX EAS
        // dependency required the relicense, and this label is the app's
        // user-facing statement of it. If this row rename fails again, check
        // AboutView.licenseFiles before suspecting the test.
        let gplRow = app.descendants(matching: .any)["Waddle & Woof! — GPL-3.0"]
        var swipes = 0
        while !gplRow.exists && swipes < 6 {
            aboutList.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(gplRow.exists, "GPL-3.0 license row never appeared")
    }

    /// Issue #484: the Feedback section's two rows. "Send feedback" is not
    /// tapped (it depends on the simulator's mail state; FeedbackRoutesTests
    /// covers both of its outcomes), and "Report a bug" goes no further than
    /// its confirmation.
    func testAboutScreenShowsFeedbackRows() {
        let app = XCUIApplication()
        app.launch()

        let menu = app.buttons["touchSchemeMenu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        menu.tap()

        let about = app.buttons["aboutButton"]
        XCTAssertTrue(about.waitForExistence(timeout: 5))
        about.tap()

        let aboutList = app.collectionViews["aboutView"]
        XCTAssertTrue(aboutList.waitForExistence(timeout: 5))

        // Rows are lazy and may start below the fold in landscape.
        for id in ["reportBugButton", "sendFeedbackButton"] {
            let row = app.buttons[id]
            var swipes = 0
            while !row.exists && swipes < 4 {
                aboutList.swipeUp()
                swipes += 1
            }
            XCTAssertTrue(row.exists, "\(id) never appeared on the About screen")
        }

        // "Report a bug" asks first, naming what the form will carry; Cancel
        // leaves without opening anything.
        app.buttons["reportBugButton"].tap()
        let confirm = app.alerts["Report a bug on GitHub?"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5),
                      "Report a bug must confirm before opening the browser")
        XCTAssertTrue(confirm.buttons["Open GitHub"].exists)
        confirm.buttons["Cancel"].tap()
        XCTAssertTrue(aboutList.waitForExistence(timeout: 5))
    }

    /// Issue #487: About shows the usage counts the diagnostics export
    /// carries before any export, and Reset Usage Counts zeroes them.
    @MainActor
    func testAboutShowsUsageCountsAndResetsThem() {
        let app = XCUIApplication()
        app.launch()

        let menu = app.buttons["touchSchemeMenu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        menu.tap()
        let about = app.buttons["aboutButton"]
        XCTAssertTrue(about.waitForExistence(timeout: 5))
        about.tap()
        let aboutList = app.collectionViews["aboutView"]
        XCTAssertTrue(aboutList.waitForExistence(timeout: 5))

        // Lazy List rows: the Diagnostics section can start below the fold.
        let viewSummary = app.buttons["viewUsageSummaryButton"]
        var swipes = 0
        while !viewSummary.isHittable && swipes < 6 {
            aboutList.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(viewSummary.isHittable, "View Usage Summary row never appeared")
        viewSummary.tap()

        let summary = app.collectionViews["usageSummaryView"]
        XCTAssertTrue(summary.waitForExistence(timeout: 5))
        // This launch was counted before the screen was opened, so the first
        // day seen is a date, not "never".
        let firstSeen = app.descendants(matching: .any)["usageRow: First seen"].firstMatch
        XCTAssertTrue(firstSeen.waitForExistence(timeout: 5))
        XCTAssertFalse(Self.text(of: firstSeen).contains("never"),
                       "launch not counted: \(Self.text(of: firstSeen))")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "usage-summary"
        shot.lifetime = .keepAlways
        add(shot)

        let reset = app.buttons["resetUsageCountsButton"]
        swipes = 0
        while !reset.isHittable && swipes < 10 {
            summary.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(reset.isHittable, "Reset Usage Counts never appeared")
        reset.tap()
        // A confirmationDialog's button matches twice (alert-textfield
        // learning), so take the first.
        let confirm = app.buttons["confirmResetUsageCountsAction"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()

        swipes = 0
        while !firstSeen.isHittable && swipes < 10 {
            summary.swipeDown()
            swipes += 1
        }
        let deadline = Date.now.addingTimeInterval(5)
        while !Self.text(of: firstSeen).contains("never") && Date.now < deadline {
            RunLoop.current.run(until: Date.now.addingTimeInterval(0.2))
        }
        XCTAssertTrue(Self.text(of: firstSeen).contains("never"),
                      "reset did not zero the counts: \(Self.text(of: firstSeen))")
    }

    /// A LabeledContent row's label and value, however the row's
    /// accessibility element combines them.
    private static func text(of element: XCUIElement) -> String {
        "\(element.label) \((element.value as? String) ?? "")"
    }
}
