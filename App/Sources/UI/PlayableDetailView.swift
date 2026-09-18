import SwiftUI
import UIKit

/// The single Read/Update/Delete surface for any game -- a base game or a
/// modded one -- reached from the Play grid's "Details" context action. Same
/// layout for both; editability differs (see the design spec's "The detail
/// page" section). Follows the `NavigationStack { Form { ... } }` pattern
/// used by `LoadoutEditorView`.
struct PlayableDetailView: View {
    let game: Game
    let library: LibraryService
    let onPlay: (Game, LaunchMode) -> Void
    let onEdit: (Game) -> Void
    let onChanged: () -> Void

    @Environment(\.dismiss) private var dismiss

    /// Mirrors the item's `schemeOverrideRaw` for the Controls picker.
    /// Written back through `LibraryService.setSchemeOverride` on change --
    /// see the type-level doc comment on `PlayableItem.schemeOverrideRaw`.
    @State private var scheme: TouchControlScheme?
    @State private var saves: [LibraryService.SaveSlot] = []
    @State private var showCreatePresetFromBase = false

    /// Width the header's art is drawn at and the height visible without
    /// scrolling, both measured from the `Form` itself: the form's contents are
    /// as tall as they need to be, and it is the *viewport* the art has to fit
    /// inside alongside the controls below it (`PlayableDetailLayout`). Both
    /// start at zero, which that type reads as "not measured yet".
    @State private var artContentWidth: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0

    init(game: Game, library: LibraryService,
         onPlay: @escaping (Game, LaunchMode) -> Void,
         onEdit: @escaping (Game) -> Void,
         onChanged: @escaping () -> Void) {
        self.game = game
        self.library = library
        self.onPlay = onPlay
        self.onEdit = onEdit
        self.onChanged = onChanged
        _scheme = State(initialValue: game.schemeOverrideRaw.flatMap(TouchControlScheme.init(rawValue:)))
    }

    /// The saves-directory key for this item -- see `PlayableItem.savesKey`,
    /// which `PlayableLauncher` keys the launch off too.
    private var savesKey: UUID { game.id }

    /// Non-nil when this item has a save the engine can boot straight into, in
    /// which case the header offers Continue. Derived from `saves`, so it
    /// tracks a deletion in `savesSection` without a second directory read.
    private var continuableSlot: Int? {
        EngineSaveSlot.newestLoadGameArgument(in: saves)
    }

    var body: some View {
        NavigationStack {
            Form {
                headerSection
                contentsSection
                controlsSection
                savesSection
                footerSection
            }
            // Measured on the Form, so this is the viewport the art competes
            // with the controls for: its own frame, less the insets the
            // navigation bar and home indicator occupy, and less the row
            // insets the art is drawn inside. Rotation and window resizing
            // both re-fire it.
            .onGeometryChange(for: CGSize.self) { proxy in
                let insets = proxy.safeAreaInsets
                return CGSize(
                    width: proxy.size.width - insets.leading - insets.trailing
                        - PlayableDetailLayout.rowHorizontalInset * 2,
                    height: proxy.size.height - insets.top - insets.bottom
                )
            } action: { size in
                artContentWidth = size.width
                viewportHeight = size.height
            }
            .waddleScrollSurface()
            .navigationTitle(game.name)
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { saves = library.saveSlots(forKey: savesKey) }
            .sheet(isPresented: $showCreatePresetFromBase, onDismiss: onChanged) {
                if let baseID = game.baseID, let wad = try? library.wad(id: baseID) {
                    LoadoutEditorView(library: library, existing: nil, seedIWAD: wad)
                }
            }
        }
    }

    // MARK: Sections
    //
    // Split out of `body` -- a Form this size inline is enough for the Swift
    // type checker to give up entirely (see ShelfView.toolbarContent's own
    // note on the same limit).

    /// What the header draws below the art, from the fonts actually in force:
    /// `UIFont` already carries the reader's Dynamic Type setting, so at
    /// accessibility sizes this reserves the taller block those rows really
    /// occupy instead of a default-size constant that would let the art push
    /// the controls back off the bottom -- the same reason `ShelfView` measures
    /// its own hero caption rather than assuming it.
    private var captionHeight: CGFloat {
        PlayableDetailLayout.captionHeight(
            titleLineHeight: UIFont.preferredFont(forTextStyle: .title2).lineHeight,
            buttonLineHeight: UIFont.preferredFont(forTextStyle: .body).lineHeight,
            primaryButtonCount: continuableSlot != nil ? 2 : 1)
    }

