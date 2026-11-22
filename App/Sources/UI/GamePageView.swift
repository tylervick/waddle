import SwiftUI
import UIKit

/// What `GamePageView` has measured of itself, and lays its hero out from.
///
/// A view that measures itself to lay itself out can feed its own
/// measurement (`docs/learnings/a-scroll-view-measured-to-lay-out-its-own-content-can-spin.md`),
/// and nothing outside the page can see its state. `GamePageMeasurementTests`
/// reads these through `gamePageMeasurementsReport` to check that none of
/// them moves once it is taken.
struct GamePageMeasurements: Hashable {
    /// The form's width less its row insets; zero until measured.
    var artContentWidth: CGFloat
    /// The form's height; zero until measured.
    var viewportHeight: CGFloat
    /// The widest unbreakable thing in the caption; nil until measured.
    var captionWordWidth: CGFloat?
    /// The width the hero row is offered; zero until measured.
    var heroRowWidth: CGFloat
    /// The wider of Continue's and New Game's labels at its natural width,
    /// from `actionLabelGauge`; zero until measured, and with no save.
    var actionLabelWidth: CGFloat = 0

    /// The arrangement the page draws from these.
    var arrangement: PlayableDetailLayout.HeroArrangement {
        PlayableDetailLayout.arrangement(contentWidth: artContentWidth,
                                         viewportHeight: viewportHeight,
                                         minimumCaptionWidth: captionWordWidth ?? .infinity,
                                         rowWidth: heroRowWidth)
    }

    /// The width the caption gives the action buttons: the hero row when
    /// the art is above the caption, what is left of it beside the art.
    var actionsWidth: CGFloat {
        switch arrangement {
        case .stacked:
            return heroRowWidth > 0 ? heroRowWidth : artContentWidth
        case .sideBySide:
            return PlayableDetailLayout.sideBySideCaptionWidth(contentWidth: artContentWidth,
                                                               viewportHeight: viewportHeight,
                                                               rowWidth: heroRowWidth)
        }
    }

    /// Continue and New Game in a row, or one over the other. The shelf's
    /// hero answers the same question for the same two buttons, and its rule
    /// is the one used: a row only where the caption holds two buttons of the
    /// wider label's width (issue #424 there, #468 here).
    var buttonArrangement: ShelfHeroLayout.ButtonArrangement {
        let minimum = actionLabelWidth > 0 ? actionLabelWidth + Theme.Spacing.base * 2 : 0
        return ShelfHeroLayout.buttonArrangement(captionWidth: actionsWidth, buttonMinimumWidth: minimum)
    }
}

extension EnvironmentValues {
    /// Called with each new set of measurements a `GamePageView` takes.
    /// Tests set it; the app never does.
    @Entry var gamePageMeasurementsReport: ((GamePageMeasurements) -> Void)?

    /// Called with where each of the hero's action buttons is drawn, by its
    /// accessibility identifier. Tests set it; the app never does.
    @Entry var gamePageActionFrameReport: ((String, CGRect) -> Void)?
}

/// One page for every tile (spec §3.2): art and Play, then what the game loads,
/// its settings, its saves, and Duplicate / Delete or Hide. Every edit applies
/// in place through `LibraryService`; the one staged edit is a base or file
/// change on a game that has saves, which `GamePage.warnsBeforeApplying`
/// routes through the Duplicate Instead / Change Anyway sheet.
///
/// Pushed into the shelf's `NavigationStack` rather than presented: there is
/// no second sheet to promote to any more, so the dismiss/present transaction
/// race the old Details → Edit pair had to work around no longer exists.
///
/// The header is a hero row, not a grouped row (design-system spec §4): the
/// art and the actions under it sit on the game's own colours, blurred behind
/// the page, and the grouped sections start on solid ground below them. The
/// page stays a `Form` for what a form is good at — the file list's reorder
/// handles and swipe-to-delete.
struct GamePageView: View {
    let game: Game
    let library: LibraryService
    let onPlay: (Game, LaunchMode) -> Void
    /// Something the shelf shows changed (name, saves, hidden, a new copy).
    let onChanged: () -> Void
    /// The game is gone from this page's point of view (deleted, hidden, or a
    /// copy was made and should be found on the shelf): pop.
    let onClose: () -> Void
    /// What the page has presented and is waiting on. The panel's trees pass
    /// the panel model's, so the same page drawn by another tree after a
    /// fold shows the same dialog (`PanelPresentation.swift`). Nil keeps it
    /// to this view, which is right for a page nothing else will draw.
    var presentation: GamePagePresentation?

