import SwiftUI
import UniformTypeIdentifiers

/// The drop entrance (#481): files dragged onto the shelf, from Finder onto a
/// Mac window or from Files in an iPad's Split View. Dragging a file onto the
/// window is the first thing a player tries on a Mac.
///
/// A drop takes the same road as the picker: `ImportService.importFiles`,
/// which imports, counts and announces, so a dropped file ends in the same
/// banner as a picked one, and a file of a type the library does not take is
/// refused with the same notice. Only the route differs, and like the
/// picker's it leaves a rejected file where it was.
enum WADDrop {
    /// What the shelf takes a drag of, and so what lights it up: a file, by
    /// its URL, or the content of one of the types the picker offers.
    ///
    /// Not `.data`. Files and Finder offer a dragged file as its own content
    /// type plus `public.file-url`. `.wad`, `.deh`/`.bex` and `.zip` have
    /// declared types that conform to `public.data` (`App/project.yml`'s
    /// `UTImportedTypeDeclarations`), but a type the app does not declare --
    /// a `.pk3`, say -- is a dynamic type that does not, and nor is a
    /// folder: those match `.data` only through `public.file-url`, whose
    /// "data" is a property list of the URL. Taking `.data` staged that
    /// property list as though it were the file (review of pull request 545),
    /// and also lit the shelf up for a text snippet or a web link.
    /// `DroppedFile` reads the content type, never the URL's bytes, and a
    /// drop with no content it can read is refused by name.
    static var acceptedTypes: [UTType] { [.fileURL] + WADImport.contentTypes }

    /// Where a dropped file is copied while it is imported. The system
    /// removes its own copy as soon as the drop hands it over, before the
    /// import has run.
    static var stagingRoot: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("Dropped Files", isDirectory: true)
    }

    /// A new, empty folder of its own under `stagingRoot`, so that two
    /// dropped files that share a name do not collide.
    static func newStagingFolder() throws -> URL {
        let folder = stagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Copies `file` into a staging folder of its own as `name` (default: its
    /// own name).
    static func stage(_ file: URL, as name: String? = nil) throws -> URL {
        let copy = try newStagingFolder().appendingPathComponent(name ?? file.lastPathComponent)
        try FileManager.default.copyItem(at: file, to: copy)
        return copy
    }

    /// The drop handler: imports `requests` through the one entry point on
    /// the `.drop` route, then removes the staging folder of every request
    /// under `stagingRoot`. A URL outside it is the caller's and is left
    /// alone.
    @MainActor
    @discardableResult
    static func importDropped(_ requests: [ImportRequest], into importer: ImportService) async -> ImportOutcome {
        let outcome = await importer.importFiles(requests, from: .drop)
        let root = stagingRoot.standardizedFileURL.path + "/"
        for request in requests where request.url.standardizedFileURL.path.hasPrefix(root) {
            try? FileManager.default.removeItem(at: request.url.deletingLastPathComponent())
        }
        return outcome
    }

    /// `importDropped(_:into:)` for files that carry their own names.
    @MainActor
    @discardableResult
    static func importDropped(_ urls: [URL], into importer: ImportService) async -> ImportOutcome {
        await importDropped(urls.map { ImportRequest(url: $0) }, into: importer)
    }
}

/// One dropped item, read out of its `NSItemProvider` into an
/// `ImportRequest` for `WADDrop.importDropped`.
///
/// The name matters as much as the bytes: the import goes by it first, and it
/// becomes the game's title. The copy a provider hands over is not reliably
/// named after the file -- with no `suggestedName` it is named after the
/// type, "Doom WAD.wad" or "Zip archive.zip" (review of pull request 545) --
/// so the name is taken, in order, from the file's own URL
/// (`public.file-url`, which Files and Finder offer), from the provider's
/// `suggestedName`, and only then from the copy. It gets its type's extension
/// if it has none, and goes through `ImportFilename.sanitized`.
enum DroppedFile {
    /// The name for a dropped file, as described above.
    static func filename(fileURL: URL?, suggestedName: String?, handedOver: URL?, type: UTType?) -> String {
        let candidates = [fileURL?.lastPathComponent, suggestedName, handedOver?.lastPathComponent]
        var name = candidates.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? "Dropped item"
        if (name as NSString).pathExtension.isEmpty, let ext = type?.preferredFilenameExtension {
            name += "." + ext
        }
        return ImportFilename.sanitized(name, fallback: "Dropped item")
    }

    /// The content type to read `provider` as: the first it offers that is
    /// file content (conforms to `public.data`) and not a URL. Nil for a
    /// folder, a type the app does not declare, or a link.
    static func contentType(of provider: NSItemProvider) -> UTType? {
        provider.registeredContentTypes.first { $0.conforms(to: .data) && !$0.conforms(to: .url) }
    }

    /// Reads `provider` into a request. Its content is copied into a staging
    /// folder under the name `filename` settles. A provider with no content
    /// to read (a folder, a `.pk3`) or whose content fails to load yields a
    /// request for a file that does not exist, under that same name, which
    /// `ImportService` refuses as it refuses that name on any route: a
    /// `.pk3` with `ImportFileType.refusedReason`, anything else as an
    /// unsupported type. Nothing of the item is read or staged.
    @MainActor
    static func request(for provider: NSItemProvider) async -> ImportRequest {
        let fileURL = await self.fileURL(of: provider)
        let suggestedName = provider.suggestedName
        guard let type = contentType(of: provider),
              let staged = await stageContent(of: provider, as: type,
                                              fileURL: fileURL, suggestedName: suggestedName) else {
            let name = filename(fileURL: fileURL, suggestedName: suggestedName, handedOver: nil, type: nil)
            let placeholder = (try? WADDrop.newStagingFolder())
                ?? WADDrop.stagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
            return ImportRequest(url: placeholder.appendingPathComponent(name))
        }
        return ImportRequest(url: staged)
    }

    /// The file's own URL, when the provider offers `public.file-url`. Only
    /// its name is used; the file is never read through it.
    @MainActor
    private static func fileURL(of provider: NSItemProvider) async -> URL? {
        guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else { return nil }
        // `loadObject(ofClass: NSURL.self)`, not `loadItem`: the item behind
        // `public.file-url` is the URL archived as a property list, which
        // NSURL's own reader decodes.
        return await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: NSURL.self) { object, _ in
                let url = (object as? NSURL) as URL?
                continuation.resume(returning: url?.isFileURL == true ? url : nil)
            }
        }
    }

    /// Copies the provider's `type` content into a staging folder, inside the
    /// load's completion: the system deletes what it handed over as soon as
    /// that returns.
    @MainActor
    private static func stageContent(of provider: NSItemProvider, as type: UTType,
                                     fileURL: URL?, suggestedName: String?) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(for: type, openInPlace: false) { handedOver, _, _ in
                guard let handedOver else { continuation.resume(returning: nil); return }
                let name = filename(fileURL: fileURL, suggestedName: suggestedName,
                                    handedOver: handedOver, type: type)
                continuation.resume(returning: try? WADDrop.stage(handedOver, as: name))
            }
        }
    }
}

