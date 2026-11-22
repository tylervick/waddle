import SwiftUI
import XCTest
@testable import Waddle

/// A game with a save shows Continue and New Game on its page, and each is
/// drawn wide enough to hold its own label on one line (issue #468).
///
/// On a closed iPhone Duo held sideways, at the default text size, the page
/// put the art beside the caption and the two buttons side by side in the
/// caption, about 136 pt each, and both labels wrapped: "Contin-" / "ue" and
/// "New" / "Game". The row was chosen by `ViewThatFits`, which asks whether
/// the two labels' natural widths fit side by side; both buttons stretch, so
/// the row is drawn as two equal halves, and wherever the sum fitted and
/// twice the wider label did not, a label wrapped. The shelf's hero had the
/// same fault and the same fix (issue #424, `ShelfHeroLayout.buttonArrangement`).
///
/// The page is hosted for real here, and every button's drawn width is
/// compared with what its label needs: the label at its natural width, plus
/// the button style's padding either side. A button narrower than that wraps
/// its label.
@MainActor
final class GamePageActionRowTests: XCTestCase {
    private var seededGameIDs: [UUID] = []

    override func tearDown() async throws {
        for id in seededGameIDs {
            try? FileManager.default.removeItem(at: LibraryService.savesDirectory(forGameID: id))
        }
        seededGameIDs = []
    }

    /// A window the page is hosted in, with the safe area its device keeps
    /// out of it.
    private struct Window {
        let name: String
        let size: CGSize
        var safeArea = UIEdgeInsets.zero
    }

    /// What the page drew in one window.
    private struct Hosted {
        /// Where each action button was last drawn, by accessibility identifier.
        var actions: [String: CGRect] = [:]
        /// The page's last measurements.
        var measurements: GamePageMeasurements?
    }

    private func host(_ game: Game, in library: LibraryService,
                      textSize: DynamicTypeSize, window spec: Window) -> Hosted {
        var hosted = Hosted()
        let window = UIWindow(frame: CGRect(origin: .zero, size: spec.size))
        let controller = UIHostingController(rootView: NavigationStack {
            GamePageView(game: game, library: library,
                         onPlay: { _, _ in }, onChanged: {}, onClose: {})
        }
        .dynamicTypeSize(textSize)
        .environment(\.gamePageActionFrameReport) { id, frame in hosted.actions[id] = frame }
        .environment(\.gamePageMeasurementsReport) { hosted.measurements = $0 })
        controller.additionalSafeAreaInsets = spec.safeArea
        window.rootViewController = controller
        window.isHidden = false
        // Several turns: the page's measurements each arrive a layout pass
        // after the state they follow from.
        for _ in 0..<10 {
            window.layoutIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        window.isHidden = true
        window.rootViewController = nil
        return hosted
    }

    /// What a button needs to show `title` on one line: the label at its
    /// natural width, and the button style's padding either side of it.
    private func neededWidth(_ title: String, systemImage: String, textSize: DynamicTypeSize) -> CGFloat {
        let label = UIHostingController(rootView: Label(title, systemImage: systemImage)
            .font(Theme.Typography.button)
            .lineLimit(1)
            .fixedSize()
            .dynamicTypeSize(textSize))
        return label.sizeThatFits(in: CGSize(width: 10_000, height: 10_000)).width + Theme.Spacing.base * 2
    }

    /// The column an iPhone Duo keeps for the clock, status icons and
    /// toolbar buttons, on the trailing edge in every pose
    /// (`docs/learnings/iphone-duo-simulator-traps.md`). It is what made the
    /// issue's row narrow enough to wrap: without it a 678 pt window has
    /// room for the two buttons side by side.
    private static let duoStatusColumn = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 84)

