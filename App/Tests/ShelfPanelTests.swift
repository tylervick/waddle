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
        model.windowWidthChanged(isRegular: true, becameRegular: false)
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
    /// column up, writes true, and never re-reads the binding if that is
    /// refused. So just after the window becomes regular the write is
    /// accepted and then taken back, which SwiftUI can see.
    @MainActor
    func testTheUnfoldsStrayColumnIsAcceptedAndThenClosed() async throws {
        let model = ShelfPanelModel()
        model.windowWidthChanged(isRegular: false, becameRegular: false)
        model.windowWidthChanged(isRegular: true, becameRegular: true)

        model.systemSetPresented(true)
        XCTAssertTrue(model.isPresented, "the write has to be accepted for the close to be a visible change")
        XCTAssertNil(model.panel, "but nothing is open")

        try await Task.sleep(for: .milliseconds(400))
        XCTAssertFalse(model.isPresented, "the stray column was left up")
    }

    /// The other order: the write arrives, and is refused, just before the
    /// width change is reported. The column is up all the same.
    @MainActor
    func testAWriteJustBeforeTheWidthChangeIsClosedToo() async throws {
        let model = ShelfPanelModel()
        model.windowWidthChanged(isRegular: false, becameRegular: false)
        model.systemSetPresented(true)
        XCTAssertFalse(model.isPresented)

        model.windowWidthChanged(isRegular: true, becameRegular: true)
        XCTAssertTrue(model.isPresented)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertFalse(model.isPresented, "the stray column was left up")
    }

    /// A window that was regular from launch: refusing is enough there, and
    /// accepting even for a frame would flash a column at every launch.
    @MainActor
    func testAWindowThatStartedRegularRefusesAndNeverPresents() async throws {
        let model = ShelfPanelModel()
        model.windowWidthChanged(isRegular: true, becameRegular: false)
        model.systemSetPresented(true)
        for _ in 0..<8 {
            XCTAssertFalse(model.isPresented)
            try await Task.sleep(for: .milliseconds(30))
        }
    }

    /// The same unfold with a panel open is the column doing its job.
    @MainActor
    func testAnUnfoldWithAPanelOpenKeepsIt() async throws {
        let model = ShelfPanelModel()
        model.windowWidthChanged(isRegular: true, becameRegular: false)
        model.panel = .settings
        model.windowWidthChanged(isRegular: false, becameRegular: false)
        model.systemSetPresented(false)
        model.windowWidthChanged(isRegular: true, becameRegular: true)
        model.systemSetPresented(true)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(model.panel, .settings)
    }

    /// Folded again before the close has run: in a compact window the
    /// accepted true would be an empty sheet, so it is taken back at once.
    @MainActor
    func testGoingBackToCompactTakesTheAcceptedWriteBack() async throws {
        let model = ShelfPanelModel()
        model.windowWidthChanged(isRegular: false, becameRegular: false)
        model.windowWidthChanged(isRegular: true, becameRegular: true)
        model.systemSetPresented(true)
        model.windowWidthChanged(isRegular: false, becameRegular: false)
        XCTAssertFalse(model.isPresented, "an empty sheet would be presented on the folded device")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(model.isPresented)
    }

    /// A panel opened while a close is in flight is not closed by it.
    @MainActor
    func testOpeningAPanelAbandonsTheClose() async throws {
        let model = ShelfPanelModel()
        model.windowWidthChanged(isRegular: false, becameRegular: false)
        model.windowWidthChanged(isRegular: true, becameRegular: true)
        model.systemSetPresented(true)
        model.panel = .settings
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(model.panel, .settings)

        model.panel = nil
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(model.isPresented)
    }

    // MARK: Two halves (issue #429)

    /// Half open, Details and Settings open in the lower half whatever the
    /// window's width: a pushed page would take the shelf's half and a sheet
    /// would lie across the fold.
    @MainActor
    func testInTwoHalvesEverythingOpensInThePanel() {
        XCTAssertTrue(ShelfPanelModel.opensInPanel(regularWidth: false, isSplit: true))
        let model = ShelfPanelModel()
        XCTAssertFalse(model.opensInPanel)
        model.foldChanged(isSplit: true)
        XCTAssertTrue(model.opensInPanel)
        model.foldChanged(isSplit: false)
        XCTAssertFalse(model.opensInPanel)
    }

    /// The inspector is not used in two halves: a panel opened there is open
    /// (the shelf marks its tile, the lower half shows it) with the
    /// inspector's binding still false.
    @MainActor
    func testAPanelOpenedInTwoHalvesNeverPresentsTheInspector() {
        let model = ShelfPanelModel()
        model.windowWidthChanged(isRegular: true, becameRegular: false)
        model.foldChanged(isSplit: true)
        model.panel = .settings
        XCTAssertEqual(model.panel, .settings)
        XCTAssertEqual(model.lowerHalf, .settings)
        XCTAssertFalse(model.isPresented, "a column beside the shelf in the upper half")

        model.panel = nil
        XCTAssertNil(model.panel)
        XCTAssertNil(model.lowerHalf, "with no game on the shelf there is nothing to rest on")
    }

    /// Bending the device with a panel open moves it to the lower half, and
    /// opening it flat again puts the column back: the launcher follows the
    /// pose both ways without losing what was open.
    @MainActor
    func testAnOpenPanelSurvivesBendingAndOpeningFlat() {
        let model = ShelfPanelModel()
        model.windowWidthChanged(isRegular: true, becameRegular: false)
        model.panel = .settings
        XCTAssertTrue(model.isPresented)

        model.foldChanged(isSplit: true)
        XCTAssertFalse(model.isPresented, "the column has to come down where SwiftUI can see it")
        XCTAssertEqual(model.panel, .settings, "the panel was lost on the way into two halves")

        // The inspector writes false as it is taken down. Nothing depends on it.
        model.systemSetPresented(false)
        XCTAssertEqual(model.panel, .settings)

        model.foldChanged(isSplit: false)
        XCTAssertTrue(model.isPresented, "the column did not come back")
        XCTAssertEqual(model.panel, .settings)
    }

    /// A panel closed in the lower half is closed: opening flat brings no
    /// column back, and a later write from the system has nothing to show.
    @MainActor
    func testAPanelClosedInTwoHalvesStaysClosedWhenOpenedFlat() {
        let model = ShelfPanelModel()
        model.windowWidthChanged(isRegular: true, becameRegular: false)
        model.panel = .settings
        model.foldChanged(isSplit: true)
        model.panel = nil
        model.foldChanged(isSplit: false)
        XCTAssertFalse(model.isPresented)
        XCTAssertNil(model.content)
        model.systemSetPresented(true)
        XCTAssertFalse(model.isPresented)
    }

    /// In two halves the system's `true` is never taken, with a panel open
    /// or not: on a window that has been regular all along it is refused.
    @MainActor
    func testTheSystemCannotPresentTheInspectorInTwoHalves() async throws {
        let model = ShelfPanelModel()
        model.windowWidthChanged(isRegular: true, becameRegular: false)
        model.foldChanged(isSplit: true)
        model.panel = .settings
        model.systemSetPresented(true)
        for _ in 0..<8 {
            XCTAssertFalse(model.isPresented)
            try await Task.sleep(for: .milliseconds(30))
        }
        XCTAssertEqual(model.panel, .settings)
    }

    /// A closed iPhone Duo opened straight to half open: the window has just
    /// become regular, SwiftUI has put its column up, and refusing its write
    /// would leave it there. It is accepted and taken back, as when nothing
    /// is open on a flat device, and the panel stays in the lower half.
    @MainActor
    func testAColumnPutUpOnTheWayIntoTwoHalvesIsClosed() async throws {
        let model = ShelfPanelModel()
        model.windowWidthChanged(isRegular: false, becameRegular: false)
        model.panel = .settings
        model.windowWidthChanged(isRegular: true, becameRegular: true)
        model.foldChanged(isSplit: true)
        XCTAssertFalse(model.isPresented)

        model.systemSetPresented(true)
        XCTAssertTrue(model.isPresented, "the write has to be accepted for the close to be a visible change")
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertFalse(model.isPresented, "the column was left up beside the shelf")
        XCTAssertEqual(model.panel, .settings)
    }

    /// Settings is one panel; a game's panel is that game's.
    func testPanelsCompareBySettingsOrByGame() {
        XCTAssertEqual(ShelfPanel.settings, ShelfPanel.settings)
        XCTAssertNil(ShelfPanel.settings.gameID)
    }
}
