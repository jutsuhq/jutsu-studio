import SwiftUI

/// Minus, the value and plus in one capsule, in place of the system stepper.
struct ValueStepper: View {
    let label: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    /// The minus and plus circles.
    var buttonSize: CGFloat = 28

    var body: some View {
        HStack(spacing: 0) {
            step("minus", title: String(localized: "Decrease"), by: -1)
            Text("\(value)")
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(Theme.text)
                .frame(minWidth: buttonSize)
                .accessibilityLabel(label)
                .accessibilityValue("\(value)")
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: adjust(by: 1)
                    case .decrement: adjust(by: -1)
                    @unknown default: break
                    }
                }
            step("plus", title: String(localized: "Increase"), by: 1)
        }
        .padding(3)
        .background(Theme.well, in: Capsule())
        .overlay { Capsule().strokeBorder(Theme.stroke, lineWidth: 1) }
    }

    private func adjust(by delta: Int) {
        if range.contains(value + delta) { value += delta }
    }

    private func step(_ systemImage: String, title: String, by delta: Int) -> some View {
        let next = value + delta
        return Button {
            value = next
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .bold))
                .frame(width: buttonSize, height: buttonSize)
                .contentShape(Circle())
        }
        .buttonStyle(StepperButtonStyle())
        .disabled(!range.contains(next))
        .accessibilityLabel("\(title) \(label)")
    }
}

private struct StepperButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StepperButton(configuration: configuration)
    }
}

private struct StepperButton: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .foregroundStyle(isEnabled ? Theme.text : Theme.faint)
            .background(
                configuration.isPressed ? Theme.glassPressed : (isHovered && isEnabled ? Theme.glass : .clear),
                in: Circle()
            )
            .pointerCursor()
            .onHover { isHovered = $0 }
    }
}
