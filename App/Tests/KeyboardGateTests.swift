import XCTest
@testable import WADdle

final class KeyboardGateTests: XCTestCase {
    func testTapPresentsOnlyInGameplay() {
        XCTAssertTrue(KeyboardGate.shouldPresentOnTap(context: .gameplay))
        XCTAssertFalse(KeyboardGate.shouldPresentOnTap(context: .none))
        XCTAssertFalse(KeyboardGate.shouldPresentOnTap(context: .saveName))
    }

    func testPollAutoPresentsForSaveName() {
        XCTAssertEqual(KeyboardGate.pollCommand(context: .saveName, isVisible: false), .present)
        XCTAssertEqual(KeyboardGate.pollCommand(context: .saveName, isVisible: true), .none)
    }

    func testPollAutoDismissesWhenLeavingTextContext() {
        XCTAssertEqual(KeyboardGate.pollCommand(context: .none, isVisible: true), .dismiss)
        XCTAssertEqual(KeyboardGate.pollCommand(context: .none, isVisible: false), .none)
    }

    func testPollLeavesGameplayKeyboardAlone() {
        XCTAssertEqual(KeyboardGate.pollCommand(context: .gameplay, isVisible: true), .none)
        XCTAssertEqual(KeyboardGate.pollCommand(context: .gameplay, isVisible: false), .none)
    }
}
