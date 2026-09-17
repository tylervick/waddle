import UIKit
import XCTest
@testable import Waddle

/// What `OverlayButton` currently tells VoiceOver — pinned, **not endorsed**
/// (issue #215).
///
/// ## Read this before "fixing" a failure here
///
/// These assertions record today's behaviour so that changing it has to be
/// deliberate. They are **not** evidence the behaviour is right. Issue #215
/// argues it is probably wrong: `accessibilityTraits = .button` means VoiceOver
/// activates the control by focusing it and double-tapping, and Doom needs
/// simultaneous, sustained input — strafe while firing, hold forward while
/// turning — none of which survives a focus-then-double-tap model. The trait
/// that passes touches straight through to the view is
/// `.allowsDirectInteraction`.
///
/// So a failure here is most likely **the fix landing**, not a regression. When
/// that happens, update these assertions and say in the commit what the device
/// run showed. Do not "restore" `.button` to get the suite green.
///
/// ## Why this file does not just make the change
///
/// #215 gates the trait choice on an observed VoiceOver run on a physical
/// device, and that gate is right: whether the answer is
/// `.allowsDirectInteraction` on each button, a direct-interaction region over
/// the whole overlay, or a custom rotor is a question about what a VoiceOver
/// user can actually *do*, which no amount of simulator arithmetic answers.
///
/// The usual fallback — prove it end to end in the UI suite — is unavailable:
/// `docs/learnings/touch-controls-ui-tests-red-at-head.md` records that the
/// tests which reach the in-game overlay fail on an unmodified tree, a full
/// step upstream, because the engine session never installs the overlay at
/// all. A new UI test on that path would be red for reasons that have nothing
/// to do with accessibility.
///
/// What is left, and what this file is, is the half of #215's definition of
/// done that can be done hermetically: pin the trait so the eventual change is
/// a visible, tested, one-line diff instead of a silent edit.
@MainActor
final class OverlayButtonAccessibilityTraitTests: XCTestCase {

    /// A button at the size the overlay actually installs one, with the press
    /// handler stubbed — nothing here activates anything, these tests only read
    /// what the control advertises to VoiceOver.
    ///
    /// 84 pt matches `OverlayButtonHitAreaTests`' fixture rather than picking a
    /// fresh number: the traits do not vary with size, so a second size would
    /// imply a dependency that is not there.
    private func makeButton(_ title: String = "FIRE") -> OverlayButton {
        OverlayButton(title: title, size: 84) { _ in }
    }

    /// The overlay's controls are individually exposed, each carrying its
    /// on-screen title. This part is not in question: a VoiceOver user being
    /// able to *enumerate* the controls is right whatever the activation model
    /// turns out to be.
    func testEachButtonIsAnAccessibilityElementLabelledWithItsTitle() {
        for title in ["FIRE", "USE", "MAP"] {
            let button = makeButton(title)
            XCTAssertTrue(button.isAccessibilityElement, title)
            XCTAssertEqual(button.accessibilityLabel, title)
        }
    }

    /// **The assertion #215 expects to overturn.** Pinned so that it cannot
    /// change without someone deciding to change it.
    func testButtonsCurrentlyAdvertiseTheButtonTraitAndNotDirectInteraction() {
        let button = makeButton()
        XCTAssertTrue(button.accessibilityTraits.contains(.button),
                      "trait changed — if this is #215's fix, update this file, do not revert the source")
        XCTAssertFalse(button.accessibilityTraits.contains(.allowsDirectInteraction),
                       "direct interaction is now set — this is #215's fix; update this file")
    }

    /// The label is the only thing a VoiceOver user gets, so it has to be the
    /// visible title rather than a synthesized description — and it must not be
    /// silently dropped for an unlabelled control.
    func testAnEmptyTitleStillProducesAnAddressableElement() {
        let button = makeButton("")
        XCTAssertTrue(button.isAccessibilityElement)
        XCTAssertEqual(button.accessibilityLabel, "")
    }
}
