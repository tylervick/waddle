import SwiftUI

/// The gear door (spec §3): everything the Play tab's gear *menu* used to
/// scatter — touch scheme, Control Feel, Show Debug Info, About — as one small
/// sheet. Deliberately player-facing only; nothing about managing files lives
/// here, that is Manage's job.
///
/// Both of its destinations were rows in the old gear `Menu`, which could not
/// host the Control Feel sliders at all (see
/// `docs/learnings/swiftui-menu-cannot-host-sliders.md`). They arrive
/// differently here: About is pushed into this sheet's own `NavigationStack`,
/// while Control Feel is presented as a sheet, because `ControlFeelView`
/// carries its own stack and Done button — see the comment on its row.
struct PlayerSettingsView: View {
    let library: LibraryService

    @AppStorage(TouchControlScheme.userDefaultsKey) private var touchScheme: TouchControlScheme = .defaultScheme
    @AppStorage(debugHUDUserDefaultsKey) private var debugHUD: Bool = false
    @State private var showControlFeel = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Touch Controls", selection: $touchScheme) {
                        Text("Classic").tag(TouchControlScheme.classic)
                        Text("Modern").tag(TouchControlScheme.modern)
                    }
                    .accessibilityIdentifier("touchSchemePicker")

                    // A sheet, not a push: `ControlFeelView` brings its own
                    // `NavigationStack` and Done button (it was built for this
                    // presentation), and pushing it would nest one stack inside
                    // another for no gain.
                    Button {
                        showControlFeel = true
                    } label: {
                        Label("Control Feel", systemImage: "slider.horizontal.3")
                    }
                    .accessibilityIdentifier("controlFeelButton")
                }

                Section {
                    Toggle("Show Debug Info", isOn: $debugHUD)
                        .accessibilityIdentifier("debugHUDToggle")

                    NavigationLink {
                        AboutView(library: library)
                    } label: {
                        Label("About", systemImage: "info.circle")
                    }
                    .accessibilityIdentifier("aboutButton")
                }
            }
            .waddleScrollSurface()
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showControlFeel) {
                ControlFeelView()
            }
        }
    }
}
