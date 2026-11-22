import SwiftUI

/// The gear door (spec §3): everything the Play tab's gear *menu* used to
/// scatter — touch scheme, Control Feel, Show Debug Info, About — as one small
/// sheet. Deliberately player-facing only; file storage and hidden games are
/// pushed from the Library section (spec §3.3); importing is the shelf's Add.
///
/// Both of its destinations were rows in the old gear `Menu`, which could not
/// host the Control Feel sliders at all (see
/// `docs/learnings/swiftui-menu-cannot-host-sliders.md`). They arrive
/// differently here: About is pushed into this sheet's own `NavigationStack`,
/// while Control Feel is presented as a sheet, because `ControlFeelView`
/// carries its own stack and Done button — see the comment on its row.
struct PlayerSettingsView: View {
    let library: LibraryService
    /// Set when Settings is the shelf's panel rather than a sheet (issue
    /// #372): an inspector column is not something `dismiss` closes, so the
    /// panel's owner says how. Nil keeps the sheet's own dismissal.
    var onDone: (() -> Void)?

    @AppStorage(TouchControlScheme.userDefaultsKey) private var touchScheme: TouchControlScheme = .defaultScheme
    @AppStorage(WeaponSelectorStyle.userDefaultsKey) private var weaponSelector: WeaponSelectorStyle = .defaultStyle
    @AppStorage(ControlHintsSetting.userDefaultsKey) private var showControlHints: Bool = ControlHintsSetting.defaultValue
    @AppStorage(debugHUDUserDefaultsKey) private var debugHUD: Bool = false
    @State private var showControlFeel = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.launcherIsInTwoHalves) private var inTwoHalves

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Touch Controls", selection: $touchScheme) {
                        Text("Classic").tag(TouchControlScheme.classic)
                        Text("Modern").tag(TouchControlScheme.modern)
                    }
                    .accessibilityIdentifier("touchSchemePicker")

                    // Read when a session starts, like the scheme above.
                    Picker("Weapon Selector", selection: $weaponSelector) {
                        ForEach(WeaponSelectorStyle.allCases, id: \.self) { style in
                            Text(style.displayLabel).tag(style)
                        }
                    }
                    .accessibilityIdentifier("weaponSelectorPicker")

                    // Names the weapon zone (and, in Modern, the two sides)
                    // after a few seconds without a touch. Read when a
                    // session starts, like the two pickers above.
                    Toggle("Show Control Hints", isOn: $showControlHints)
                        .accessibilityIdentifier("controlHintsToggle")

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
                } header: {
                    WaddleSectionHeader("Controls")
                }

                Section {
                    NavigationLink {
                        FilesView(library: library)
                    } label: {
                        Label("Files", systemImage: "internaldrive")
                    }
                    .accessibilityIdentifier("filesButton")

                    NavigationLink {
                        HiddenGamesView(library: library)
                    } label: {
                        Label("Hidden Games", systemImage: "eye.slash")
                    }
                    .accessibilityIdentifier("hiddenGamesButton")
                } header: {
                    WaddleSectionHeader("Library")
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
            .labelStyle(WaddleRowLabelStyle())
            .waddleScrollSurface()
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { if let onDone { onDone() } else { dismiss() } }
                }
            }
            // In the lower half of a half-open iPhone Duo it is pushed like
            // the other rows' screens: a sheet covers the window, and there
            // that is across the fold (issue #429).
            .sheet(isPresented: inTwoHalves ? .constant(false) : $showControlFeel) {
                ControlFeelView()
            }
            .navigationDestination(isPresented: inTwoHalves ? $showControlFeel : .constant(false)) {
                ControlFeelView(isPushed: true)
            }
        }
    }
}
