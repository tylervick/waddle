import SwiftUI

/// Full-screen drag-and-drop editor for the touch overlay's button positions
/// (issue #115), opened from Control Feel's "Edit Layout…". The canvas is the
/// UIKit `TouchLayoutEditorCanvas`, filling the screen under the safe areas
/// so its geometry is the session overlay's; a small pill at the top centre
/// carries Cancel, Reset and Done. Top centre because that is the one band
/// the default arrangement leaves empty in both orientations: MAP and MENU
/// hold the corners, the clusters are at the bottom.
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

            VStack(spacing: 6) {
                HStack(spacing: 18) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("layoutEditorCancelButton")
                    Button("Reset") { overrides = .none }
                        .accessibilityIdentifier("layoutEditorResetButton")
                    Button("Done") {
                        overrides.save()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .accessibilityIdentifier("layoutEditorDoneButton")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.12), in: Capsule())

                Text("Drag a button where your thumb wants it.")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.6))
            }
            .frame(maxWidth: 260)
            .padding(.top, 4)
        }
        .tint(.white)
        .preferredColorScheme(.dark)
        .background(Color.black)
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
