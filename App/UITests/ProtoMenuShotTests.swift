import XCTest

// THROWAWAY PROTOTYPE (branch tylervick/proto-browser-mockups, never merged):
// opens a menu in a WADDLE_PROTO scene and writes a screenshot to the host.
// Skips unless TEST_RUNNER_PROTO_SCENE is set.
final class ProtoMenuShotTests: XCTestCase {
    func testMenuShot() throws {
        let env = ProcessInfo.processInfo.environment
        guard let scene = env["PROTO_SCENE"], let out = env["PROTO_OUT"] else {
            throw XCTSkip("prototype capture only")
        }
        let app = XCUIApplication()
        app.launchEnvironment["WADDLE_PROTO"] = scene
        app.launch()
        sleep(UInt32(env["PROTO_WAIT"].flatMap { UInt32($0) } ?? 6))
        if let tap = env["PROTO_TAP"] {
            let button = app.buttons[tap].firstMatch
            XCTAssertTrue(button.waitForExistence(timeout: 10))
            button.tap()
            sleep(2)
        }
        if let tap2 = env["PROTO_TAP2"] {
            let item = app.buttons[tap2].firstMatch
            if item.waitForExistence(timeout: 5) { item.tap(); sleep(2) }
        }
        let png = XCUIScreen.main.screenshot().pngRepresentation
        try png.write(to: URL(fileURLWithPath: out))
    }
}
