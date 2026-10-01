import CoreGraphics
import XCTest
@testable import Waddle

/// Persistence of the user's button positions (issue #115): per-control
/// offsets from the default frame, in reference points, kept in UserDefaults
/// and read once at overlay-install time like the rest of the touch
/// settings. Each test gets its own defaults suite so nothing leaks into the
/// simulator's real defaults or between tests.
final class TouchOverlayLayoutOverridesTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() {
        super.setUp()
        suite = "TouchOverlayLayoutOverridesTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    /// The round trip: a moved button's offset survives a save and a fresh
    /// read, which is what an overlay reinstall (next session) does.
    func testSavedOffsetsReadBackEqual() {
        var overrides = TouchOverlayLayoutOverrides.none
        overrides[.fire] = CGPoint(x: -120.5, y: -80)
        overrides[.menu] = CGPoint(x: 30, y: 12.25)
        overrides.save(to: defaults)

        let read = TouchOverlayLayoutOverrides.current(defaults: defaults)
        XCTAssertEqual(read, overrides)
        XCTAssertEqual(read[.fire], CGPoint(x: -120.5, y: -80))
        XCTAssertEqual(read[.menu], CGPoint(x: 30, y: 12.25))
        XCTAssertNil(read[.use], "an unmoved control must read back as unmoved, not as zero")
    }

    func testNothingSavedReadsAsNoOverrides() {
        let read = TouchOverlayLayoutOverrides.current(defaults: defaults)
        XCTAssertEqual(read, .none)
        XCTAssertTrue(read.isEmpty)
    }

    /// Reset restores the defaults: after it, the next session lays out
    /// exactly as if nothing had ever been moved.
    func testResetClearsEverything() {
        var overrides = TouchOverlayLayoutOverrides.none
        overrides[.fire] = CGPoint(x: -50, y: -50)
        overrides.save(to: defaults)
        XCTAssertFalse(TouchOverlayLayoutOverrides.current(defaults: defaults).isEmpty)

        TouchOverlayLayoutOverrides.reset(in: defaults)
        XCTAssertTrue(TouchOverlayLayoutOverrides.current(defaults: defaults).isEmpty)
        XCTAssertNil(defaults.object(forKey: TouchOverlayLayoutOverrides.userDefaultsKey),
                     "reset removes the key rather than storing an empty table")
    }

    /// Saving an empty table is the same as reset: no key left behind to
    /// decode on every launch.
    func testSavingEmptyRemovesTheKey() {
        var overrides = TouchOverlayLayoutOverrides.none
        overrides[.use] = CGPoint(x: 1, y: 1)
        overrides.save(to: defaults)
        TouchOverlayLayoutOverrides.none.save(to: defaults)
        XCTAssertNil(defaults.object(forKey: TouchOverlayLayoutOverrides.userDefaultsKey))
    }

    /// Garbage under the key (a future format, a corrupted write) must not
    /// take the overlay down with it: it reads as no overrides, the same
    /// tolerant posture `TouchTuning.current` takes toward non-numeric values.
    func testGarbageReadsAsNoOverrides() {
        defaults.set("not json".data(using: .utf8), forKey: TouchOverlayLayoutOverrides.userDefaultsKey)
        XCTAssertEqual(TouchOverlayLayoutOverrides.current(defaults: defaults), .none)
        defaults.set(12345, forKey: TouchOverlayLayoutOverrides.userDefaultsKey)
        XCTAssertEqual(TouchOverlayLayoutOverrides.current(defaults: defaults), .none)
    }

    /// A control this build does not know (removed, renamed, or from a newer
    /// build) is dropped; a pair that is not two numbers is dropped; the ones
    /// it knows are kept.
    func testUnknownControlsAndMalformedPairsAreDropped() throws {
        let json = """
        {"fireButton":[-10,-20],"laserButton":[5,5],"useButton":[1,"x"],"menuButton":[3]}
        """
        defaults.set(Data(json.utf8), forKey: TouchOverlayLayoutOverrides.userDefaultsKey)
        let read = TouchOverlayLayoutOverrides.current(defaults: defaults)
        XCTAssertEqual(read[.fire], CGPoint(x: -10, y: -20))
        XCTAssertNil(read[.use], "a non-numeric coordinate must be dropped, not zeroed")
        XCTAssertNil(read[.menu], "a malformed pair must be dropped")
        XCTAssertEqual(read.offsets.count, 1)
    }

    /// A non-finite offset would put a button nowhere; it is refused at the
    /// setter, so nothing downstream has to defend against it.
    func testNonFiniteOffsetsAreRefused() {
        var overrides = TouchOverlayLayoutOverrides.none
        overrides[.use] = CGPoint(x: CGFloat.nan, y: 0)
        XCTAssertNil(overrides[.use])
        overrides[.use] = CGPoint(x: 0, y: CGFloat.infinity)
        XCTAssertNil(overrides[.use])
        XCTAssertTrue(overrides.isEmpty)
    }

    /// The stored shape is plain JSON keyed by the controls' accessibility
    /// identifiers, so a future reader (or a human with `defaults read`) can
    /// make sense of it without this type.
    func testStoredShapeIsJSONKeyedByControlIdentifier() throws {
        var overrides = TouchOverlayLayoutOverrides.none
        overrides[.weaponNext] = CGPoint(x: 7, y: -3)
        overrides.save(to: defaults)
        let data = try XCTUnwrap(defaults.data(forKey: TouchOverlayLayoutOverrides.userDefaultsKey))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: [Double]])
        XCTAssertEqual(object, ["weaponNextButton": [7, -3]])
    }
}
