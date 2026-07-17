import SwiftUI

struct LoadoutEditorView: View {
    let library: LibraryService
    let existing: Loadout?
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var iwadID: UUID?
    @State private var pwadIDs: [UUID] = []
    @State private var dehIDs: [UUID] = []
    @State private var complevel: String?

    private var iwads: [WADFile] { (try? library.allWADs())?.filter { $0.kindRaw == "IWAD" } ?? [] }
    private var pwads: [WADFile] { (try? library.allWADs())?.filter { $0.kindRaw == "PWAD" } ?? [] }
    private var dehs: [WADFile] { (try? library.allWADs())?.filter { $0.kindRaw == "DEH" } ?? [] }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Loadout name", text: $name)
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
                    Menu("Add PWAD") {
                        ForEach(pwads.filter { !pwadIDs.contains($0.id) }, id: \.id) { wad in
                            Button(wad.displayName) { pwadIDs.append(wad.id) }
                                .accessibilityIdentifier("addPWADButton-\(wad.displayName)")
                        }
                    }
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
            .navigationTitle(existing == nil ? "New Loadout" : "Edit Loadout")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(name.isEmpty || iwadID == nil)
                        .accessibilityIdentifier("saveLoadoutButton")
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .environment(\.editMode, .constant(.active))
            .onAppear(perform: populate)
        }
    }

    private func populate() {
        guard let existing else { return }
        name = existing.name
        iwadID = existing.iwadID
        pwadIDs = existing.pwadIDs
        dehIDs = existing.dehIDs
        complevel = existing.complevel
    }

    private func save() {
        guard let iwadID else { return }
        if let existing {
            existing.name = name
            existing.iwadID = iwadID
            existing.pwadIDs = pwadIDs
            existing.dehIDs = dehIDs
            existing.complevel = complevel
        } else {
            let loadout = try? library.createLoadout(name: name, iwadID: iwadID,
                                                     pwadIDs: pwadIDs, dehIDs: dehIDs)
            loadout?.complevel = complevel
        }
        dismiss()
    }
}
