import XCTest

/// What the shipped Info.plist declares about the app itself. `Bundle.main`
/// inside a hosted unit-test bundle is the host app, not the test bundle, so
/// these read the plist XcodeGen generated from `App/project.yml`'s
/// `info.properties` block -- the same idiom as
/// `LiveDeviceOverlayLayoutTests.testHostAppIsBuiltForIPadAndIPhone`.
final class BundleInfoTests: XCTestCase {
    /// The bundle told the system nothing about what kind of app this is
    /// (issue #245): a game with a virtual gamepad, indirect input events and
    /// Bluetooth controllers, and no `LSApplicationCategoryType`. The value
    /// matches the App Store listing (`docs/app-store/metadata.md` §7: Games,
    /// Action), and it is spelled out here so the plist and the test cannot
    /// drift apart. `XCTUnwrap`, not a bare equality: `object(forInfoDictionaryKey:)`
    /// returns nil for a missing key rather than throwing, and an assertion
    /// written carelessly sails past exactly the defect this pins.
    func testHostAppDeclaresItsCategoryAsAnActionGame() throws {
        let category = try XCTUnwrap(
            Bundle.main.object(forInfoDictionaryKey: "LSApplicationCategoryType") as? String,
            "the host app declares no LSApplicationCategoryType at all")
        XCTAssertEqual(category, "public.app-category.action-games")
    }
}
