import SwiftUI

/// What a list says when it has nothing to list (design-system spec §3): a
/// glyph, a line, and optionally a hint about how to change that.
///
/// Compact on purpose — an icon beside the text rather than a centred stack —
/// so it reads the same inside a form section ("No saves yet") as it does on
/// an otherwise empty screen, and a section does not grow a tall placeholder
/// that pushes the rows under it off the fold.
struct EmptyStateView: View {
    let systemImage: String
    let title: String
    var hint: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.md) {
            Image(systemName: systemImage)
                .font(Theme.Typography.secondary)
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text(title)
                    .font(Theme.Typography.secondary)
                if let hint {
                    Text(hint)
                        .font(Theme.Typography.caption)
                }
            }
        }
        .foregroundStyle(Color.appSecondaryText)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
