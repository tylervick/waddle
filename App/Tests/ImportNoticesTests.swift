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

    // MARK: rejections that say why (#516)

    /// A zip refused by an import limit says why, as a failed link download
    /// does, and any other rejection is counted after it.
    func testAnExplainedRejectionSaysWhyAndIsNotCountedAgain() {
        var outcome = ImportOutcome()
        outcome.imported = ["Sunlust"]
        outcome.rejected = ["junk.wad": "Not a WAD file (bad header magic)."]
        outcome.reject("big.zip", reason: "This zip unpacks to more than 1 GB, the import limit.", explained: true)
        XCTAssertEqual(ImportNotices.summary(of: outcome),
            "Imported Sunlust · "
            + "Import failed for big.zip: This zip unpacks to more than 1 GB, the import limit. · 1 more failed")
    }

    func testAnExplainedRejectionDuringAdoptionSaysWhereTheFileWent() {
        var outcome = ImportOutcome()
        outcome.reject("big.zip", reason: "This zip unpacks to more than 1 GB, the import limit.", explained: true)
        XCTAssertEqual(ImportNotices.summary(of: outcome, quarantines: true),
            "Import failed for big.zip: This zip unpacks to more than 1 GB, the import limit. "
            + "Moved to Import Failed.")
    }

    func testMergeKeepsExplainedRejections() {
        var aggregate = ImportOutcome()
        aggregate.reject("a.zip", reason: "x", explained: true)
        var candidate = ImportOutcome()
        candidate.reject("b.zip", reason: "y", explained: true)
        aggregate.merge(candidate)
        XCTAssertEqual(aggregate.explained, ["Import failed for a.zip: x", "Import failed for b.zip: y"])
        XCTAssertEqual(ImportNotices.summary(of: aggregate), "Import failed for a.zip: x · 1 more failed")
    }

    /// One line per refused file would let a folder of refused zips cover
    /// the screen (the #521 review dropped 20 into Documents): the banner
    /// says why for the first and counts the rest, however many there are.
    func testOnlyTheFirstExplainedRejectionIsShown() {
        var outcome = ImportOutcome()
        for index in 0..<20 {
            outcome.reject("big\(index).zip", reason: "This zip unpacks to more than 1 GB, the import limit.",
                           explained: true)
        }
        outcome.rejected["junk.wad"] = "Not a WAD file (bad header magic)."
        XCTAssertEqual(ImportNotices.summary(of: outcome, quarantines: true),
            "Import failed for big0.zip: This zip unpacks to more than 1 GB, the import limit. "
            + "Moved to Import Failed. · 20 more failed (moved to Import Failed)")
        XCTAssertEqual(ImportNotices.summary(of: outcome),
            "Import failed for big0.zip: This zip unpacks to more than 1 GB, the import limit. · 20 more failed")
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
