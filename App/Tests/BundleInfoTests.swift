import XCTest
@testable import Waddle

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

    /// The share extension (#551), as embedded in the built app.
    private func shareExtensionInfo() throws -> [String: Any] {
        let plugIns = try XCTUnwrap(Bundle.main.builtInPlugInsURL, "the host app has no PlugIns folder")
        let appex = plugIns.appendingPathComponent("WaddleShare.appex")
        let bundle = try XCTUnwrap(Bundle(url: appex), "WaddleShare.appex is not embedded in the app")
        return try XCTUnwrap(bundle.infoDictionary)
    }

    /// Waddle is offered for a web link and for nothing else (#551). A file
    /// shared from Files already goes through Open in Waddle, by the
    /// document types; an activation rule that also took files, or a
    /// TRUEPREDICATE, would list Waddle twice in that share sheet. The rule
    /// is compared whole, so any key added to it fails here.
    func testTheShareExtensionIsOfferedForOneWebLinkAndNothingElse() throws {
        let info = try shareExtensionInfo()
        let ext = try XCTUnwrap(info["NSExtension"] as? [String: Any])
        XCTAssertEqual(ext["NSExtensionPointIdentifier"] as? String, "com.apple.share-services")
        let attributes = try XCTUnwrap(ext["NSExtensionAttributes"] as? [String: Any])
        let rule = try XCTUnwrap(attributes["NSExtensionActivationRule"] as? [String: Any],
                                 "the activation rule is not a dictionary of keys")
        XCTAssertEqual(rule as NSDictionary, ["NSExtensionActivationSupportsWebURLWithMaxCount": 1] as NSDictionary)
        XCTAssertEqual(info["CFBundleDisplayName"] as? String, "Waddle")
    }

    /// The extension leaves a link where the app looks for it only if both
    /// name the same App Group, and App Store validation refuses an embedded
    /// extension whose version differs from its app's.
    func testTheShareExtensionSharesTheAppsGroupAndVersion() throws {
        let info = try shareExtensionInfo()
        let key = PendingLinkInbox.appGroupInfoKey
        let group = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: key) as? String)
        XCTAssertTrue(group.hasPrefix("group."), group)
        XCTAssertEqual(info[key] as? String, group)
        for versionKey in ["CFBundleShortVersionString", "CFBundleVersion"] {
            XCTAssertEqual(info[versionKey] as? String,
                           Bundle.main.object(forInfoDictionaryKey: versionKey) as? String, versionKey)
        }
    }
}
