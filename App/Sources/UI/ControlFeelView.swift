import SwiftUI

/// Touch-control tuning sliders ("Control Feel…" in the Play tab's gear
/// menu). Writes the same @AppStorage keys TouchTuning.current() reads at
/// overlay-install time; values apply when the next engine session starts.
struct ControlFeelView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(TouchTuning.turnSpeedKey)
    private var turnSpeed: Double = TouchTuning.default.turnSpeed
    @AppStorage(TouchTuning.stickDeadZoneKey)
    private var stickDeadZone: Double = TouchTuning.default.stickDeadZone
    @AppStorage(TouchTuning.moveSensitivityKey)
    private var moveSensitivity: Double = TouchTuning.default.moveSensitivity

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    slider("Turn Speed", value: $turnSpeed,
                           range: TouchTuning.turnSpeedRange,
                           id: "turnSpeedSlider")
                } footer: {
                    Text("Scales stick turning (Classic) and drag-to-turn (Modern).")
                }
                Section {
                    slider("Stick Dead Zone", value: $stickDeadZone,
                           range: TouchTuning.stickDeadZoneRange,
                           id: "stickDeadZoneSlider")
                } footer: {
                    Text("Fraction of the stick radius that ignores small wobbles.")
                }
                Section {
                    slider("Move Sensitivity", value: $moveSensitivity,
                           range: TouchTuning.moveSensitivityRange,
                           id: "moveSensitivitySlider")
                } footer: {
                    Text("Scales forward/back and strafe output.")
                }
                Section {
                    Button("Reset to Defaults") {
                        turnSpeed = TouchTuning.default.turnSpeed
                        stickDeadZone = TouchTuning.default.stickDeadZone
                        moveSensitivity = TouchTuning.default.moveSensitivity
                    }
                    .accessibilityIdentifier("controlFeelResetButton")
                } footer: {
                    Text("Changes apply when the next session starts. Turn on "
                         + "Show Debug Info to see the effective values in-game.")
                }
            }
            .navigationTitle("Control Feel")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("controlFeelDoneButton")
                }
            }
        }
    }

    private func slider(_ title: String, value: Binding<Double>,
                        range: ClosedRange<Double>, id: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: "%.2f", value.wrappedValue))
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("\(id)Value")
            }
            Slider(value: value, in: range) {
                Text(title)
            } minimumValueLabel: {
                Text(String(format: "%.2f", range.lowerBound)).font(.caption2)
            } maximumValueLabel: {
                Text(String(format: "%.2f", range.upperBound)).font(.caption2)
            }
            .accessibilityIdentifier(id)
        }
    }
}
