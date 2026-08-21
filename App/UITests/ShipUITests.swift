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
}
