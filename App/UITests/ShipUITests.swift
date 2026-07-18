import XCTest

/// Smoke test for the About & licenses screen (Plan 4 GPL compliance
/// surface): gear menu -> About sheet shows the license list and build info.
final class ShipUITests: XCTestCase {

    @MainActor
    func testAboutScreenShowsLicensesAndBuild() {
        let app = XCUIApplication()
        app.launch()

        // The gear menu trigger in LoadoutGridView's toolbar.
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

        // The app is landscape-only, so the Licenses section starts below
        // the fold, and List rows are lazy -- they don't exist in the
        // hierarchy until scrolled on-screen.
        let gplRow = app.descendants(matching: .any)["BoomBox & Woof! — GPL-2.0"]
        var swipes = 0
        while !gplRow.exists && swipes < 6 {
            aboutList.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(gplRow.exists, "GPL-2.0 license row never appeared")
    }
}
