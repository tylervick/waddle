import CoreGraphics
import XCTest
@testable import Waddle

/// The gesture -> automap-input translation (issue #113), as pure math over
/// supplied deltas: no UIKit, no SDL, no timing. The engine pans and zooms
/// the automap while a key is HELD (`AM_Responder`: arrows, '=' and '-'), so
/// the translation answers "which keys should be down right now" for one
/// event's drag delta or pinch ratio; the overlay diffs that against what it
/// holds and injects the keydown/keyup pairs.
///
/// Bounded work, per the issue's performance guard: the translator is a value
/// with no storage and the answer is an `OptionSet` in one byte, so an event
/// allocates nothing and touches nothing that scales with the map.
final class AutomapGestureTests: XCTestCase {
    private let translator = AutomapGestureTranslator()

    // MARK: Pan. The map content follows the finger, so the engine's view
    // window moves the other way: dragging right = view window left.

    func testDragRightHoldsPanLeft() {
        XCTAssertEqual(translator.keys(forDrag: CGPoint(x: 12, y: 0)), .panLeft)
    }

    func testDragLeftHoldsPanRight() {
        XCTAssertEqual(translator.keys(forDrag: CGPoint(x: -12, y: 0)), .panRight)
    }

    func testDragDownHoldsPanUp() {
        // UIKit y grows downward: a finger moving down carries the content
        // down, so the view window goes up.
        XCTAssertEqual(translator.keys(forDrag: CGPoint(x: 0, y: 12)), .panUp)
    }

    func testDragUpHoldsPanDown() {
        XCTAssertEqual(translator.keys(forDrag: CGPoint(x: 0, y: -12)), .panDown)
    }

    func testDiagonalDragHoldsBothAxes() {
        XCTAssertEqual(translator.keys(forDrag: CGPoint(x: 12, y: -12)), [.panLeft, .panDown])
    }

    func testJitterBelowThresholdHoldsNothing() {
        XCTAssertEqual(translator.keys(forDrag: CGPoint(x: 1, y: -1)), [])
        XCTAssertEqual(translator.keys(forDrag: .zero), [])
    }

    // MARK: Zoom. A pinch ratio is this event's finger distance over the
    // previous event's: spreading (> 1) zooms in, closing (< 1) zooms out.

    func testSpreadingPinchHoldsZoomIn() {
        XCTAssertEqual(translator.keys(forPinchRatio: 1.10), .zoomIn)
    }

    func testClosingPinchHoldsZoomOut() {
        XCTAssertEqual(translator.keys(forPinchRatio: 0.90), .zoomOut)
    }

    func testSteadyPinchHoldsNothing() {
        XCTAssertEqual(translator.keys(forPinchRatio: 1.0), [])
        XCTAssertEqual(translator.keys(forPinchRatio: 1.005), [])
        XCTAssertEqual(translator.keys(forPinchRatio: 0.995), [])
    }

    // MARK: Engine keys. The codes `AM_Responder`'s default bindings read
    // (m_input.c: arrows for pan, '=' / '-' for zoom), pinned as literals.

    func testKeysMapToTheAutomapBindings() {
        XCTAssertEqual(AutomapKeys.panLeft.engineKeyCodes, [0xac])   // KEY_LEFTARROW
        XCTAssertEqual(AutomapKeys.panRight.engineKeyCodes, [0xae])  // KEY_RIGHTARROW
        XCTAssertEqual(AutomapKeys.panUp.engineKeyCodes, [0xad])     // KEY_UPARROW
        XCTAssertEqual(AutomapKeys.panDown.engineKeyCodes, [0xaf])   // KEY_DOWNARROW
        XCTAssertEqual(AutomapKeys.zoomIn.engineKeyCodes, [0x3d])    // '='
        XCTAssertEqual(AutomapKeys.zoomOut.engineKeyCodes, [0x2d])   // '-'
        XCTAssertEqual(Set(AutomapKeys([.panLeft, .zoomIn]).engineKeyCodes), [0xac, 0x3d])
    }

    // MARK: Bounded work: one byte of answer, no per-event state.

    func testAnswerIsOneByteAndTheTranslatorHoldsNoState() {
        XCTAssertEqual(MemoryLayout<AutomapKeys>.size, 1)
        XCTAssertEqual(MemoryLayout<AutomapGestureTranslator>.size, 0,
                       "the translator must carry no per-event state to reuse or rebuild")
        // The same event answers the same way however many came before it.
        for _ in 0..<1000 {
            XCTAssertEqual(translator.keys(forDrag: CGPoint(x: 12, y: 0)), .panLeft)
        }
    }
}
