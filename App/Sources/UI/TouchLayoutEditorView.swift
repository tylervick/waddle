import SwiftUI

/// Full-screen drag-and-drop editor for the touch overlay's button positions
/// (issue #115), opened from Control Feel's "Edit Layout…". The canvas is the
/// UIKit `TouchLayoutEditorCanvas`, filling the screen under the safe areas
/// so its geometry is the session overlay's; a small pill at the top centre
/// carries Cancel, Reset and Done (`TouchLayoutEditorToolbar`). Top centre
/// because that is the one band the default arrangement leaves empty in both
/// orientations: MAP and MENU hold the corners, the clusters are at the bottom.
///
/// Done saves (`TouchOverlayLayoutOverrides.save`), Cancel discards, Reset
/// shows the defaults live and is saved by Done like any other change.
struct TouchLayoutEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var overrides = TouchOverlayLayoutOverrides.current()

    var body: some View {
        ZStack(alignment: .top) {
            TouchLayoutEditorCanvasRepresentable(overrides: $overrides)
                .ignoresSafeArea()

            // The reader's size is the window less its safe area, which is
            // the rect the canvas lays MAP and MENU out in.
            GeometryReader { proxy in
                VStack(spacing: 6) {
                    TouchLayoutEditorToolbar(
                        cancel: { dismiss() },
                        reset: { overrides = .none },
                        done: {
                            overrides.save()
                            dismiss()
                        })

                    Text("Drag a button where your thumb wants it.")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.6))
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: TouchLayoutEditorToolbar.availableWidth(in: proxy.size))
                .padding(.top, 4)
                .frame(maxWidth: .infinity)
            }
        }
        .tint(.white)
        .preferredColorScheme(.dark)
        .background(Color.black)
    }
}

/// Cancel, Reset and Done, in the pill at the top of the layout editor.
///
/// The band between MAP and MENU is narrow on a phone held upright
/// (`availableWidth(in:)`), and the three words do not fit across it at every
/// text size: at the largest accessibility size they need about 480 pt. A row
/// that is merely squeezed breaks each word two letters to a line (issue
/// #422), so the words are never squeezed. Each is one line at its own width,
/// and when the row does not fit the offered width the three stand in a
/// column instead, which fits at every size.
struct TouchLayoutEditorToolbar: View {
    /// Kept clear between the toolbar and each of MAP and MENU.
    static let clearance: CGFloat = 8
    /// Never offered less than this, however small the window: narrower than
    /// one word at a large text size helps nobody.
    static let minimumWidth: CGFloat = 120

    /// The widest the toolbar and the hint under it may be in a window whose
    /// safe area is `safeAreaSize`: the band between MAP and MENU where the
    /// overlay puts them by default, less `clearance` on each side. It was a
    /// fixed 260 pt, which is wider than that band on the narrowest phone and
    /// a small part of it on an open iPhone Duo.
    static func availableWidth(in safeAreaSize: CGSize) -> CGFloat {
        let layout = TouchOverlayLayout(bounds: CGRect(origin: .zero, size: safeAreaSize),
                                        safeAreaInsets: .zero, hudReserve: 0)
        let band = layout.defaultFrame(for: .menu).minX - layout.defaultFrame(for: .automap).maxX
        return max(minimumWidth, band - clearance * 2)
    }

    static let rowSpacing: CGFloat = 18
    static let columnSpacing: CGFloat = 10
    static let horizontalPadding: CGFloat = 16
    static let verticalPadding: CGFloat = 8
    /// The column's corner radius. A capsule that tall is round for its
    /// whole width at each end, and would cut across the first and last word.
    static let columnCornerRadius: CGFloat = 22

    let cancel: () -> Void
    let reset: () -> Void
    let done: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Self.rowSpacing) { buttons }
                .padding(.horizontal, Self.horizontalPadding)
                .padding(.vertical, Self.verticalPadding)
                .background(Color.white.opacity(0.12), in: Capsule())
            VStack(spacing: Self.columnSpacing) { buttons }
                .padding(.horizontal, Self.horizontalPadding)
                .padding(.vertical, Self.verticalPadding)
                .background(Color.white.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: Self.columnCornerRadius))
        }
    }

    /// `fixedSize` is what keeps a word whole: without it a label offered
    /// less than its width wraps inside the word rather than overflow.
    @ViewBuilder private var buttons: some View {
        Button("Cancel", action: cancel)
            .lineLimit(1)
            .fixedSize()
            .accessibilityIdentifier("layoutEditorCancelButton")
        Button("Reset", action: reset)
            .lineLimit(1)
            .fixedSize()
            .accessibilityIdentifier("layoutEditorResetButton")
        Button("Done", action: done)
            .fontWeight(.semibold)
            .lineLimit(1)
            .fixedSize()
            .accessibilityIdentifier("layoutEditorDoneButton")
    }
}

/// Hosts the UIKit canvas and keeps the SwiftUI copy of the table and the
/// canvas's working copy equal in both directions: a drag reports up through
/// `onChange`, Reset flows down through `updateUIView`. Equality is checked
/// before writing down so the round trip settles instead of looping.
private struct TouchLayoutEditorCanvasRepresentable: UIViewRepresentable {
    @Binding var overrides: TouchOverlayLayoutOverrides

    func makeUIView(context: Context) -> TouchLayoutEditorCanvas {
        let canvas = TouchLayoutEditorCanvas(overrides: overrides)
        canvas.onChange = { overrides = $0 }
        return canvas
    }

    func updateUIView(_ canvas: TouchLayoutEditorCanvas, context: Context) {
        if canvas.overrides != overrides {
            canvas.overrides = overrides
        }
    }
}