    @State private var ownPresentation = GamePagePresentation()
    private var shown: GamePagePresentation { presentation ?? ownPresentation }
    @Environment(\.panelHost) private var host

    @State private var saves: [LibraryService.SaveSlot] = []
    @State private var files: [WADFile] = []
    @State private var baseGames: [WADFile] = []
    @State private var allFiles: [WADFile] = []
    @State private var scheme: TouchControlScheme?
    @State private var complevel: String?
    @State private var baseSelection: UUID?
    /// The file the Add… picker picked, staged until the sheet has finished
    /// dismissing (`showAddFile`'s `onDismiss`) so the confirmation dialog
    /// this can lead to is never presented while the sheet is still
    /// dismissing itself (the cfaed69 race).
    /// A base or file edit waiting on the change-with-saves confirmation.
    @State private var artContentWidth: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0
    /// The widest unbreakable thing in the hero's caption, from
    /// `captionProbe`. Nil until measured, and until then the hero stacks.
    @State private var captionWordWidth: CGFloat?
    /// The hero row's measured width; zero until measured.
    @State private var heroRowWidth: CGFloat = 0
    @Environment(\.launcherIsInTwoHalves) private var inTwoHalves
    /// The wider action label, from `actionLabelGauge`; zero until measured.
    @State private var actionLabelWidth: CGFloat = 0

    /// Where a test reads what the page measured; nil in the app.
    @Environment(\.gamePageMeasurementsReport) private var measurementsReport
    /// Where a test reads where the action buttons were drawn; nil in the app.
    @Environment(\.gamePageActionFrameReport) private var actionFrameReport

