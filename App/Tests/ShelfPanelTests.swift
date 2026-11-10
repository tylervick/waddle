import XCTest
@testable import Waddle

/// Issue #372: where Details and Settings open. The rule is one line, and it
/// is pinned here because the rest of the feature is presentation that only a
/// look at the screen can check.
final class ShelfPanelTests: XCTestCase {

    /// A regular-width window gets the panel; a compact one keeps the pushed
    /// page and the sheet, which is every phone and the closed iPhone Duo.
    func testOnlyARegularWidthWindowOpensThePanel() {
        XCTAssertTrue(ShelfPanelModel.opensInPanel(regularWidth: true))
        XCTAssertFalse(ShelfPanelModel.opensInPanel(regularWidth: false))
    }

    /// Until the root has reported a size class, the shelf behaves as a
    /// phone: the page and the sheet are right everywhere, the panel is not.
    @MainActor
    func testAnUnmeasuredWindowIsTreatedAsCompact() {
        let model = ShelfPanelModel()
        XCTAssertFalse(model.opensInPanel)
        model.windowIsRegularWidth = true
        XCTAssertTrue(model.opensInPanel)
    }

    /// The fold: SwiftUI writes false and then true to the inspector's
    /// binding while it swaps a column for a sheet. What was open has to
    /// still be there when the true arrives.
    @MainActor
    func testWhatWasOpenSurvivesTheSystemTogglingThePresentation() {
        let model = ShelfPanelModel()
        model.panel = .settings
        XCTAssertTrue(model.isPresented)
        XCTAssertEqual(model.panel, .settings)

        model.systemSetPresented(false)
        XCTAssertNil(model.panel, "a hidden panel reports nothing open")
        XCTAssertEqual(model.content, .settings, "but what it showed is kept")

        model.systemSetPresented(true)
        XCTAssertEqual(model.panel, .settings, "the panel came back empty after a fold")
    }

    /// The regression this was added for: on a regular-width window SwiftUI
    /// writes true to the binding a moment after launch, with nothing open.
    /// Accepting it showed an empty column beside the shelf on an iPad and a
    /// landscape iPhone 17 Pro Max.
    @MainActor
    func testTheSystemCannotPresentAPanelWithNothingInIt() {
        let model = ShelfPanelModel()
        model.systemSetPresented(true)
        XCTAssertFalse(model.isPresented)
        XCTAssertNil(model.panel)
    }

    /// Closing the panel forgets what it showed, so a later write of true
    /// from the system cannot bring a closed panel back.
    @MainActor
    func testAClosedPanelIsNotReopenedByTheSystem() {
        let model = ShelfPanelModel()
        model.panel = .settings
        model.panel = nil
        XCTAssertFalse(model.isPresented)
        XCTAssertNil(model.content)

        model.systemSetPresented(true)
        XCTAssertFalse(model.isPresented, "a panel the player closed reopened by itself")
    }

    /// Unfolding an iPhone Duo with nothing open: SwiftUI puts an empty
    /// column up and never re-reads the binding, so the model bounces it.
    /// Whatever happens in between, it must end not presented.
    @MainActor
    func testAStrayColumnIsBouncedShutWhenNothingIsOpen() async throws {
        let model = ShelfPanelModel()
        model.dismissStrayColumn()
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertFalse(model.isPresented)
        XCTAssertNil(model.panel)
    }

    /// The same unfold with a panel open is the column doing its job, and
    /// the bounce must leave it alone.
    @MainActor
    func testTheBounceLeavesAnOpenPanelAlone() async throws {
        let model = ShelfPanelModel()
        model.panel = .settings
        model.dismissStrayColumn()
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(model.panel, .settings)
    }

    /// Settings is one panel; a game's panel is that game's.
    func testPanelsCompareBySettingsOrByGame() {
        XCTAssertEqual(ShelfPanel.settings, ShelfPanel.settings)
        XCTAssertNil(ShelfPanel.settings.gameID)
    }
}
