import XCTest
@testable import Waddle

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
    // an entry under the identical basename. Silently overwriting on
    // collision would drop one of them from `rejected`; merge uniquifies
    // instead (same suffixing convention as ImportService.moveToImportFailed
    // uses for on-disk name clashes) so both survive and the "N failed"
    // count ImportNotices.summary(of:quarantines:) reports stays accurate.
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

    func testGamesAddOnsAndUnpairedEachGetTheirSentence() {
        var outcome = ImportOutcome()
        outcome.imported = ["Sunlust", "smoothdoom", "weird"]
        outcome.games = ["Sunlust"]
        outcome.addOns = ["smoothdoom"]
        outcome.unpaired = ["weird"]
        XCTAssertEqual(ImportNotices.summary(of: outcome),
                       "Added Sunlust · Imported smoothdoom as an add-on. Attach it from any game's page. · No base game found for weird. Choose one on its page.")
    }

    func testPluralAddOnsAndUnpaired() {
        var outcome = ImportOutcome()
        outcome.imported = ["a", "b", "c", "d"]
        outcome.addOns = ["a", "b"]
        outcome.unpaired = ["c", "d"]
        XCTAssertEqual(ImportNotices.summary(of: outcome),
                       "Imported a, b as add-ons. Attach them from any game's page. · No base game found for c, d. Choose one on their pages.")
    }

    func testRestoredFileKeepsTheGenericImportedLine() {
        var outcome = ImportOutcome()
        outcome.imported = ["Sunlust", "restored"]
        outcome.games = ["Sunlust"]
        XCTAssertEqual(ImportNotices.summary(of: outcome), "Added Sunlust · Imported restored")
    }

    func testMergeAppendsTheNewCategories() {
        var a = ImportOutcome(); a.games = ["x"]; a.addOns = ["y"]
        var b = ImportOutcome(); b.unpaired = ["z"]; b.addOns = ["w"]
        a.merge(b)
        XCTAssertEqual(a.games, ["x"]); XCTAssertEqual(a.addOns, ["y", "w"]); XCTAssertEqual(a.unpaired, ["z"])
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
