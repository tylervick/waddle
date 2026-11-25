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
    /// What the shelf accepts as dropped. Wider than the picker's
    /// `WADImport.contentTypes` on purpose: `.wad`, `.deh` and `.bex` have no
    /// declared type, so a drag may carry only a dynamic one, and a filter
    /// here would ignore such a file in silence. Anything that is a file is
    /// taken and `ImportService` decides, from its name and then its bytes,
    /// exactly as it does for the picker.
    static let contentTypes: [UTType] = [.data]

    /// Where a dropped file is copied while it is imported. The system
    /// removes its own copy as soon as the drop hands it over, before the
    /// import has run.
    static var stagingRoot: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("Dropped Files", isDirectory: true)
    }

    /// Copies a file the system handed over into a folder of its own under
    /// `stagingRoot`, keeping its name: the name is what the import goes by
    /// first, and two dropped files may share one.
    static func stage(_ file: URL) throws -> URL {
        let folder = stagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let copy = folder.appendingPathComponent(file.lastPathComponent)
        try FileManager.default.copyItem(at: file, to: copy)
        return copy
    }

    /// The drop handler: imports `urls` through the one entry point on the
    /// `.drop` route, then removes whatever copies `stage` made of them. A
    /// URL outside `stagingRoot` is the caller's and is left alone.
    @MainActor
    @discardableResult
    static func importDropped(_ urls: [URL], into importer: ImportService) async -> ImportOutcome {
        let outcome = await importer.importFiles(at: urls, from: .drop)
        let root = stagingRoot.standardizedFileURL.path + "/"
        for url in urls where url.standardizedFileURL.path.hasPrefix(root) {
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        return outcome
    }
}

/// One dropped file, copied out of the drag by `WADDrop.stage`.
struct DroppedFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .data) { received in
            DroppedFile(url: try WADDrop.stage(received.file))
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
        dropDestination(for: DroppedFile.self) { files, _ in
            guard !files.isEmpty else { return false }
            Task {
                let outcome = await WADDrop.importDropped(files.map(\.url), into: importer)
                onOutcome(outcome)
            }
            return true
        } isTargeted: { targeted in
            isTargeted.wrappedValue = targeted
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
