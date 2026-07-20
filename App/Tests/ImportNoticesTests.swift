import XCTest
@testable import WADdle

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

    // MARK: merge

    func testMergeAppendsImportedAndDuplicates() {
        var aggregate = ImportOutcome()
        aggregate.imported = ["Sunlust"]
        var candidate = ImportOutcome()
        candidate.imported = ["Scythe"]
        candidate.duplicates = ["Eviternity II"]

        aggregate.merge(candidate)

        XCTAssertEqual(aggregate.imported, ["Sunlust", "Scythe"])
        XCTAssertEqual(aggregate.duplicates, ["Eviternity II"])
    }

    // Two independent candidates (e.g. two different zips) can each reject
    // an entry under the identical basename. LibraryView.summary(of:) lists
    // every rejected key/value to the user, so silently overwriting on
    // collision would hide one of them; merge uniquifies instead (same
    // suffixing convention as ImportService.moveToImportFailed uses for
    // on-disk name clashes) so both survive and the "N failed" count stays
    // accurate.
    func testMergeUniquifiesCollidingRejectedKeys() {
        var aggregate = ImportOutcome()
        aggregate.rejected = ["big.wad": "Entry exceeds the 5 MB import limit."]
        var candidate = ImportOutcome()
        candidate.rejected = ["big.wad": "Entry exceeds the 5 MB import limit."]

        aggregate.merge(candidate)

        XCTAssertEqual(aggregate.rejected.count, 2)
        XCTAssertEqual(aggregate.rejected["big.wad"], "Entry exceeds the 5 MB import limit.")
        XCTAssertEqual(aggregate.rejected["big (2).wad"], "Entry exceeds the 5 MB import limit.")
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
