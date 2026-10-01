#if DEBUG
import SwiftUI

/// The design system's components, one canvas each, in every state they have
/// (design-system spec §3). The repo has no automated eye, so this is where a
/// human one plugs in before trusting that a token change still composes —
/// `docs/learnings/geometry-tests-cannot-see-the-screen.md`.
private struct ComponentSheet: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.section) {
                group("Buttons") {
                    Button("Continue") {}.buttonStyle(.waddlePrimary)
                    Button("New Game") {}.buttonStyle(.waddleSecondary)
                    HStack(spacing: Theme.Spacing.md) {
                        Button("Continue") {}.buttonStyle(.waddlePrimary)
                        Button("New Game") {}.buttonStyle(.waddleSecondary)
                    }
                    Button("Play") {}.buttonStyle(.waddlePrimary).disabled(true)
                }
                group("Badges") {
                    HStack(spacing: Theme.Spacing.sm) {
                        StatusBadge("Needs a base game", tone: .warning)
                        StatusBadge("Missing", tone: .danger)
                        StatusBadge("Bundled", tone: .neutral)
                    }
                }
                group("Empty state") {
                    EmptyStateView(systemImage: "clock.arrow.circlepath", title: "No saves yet")
                    EmptyStateView(systemImage: "eye.slash", title: "Nothing is hidden.",
                                   hint: "Long-press a tile on the shelf to hide it.")
                }
                group("Card") {
                    VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                        Text("Bring your own WADs, or start with the Freedoom games below.")
                            .font(Theme.Typography.secondary)
                            .foregroundStyle(Color.appSecondaryText)
                        Button("Add Your Games") {}.buttonStyle(.waddlePrimary)
                    }
                    .waddleCard()
                }
                group("Type") {
                    Text("Hero title").font(Theme.Typography.heroTitle)
                    Text("Tile title").font(Theme.Typography.tileTitle)
                    Text("Body").font(.body)
                    Text("Secondary").font(Theme.Typography.secondary)
                        .foregroundStyle(Color.appSecondaryText)
                    Text("Caption").font(Theme.Typography.caption)
                        .foregroundStyle(Color.appSecondaryText)
                    Text("mono 798acebd").font(Theme.Typography.mono)
                        .foregroundStyle(Color.appSecondaryText)
                }
                group("Wordmark") {
                    Image("WaddleWordmark")
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(height: Theme.wordmarkHeight)
                }
            }
            .padding(Theme.Spacing.base)
        }
        .background(Color.appBackground)
        .preferredColorScheme(.dark)
    }

    private func group<Content: View>(_ title: String,
                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            WaddleSectionHeader(title)
            content()
        }
    }
}

#Preview("Components") {
    ComponentSheet()
}

#Preview("Components, accessibility3") {
    ComponentSheet()
        .dynamicTypeSize(.accessibility3)
}
#endif