extension View {
    /// Accepts files dropped on this view and hands them to `WADDrop`, which
    /// imports them and posts the notice; the outcome then goes to
    /// `onOutcome`, as `wadFileImporter`'s does. `isTargeted` is true while a
    /// drag is over the view, for its highlight.
    func wadDropDestination(importer: ImportService,
                            isTargeted: Binding<Bool>,
                            onOutcome: @escaping (ImportOutcome) -> Void) -> some View {
        onDrop(of: WADDrop.acceptedTypes, isTargeted: isTargeted) { providers in
            guard !providers.isEmpty else { return false }
            Task { @MainActor in
                var requests: [ImportRequest] = []
                for provider in providers {
                    requests.append(await DroppedFile.request(for: provider))
                }
                onOutcome(await WADDrop.importDropped(requests, into: importer))
            }
            return true
        }
    }
}

/// What the shelf shows while a drag is over it: the page dimmed, its edge
/// outlined in the accent, and a card in the middle saying what letting go
/// will do. It takes no touches, so the drop lands on the shelf beneath.
struct ShelfDropHighlight: View {
    var body: some View {
        ZStack {
            Color.appBackground.opacity(0.72)
            RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                .strokeBorder(Color.appAccent,
                              style: StrokeStyle(lineWidth: 3, dash: [12, 8]))
                .padding(Theme.Spacing.sm)
            VStack(spacing: Theme.Spacing.sm) {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(Color.appAccent)
                Text("Drop to Add")
                    .font(Theme.Typography.heroTitle)
                Text(".wad, .deh, .bex and .zip files")
                    .font(Theme.Typography.secondary)
                    .foregroundStyle(Color.appSecondaryText)
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, Theme.Spacing.section)
            .padding(.vertical, Theme.Spacing.grid)
            .background(Color.appSurface,
                        in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .strokeBorder(Color.appHairline, lineWidth: Theme.tileHairlineWidth)
            )
            .padding(Theme.Spacing.section)
            .accessibilityElement(children: .combine)
        }
        .allowsHitTesting(false)
        .accessibilityIdentifier("shelfDropHighlight")
    }
}

#Preview("Shelf drop highlight") {
    ShelfDropHighlight()
        .preferredColorScheme(.dark)
}
