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
    func testWhatWasOpenSurvivesThePresentationBeingToggled() {
        let model = ShelfPanelModel()
        model.panel = .settings
        XCTAssertTrue(model.isPresented)
        XCTAssertEqual(model.panel, .settings)

        model.isPresented = false
        XCTAssertNil(model.panel, "a closed panel reports nothing open")
        XCTAssertEqual(model.content, .settings, "but what it showed is kept")

        model.isPresented = true
        XCTAssertEqual(model.panel, .settings, "the panel came back empty after a fold")
    }

    /// Closing through the model closes the inspector.
    @MainActor
    func testSettingThePanelToNilClosesIt() {
        let model = ShelfPanelModel()
        model.panel = .settings
        model.panel = nil
        XCTAssertFalse(model.isPresented)
        XCTAssertNil(model.panel)
    }

    /// Settings is one panel; a game's panel is that game's.
    func testPanelsCompareBySettingsOrByGame() {
        XCTAssertEqual(ShelfPanel.settings, ShelfPanel.settings)
        XCTAssertNil(ShelfPanel.settings.gameID)
    }
}
