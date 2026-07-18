import Foundation
import Observation

@MainActor
@Observable
final class ImportNotices {
    static let shared = ImportNotices()
    private(set) var current: String?
    private var dismissTask: Task<Void, Never>?

    func post(outcome: ImportOutcome) {
        guard let text = Self.summary(of: outcome) else { return }
        post(message: text)
    }

    /// One-off notices that aren't import outcomes (e.g. "Created loadout …"),
    /// sharing the same banner and auto-dismiss behavior.
    func post(message: String) {
        current = message
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            if !Task.isCancelled { self?.current = nil }
        }
    }

    func dismiss() {
        dismissTask?.cancel()
        current = nil
    }

    // nonisolated: pure function over the outcome value, so the class-level
    // @MainActor isolation would only get in the way of synchronous callers
    // (XCTest methods are nonisolated under Swift 6).
    nonisolated static func summary(of outcome: ImportOutcome) -> String? {
        var parts: [String] = []
        if !outcome.imported.isEmpty {
            parts.append("Imported \(outcome.imported.joined(separator: ", "))")
        }
        if !outcome.duplicates.isEmpty {
            parts.append("\(outcome.duplicates.count) already in library")
        }
        if !outcome.rejected.isEmpty {
            parts.append("\(outcome.rejected.count) failed (moved to Import Failed)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

extension Notification.Name {
    static let libraryDidChange = Notification.Name("libraryDidChange")
}