    private var measurements: GamePageMeasurements {
        GamePageMeasurements(artContentWidth: artContentWidth, viewportHeight: viewportHeight,
                             captionWordWidth: captionWordWidth, heroRowWidth: heroRowWidth,
                             actionLabelWidth: continuableSlot != nil ? actionLabelWidth : 0)
    }

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
        // `proxy.size` is the container's size *inside* its safe area -- for
        // a pushed Form that is the region between the navigation bar and the
        // home indicator, 724 pt on an iPhone 17 Pro -- and `safeAreaInsets`
        // are what lies outside it. Subtracting the insets from that size
        // again (as this did until 2026-09-30) under-measured the viewport by
        // 150 pt and capped the art in portrait, where it has room to spare.
        // See `docs/learnings/geometry-proxy-size-already-excludes-safe-area.md`.
        .onGeometryChange(for: CGSize.self) { proxy in
            CGSize(width: proxy.size.width - PlayableDetailLayout.rowHorizontalInset * 2,
                   height: proxy.size.height)
        } action: { size in
            artContentWidth = size.width
            viewportHeight = size.height
        }
        .onChange(of: measurements, initial: true) { _, measured in
            measurementsReport?(measured)
        }
        .scrollContentBackground(.hidden)
        // The backdrop stands in for `waddleScrollSurface`'s flat background:
        // it paints `appBackground` itself and the art over that, so the page
        // is the same two tones everywhere the art has faded out.
        .background { ArtBackdropView(game: game, library: library) }
        .listRowBackground(Color.appSurface)
        .accessibilityIdentifier("gamePage")
        .navigationTitle(game.name)
        .navigationBarTitleDisplayMode(.inline)
        // Reorder handles on the file list, always. The list is short and the
        // page is the one place load order is edited, so a separate Edit mode
        // would be a second step for no gain (spec §3.2: "edits apply in place").
        .environment(\.editMode, .constant(.active))
        .onAppear(perform: reload)
        .alert("Rename", isPresented: host.presented({ shown.showRename },
                                                     dismiss: { shown.showRename = false })) {
            TextField("Name", text: Binding(get: { shown.draftName }, set: { shown.draftName = $0 }))
                .accessibilityIdentifier("renameField")
            Button("Save") {
                let trimmed = shown.draftName.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return }
                try? library.rename(game, to: trimmed)
                onChanged()
            }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: inTwoHalves ? .constant(false) : addFileShown,
               onDismiss: addPickedFile) {
            AddFilePicker(candidates: GamePage.addableFiles(from: allFiles, to: game)) { wad in
                shown.pendingAdd = wad
            }
        }
        // In the lower half of a half-open iPhone Duo the picker is pushed:
        // a sheet covers the window, and there that is across the fold
        // (issue #429). The pick is still applied once the picker has gone.
        .navigationDestination(isPresented: inTwoHalves ? addFileShown : .constant(false)) {
            AddFilePicker(candidates: GamePage.addableFiles(from: allFiles, to: game),
                          isPushed: true) { wad in
                shown.pendingAdd = wad
            }
        }
        .onChange(of: shown.showAddFile) { _, isShown in
            if inTwoHalves, !isShown { addPickedFile() }
        }
        // A pick made in the moment a fold took the picker's tree down is
        // still waiting when this one is up.
        .onChange(of: host.presents) { _, presents in
            if presents, !shown.showAddFile { addPickedFile() }
        }
        .confirmationDialog(saveWarningTitle, isPresented: pendingEditBinding,
                            titleVisibility: .visible, presenting: shown.pendingEdit) { edit in
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
        .deleteGamePrompt(game: Binding(get: { host.presents ? shown.deleteCandidate : nil },
                                        set: { if host.presents { shown.deleteCandidate = $0 } }),
                          library: library) {
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

    /// Measures the widest thing in the caption that cannot wrap: a word of
    /// the title beside its pencil, or a word of a button's label beside its
    /// icon, inside the button's padding. Drawn hidden at its natural size
    /// and read back, because the first version worked this out from
    /// `UIFont` and came out too wide: a font cannot say how wide a symbol
    /// is drawn or how far a `Label` sets it from its title, and on a closed
    /// iPhone Duo held sideways the over-count stacked a page whose caption
    /// fitted beside the art with 13 pt to spare (review of pull request 435).
    private var captionProbe: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The title's pieces, not its words: the title may end a line
            // wherever `WholeWordText` lets it, so that is what has to fit.
            ForEach(Array(WholeWordText.pieces(game.name).enumerated()), id: \.offset) { _, piece in
                titleLabel(piece)
            }
            ForEach(Array(primaryActionWords.enumerated()), id: \.offset) { _, action in
                // Title and icon, said outright: in a form row's background
                // a `Label` is drawn as its icon alone, and this measured
                // 40 pt of icon for every word (found with issue #468).
                Label(action.word, systemImage: action.systemImage)
                    .labelStyle(.titleAndIcon)
                    .font(Theme.Typography.button)
                    .padding(.horizontal, Theme.Spacing.base)
            }
        }
        .lineLimit(1)
        .fixedSize()
        .hidden()
        .accessibilityHidden(true)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            captionWordWidth = width
        }
    }

    /// Each word of each primary button's label, with that button's icon.
    private var primaryActionWords: [(word: String, systemImage: String)] {
        if continuableSlot != nil {
            return [("Continue", "clock.arrow.circlepath"), ("New", "play.fill"), ("Game", "play.fill")]
        }
        return [("Play", "play.fill")]
    }

    /// The title as the page draws it, shared with `captionProbe` so the
    /// measurement cannot drift from the thing measured.
    private func titleLabel(_ name: String) -> some View {
        HStack(spacing: Theme.Spacing.sm) {
            // A name with no spaces in it is one word to the line breaker,
            // and the system hyphenated it inside a syllable ("sunlust_fi-" /
            // "nal_v13", issue #441). A game made from a map set is named
            // after its file, so that is the ordinary imported game.
            WholeWordText(name, textStyle: .title2, weight: .bold)
                .font(Theme.Typography.heroTitle)
            Image(systemName: "pencil")
                .font(Theme.Typography.secondary)
                .foregroundStyle(Color.appSecondaryText)
        }
    }

    /// The hero row: art, title, actions. Zero row insets and a clear row
    /// background so it is drawn on the backdrop rather than in a grouped
    /// cell. The Form's own section margin (`rowHorizontalInset`) is the only
    /// horizontal inset, and it is what the art's width is measured against.
    /// `PlayableDetailLayout.arrangement` decides whether the art sits above
    /// the caption or beside it.
    private var headerSection: some View {
        Section {
            Group {
                switch measurements.arrangement {
                case .stacked:
                    VStack(alignment: .leading, spacing: PlayableDetailLayout.captionSpacing) {
                        // Not in the lower half of a half-open iPhone Duo
                        // (issue #429). Stacked there means the caption did
                        // not fit beside the art, which is the large text
                        // sizes, and in a half some 380 pt tall the art was
                        // on its 96 pt floor: a strip above a title and
                        // buttons that already overflow. The half is theirs.
                        if !inTwoHalves {
                            heroArt(height: PlayableDetailLayout.artHeight(
                                contentWidth: artContentWidth,
                                viewportHeight: viewportHeight,
                                captionHeight: captionHeight))
                        }
                        titleButton
                        actionsRow
                    }
                case .sideBySide:
                    // Wider than tall (design-system spec §8): the art takes
                    // up to half the row and the caption the rest, so the
                    // art is a picture again instead of the 96 pt strip the
                    // stacked budget left it on a landscape phone.
                    HStack(alignment: .top, spacing: PlayableDetailLayout.captionSpacing) {
                        heroArt(height: PlayableDetailLayout.sideBySideArtHeight(
                            contentWidth: artContentWidth, viewportHeight: viewportHeight))
                            .frame(width: PlayableDetailLayout.sideBySideArtWidth(
                                contentWidth: artContentWidth, viewportHeight: viewportHeight))
                        VStack(alignment: .leading, spacing: PlayableDetailLayout.captionSpacing) {
                            titleButton
                            actionsRow
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // The row's width, which is what the caption really has to fit
            // in. It is not always the form's width less the insets the art
            // is sized from: on a closed iPhone Duo held sideways the row is
            // about 11 pt wider than that, and the caption fitted in the
            // difference.
            //
            // The width the row is *offered*, not the one it reports. The
            // frame above is as wide as its content when the content reports
            // over, and the content is what this measurement arranges: read
            // off the frame, the stacked row came back a quarter of a point
            // wider than the side-by-side one, and the page changed
            // arrangement on every layout pass (issue #450).
            .onOfferedWidthChange { width in
                heroRowWidth = width
            }
            .background(alignment: .topLeading) { captionProbe }
            .background(alignment: .topLeading) { actionLabelGauge }
            .padding(.top, PlayableDetailLayout.captionTopPadding)
            .padding(.bottom, PlayableDetailLayout.captionBottomPadding)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
    }

    private func heroArt(height: CGFloat) -> some View {
        TitleArtView(game: game, library: library,
                     aspectRatio: Theme.heroAspectRatio,
                     height: height)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .strokeBorder(Color.appHairline, lineWidth: Theme.tileHairlineWidth)
            )
    }

    /// Tap to rename (spec §3.2). A button rather than an inline field so the
    /// title reads as a title and VoiceOver announces one action.
    private var titleButton: some View {
        Button {
            shown.draftName = game.name
            shown.showRename = true
        } label: {
            titleLabel(game.name)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("gameNameButton")
        .accessibilityLabel("Rename \(game.name)")
    }

    /// Side by side where each button can hold the wider label on one line,
    /// stacked where it cannot (`GamePageMeasurements.buttonArrangement`).
    ///
    /// This was a `ViewThatFits`, which asks whether the two labels' natural
    /// widths fit side by side. Both buttons stretch, so a row is drawn as
    /// two equal halves, and wherever the sum fitted and twice the wider
    /// label did not, the labels wrapped: "Contin-" / "ue" and "New" /
    /// "Game" on a closed iPhone Duo held sideways at the default text size
    /// (issue #468), the fault the shelf's hero had in #424.
    private var actionsRow: some View {
        Group {
            switch measurements.buttonArrangement {
            case .row:
                HStack(spacing: ShelfHeroLayout.buttonRowSpacing) { primaryActions }
            case .column:
                VStack(spacing: PlayableDetailLayout.captionSpacing) { primaryActions }
            }
        }
    }

    // Title and icon, said outright: a `Label` the page draws in a form
    // row's background, where the gauges are, resolves to its icon alone,
    // and a gauge of icons measured both labels at 40 pt.
    private var continueLabel: some View {
        Label("Continue", systemImage: "clock.arrow.circlepath").labelStyle(.titleAndIcon)
    }

    private var newGameLabel: some View {
        Label("New Game", systemImage: "play.fill").labelStyle(.titleAndIcon)
    }

    /// Continue's and New Game's labels at their natural width, never drawn,
    /// read back as the wider of the two. From the views, not from `UIFont`,
    /// for the reason `captionProbe` gives; and a `fixedSize()` copy that no
    /// offer reaches, so nothing the row decides can move it (issues #437,
    /// #450). Labels only, so the buttons' identifiers are not doubled.
    private var actionLabelGauge: some View {
        VStack(alignment: .leading, spacing: 0) {
            continueLabel
            newGameLabel
        }
        .font(Theme.Typography.button)
        .lineLimit(1)
        .fixedSize()
        .hidden()
        .accessibilityHidden(true)
        .onGeometryChange(for: CGFloat.self) { proxy in
            ceil(proxy.size.width)
        } action: { width in
            actionLabelWidth = width
        }
    }

    /// Reports where an action button is drawn, for tests only.
    private func reportingFrame(_ id: String) -> some View {
        Color.clear.onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .global)
        } action: { frame in
            actionFrameReport?(id, frame)
        }
    }

    /// Continue and New Game with a resumable save; Play without one. The
    /// primary style carries the accent and its dark label (design-system
    /// spec §3) — this is the screen that shipped `.borderedProminent`'s
    /// white-on-green.
    @ViewBuilder
    private var primaryActions: some View {
        if continuableSlot != nil {
            Button {
                onPlay(game, .continueNewest)
            } label: {
                continueLabel
            }
            .buttonStyle(.waddlePrimary)
            .disabled(game.baseID == nil)
            .accessibilityIdentifier("continueButton")
            .background { reportingFrame("continueButton") }
            Button {
                onPlay(game, .newGame)
            } label: {
                newGameLabel
            }
            .buttonStyle(.waddleSecondary)
            .disabled(game.baseID == nil)
            .accessibilityIdentifier("playButton")
            .background { reportingFrame("playButton") }
        } else {
            Button {
                onPlay(game, .newGame)
            } label: {
                Label("Play", systemImage: "play.fill")
            }
            .buttonStyle(.waddlePrimary)
            .disabled(game.baseID == nil)
            .accessibilityIdentifier("playButton")
        }
    }

    @ViewBuilder
    private var baseSection: some View {
        Section {
            if game.isBaseGame {
                // Locked: this game *is* the IWAD (spec §3.2).
                LabeledContent("Base", value: baseName)
            } else {
                MenuPickerRow(title: "Base", current: baseSelectionName,
                              identifier: "basePicker", selection: $baseSelection) {
                    // Only offered while unpaired: once a game has a base,
                    // the picker must not be able to un-pair it back to none.
                    if game.baseID == nil {
                        Text("Choose a base game").tag(UUID?.none)
                    }
                    ForEach(baseGames, id: \.id) { wad in
                        Text(wad.displayName).tag(UUID?.some(wad.id))
                    }
                }
                .onChange(of: baseSelection) { _, newValue in
                    guard newValue != game.baseID else { return }
                    attempt(.base(newValue))
                }
            }
        } header: {
            WaddleSectionHeader("Base game")
        }
    }

    private var baseSelectionName: String {
        baseGames.first { $0.id == baseSelection }?.displayName ?? "Choose a base game"
    }

    private var baseName: String {
        guard let baseID = game.baseID else { return "None" }
        return (try? library.wad(id: baseID))?.displayName ?? "?"
    }

    private var filesSection: some View {
        Section {
            ForEach(files, id: \.id) { file in
                VStack(alignment: .leading, spacing: Theme.Spacing.xs / 2) {
                    WholeWordText(file.displayName)
                    Text(GamePage.roleLabel(for: file))
                        .font(Theme.Typography.caption)
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
                shown.showAddFile = true
            } label: {
                Label("Add…", systemImage: "plus")
            }
            .accessibilityIdentifier("addFileButton")
        } header: {
            WaddleSectionHeader("Maps & Add-ons")
        } footer: {
            Text("Load order, top to bottom.")
        }
    }

    private var settingsSection: some View {
        Section {
            MenuPickerRow(title: "Compatibility", current: complevel ?? "Auto",
                          identifier: "complevelPicker", selection: $complevel) {
                Text("Auto").tag(String?.none)
                ForEach(["vanilla", "boom", "mbf", "mbf21"], id: \.self) {
                    Text($0).tag(String?.some($0))
                }
            }
            .onChange(of: complevel) { _, newValue in
                guard newValue != game.complevel else { return }
                try? library.setComplevel(game, newValue)
            }
            MenuPickerRow(title: "Touch layout", current: scheme?.displayLabel ?? defaultSchemeLabel,
                          identifier: "schemePicker", selection: $scheme) {
                Text(defaultSchemeLabel).tag(TouchControlScheme?.none)
                Text("Classic").tag(TouchControlScheme?.some(.classic))
                Text("Modern").tag(TouchControlScheme?.some(.modern))
            }
            .onChange(of: scheme) { _, newValue in
                guard newValue?.rawValue != game.schemeOverrideRaw else { return }
                try? library.setSchemeOverride(newValue?.rawValue, for: game)
                onChanged()
            }
        }
    }

    private var defaultSchemeLabel: String {
        "Default (\(TouchControlScheme.current().displayLabel))"
    }

    @ViewBuilder
    private var savesSection: some View {
        Section {
            if saves.isEmpty {
                EmptyStateView(systemImage: "clock.arrow.circlepath", title: "No saves yet")
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
        } header: {
            WaddleSectionHeader(saves.isEmpty ? "Saves" : "Saves · \(saves.count)")
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
                    shown.deleteCandidate = game
                }
                .accessibilityIdentifier("deleteGameButton")
            }
        }
    }

    // MARK: Edits

    /// Attaches the file the Add… picker picked, once the picker has gone.
    private func addPickedFile() {
        // Not while this tree is being replaced: the picker going down with
        // its tree is not the player having finished with it.
        guard host.presents, let file = shown.pendingAdd else { return }
        shown.pendingAdd = nil
        attempt(.files(game.fileIDs + [file.id]))
    }

    /// Applies a base or file edit, or stages it behind the change-with-saves
    /// confirmation (spec §3.2).
    private func attempt(_ edit: GameEdit) {
        if GamePage.warnsBeforeApplying(edit, saveCount: saves.count) {
            shown.pendingEdit = edit
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
        // A base change still waiting on its warning, on a page another
        // tree has just redrawn after a fold: the picker shows what was
        // chosen, as it did when the warning went up.
        if case .base(let chosen)? = shown.pendingEdit { baseSelection = chosen }
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
    ///
    /// Through `host`, so that the dialog going down with a tree that a fold
    /// is replacing is not taken for a cancel: the edit stays pending and
    /// the next tree asks again (issue #429).
    private var pendingEditBinding: Binding<Bool> {
        host.presented({ shown.pendingEdit != nil },
                       dismiss: { shown.pendingEdit = nil; reload() })
    }

    private var addFileShown: Binding<Bool> {
        host.presented({ shown.showAddFile },
                       dismiss: { shown.showAddFile = false },
                       present: { shown.showAddFile = true })
    }
}

/// A row that picks one value from a menu.
///
/// At the ordinary text sizes it is the system's menu `Picker`, untouched. At
/// the accessibility sizes the system lays that picker's title over its value
/// and sizes the row as if the value were one line: a value that wraps
/// ("Freedoom" / "Phase 2") spilled out of the row both ways, and pushed the
/// title against the top edge of its card (issue #425). So there the row is
/// built here: a `Menu` whose label is the title over the value, ordinary
/// text the list can measure. The menu holds the same picker, so choosing is
/// unchanged.
private struct MenuPickerRow<Value: Hashable, Options: View>: View {
    let title: String
    /// The selected option's name, for the hand-built row to show.
    let current: String
    let identifier: String
    @Binding var selection: Value
    @ViewBuilder var options: Options
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            // The whole row is the menu's label, so a touch anywhere on it
            // opens the menu, as it does on the system's row.
            Menu {
                Picker(title, selection: $selection) { options }
            } label: {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    WholeWordText(title)
                        .foregroundStyle(Color.primary)
                    HStack(spacing: Theme.Spacing.sm) {
                        Text(current).multilineTextAlignment(.leading)
                        Image(systemName: "chevron.up.chevron.down").imageScale(.small)
                    }
                    .foregroundStyle(Color.appAccent)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // What the system's menu picker reads: "Touch layout, Default
            // (Classic)" as the label and no value (read off the default-size
            // row by `GamePageTests`, which holds this row to it).
            .accessibilityLabel("\(title), \(current)")
            .accessibilityIdentifier(identifier)
        } else {
            Picker(title, selection: $selection) { options }
                .pickerStyle(.menu)
                .accessibilityIdentifier(identifier)
        }
    }
}

/// The Add… picker (spec §3.2): every non-base file the game does not already
/// load, grouped by role. Picking one attaches it at the end of the load order.
struct AddFilePicker: View {
    let candidates: [WADFile]
    /// Pushed into the page's own stack instead of presented with one of its
    /// own: see where `GamePageView` opens it.
    var isPushed = false
    let onPick: (WADFile) -> Void
    @Environment(\.dismiss) private var dismiss

    private var mapSets: [WADFile] { candidates.filter { $0.role == .mapSet } }
    private var addOns: [WADFile] { candidates.filter { $0.role == .addOn } }

    var body: some View {
        if isPushed {
            list
        } else {
            NavigationStack {
                list.toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
            }
        }
    }

    private var list: some View {
        List {
            if candidates.isEmpty {
                EmptyStateView(systemImage: "tray",
                               title: "Every file you've imported is already in this game.")
            }
            if !mapSets.isEmpty {
                Section { rows(mapSets) } header: { WaddleSectionHeader("Map sets") }
            }
            if !addOns.isEmpty {
                Section { rows(addOns) } header: { WaddleSectionHeader("Add-ons") }
            }
        }
        .waddleScrollSurface()
        .navigationTitle("Add to Game")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func rows(_ files: [WADFile]) -> some View {
        ForEach(files, id: \.id) { file in
            Button {
                onPick(file)
                dismiss()
            } label: {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs / 2) {
                    WholeWordText(file.displayName)
                    Text(GamePage.roleLabel(for: file))
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Color.appSecondaryText)
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
