import SwiftUI

/// The two button treatments the shell draws itself (design-system spec §3).
///
/// Primary is the one accent, worn by the primary action of whichever screen
/// is showing: Add Your Games on a factory shelf, Continue or Play on the game
/// page. Secondary is the surface tone with the hairline, for the action that
/// sits next to it (New Game beside Continue).
///
/// Why a style of our own rather than `.borderedProminent`: the accent is a
/// light green, and the system style's default white label measures 1.29:1
/// against it. The shelf fixed that with a `.foregroundStyle(.black)` at one
/// call site; the game page did not, and shipped the contrast failure. A
/// style that sets `Theme.onAccent` itself cannot be forgotten at the next
/// call site.
struct WaddlePrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Typography.button)
            .foregroundStyle(Theme.onAccent)
            .padding(.horizontal, Theme.Spacing.base)
            .padding(.vertical, Theme.buttonVerticalPadding)
            .frame(maxWidth: .infinity, minHeight: Theme.minimumTapTarget)
            .background(Color.appAccent,
                        in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
            .opacity(configuration.isPressed ? 0.8 : (isEnabled ? 1 : 0.4))
            .contentShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
    }
}

struct WaddleSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Typography.button)
            .foregroundStyle(.white)
            .padding(.horizontal, Theme.Spacing.base)
            .padding(.vertical, Theme.buttonVerticalPadding)
            .frame(maxWidth: .infinity, minHeight: Theme.minimumTapTarget)
            .background(Color.appSurface,
                        in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .strokeBorder(Color.appHairline, lineWidth: Theme.tileHairlineWidth)
            )
            .opacity(configuration.isPressed ? 0.8 : (isEnabled ? 1 : 0.4))
            .contentShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
    }
}

extension ButtonStyle where Self == WaddlePrimaryButtonStyle {
    static var waddlePrimary: WaddlePrimaryButtonStyle { WaddlePrimaryButtonStyle() }
}

extension ButtonStyle where Self == WaddleSecondaryButtonStyle {
    static var waddleSecondary: WaddleSecondaryButtonStyle { WaddleSecondaryButtonStyle() }
}