    /// The window that filed the issue first: a closed iPhone Duo on its
    /// side. Then the Duo's other windows and a regular iPhone both ways up,
    /// so a fix that only moved the threshold is caught as well.
    private let windows: [Window] = [
        Window(name: "closed iPhone Duo on its side", size: CGSize(width: 678, height: 466), safeArea: duoStatusColumn),
        Window(name: "closed iPhone Duo", size: CGSize(width: 466, height: 678), safeArea: duoStatusColumn),
        Window(name: "open iPhone Duo", size: CGSize(width: 951, height: 669), safeArea: duoStatusColumn),
        Window(name: "open iPhone Duo turned", size: CGSize(width: 669, height: 951), safeArea: duoStatusColumn),
        Window(name: "iPhone 18 Pro in landscape", size: CGSize(width: 874, height: 402),
               safeArea: UIEdgeInsets(top: 0, left: 62, bottom: 21, right: 62)),
        Window(name: "iPhone 18 Pro", size: CGSize(width: 402, height: 874),
               safeArea: UIEdgeInsets(top: 62, left: 0, bottom: 34, right: 0)),
    ]

    /// Portrait windows whose row lands where the two labels side by side
    /// fit but two buttons of the wider do not: the band `ViewThatFits` let
    /// through, because it asks about the sum and a row of stretching
    /// buttons is drawn as two halves (`ShelfHeroLayout.buttonArrangement`).
    /// The band is ten points or so wide and moves with the text size, so
    /// it is searched for, a little either side, in two-point steps. A row is
    /// the window less 16 pt each side.
    private func evenSplitBand(needed: [String: CGFloat]) -> [Window] {
        let labels = Array(needed.values)
        guard labels.count == 2, let widest = labels.max() else { return [] }
        let gap = ShelfHeroLayout.buttonRowSpacing
        let low = labels.reduce(0, +) + gap - 12, high = widest * 2 + gap + 12
        return stride(from: (low / 2).rounded(.down) * 2, through: high, by: 2).map { row in
            Window(name: "portrait window with a \(Int(row)) pt row",
                   size: CGSize(width: row + PlayableDetailLayout.rowHorizontalInset * 2, height: 874))
        }
    }

    private let textSizes: [DynamicTypeSize] = [.large, .xxxLarge, .accessibility1, .accessibility3, .accessibility5]

    func testEachActionButtonHoldsItsLabelOnOneLine() throws {
        let fixture = ShelfPreviewFixture.continueHero()
        let game = try XCTUnwrap(try fixture.library.shelfGames().first)
        seededGameIDs.append(game.id)

        for textSize in textSizes {
            let needed = [
                "continueButton": neededWidth("Continue", systemImage: "clock.arrow.circlepath", textSize: textSize),
                "playButton": neededWidth("New Game", systemImage: "play.fill", textSize: textSize),
            ]
            for window in windows + evenSplitBand(needed: needed) {
                let hosted = host(game, in: fixture.library, textSize: textSize, window: window)
                let drawn = hosted.actions.mapValues(\.width)
                let context = "\(window.name) (\(Int(window.size.width))x\(Int(window.size.height))), "
                    + "\(textSize): drawn \(drawn), needed \(needed), \(String(describing: hosted.measurements))"
                XCTAssertEqual(Set(drawn.keys), Set(needed.keys), "the page did not draw Continue and New Game. \(context)")
                let measured = try XCTUnwrap(hosted.measurements, context)
                // The page's own gauge sees at least what a label on its own
                // does. A `Label` in a form row's background is drawn as its
                // icon alone, and a gauge that forgot to say otherwise read
                // 40 pt for both labels.
                XCTAssertGreaterThanOrEqual(measured.actionLabelWidth + Theme.Spacing.base * 2 + 0.5,
                                            needed.values.max() ?? 0,
                                            "the page measured its labels narrower than they are. \(context)")
                for (id, width) in drawn {
                    let need = try XCTUnwrap(needed[id])
                    // A button already as wide as the whole caption is as
                    // wide as this row can make it; whether the caption is
                    // wide enough is the hero's arrangement's to decide
                    // (issue #425), and a label there may still break
                    // between its words. Anywhere else, half a point for
                    // rounding: a label short by that is not on two lines.
                    if abs(width - measured.actionsWidth) < 1 { continue }
                    XCTAssertGreaterThanOrEqual(width + 0.5, need,
                                                "\(id) is drawn narrower than its label on one line. \(context)")
                }
            }
        }
    }

