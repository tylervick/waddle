import SwiftUI

/// The usage counts the diagnostics export carries (issue #487), shown before
/// any export so the user can see exactly what a shared file would say, and
/// reset them. The rows are `UsageSummary.rows`, the same ones info.txt
/// prints.
struct UsageSummaryView: View {
    /// Where the reset confirmation is kept when Settings is the shelf's
    /// panel (`PanelPresentation.swift`); nil keeps it here.
    var presentation: SettingsPresentation?
    @State private var ownPresentation = SettingsPresentation()
    private var shown: SettingsPresentation { presentation ?? ownPresentation }
    @Environment(\.panelHost) private var host

    var store: UsageStore = .shared
    @State private var summary = UsageSummary()

    var body: some View {
        List {
            Section {
                ForEach(Array(summary.rows.enumerated()), id: \.offset) { _, row in
                    LabeledContent(row.label, value: row.value)
                        .accessibilityIdentifier("usageRow: \(row.label)")
                }
            } footer: {
                Text("Counted only on this device. These counts are included in the diagnostics file when you export it, and go nowhere otherwise.")
            }
            Section {
                Button("Reset Usage Counts", role: .destructive) {
                    shown.confirmUsageReset = true
                }
                .accessibilityIdentifier("resetUsageCountsButton")
            }
        }
        .waddleScrollSurface()
        .navigationTitle("Usage Summary")
        .accessibilityIdentifier("usageSummaryView")
        .onAppear { summary = store.summary() }
        .confirmationDialog("Reset usage counts?",
                            isPresented: host.presented({ shown.confirmUsageReset },
                                                        dismiss: { shown.confirmUsageReset = false }),
                            titleVisibility: .visible) {
            Button("Reset Usage Counts", role: .destructive) {
                store.reset()
                summary = store.summary()
            }
            .accessibilityIdentifier("confirmResetUsageCountsAction")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every count goes back to zero. Your games, files and saves are not affected.")
        }
    }
}
