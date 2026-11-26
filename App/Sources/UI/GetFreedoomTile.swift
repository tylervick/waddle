import SwiftUI
import UIKit

/// The tile that offers Freedoom to a shelf without it (#552): Freedoom's
/// title art, **Freedoom** with **Free · 24.1 MB** under it, and **Get**. It
/// is not a game. A tap downloads the release (`GetFreedoom`), and the two
/// Freedoom games take its place once they arrive.
///
/// Drawn as a shelf tile is (`PlayableTileView`): the same shape, radius,
/// hairline and scrim, so it sits in the grid as one of them. The art ships
/// in the app (`FreedoomTitle`, extracted by
/// `Scripts/extract-freedoom-titlepic.py`), because a player who has no
/// Freedoom has no WAD to read it from.
struct GetFreedoomTile: View {
    let state: GetFreedoom.State
    /// **From a Link…** is downloading: **Get** waits.
    var isBlocked = false
    var aspectRatio: CGFloat = Theme.tileAspectRatio
    var onGet: () -> Void = {}
    var onCancel: () -> Void = {}

    var body: some View {
        Color.appSurface
            .aspectRatio(aspectRatio, contentMode: .fit)
            .overlay { art }
            .clipped()
            .overlay(alignment: .bottom) { scrim }
            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .strokeBorder(Color.appHairline, lineWidth: Theme.tileHairlineWidth)
            )
            .contentShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
            // The whole tile is the target while it offers, as a game's tile
            // is; the button is where it says so.
            .onTapGesture { if case .offered = state, !isBlocked { onGet() } }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("getFreedoomTile")
    }

    // MARK: Art

    @ViewBuilder
    private var art: some View {
        if let image = Self.titleImage {
            Image(decorative: TitleArtView.croppedToAspect(image, aspectRatio), scale: 1)
                .resizable()
        }
    }

    /// Freedoom Phase 1's TITLEPIC at its own 320×200 pixels, cropped by
    /// the tile as `TitleArtView` crops a game's.
    private static let titleImage: CGImage? = UIImage(named: "FreedoomTitle")?.cgImage

    // MARK: Scrim

    private var scrim: some View {
        // One row where the words and the button fit side by side, and the
        // button under them where they do not (an accessibility text size):
        // a squeezed row would wrap each text in a column of its own
        // (`docs/learnings/a-squeezed-row-of-texts-hyphenates-and-a-fixed-share-truncates.md`).
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .bottom, spacing: Theme.Spacing.xs) {
                words.fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 0)
                control
            }
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                words
                control
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, PlayableTileLayout.scrimHorizontalPadding)
        .padding(.top, PlayableTileLayout.scrimTopPadding)
        .padding(.bottom, PlayableTileLayout.scrimBottomPadding)
        .background(
            LinearGradient(stops: [.init(color: .black.opacity(0), location: 0),
                                   .init(color: .black.opacity(0.75), location: 0.55),
                                   .init(color: .black.opacity(0.92), location: 1)],
                           startPoint: .top, endPoint: .bottom)
        )
    }

    private var words: some View {
        VStack(alignment: .leading, spacing: PlayableTileLayout.titleSubtitleSpacing) {
            Text("Freedoom")
                .font(Theme.Typography.tileTitle)
                .foregroundStyle(.white)
                .lineLimit(1)
            Text(subtitle)
                .font(Theme.Typography.caption)
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(1)
                .accessibilityIdentifier("getFreedoomSubtitle")
            if case .offered(let failure?) = state {
                Text(failure)
                    .font(Theme.Typography.caption.weight(.semibold))
                    .foregroundStyle(Color.appWarning)
                    .lineLimit(1)
                    .accessibilityIdentifier("getFreedoomFailure")
            }
        }
    }

    /// The line under the title: the size before the tap, then how far the
    /// download has got, then what is happening to it.
    private var subtitle: String {
        switch state {
        case .offered:
            return "Free · \(FreedoomRelease.sizeText)"
        case .downloading(let received, let expected):
            let total = expected.flatMap { $0 > 0 ? $0 : nil } ?? FreedoomRelease.byteCount
            // "9.7 of 24.1 MB": one unit, so the line stays short enough to
            // sit beside the ring in a phone's two-column tile.
            return "\(Self.megabytes(received, unit: false)) of \(Self.megabytes(total, unit: true))"
        case .importing:
            return "Adding…"
        }
    }

    @ViewBuilder
    private var control: some View {
        switch state {
        case .offered:
            Button(action: onGet) {
                Text("Get")
                    .font(.subheadline.bold())
                    .lineLimit(1)
                    .fixedSize()
                    .foregroundStyle(Theme.onAccent)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Color.appAccent, in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(isBlocked)
            .opacity(isBlocked ? 0.4 : 1)
            .accessibilityLabel("Get Freedoom, free, \(FreedoomRelease.sizeText)")
            .accessibilityHint(isBlocked ? "Waits for the download from a link to finish." : "")
            .accessibilityIdentifier("getFreedoomButton")
        case .downloading(let received, let expected):
            Button(action: onCancel) {
                ProgressRing(fraction: Self.fraction(received, expected))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel Download")
            .accessibilityValue("\(Int((Self.fraction(received, expected) * 100).rounded())) percent")
            .accessibilityIdentifier("getFreedoomCancel")
        case .importing:
            ProgressView()
                .tint(.white)
                .frame(width: ProgressRing.side, height: ProgressRing.side)
                .accessibilityLabel("Adding Freedoom")
                .accessibilityIdentifier("getFreedoomAdding")
        }
    }

    private static func fraction(_ received: Int64, _ expected: Int64?) -> Double {
        let total = expected.flatMap { $0 > 0 ? $0 : nil } ?? FreedoomRelease.byteCount
        return min(1, max(0, Double(received) / Double(total)))
    }

    private static func megabytes(_ bytes: Int64, unit: Bool) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = .useMB
        formatter.includesUnit = unit
        formatter.zeroPadsFractionDigits = true
        return formatter.string(fromByteCount: bytes)
    }
}

/// A download's progress round a stop square, the shape the system uses for
/// a download that a tap cancels.
private struct ProgressRing: View {
    let fraction: Double
    @ScaledMetric(relativeTo: .subheadline) private var scaledSide: CGFloat = 30
    static let side: CGFloat = 30

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.25), lineWidth: 3)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(Color.appAccent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.appAccent)
                .frame(width: scaledSide * 0.3, height: scaledSide * 0.3)
        }
        .frame(width: scaledSide, height: scaledSide)
        .contentShape(Circle())
    }
}
