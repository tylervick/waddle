import SwiftUI

struct LoadoutGridView: View {
    let library: LibraryService
    @Binding var lastExitCode: Int32?
    @State private var loadouts: [Loadout] = []
    @State private var editorLoadout: Loadout?
    @State private var showNewEditor = false
    @AppStorage(TouchControlScheme.userDefaultsKey) private var touchScheme: TouchControlScheme = .defaultScheme
    @AppStorage(debugHUDUserDefaultsKey) private var debugHUD: Bool = false
    @State private var showControlFeel = false
    @State private var showAbout = false
    @State private var errorAlert: EngineErrorAlert?

    private let columns = [GridItem(.adaptive(minimum: 200), spacing: 16)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(loadouts, id: \.id) { loadout in
                        tile(for: loadout)
                    }
                }
                .padding()
            }
            .navigationTitle("BoomBox")
            .toolbar { toolbarContent }
            // .overlay, not .safeAreaInset -- a conditionally-empty
            // safeAreaInset directly above a ScrollView/LazyVGrid crashed
            // SwiftUI's layout engine here (HVGrid.minorGeometry, SwiftUI
            // internal, iOS 26.2 SDK); .overlay is the same pattern
            // ContentView already uses successfully for its own
            // conditional post-session labels.
            .overlay(alignment: .bottom) {
                if debugHUD {
                    Text("BoomBox \(BuildInfo.commit) (\(BuildInfo.branch)) · built \(BuildInfo.builtAt)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                        .accessibilityIdentifier("buildInfoLabel")
                }
            }
            .sheet(isPresented: $showControlFeel) {
                ControlFeelView()
            }
            .sheet(isPresented: $showAbout) {
                NavigationStack { AboutView() }
            }
            .sheet(isPresented: $showNewEditor, onDismiss: refresh) {
                LoadoutEditorView(library: library, existing: nil)
            }
            .sheet(item: $editorLoadout, onDismiss: refresh) { loadout in
                LoadoutEditorView(library: library, existing: loadout)
            }
            .alert(errorAlert?.title ?? "", isPresented: Binding(
                get: { errorAlert != nil }, set: { if !$0 { errorAlert = nil } }
            ), presenting: errorAlert) { _ in
                Button("OK") { errorAlert = nil }
            } message: { alert in
                Text([alert.engineMessage, alert.hint].compactMap { $0 }
                    .joined(separator: "\n\n"))
            }
            .onAppear(perform: refresh)
        }
    }

    // Split out of `body`: a toolbar this size inline was enough for the
    // Swift type checker to give up entirely ("failed to produce diagnostic
    // for expression") rather than report a real error.
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            touchSchemeMenu
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            Button {
                showNewEditor = true
            } label: {
                Label("New Loadout", systemImage: "plus")
            }
            .accessibilityIdentifier("newLoadoutButton")
        }
    }

    private var touchSchemeMenu: some View {
        Menu {
            Picker("Touch Controls", selection: $touchScheme) {
                Text("Classic").tag(TouchControlScheme.classic)
                Text("Modern").tag(TouchControlScheme.modern)
            }
            .accessibilityIdentifier("touchSchemePicker")

            Toggle("Show Debug Info", isOn: $debugHUD)
                .accessibilityIdentifier("debugHUDToggle")

            // Sliders can't render inside a Menu (UIMenu has no slider row),
            // so the tuning sliders live in a sheet opened from here.
            Button {
                showControlFeel = true
            } label: {
                Label("Control Feel…", systemImage: "slider.horizontal.3")
            }
            .accessibilityIdentifier("controlFeelButton")

            Button {
                showAbout = true
            } label: {
                Label("About", systemImage: "info.circle")
            }
            .accessibilityIdentifier("aboutButton")
        } label: {
            Label("Touch Controls", systemImage: "gearshape")
        }
        .accessibilityIdentifier("touchSchemeMenu")
    }

    private func tile(for loadout: Loadout) -> some View {
        Button {
            play(loadout)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: "flame.fill")
                    .font(.title)
                Text(loadout.name).font(.headline).lineLimit(2)
                Text(subtitle(for: loadout))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(loadout.name == "Freedoom Phase 1"
                                 ? "playFreedoom1" : "loadout-\(loadout.name)")
        .contextMenu {
            Button("Edit") { editorLoadout = loadout }
            Button("Delete Loadout & Saves", role: .destructive) {
                try? library.deleteLoadout(loadout, deleteSaves: true)
                refresh()
            }
            Button("Delete Loadout, Keep Saves", role: .destructive) {
                try? library.deleteLoadout(loadout, deleteSaves: false)
                refresh()
            }
        }
    }

    private func subtitle(for loadout: Loadout) -> String {
        let pwads = loadout.pwadIDs.compactMap { try? library.wad(id: $0)?.displayName }
        return pwads.isEmpty ? "Base game" : pwads.joined(separator: " + ")
    }

    private func play(_ loadout: Loadout) {
        lastExitCode = nil
        do {
            let args = try LoadoutArguments.build(loadout: loadout) { id in
                guard let wad = try library.wad(id: id) else {
                    throw LoadoutArgumentsError.missingWAD(id)
                }
                return library.fileURL(for: wad)
            }
            loadout.lastPlayed = .now
            try? library.saveChanges()
            lastExitCode = EngineSession.play(arguments: args)
            errorAlert = EngineErrorAlert.from(exitCode: lastExitCode ?? 0,
                                               engineMessage: EngineSession.lastErrorMessage)
        } catch {
            lastExitCode = -101   // arg-building failure (missing WAD)
            errorAlert = EngineErrorAlert.from(
                exitCode: -101,
                engineMessage: "A file in this loadout is missing from the library.")
        }
        refresh()
    }

    private func refresh() {
        loadouts = (try? library.allLoadouts()) ?? []
    }
}
