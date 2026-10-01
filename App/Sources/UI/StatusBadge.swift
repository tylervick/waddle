import SwiftUI

/// A small capsule that names a state (design-system spec §3): "Needs a base
/// game" on a tile, "no base" on a Files row.
///
/// The tones are semantic, not decorative. Before this existed the tile badge
/// wore the accent — which spec §5 reserves for primary actions, so a warning
/// looked like a Play button — and the Files badge wore a 35 % red of its
/// own. One component, three tones, and the colours come from the catalog.
struct StatusBadge: View {
    enum Tone {
        /// Needs attention, not broken: amber, dark label.
        case warning
        /// Broken or gone: red, dark label.
        case danger
        /// Just a label: the surface tone, white text.
        case neutral
    }

    let text: String
    let tone: Tone

    init(_ text: String, tone: Tone) {
        self.text = text
        self.tone = tone
    }

    var body: some View {
        Text(text)
            .font(Theme.Typography.badge)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .foregroundStyle(foreground)
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.vertical, Theme.Spacing.xs)
            .background(fill, in: Capsule())
    }

    private var fill: Color {
        switch tone {
        case .warning: return .appWarning
        case .danger: return .appDanger
        case .neutral: return .appSurface
        }
    }

    private var foreground: Color {
        switch tone {
        case .warning, .danger: return Theme.onAccent
        case .neutral: return .white
        }
    }
}
