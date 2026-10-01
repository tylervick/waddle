import UIKit
import XCTest
@testable import Waddle

/// What `OverlayButton` tells VoiceOver (issue #215), pinned so it cannot
/// change without someone deciding to change it.
///
/// ## The decision this file records
///
/// The overlay's buttons advertise `.allowsDirectInteraction`, not `.button`.
/// A `.button` element is activated by VoiceOver with focus-then-double-tap,
/// one control at a time, and Doom needs simultaneous, sustained input:
/// strafe while firing, hold forward while turning. None of that survives a
/// focus-then-double-tap model. `.allowsDirectInteraction` is the trait Apple
/// gives a control that must receive the user's touches as touches (an
/// on-screen piano keyboard, a drawing canvas): VoiceOver passes a touch on
/// the element straight through to `touchesBegan`/`touchesEnded`, so the
/// press-and-hold path that drives the virtual gamepad works exactly as it
/// does with VoiceOver off. The label stays, so a VoiceOver user can still
/// find each control by exploring the screen, and `.button` stays beside the
/// new trait: it is what announces the control as a button, and it is how
/// XCUITest and Revyl locate the overlay (`app.buttons["fireButton"]`).
/// Measured 2026-09-30 with `.button` removed: `TouchControlsTests` could
/// not find a single overlay control and every in-game case failed on
/// `waitForExistence`. Direct interaction decides what a held finger does;
/// `.button` only says what the thing is.
///
/// `docs/learnings/voiceover-direct-interaction-for-game-controls.md` has the
/// reasoning and the device observation. This file used to pin `.button`
/// with a note that a failure would most likely be the fix landing; this is
/// that fix. If a device run ever shows direct interaction is the wrong
/// answer, change the source and this file together and say what the run
/// showed, in that order.
@MainActor
final class OverlayButtonAccessibilityTraitTests: XCTestCase {

    /// A button at the size the overlay actually installs one, with the press
    /// handler stubbed: nothing here activates anything, these tests only read
    /// what the control advertises to VoiceOver.
    private func makeButton(_ title: String = "FIRE") -> OverlayButton {
        OverlayButton(title: title, size: 84) { _ in }
    }

    /// The overlay's controls are individually exposed, each carrying its
    /// on-screen title, so a VoiceOver user can enumerate them whatever the
    /// activation model.
    func testEachButtonIsAnAccessibilityElementLabelledWithItsTitle() {
        for title in ["FIRE", "USE", "MAP"] {
            let button = makeButton(title)
            XCTAssertTrue(button.isAccessibilityElement, title)
            XCTAssertEqual(button.accessibilityLabel, title)
        }
    }

    /// The decision above, as an assertion: touches pass straight through
    /// (direct interaction), and the control still identifies as a button.
    func testButtonsAllowDirectInteractionAndStillIdentifyAsButtons() {
        let button = makeButton()
        XCTAssertTrue(button.accessibilityTraits.contains(.allowsDirectInteraction),
                      "a game control must receive touches as touches under VoiceOver (issue #215)")
        XCTAssertTrue(button.accessibilityTraits.contains(.button),
                      ".button is how the control announces itself and how `app.buttons[...]` finds "
                      + "the overlay in every in-game UI test; drop it and TouchControlsTests goes red")
    }

    /// The label is the only thing a VoiceOver user gets, so it has to be the
    /// visible title rather than a synthesized description, and it must not be
    /// silently dropped for an unlabelled control.
    func testAnEmptyTitleStillProducesAnAddressableElement() {
        let button = makeButton("")
        XCTAssertTrue(button.isAccessibilityElement)
        XCTAssertEqual(button.accessibilityLabel, "")
    }
}
