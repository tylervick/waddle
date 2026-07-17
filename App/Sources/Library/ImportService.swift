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
            importOne(url: url, into: &outcome)
            // Adopted or rejected either way, remove the loose original so
            // the scan doesn't re-report it forever (imports are copies).
            try? FileManager.default.removeItem(at: url)
        }
        return outcome
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
            storeAndRegister(url: url, name: name, kind: "DEH",
                             family: GameFamily.unknown.rawValue, into: &outcome)
        case "wad":
            do {
                guard let data = try? Data(contentsOf: url) else {
                    outcome.rejected[name] = "File could not be read."
                    return
                }
                let parsed = try WADParser.parse(data)
                storeAndRegister(url: url, name: name, kind: parsed.kind.rawValue,
                                 family: WADParser.gameFamily(of: parsed.lumpNames).rawValue,
                                 into: &outcome)
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

    private func storeAndRegister(url: URL, name: String, kind: String,
                                  family: String, into outcome: inout ImportOutcome) {
        do {
            let stored = try store.store(fileAt: url, preferredName: name)
            if stored.isDuplicate || (try? library.findWAD(sha1: stored.sha1)) != nil {
                if (try? library.findWAD(sha1: stored.sha1)) == nil {
                    // File existed on disk but not in the DB (e.g. prior
                    // failed import) — register it now instead of dropping it.
                    try library.registerImported(filename: stored.filename,
                                                 sha1: stored.sha1, kind: kind, family: family)
                    outcome.imported.append((stored.filename as NSString).deletingPathExtension)
                } else {
                    outcome.duplicates.append((name as NSString).deletingPathExtension)
                }
                return
            }
            try library.registerImported(filename: stored.filename, sha1: stored.sha1,
                                         kind: kind, family: family)
            outcome.imported.append((stored.filename as NSString).deletingPathExtension)
        } catch {
            outcome.rejected[name] = "Could not copy file into the library."
        }
    }
}
