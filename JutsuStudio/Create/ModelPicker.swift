import JutsuCore
import Presentation
import SwiftUI

/// Create's model picker: a pull-down with the selected model, opening one flat list where each model shows its price
/// per second and, when the models differ in it, its longest length (`CreateForm.modelMenu`).
struct ModelPicker: View {
    @Binding var selection: VideoModel
    let rows: [ModelMenuRow]
    @State private var isHovered = false

    var body: some View {
        Menu {
            Picker(String(localized: "Model"), selection: $selection) {
                ForEach(rows) { row in
                    Text(row.detail.map { "\(row.title) · \($0)" } ?? row.title).tag(row.model)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 6) {
                Text(selection.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.faint)
            }
            .foregroundStyle(isHovered ? Theme.text : Theme.muted)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 34)
            .background(isHovered ? Theme.glassHover : Theme.well, in: Capsule())
            .overlay { Capsule().strokeBorder(Theme.stroke, lineWidth: 1) }
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .pointerCursor()
        .menuIndicator(.hidden)
        .onHover { isHovered = $0 }
        .motionAnimation(.easeOut(duration: 0.12), value: isHovered)
        .accessibilityLabel(String(localized: "Model"))
        .accessibilityValue(selection.title)
    }
}
