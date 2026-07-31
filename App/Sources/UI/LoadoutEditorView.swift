import SwiftUI

struct LoadoutEditorView: View {
    let library: LibraryService
    let existing: Loadout?
    /// Base game to pre-seed a *new* loadout with (from `PresetCreationFlow`);
    /// ignored when editing an `existing` loadout.
    let seedIWAD: WADFile?
    /// Called instead of `dismiss()` on Save/Cancel when set. `PresetCreationFlow`
    /// pushes this view as a `.navigationDestination` rather than presenting it
    /// as a sheet's direct root, so this view's own `dismiss()` only pops back
    /// to the base-game picker -- it does not close the enclosing sheet. When
    /// set, `onComplete` is the outer flow's `dismiss()` instead, closing the
    /// whole sheet so `PlayView`'s `.sheet(..., onDismiss: refresh)` fires.
    /// `nil` when editing an existing loadout, where this view IS the sheet's
    /// direct root and its own `dismiss()` is already correct.
    var onComplete: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    init(library: LibraryService, existing: Loadout?, seedIWAD: WADFile? = nil,
         onComplete: (() -> Void)? = nil) {
        self.library = library
        self.existing = existing
        self.seedIWAD = seedIWAD
        self.onComplete = onComplete
    }

    @State private var name = ""
    @State private var iwadID: UUID?
    @State private var pwadIDs: [UUID] = []
    @State private var dehIDs: [UUID] = []
    @State private var complevel: String?
    /// True once the user has typed in the name field directly; while false,
    /// the name auto-updates from `seedIWAD` + the current PWAD list.
    @State private var nameEdited = false

    private var iwads: [WADFile] { (try? library.allWADs())?.filter { $0.kindRaw == WADKind.iwad.rawValue } ?? [] }
    private var pwads: [WADFile] { (try? library.allWADs())?.filter { $0.kindRaw == WADKind.pwad.rawValue } ?? [] }
    private var dehs: [WADFile] { (try? library.allWADs())?.filter { $0.kindRaw == WADKind.deh.rawValue } ?? [] }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Preset name", text: nameBinding)
                        .accessibilityIdentifier("loadoutNameField")
                }
                Section("Base game (IWAD)") {
                    Picker("IWAD", selection: $iwadID) {
                        Text("Choose…").tag(UUID?.none)
                        ForEach(iwads, id: \.id) { wad in
                            Text(wad.displayName).tag(UUID?.some(wad.id))
                        }
                    }
                    .accessibilityIdentifier("iwadPicker")
                }
                Section("Mods (PWADs, load order top → bottom)") {
                    ForEach(pwadIDs, id: \.self) { id in
                        Text((try? library.wad(id: id))?.displayName ?? "?")
                    }
                    .onMove { pwadIDs.move(fromOffsets: $0, toOffset: $1) }
                    .onDelete { pwadIDs.remove(atOffsets: $0) }
                    Menu {
                        ForEach(pwads.filter { !pwadIDs.contains($0.id) }, id: \.id) { wad in
                            Button(wad.displayName) { pwadIDs.append(wad.id) }
                                .accessibilityIdentifier("addPWADButton-\(wad.displayName)")
                        }
                    } label: {
                        Text("Add PWAD")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .accessibilityIdentifier("addPWADMenu")
                }
                Section("DeHackEd patches") {
                    ForEach(dehIDs, id: \.self) { id in
                        Text((try? library.wad(id: id))?.displayName ?? "?")
                    }
                    .onDelete { dehIDs.remove(atOffsets: $0) }
                    Menu("Add patch") {
                        ForEach(dehs.filter { !dehIDs.contains($0.id) }, id: \.id) { deh in
                            Button(deh.displayName) { dehIDs.append(deh.id) }
                        }
                    }
                }
                Section("Compatibility") {
                    Picker("Complevel", selection: $complevel) {
                        Text("Auto (recommended)").tag(String?.none)
                        ForEach(["vanilla", "boom", "mbf", "mbf21"], id: \.self) {
                            Text($0).tag(String?.some($0))
                        }
                    }
                }
            }
            .navigationTitle(existing == nil ? "New Preset" : "Edit Preset")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(name.isEmpty || iwadID == nil)
                        .accessibilityIdentifier("saveLoadoutButton")
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { complete() }
                }
            }
            .environment(\.editMode, .constant(.active))
            .onAppear(perform: populate)
            .onChange(of: pwadIDs) { _, _ in updateAutoName() }
        }
    }

    /// Writes to `name` through this binding (i.e. the TextField itself, so
    /// only actual user keystrokes) flip `nameEdited`; programmatic auto-name
    /// updates assign `name` directly and don't pass through it.
    private var nameBinding: Binding<String> {
        Binding(get: { name }, set: { name = $0; nameEdited = true })
    }

    private func populate() {
        if let existing {
            name = existing.name
            iwadID = existing.iwadID
            pwadIDs = existing.pwadIDs
            dehIDs = existing.dehIDs
            complevel = existing.complevel
        } else if let seedIWAD {
            iwadID = seedIWAD.id
            updateAutoName()
        }
    }

    /// Keeps `name` in sync with `PresetName.suggested` as PWADs are added or
    /// removed, until the user edits the name field directly.
    private func updateAutoName() {
        guard existing == nil, !nameEdited, let seedIWAD else { return }
        let pwadNames = pwadIDs.compactMap { try? library.wad(id: $0)?.displayName }
        name = PresetName.suggested(base: seedIWAD.displayName, pwads: pwadNames)
    }

    private func save() {
        guard let iwadID else { return }
        if let existing {
            existing.name = name
            existing.iwadID = iwadID
            existing.pwadIDs = pwadIDs
            existing.dehIDs = dehIDs
            existing.complevel = complevel
            try? library.saveChanges()
        } else {
            let loadout = try? library.createLoadout(name: name, iwadID: iwadID,
                                                     pwadIDs: pwadIDs, dehIDs: dehIDs)
            loadout?.complevel = complevel
            try? library.saveChanges()
        }
        complete()
    }

    /// Closes this view: via `onComplete` when set (pushed-destination case,
    /// see its doc comment), otherwise via this view's own `dismiss()` (the
    /// direct-sheet-root case).
    private func complete() {
        if let onComplete {
            onComplete()
        } else {
            dismiss()
        }
    }
}
