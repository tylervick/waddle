import SwiftUI
import WoofEngine

struct ContentView: View {
    let library: LibraryService
    let importer: ImportService
    @State private var lastExitCode: Int32?
    /// The shelf's panel (issue #372). Owned here because the inspector that
    /// shows it has to sit outside the shelf's `NavigationStack`; see
    /// `ShelfPanelModel`.
    @State private var panelModel = ShelfPanelModel()
    /// The two halves of the window while an iPhone Duo stands half open
    /// with the fold across it, and nil otherwise (issue #429). From
    /// `LauncherFoldReader`: the device and the window, never the content.
    @State private var halves: HalfOpenSplit?
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        // One stack, one screen: the shelf is the app's home, and management is
        // a door off it rather than a co-equal tab (spec §§2–3). The former
        // two-tab `TabView` and its iOS 26 tab-bar identifier workaround are
        // gone with it — nothing addresses a tab bar any more.
        //
        // Half open, the launcher parts at the fold the way the session does
        // (issue #429): the shelf keeps the upper half and the panel has the
        // lower one. The stack's place in the tree is the same in both
        // arrangements, so bending the device or opening it flat moves the
        // shelf without rebuilding it. Flat, `halves` is nil, the column has
        // one child at its own size and the safe area is left alone.
        VStack(spacing: 0) {
            shelfStack
                .frame(height: halves?.pictureArea.height)
                #if DEBUG
                .background(alignment: .bottomLeading) { halfMarker("launcherUpperHalf") }
                #endif
            if let halves {
                // The band: nothing of ours is drawn on it.
                Color.clear.frame(height: halves.crease.height)
                LowerHalfPanelView(model: panelModel, library: library)
                    .frame(height: halves.controlsArea.height)
                    #if DEBUG
                    .background(alignment: .topLeading) { halfMarker("launcherLowerHalf") }
                    #endif
            }
        }
        // The reader is the size of this column, which is the window inside
        // its safe area, so the halves it reports are measured from where
        // the column starts and add up to its height. Each half's bars then
        // reach out under the status bar and the home indicator on their
        // own, as the one stack does when the device is flat. (A column that
        // ignored the safe area took the insets from the bars inside it too,
        // and the shelf's wordmark went under the status bar.)
        .onChange(of: horizontalSizeClass, initial: true) { old, sizeClass in
            // Unfolding an iPhone Duo with nothing open leaves an empty
            // column up; the model deals with it. See `systemSetPresented`.
            let isRegular = sizeClass == .regular
            let wasCompact = old == .compact
            panelModel.windowWidthChanged(isRegular: isRegular,
                                          becameRegular: wasCompact && isRegular)
        }
        .overlay(alignment: .bottom) {
            if let notice = ImportNotices.shared.current {
                ImportNoticeBanner(text: notice)
                    .accessibilityIdentifier("importNoticeBanner")
                    .onTapGesture { ImportNotices.shared.dismiss() }
                    // Clear of the window's edges, so a wrapped banner is an
                    // object on the shelf and not a band across it.
                    .padding(.horizontal, Theme.Spacing.base)
                    .padding(.bottom, 100)
            }
            if let code = lastExitCode {
                VStack(spacing: Theme.Spacing.sm) {
                    #if DEBUG
                    sessionStartDebugStack
                    #endif
                    Text("Engine exited: \(code)")
                        .font(Theme.Typography.mono)
                        .padding(.horizontal, Theme.Spacing.md)
                        .padding(.vertical, Theme.Spacing.sm)
                        .waddleBanner()
                        .accessibilityIdentifier("engineExitLabel")
                }
                .padding(.bottom, 60)
            }
            #if DEBUG
            if ProcessInfo.processInfo.environment["WADDLE_DEBUG_INPUT_COUNTS"] != nil,
               lastExitCode != nil {
                Text("touchEvents: \(WoofIOS_DebugTouchEventCount())")
                    .font(.footnote.monospaced())
                    .accessibilityIdentifier("touchEventCountLabel")
                    .padding(.bottom, 100)
                // The same writes, per control (issue #48), so a test can say
                // WHICH button or axis an input reached. verbatim: the
                // string is the engine's own.
                Text(verbatim: String(cString: WoofIOS_DebugTouchWrites()))
                    .font(.footnote.monospaced())
                    .accessibilityIdentifier("touchWritesLabel")
                // Auto-use (issue #114): the switch as the engine saw it and
                // the presses it made, read after the session.
                Text(verbatim: String(cString: WoofIOS_DebugAutoUseState()))
                    .font(.footnote.monospaced())
                    .accessibilityIdentifier("autoUseLabel")
                // Cached mid-session (TouchGamepad.lastFireReleaseTriggerResidue) --
                // WoofIOS_DebugTriggerValue() itself would just return -1 by
                // now, since the session that attached the touch gamepad
                // has already torn it down.
                if let residue = TouchGamepad.lastFireReleaseTriggerResidue {
                    Text("triggerResidue: \(residue)")
                        .font(.footnote.monospaced())
                        .accessibilityIdentifier("triggerResidueLabel")
                        .padding(.bottom, 130)
                }
                // Cached for the same reason as the residue above: the
                // overlay is gone by the time this is on screen, so the
                // count has to survive the session rather than be queried
                // from it.
                Text("buttonPresses: \(OverlayButton.debugPressCount)")
                    .font(.footnote.monospaced())
                    .accessibilityIdentifier("buttonPressCountLabel")
                    .padding(.bottom, 160)
            }
            // Same seam family: the engine's menu tables as the next session
            // will inherit them. They are process-lifetime statics, so reading
            // them after the session ended is the point (issue #253).
            if ProcessInfo.processInfo.environment["WADDLE_DEBUG_MENU_GEOMETRY"] != nil,
               lastExitCode != nil {
                Text(String(cString: WoofIOS_DebugMenuGeometry()))
                    .font(.footnote.monospaced())
                    .accessibilityIdentifier("menuGeometryLabel")
                    .padding(.bottom, 190)
            }
            // And what the session that just ended started with, captured by
            // the engine at the start of its game loop (issue #266).
            #endif
        }
        // Always dark, and set once at the root so it reaches the sheets,
        // dialogs and alerts presented from anywhere below (spec §5). The
        // engine the shell hands off to is dark; a launcher that followed the
        // system setting would flash white between worlds. The semantic
        // colorsets in `Theme` are appearance-agnostic on their own — this is
        // what settles the system-drawn chrome around them.
        .preferredColorScheme(.dark)
    }

    /// The shelf in its navigation stack, with the inspector that is its
    /// panel everywhere but in two halves.
    private var shelfStack: some View {
        NavigationStack {
            ShelfView(library: library, importer: importer, lastExitCode: $lastExitCode,
                      panelModel: panelModel)
        }
        // A trailing column beside the shelf on a regular-width window, and a
        // sheet on a compact one. The shelf only opens it on a regular-width
        // window, so the sheet form is what a panel becomes when an iPhone
        // Duo is folded with it open: nothing is lost, and unfolding brings
        // the column back.
        .inspector(isPresented: Binding(
            get: { panelModel.isPresented },
            set: { panelModel.systemSetPresented($0) }
        )) {
            ShelfPanelView(model: panelModel, library: library)
                .inspectorColumnWidth(min: 320, ideal: 376, max: 420)
        }
    }

    #if DEBUG
    /// Where a half meets the band, for `HalfOpenLauncherTests` to read: the
    /// corner-marker pattern the touch overlay uses, a 2 pt element in the
    /// half's corner on the band's side, and only while the launcher is
    /// parted. Not the size of the half: an element that large answered the
    /// accessibility hit test for everything in front of it, and the shelf's
    /// own buttons stopped being hittable to a UI test.
    @ViewBuilder private func halfMarker(_ identifier: String) -> some View {
        if halves != nil {
            Color.clear
                .frame(width: 2, height: 2)
                .accessibilityElement()
                .accessibilityIdentifier(identifier)
        }
    }
    #endif

    #if DEBUG
    /// The engine's session-state readouts (issues #266, #268, #269, #111), shown
    /// just above the exit label after a session when WADDLE_DEBUG_SESSION_START
    /// is set. Stacked with the label rather than given their own bottom
    /// paddings: the session-start line wraps to three lines on a phone, and
    /// separately padded labels overlapped each other and the exit label.
    /// XCUITest reads them by identifier and never noticed; the Revyl agent
    /// reads the screen and could not (#277). Opaque, because it lands on tile
    /// art.
    @ViewBuilder private var sessionStartDebugStack: some View {
        if ProcessInfo.processInfo.environment["WADDLE_DEBUG_SESSION_START"] != nil {
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: String(cString: WoofIOS_DebugAutomapBounds()))
                    .accessibilityIdentifier("automapBoundsLabel")
                Text(verbatim: String(cString: WoofIOS_DebugSessionEntryState()))
                    .accessibilityIdentifier("sessionEntryStateLabel")
                Text(verbatim: String(cString: WoofIOS_DebugDehNow()))
                    .accessibilityIdentifier("dehNowLabel")
                Text(verbatim: String(cString: WoofIOS_DebugLevelStateNow()))
                    .accessibilityIdentifier("levelStateNowLabel")
                // verbatim: a localized interpolation would print 1,500. The
                // player's cheat flags (issue #304) share this line rather than
                // taking one of their own: the stack sits on the tile row, and
                // one more line put it over the tiles' tap points, so every
                // two-session UI test failed on "previous exit label never
                // cleared" (docs/learnings/post-session-debug-stack-covers-the-tiles.md).
                Text(verbatim: "zowned=\(WoofIOS_DebugSessionStartZoneKB()) zlumps=\(WoofIOS_DebugSessionStartLumpsKB()) "
                     + String(cString: WoofIOS_DebugPlayerCheatsNow()))
                    .accessibilityIdentifier("sessionStartZoneLabel")
                Text(verbatim: String(cString: WoofIOS_DebugSessionStartState()))
                    .accessibilityIdentifier("sessionStartStateLabel")
                Text(verbatim: String(cString: WoofIOS_DebugZipWadBuffers()))
                    .accessibilityIdentifier("zipWadBuffersLabel")
                Text(verbatim: String(cString: WoofIOS_DebugBackgroundState()))
                    .accessibilityIdentifier("backgroundStateLabel")
            }
            .font(.footnote.monospaced())
            .padding(8)
            .background(.black, in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 16)
            // Readable, never tappable: a tile under the stack must still
            // start a session when a test taps its frame (same learning).
            .allowsHitTesting(false)
        }
    }
    #endif
}
