import SwiftUI
import WoofEngine

struct ContentView: View {
    let library: LibraryService
    let importer: ImportService
    @State private var lastExitCode: Int32?

    var body: some View {
        // One stack, one screen: the shelf is the app's home, and management is
        // a door off it rather than a co-equal tab (spec §§2–3). The former
        // two-tab `TabView` and its iOS 26 tab-bar identifier workaround are
        // gone with it — nothing addresses a tab bar any more.
        NavigationStack {
            ShelfView(library: library, importer: importer, lastExitCode: $lastExitCode)
        }
        .overlay(alignment: .bottom) {
            if let notice = ImportNotices.shared.current {
                Text(notice)
                    .font(.footnote)
                    .padding(.horizontal, 16)
                    .frame(minHeight: Theme.minimumTapTarget)
                    .background(.thinMaterial, in: Capsule())
                    .accessibilityIdentifier("importNoticeBanner")
                    // The banner is tappable to dismiss, so it is one of the
                    // controls the shell draws itself and owes spec §5's 44 pt
                    // minimum; `contentShape` makes the whole capsule hittable
                    // rather than just the glyphs.
                    .contentShape(Capsule())
                    .onTapGesture { ImportNotices.shared.dismiss() }
                    .padding(.bottom, 100)
            }
            if let code = lastExitCode {
                Text("Engine exited: \(code)")
                    .font(.footnote.monospaced())
                    .padding(6)
                    .background(.thinMaterial, in: Capsule())
                    .accessibilityIdentifier("engineExitLabel")
                    .padding(.bottom, 60)
            }
            #if DEBUG
            if ProcessInfo.processInfo.environment["WADDLE_DEBUG_INPUT_COUNTS"] != nil,
               lastExitCode != nil {
                Text("touchEvents: \(WoofIOS_DebugTouchEventCount())")
                    .font(.footnote.monospaced())
                    .accessibilityIdentifier("touchEventCountLabel")
                    .padding(.bottom, 100)
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
}