    /// Where the buttons can share a row, they do: the fix must not buy
    /// whole labels by stacking a page that has the room. Judged from the
    /// widths the page itself measured, because what a test window keeps out
    /// of the page differs between the simulators CI runs this on, and a
    /// label drawn in the page is a few points wider than one on its own.
    func testTheButtonsShareARowWhereTwoOfTheWiderFitSideBySide() throws {
        let fixture = ShelfPreviewFixture.continueHero()
        let game = try XCTUnwrap(try fixture.library.shelfGames().first)
        seededGameIDs.append(game.id)
        var rows = 0, columns = 0

        for textSize in textSizes {
            for window in windows {
                let hosted = host(game, in: fixture.library, textSize: textSize, window: window)
                let context = "\(window.name), \(textSize): \(hosted)"
                let measured = try XCTUnwrap(hosted.measurements, context)
                let caption = measured.actionsWidth
                // The page's own reading of its labels, taken where its
                // buttons are drawn; the test above holds it to a label on
                // its own.
                let widest = measured.actionLabelWidth + Theme.Spacing.base * 2
                let continueFrame = try XCTUnwrap(hosted.actions["continueButton"], context)
                let newGameFrame = try XCTUnwrap(hosted.actions["playButton"], context)
                let sideBySide = abs(continueFrame.minY - newGameFrame.minY) < 0.5
                // A point either side of the line is left alone: there the
                // label measured here and the one the page measured may
                // round apart.
                let room = caption - (widest * 2 + ShelfHeroLayout.buttonRowSpacing)
                if room >= 1 {
                    rows += 1
                    XCTAssertTrue(sideBySide, "the buttons are stacked where they fit side by side. \(context)")
                } else if room <= -1 {
                    columns += 1
                    XCTAssertFalse(sideBySide, "the buttons share a row they do not fit. \(context)")
                }
            }
        }
        // Not vacuous: both answers were asked for.
        XCTAssertGreaterThan(rows, 0, "no window had room for the buttons side by side")
        XCTAssertGreaterThan(columns, 0, "no window was too narrow for the buttons side by side")
    }

    /// The issue's own window: a closed iPhone Duo on its side, at the
    /// default text size. The caption beside the art is 267 pt and a button
    /// needs 150 (the wider label, 118, and its padding), so the row rule
    /// stacks them: two such buttons and the gap are 312.
    ///
    /// What put them side by side on `main` was not the even split. It was
    /// the labels: in a form row a `Label` is drawn as its icon, and
    /// `ViewThatFits` read the two as about 40 pt each, a 156 pt row. With
    /// the labels drawn whole it reads about 302 pt and stacks here too, so
    /// this window fails with the labels' style taken away, not with the
    /// row alone; the searched band above is what fails with the row alone.
    func testTheIssuesWindowStacksTheButtonsWhole() throws {
        let fixture = ShelfPreviewFixture.continueHero()
        let game = try XCTUnwrap(try fixture.library.shelfGames().first)
        seededGameIDs.append(game.id)
        let window = Window(name: "closed iPhone Duo on its side", size: CGSize(width: 678, height: 466),
                            safeArea: Self.duoStatusColumn)
        let hosted = host(game, in: fixture.library, textSize: .large, window: window)
        let context = "\(hosted)"
        let measured = try XCTUnwrap(hosted.measurements, context)
        let continueFrame = try XCTUnwrap(hosted.actions["continueButton"], context)
        let newGameFrame = try XCTUnwrap(hosted.actions["playButton"], context)

        XCTAssertEqual(measured.arrangement, .sideBySide, "the art is no longer beside the caption. \(context)")
        XCTAssertEqual(measured.buttonArrangement, .column, context)
        XCTAssertLessThanOrEqual(continueFrame.maxY, newGameFrame.minY + 0.5,
                                 "Continue and New Game share a row they do not fit. \(context)")
        let need = neededWidth("New Game", systemImage: "play.fill", textSize: .large)
        XCTAssertGreaterThanOrEqual(newGameFrame.width + 0.5, need, context)
        XCTAssertGreaterThanOrEqual(continueFrame.width + 0.5,
                                    neededWidth("Continue", systemImage: "clock.arrow.circlepath", textSize: .large),
                                    context)
        // The rule itself, with the numbers this window measured.
        XCTAssertEqual(ShelfHeroLayout.buttonArrangement(captionWidth: measured.actionsWidth,
                                                         buttonMinimumWidth: measured.actionLabelWidth + Theme.Spacing.base * 2),
                       .column, context)
    }
}
