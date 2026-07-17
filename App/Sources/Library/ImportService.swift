import Foundation

struct ImportOutcome: Equatable {
    var imported: [String] = []
    var duplicates: [String] = []
    var rejected: [String: String] = [:]
}

@MainActor
final class ImportService {
    private let library: LibraryService
    private let store: WADStore

    init(library: LibraryService, store: WADStore) {
        self.library = library
        self.store = store
    }

    /// Imports picker/Files-app URLs: .wad validated+classified, .deh/.bex
    /// taken by extension, .zip recursed into. Security-scoped access is
    /// handled here so callers can pass fileImporter URLs directly.
    func importFiles(at urls: [URL]) -> ImportOutcome {
        var outcome = ImportOutcome()
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            importOne(url: url, into: &outcome)
        }
        return outcome
    }

    /// Adopts files users dropped into Documents via the Files app
    /// (UIFileSharingEnabled exposes it). Call on launch/foreground.
    func adoptLooseFiles() -> ImportOutcome {
        var outcome = ImportOutcome()
        let docs = URL.documentsDirectory
        let candidates = ((try? FileManager.default.contentsOfDirectory(
            at: docs, includingPropertiesForKeys: [.isRegularFileKey])) ?? [])
            .filter { ["wad", "deh", "bex", "zip"].contains($0.pathExtension.lowercased()) }
        for url in candidates {
            let name = url.lastPathComponent
            importOne(url: url, into: &outcome)
            if outcome.rejected[name] != nil {
                // Don't destroy files the user can't explain a failure for;
                // move them somewhere visible/recoverable in the Files app
                // instead, so the scan doesn't re-report them forever.
                moveToImportFailed(url)
            } else {
                // Imported or duplicate either way, the content now lives in
                // the store (or already did); the loose original is redundant.
                try? FileManager.default.removeItem(at: url)
            }
        }
        return outcome
    }

    /// Moves a loose file that failed import into Documents/Import Failed/,
    /// uniquifying on name collision the same way WADStore does.
    private func moveToImportFailed(_ url: URL) {
        let failedDir = URL.documentsDirectory.appendingPathComponent("Import Failed", isDirectory: true)
        try? FileManager.default.createDirectory(at: failedDir, withIntermediateDirectories: true)

        let name = url.lastPathComponent
        var candidate = name
        var counter = 2
        while FileManager.default.fileExists(atPath: failedDir.appendingPathComponent(candidate).path) {
            let base = (name as NSString).deletingPathExtension
            let ext = (name as NSString).pathExtension
            candidate = ext.isEmpty ? "\(base) (\(counter))" : "\(base) (\(counter)).\(ext)"
            counter += 1
        }
        try? FileManager.default.moveItem(at: url, to: failedDir.appendingPathComponent(candidate))
    }

    private func importOne(url: URL, into outcome: inout ImportOutcome) {
        let name = url.lastPathComponent
        switch url.pathExtension.lowercased() {
        case "zip":
            do {
                let extraction = try ZipExtractor.extractGameFiles(from: url)
                defer { try? FileManager.default.removeItem(at: extraction.dir) }
                if extraction.files.isEmpty {
                    outcome.rejected[name] = "No WAD or DEH files inside the zip."
                    return
                }
                for file in extraction.files {
                    importOne(url: file.url, into: &outcome)
                }
            } catch {
                outcome.rejected[name] = "Could not read zip archive."
            }
        case "deh", "bex":
            guard let data = try? Data(contentsOf: url) else {
                outcome.rejected[name] = "File could not be read."
                return
            }
            storeAndRegister(url: url, name: name, kind: "DEH",
                             family: GameFamily.unknown.rawValue,
                             sha1: WADStore.sha1(of: data), into: &outcome)
        case "wad":
            do {
                guard let data = try? Data(contentsOf: url) else {
                    outcome.rejected[name] = "File could not be read."
                    return
                }
                let parsed = try WADParser.parse(data)
                storeAndRegister(url: url, name: name, kind: parsed.kind.rawValue,
                                 family: WADParser.gameFamily(of: parsed.lumpNames).rawValue,
                                 sha1: WADStore.sha1(of: data), into: &outcome)
            } catch WADParseError.badMagic {
                outcome.rejected[name] = "Not a WAD file (bad header magic)."
            } catch WADParseError.tooSmall {
                outcome.rejected[name] = "File is truncated (smaller than a WAD header)."
            } catch {
                outcome.rejected[name] = "WAD directory is corrupt."
            }
        default:
            outcome.rejected[name] = "Unsupported file type."
        }
    }

    private func storeAndRegister(url: URL, name: String, kind: String, family: String,
                                  sha1: String, into outcome: inout ImportOutcome) {
        // Check the library's sha1 index before touching the store: it's a
        // single lookup, versus WADStore.store's on-disk rescan (reads and
        // hashes every stored file) to do the same dedupe check.
        if let existing = try? library.findWAD(sha1: sha1) {
            if existing.isBundled ||
               FileManager.default.fileExists(atPath: library.fileURL(for: existing).path) {
                outcome.duplicates.append((name as NSString).deletingPathExtension)
                return
            }
            // The DB row is legit but its backing file vanished from disk
            // (deleted out-of-band) — restore it under a fresh store
            // filename and repoint the row, rather than reporting a
            // duplicate that doesn't actually exist anywhere.
            do {
                let stored = try store.store(fileAt: url, preferredName: name)
                try library.repairFilename(of: existing, to: stored.filename)
                outcome.imported.append((stored.filename as NSString).deletingPathExtension)
            } catch {
                outcome.rejected[name] = "Could not copy file into the library."
            }
            return
        }
        do {
            let stored = try store.store(fileAt: url, preferredName: name)
            try library.registerImported(filename: stored.filename, sha1: stored.sha1,
                                         kind: kind, family: family)
            outcome.imported.append((stored.filename as NSString).deletingPathExtension)
        } catch {
            outcome.rejected[name] = "Could not copy file into the library."
        }
    }
}
