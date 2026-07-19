import XCTest
@testable import BoomBox

final class ImportNoticesTests: XCTestCase {
    func testEmptyOutcomeYieldsNil() {
        XCTAssertNil(ImportNotices.summary(of: ImportOutcome()))
    }

    func testImportOnly() {
        var outcome = ImportOutcome()
        outcome.imported = ["Sunlust"]
        XCTAssertEqual(ImportNotices.summary(of: outcome), "Imported Sunlust")
    }

    func testMixedOutcomeDuringAdoptionMentionsQuarantine() {
        var outcome = ImportOutcome()
        outcome.imported = ["Sunlust", "Scythe"]
        outcome.duplicates = ["Eviternity II"]
        outcome.rejected = ["junk.wad": "Not a WAD file (bad header magic)."]
        XCTAssertEqual(ImportNotices.summary(of: outcome, quarantines: true),
            "Imported Sunlust, Scythe · 1 already in library · 1 failed (moved to Import Failed)")
    }

    func testRejectionOnlyDuringAdoptionMentionsQuarantine() {
        var outcome = ImportOutcome()
        outcome.rejected = ["a.wad": "x", "b.zip": "y"]
        XCTAssertEqual(ImportNotices.summary(of: outcome, quarantines: true),
            "2 failed (moved to Import Failed)")
    }

    // Picker (fileImporter) and onOpenURL paths don't move rejects into
    // Import Failed, so their banner must not claim they were quarantined
    // (quarantines defaults to false — only ImportService.adoptLooseFiles's
    // call site opts in).
    func testRejectionOnlyOutsideAdoptionIsPlain() {
        var outcome = ImportOutcome()
        outcome.rejected = ["a.wad": "x", "b.zip": "y"]
        XCTAssertEqual(ImportNotices.summary(of: outcome), "2 failed")
    }
}

@MainActor
final class ImportNoticesMessageTests: XCTestCase {
    func testPostMessageShowsBanner() {
        let notices = ImportNotices()
        notices.post(message: "Created loadout Sunlust — find it in Play")
        XCTAssertEqual(notices.current, "Created loadout Sunlust — find it in Play")
        notices.dismiss()
        XCTAssertNil(notices.current)
    }
}