    private var headerSection: some View {
        Section {
            // Capped against the viewport rather than left to an aspect ratio:
            // at full width the tile's 3:4 shape asked for 481 pt of a 708 pt
            // sheet, which pushed every control below it out of a lazy `Form`
            // entirely -- not just out of sight, but out of the accessibility
            // hierarchy. `PlayableDetailLayout` owns that arithmetic and is
            // where it is tested.
            TitleArtView(game: game, library: library,
                         aspectRatio: Theme.heroAspectRatio,
                         height: PlayableDetailLayout.artHeight(
                            contentWidth: artContentWidth,
                            viewportHeight: viewportHeight,
                            captionHeight: captionHeight))
            Text(game.name).font(.title2.bold())
            // With a resumable save, Continue takes the prominent slot and Play
            // becomes the explicit "New Game" half of the pair -- the
            // predecessor's RESUME/NEW split. With no saves the `else` branch
            // is exactly the single prominent Play button this has always been.
            if continuableSlot != nil {
                Button {
                    onPlay(game, .continueNewest)
                } label: {
                    Label("Continue", systemImage: "clock.arrow.circlepath")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("detailContinueButton")

                Button {
                    onPlay(game, .newGame)
                } label: {
                    Label("New Game", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .accessibilityIdentifier("detailPlayButton")
            } else {
                Button {
                    onPlay(game, .newGame)
                } label: {
                    Label("Play", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("detailPlayButton")
            }
        }
    }

    @ViewBuilder
    private var contentsSection: some View {
        Section("Contents") {
            LabeledContent("Base", value: baseName)
            if !game.isBaseGame {
                LabeledContent("Mods", value: names(ofKind: .pwad))
                LabeledContent("Patches", value: names(ofKind: .deh))
                LabeledContent("Compat", value: game.complevel ?? "Auto")
                Button("Edit") {
                    onEdit(game)
                    dismiss()
                }
                .accessibilityIdentifier("detailEditButton")
            }
        }
    }

    private var baseName: String {
        guard let baseID = game.baseID else { return "None" }
        return (try? library.wad(id: baseID))?.displayName ?? "?"
    }

    /// The game's files of one kind, in load order, as a display list.
    private func names(ofKind kind: WADKind) -> String {
        let names = game.fileIDs
            .compactMap { try? library.wad(id: $0) }
            .filter { $0.kind == kind }
            .map(\.displayName)
        return names.isEmpty ? "None" : names.joined(separator: ", ")
    }

    private var controlsSection: some View {
        Section("Controls") {
            Picker("Layout", selection: $scheme) {
                Text("Default (\(TouchControlScheme.current().displayLabel))")
                    .tag(TouchControlScheme?.none)
                Text("Classic").tag(TouchControlScheme?.some(.classic))
                Text("Modern").tag(TouchControlScheme?.some(.modern))
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("detailSchemePicker")
            .onChange(of: scheme) { _, newValue in
                applySchemeOverride(newValue?.rawValue)
            }
        }
    }

    @ViewBuilder
    private var savesSection: some View {
        Section("Saves") {
            if saves.isEmpty {
                Text("No saves yet").foregroundStyle(.secondary)
            } else {
                ForEach(saves) { slot in
                    LabeledContent(slot.id,
                                  value: slot.modified.formatted(date: .abbreviated, time: .shortened))
                }
                .onDelete(perform: deleteSaves)
            }
        }
    }

    @ViewBuilder
    private var footerSection: some View {
        if game.isBaseGame {
            Section {
                Button("Create preset from this") {
                    showCreatePresetFromBase = true
                }
                .accessibilityIdentifier("createPresetFromBaseButton")
            }
        } else {
            Section {
                // One button (spec §4.4): deleting a game deletes its saves.
                // The keep-saves fork is gone with the preset concept.
                Button("Delete Game", role: .destructive) {
                    try? library.deleteGame(game)
                    onChanged()
                    dismiss()
                }
                .accessibilityIdentifier("detailDeleteGameButton")
            }
        }
    }

    // MARK: Actions

    private func applySchemeOverride(_ raw: String?) {
        try? library.setSchemeOverride(raw, for: game)
        onChanged()
    }

    private func deleteSaves(at offsets: IndexSet) {
        for index in offsets {
            library.deleteSave(saves[index], forKey: savesKey)
        }
        saves = library.saveSlots(forKey: savesKey)
    }
}
