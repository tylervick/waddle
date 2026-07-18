import SwiftUI
import WoofEngine

struct ContentView: View {
    let library: LibraryService
    let importer: ImportService
    @State private var lastExitCode: Int32?

    var body: some View {
        TabView {
            // NOTE on tab-bar accessibility identifiers (iOS 26 "Liquid
            // Glass" TabView): the native tab bar button is reconstructed by
            // the system from the tabItem's icon/title; it does NOT inherit
            // SwiftUI identifiers/modifiers set on the tabItem content
            // (verified empirically — neither `.tabItem { Label(...)
            // .accessibilityIdentifier(...) }` nor `Tab(...)
            // .accessibilityIdentifier(...)` reach the rendered button). The
            // identifiers below land on each tab's content-pane container
            // instead, which IS reachable once that tab is showing. UI tests
            // must switch tabs by the button's label text
            // (`app.tabBars.buttons["Play"].tap()` / `["Library"].tap()`);
            // use `app.otherElements["playTab"]` / `["libraryTab"]` to assert
            // which tab's content is now on screen.
            LoadoutGridView(library: library, lastExitCode: $lastExitCode)
                .tabItem {
                    Label("Play", systemImage: "play.circle.fill")
                }
                .accessibilityIdentifier("playTab")

            LibraryView(library: library, importer: importer)
                .tabItem {
                    Label("Library", systemImage: "books.vertical")
                }
                .accessibilityIdentifier("libraryTab")
        }
        .overlay(alignment: .bottom) {
            if let notice = ImportNotices.shared.current {
                Text(notice)
                    .font(.footnote)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.thinMaterial, in: Capsule())
                    .accessibilityIdentifier("importNoticeBanner")
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
            if ProcessInfo.processInfo.environment["BOOMBOX_DEBUG_INPUT_COUNTS"] != nil,
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
            }
        }
    }
}
