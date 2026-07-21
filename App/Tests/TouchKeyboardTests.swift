import UIKit
import XCTest
@testable import WADdle

@MainActor
final class TouchKeyboardTests: XCTestCase {
    final class SpyInjector: TextInjecting {
        var characters: [UnicodeScalar] = []
        var backspaces = 0
        var confirms = 0
        func injectCharacter(_ scalar: UnicodeScalar) { characters.append(scalar) }
        func injectBackspace() { backspaces += 1 }
        func injectMenuConfirm() { confirms += 1 }
    }

    func testTypingInjectsEachCharacterInOrder() {
        let spy = SpyInjector()
        let kb = TouchKeyboard(injector: spy)
        for ch in "iddqd" {
            _ = kb.textField(kb.field,
                             shouldChangeCharactersIn: NSRange(location: 1, length: 0),
                             replacementString: String(ch))
        }
        XCTAssertEqual(String(String.UnicodeScalarView(spy.characters)), "iddqd")
    }

    func testEmptyReplacementInjectsBackspace() {
        let spy = SpyInjector()
        let kb = TouchKeyboard(injector: spy)
        _ = kb.textField(kb.field,
                         shouldChangeCharactersIn: NSRange(location: 0, length: 1),
                         replacementString: "")
        XCTAssertEqual(spy.backspaces, 1)
    }

    func testDelegateNeverAccumulates() {
        let spy = SpyInjector()
        let kb = TouchKeyboard(injector: spy)
        let result = kb.textField(kb.field,
                                  shouldChangeCharactersIn: NSRange(location: 1, length: 0),
                                  replacementString: "z")
        XCTAssertFalse(result)
    }

    func testReturnInvokesOnReturn() {
        let spy = SpyInjector()
        let kb = TouchKeyboard(injector: spy)
        var called = false
        kb.onReturn = { called = true }
        _ = kb.textFieldShouldReturn(kb.field)
        XCTAssertTrue(called)
    }
}
