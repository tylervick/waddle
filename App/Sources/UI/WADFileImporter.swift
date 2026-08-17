import SwiftUI
import UniformTypeIdentifiers

/// The file-import entrance, in one place because the shell now has two of
/// them: Manage's Import button and the welcome card's **Add Your Games**
/// (spec §4, which asks for "exactly today's machinery"). Shared rather than
/// copied so the two cannot drift apart on which files they accept or on what
/// happens once the picker closes -- a welcome card that quietly refused `.deh`
/// patches would be a first-launch bug nobody would think to look for.
enum WADImport {
    /// What the picker offers. `.zip` is first-class: a mod downloaded on a
    /// phone almost always arrives zipped, and `ImportService` unpacks it.
    ///
    /// The three extension-derived types are built rather than hard-coded
    /// because `.wad`, `.deh` and `.bex` have no system-declared UTI; each is
    /// dropped when the system cannot make one rather than substituting
    /// something broader.
    static var contentTypes: [UTType] {
        var types: [UTType] = [.zip]
        for ext in ["wad", "deh", "bex"] {
            if let type = UTType(filenameExtension: ext) { types.append(type) }
        }
        return types
    }
}

extension View {
    /// Presents the standard multi-select importer and runs the outcome
    /// through the shared notice banner, handing it on to `onOutcome` for
    /// whatever else the presenting screen owes (a refresh, its own summary).
    ///
    /// A cancelled or failed pick is deliberately silent: the user closing the
    /// picker is not an event either screen has anything to say about.
    func wadFileImporter(isPresented: Binding<Bool>,
                         importer: ImportService,
                         onOutcome: @escaping (ImportOutcome) -> Void) -> some View {
        fileImporter(isPresented: isPresented,
                     allowedContentTypes: WADImport.contentTypes,
                     allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            let outcome = importer.importFiles(at: urls)
            ImportNotices.shared.post(outcome: outcome)
            onOutcome(outcome)
        }
    }
}
