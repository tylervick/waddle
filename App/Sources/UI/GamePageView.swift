import SwiftUI
import UIKit

/// One page for every tile (spec §3.2): art and Play, then what the game loads,
/// its settings, its saves, and Duplicate / Delete or Hide. Every edit applies
/// in place through `LibraryService`; the one staged edit is a base or file
/// change on a game that has saves, which `GamePage.warnsBeforeApplying`
/// routes through the Duplicate Instead / Change Anyway sheet.
///
/// Pushed into the shelf's `NavigationStack` rather than presented: there is
/// no second sheet to promote to any more, so the dismiss/present transaction
/// race the old Details → Edit pair had to work around no longer exists.
struct GamePageView: View {
    let game: Game
    let library: LibraryService
    let onPlay: (Game, LaunchMode) -> Void
    /// Something the shelf shows changed (name, saves, hidden, a new copy).
    let onChanged: () -> Void
    /// The game is gone from this page's point of view (deleted, hidden, or a
    /// copy was made and should be found on the shelf): pop.
    let onClose: () -> Void

    @State private var saves: [LibraryService.SaveSlot] = []
    @State private var files: [WADFile] = []
    @State private var baseGames: [WADFile] = []
    @State private var allFiles: [WADFile] = []
    @State private var scheme: TouchControlScheme?
    @State private var complevel: String?
    @State private var baseSelection: UUID?
    @State private var showRename = false
    @State private var draftName = ""
    @State private var showAddFile = false
    /// The file the Add… picker picked, staged until the sheet has finished
    /// dismissing (`showAddFile`'s `onDismiss`) so the confirmation dialog
    /// this can lead to is never presented while the sheet is still
    /// dismissing itself (the cfaed69 race).
    @State private var pendingAdd: WADFile?
    /// A base or file edit waiting on the change-with-saves confirmation.
    @State private var pendingEdit: GameEdit?
    @State private var deleteCandidate: Game?
    @State private var artContentWidth: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0

    private var continuableSlot: Int? { EngineSaveSlot.newestLoadGameArgument(in: saves) }

    var body: some View {
        Form {
            headerSection
            baseSection
            filesSection
            settingsSection
            savesSection
            footerSection
        }
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
        .accessibilityIdentifier("gamePage")
        .navigationTitle(game.name)
        .navigationBarTitleDisplayMode(.inline)
        // Reorder handles on the file list, always. The list is short and the
        // page is the one place load order is edited, so a separate Edit mode
        // would be a second step for no gain (spec §3.2: "edits apply in place").
        .environment(\.editMode, .constant(.active))
        .onAppear(perform: reload)
        .alert("Rename", isPresented: $showRename) {
            TextField("Name", text: $draftName)
                .accessibilityIdentifier("renameField")
            Button("Save") {
                let trimmed = draftName.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return }
                try? library.rename(game, to: trimmed)
                onChanged()
            }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showAddFile, onDismiss: {
            if let file = pendingAdd {
                pendingAdd = nil
                attempt(.files(game.fileIDs + [file.id]))
            }
        }) {
            AddFilePicker(candidates: GamePage.addableFiles(from: allFiles, to: game)) { wad in
                pendingAdd = wad
            }
        }
        .confirmationDialog(saveWarningTitle, isPresented: pendingEditBinding,
                            titleVisibility: .visible, presenting: pendingEdit) { edit in
            Button("Duplicate Instead") {
                if (try? library.duplicate(game, applying: edit)) != nil {
                    onChanged()
                    onClose()
                }
            }
            .accessibilityIdentifier("duplicateInsteadAction")
            Button("Change Anyway", role: .destructive) { apply(edit) }
                .accessibilityIdentifier("changeAnywayAction")
            Button("Cancel", role: .cancel) { reload() }
        } message: { _ in
            Text("Changing what it loads may make them unplayable.")
        }
        .deleteGamePrompt(game: $deleteCandidate, library: library) {
            onChanged()
            onClose()
        }
    }

    // MARK: Sections

    private var captionHeight: CGFloat {
        PlayableDetailLayout.captionHeight(
            titleLineHeight: UIFont.preferredFont(forTextStyle: .title2).lineHeight,
            buttonLineHeight: UIFont.preferredFont(forTextStyle: .body).lineHeight,
            primaryButtonCount: continuableSlot != nil ? 2 : 1)
    }

    private var headerSection: some View {
        Section {
            TitleArtView(game: game, library: library,
                         aspectRatio: Theme.heroAspectRatio,
                         height: PlayableDetailLayout.artHeight(
                            contentWidth: artContentWidth,
                            viewportHeight: viewportHeight,
                            captionHeight: captionHeight))
            // Tap to rename (spec §3.2). A button rather than an inline field so
            // the title reads as a title and VoiceOver announces one action.
            Button {
                draftName = game.name
                showRename = true
            } label: {
                HStack {
                    Text(game.name).font(.title2.bold())
                    Image(systemName: "pencil").foregroundStyle(Color.appSecondaryText)
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("gameNameButton")
            .accessibilityLabel("Rename \(game.name)")

            if continuableSlot != nil {
                Button {
                    onPlay(game, .continueNewest)
                } label: {
                    Label("Continue", systemImage: "clock.arrow.circlepath").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(game.baseID == nil)
                .accessibilityIdentifier("continueButton")
                Button {
                    onPlay(game, .newGame)
                } label: {
                    Label("New Game", systemImage: "play.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(game.baseID == nil)
                .accessibilityIdentifier("playButton")
            } else {
                Button {
                    onPlay(game, .newGame)
                } label: {
                    Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(game.baseID == nil)
                .accessibilityIdentifier("playButton")
            }
        }
    }

    @ViewBuilder
    private var baseSection: some View {
        Section("Base game") {
            if game.isBaseGame {
                // Locked: this game *is* the IWAD (spec §3.2).
                LabeledContent("Base", value: baseName)
            } else {
                Picker("Base", selection: $baseSelection) {
                    // Only offered while unpaired: once a game has a base,
                    // the picker must not be able to un-pair it back to none.
                    if game.baseID == nil {
                        Text("Choose a base game").tag(UUID?.none)
                    }
                    ForEach(baseGames, id: \.id) { wad in
                        Text(wad.displayName).tag(UUID?.some(wad.id))
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("basePicker")
                .onChange(of: baseSelection) { _, newValue in
                    guard newValue != game.baseID else { return }
                    attempt(.base(newValue))
                }
            }
        }
    }

    private var baseName: String {
        guard let baseID = game.baseID else { return "None" }
        return (try? library.wad(id: baseID))?.displayName ?? "?"
    }

    private var filesSection: some View {
        Section {
            ForEach(files, id: \.id) { file in
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.displayName)
                    Text(GamePage.roleLabel(for: file))
                        .font(.caption)
                        .foregroundStyle(Color.appSecondaryText)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("fileRow-\(file.displayName)")
            }
            .onMove { from, to in
                var ids = files.map(\.id)
                ids.move(fromOffsets: from, toOffset: to)
                attempt(.files(ids))
            }
            .onDelete { offsets in
                var ids = files.map(\.id)
                ids.remove(atOffsets: offsets)
                attempt(.files(ids))
            }
            Button {
                showAddFile = true
            } label: {
                Label("Add…", systemImage: "plus")
            }
            .accessibilityIdentifier("addFileButton")
        } header: {
            Text("Maps & Add-ons")
        } footer: {
            Text("Load order, top to bottom.")
        }
    }

    private var settingsSection: some View {
        Section {
            Picker("Compatibility", selection: $complevel) {
                Text("Auto").tag(String?.none)
                ForEach(["vanilla", "boom", "mbf", "mbf21"], id: \.self) {
                    Text($0).tag(String?.some($0))
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("complevelPicker")
            .onChange(of: complevel) { _, newValue in
                guard newValue != game.complevel else { return }
                try? library.setComplevel(game, newValue)
            }
            Picker("Touch layout", selection: $scheme) {
                Text("Default (\(TouchControlScheme.current().displayLabel))").tag(TouchControlScheme?.none)
                Text("Classic").tag(TouchControlScheme?.some(.classic))
                Text("Modern").tag(TouchControlScheme?.some(.modern))
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("schemePicker")
            .onChange(of: scheme) { _, newValue in
                guard newValue?.rawValue != game.schemeOverrideRaw else { return }
                try? library.setSchemeOverride(newValue?.rawValue, for: game)
                onChanged()
            }
        }
    }

    @ViewBuilder
    private var savesSection: some View {
        Section(saves.isEmpty ? "Saves" : "Saves · \(saves.count)") {
            if saves.isEmpty {
                Text("No saves yet").foregroundStyle(.secondary)
            } else {
                ForEach(saves) { slot in
                    LabeledContent(slot.id,
                                   value: slot.modified.formatted(date: .abbreviated, time: .shortened))
                        .accessibilityIdentifier("saveRow-\(slot.id)")
                }
                .onDelete { offsets in
                    for index in offsets { library.deleteSave(saves[index], forKey: game.id) }
                    saves = library.saveSlots(forKey: game.id)
                    onChanged()
                }
            }
        }
    }

    @ViewBuilder
    private var footerSection: some View {
        Section {
            Button("Duplicate") {
                if (try? library.duplicate(game)) != nil {
                    onChanged()
                    onClose()
                }
            }
            .accessibilityIdentifier("duplicateButton")
            if game.isBaseGame {
                Button("Hide from Shelf", role: .destructive) {
                    try? library.hide(game)
                    onChanged()
                    onClose()
                }
                .accessibilityIdentifier("hideGameButton")
            } else {
                Button("Delete Game", role: .destructive) {
                    deleteCandidate = game
                }
                .accessibilityIdentifier("deleteGameButton")
            }
        }
    }

    // MARK: Edits

    /// Applies a base or file edit, or stages it behind the change-with-saves
    /// confirmation (spec §3.2).
    private func attempt(_ edit: GameEdit) {
        if GamePage.warnsBeforeApplying(edit, saveCount: saves.count) {
            pendingEdit = edit
        } else {
            apply(edit)
        }
    }

    private func apply(_ edit: GameEdit) {
        switch edit {
        case .base(let id): try? library.setBase(game, baseID: id)
        case .files(let ids): try? library.setFiles(game, fileIDs: ids)
        }
        reload()
        onChanged()
    }

    private func reload() {
        saves = library.saveSlots(forKey: game.id)
        allFiles = (try? library.allWADs()) ?? []
        files = game.fileIDs.compactMap { id in allFiles.first { $0.id == id } }
        baseGames = (try? library.baseGames()) ?? []
        baseSelection = game.baseID
        complevel = game.complevel
        scheme = game.schemeOverrideRaw.flatMap(TouchControlScheme.init(rawValue:))
    }

    private var saveWarningTitle: String {
        "\(game.name) has \(saves.count) \(saves.count == 1 ? "save" : "saves")"
    }

    // Cancel-by-dismissal (swipe or tap-away) has to reset the staged picker
    // state the same as the explicit Cancel button does, or the next attempt
    // sees a stale `pendingEdit`/`baseSelection` pair. `reload()` is
    // idempotent, so re-running it here alongside the button's own call is
    // harmless.
    private var pendingEditBinding: Binding<Bool> {
        Binding(get: { pendingEdit != nil }, set: { if !$0 { pendingEdit = nil; reload() } })
    }
}

/// The Add… picker (spec §3.2): every non-base file the game does not already
/// load, grouped by role. Picking one attaches it at the end of the load order.
struct AddFilePicker: View {
    let candidates: [WADFile]
    let onPick: (WADFile) -> Void
    @Environment(\.dismiss) private var dismiss

    private var mapSets: [WADFile] { candidates.filter { $0.role == .mapSet } }
    private var addOns: [WADFile] { candidates.filter { $0.role == .addOn } }

    var body: some View {
        NavigationStack {
            List {
                if candidates.isEmpty {
                    Text("Every file you've imported is already in this game.")
                        .foregroundStyle(.secondary)
                }
                if !mapSets.isEmpty {
                    Section("Map sets") { rows(mapSets) }
                }
                if !addOns.isEmpty {
                    Section("Add-ons") { rows(addOns) }
                }
            }
            .waddleScrollSurface()
            .navigationTitle("Add to Game")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func rows(_ files: [WADFile]) -> some View {
        ForEach(files, id: \.id) { file in
            Button {
                onPick(file)
                dismiss()
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.displayName)
                    Text(GamePage.roleLabel(for: file)).font(.caption).foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("addFile-\(file.displayName)")
        }
    }
}

/// The Delete Game confirmation (spec §4.4), shared by the page's footer and
/// the shelf's long-press so the two cannot drift on what they offer.
private struct DeleteGamePrompt: ViewModifier {
    @Binding var game: Game?
    let library: LibraryService
    let onDeleted: () -> Void

    func body(content: Content) -> some View {
        content.confirmationDialog(
            game.map { GamePage.deleteMessage(gameName: $0.name,
                                              saveCount: library.saveSlots(forKey: $0.id).count,
                                              deletableFiles: deletable(for: $0).map(\.filename)) } ?? "",
            isPresented: Binding(get: { game != nil }, set: { if !$0 { game = nil } }),
            titleVisibility: .visible, presenting: game
        ) { game in
            Button("Delete Game and Saves", role: .destructive) {
                try? library.deleteGame(game)
                onDeleted()
            }
            .accessibilityIdentifier("deleteGameAndSavesAction")
            let files = deletable(for: game)
            if !files.isEmpty {
                Button("Also Delete \(files.map(\.filename).joined(separator: ", "))", role: .destructive) {
                    try? library.deleteGame(game)
                    for file in files { try? library.deleteWAD(file) }
                    onDeleted()
                }
                .accessibilityIdentifier("deleteGameAndFilesAction")
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func deletable(for game: Game) -> [WADFile] {
        (try? library.deletableMapSets(of: game)) ?? []
    }
}

extension View {
    func deleteGamePrompt(game: Binding<Game?>, library: LibraryService,
                          onDeleted: @escaping () -> Void) -> some View {
        modifier(DeleteGamePrompt(game: game, library: library, onDeleted: onDeleted))
    }
}
