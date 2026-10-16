import Presentation
import SwiftUI

/// A generated image opened large over Generate…: ← and → step through the results, Space picks or unpicks, Escape
/// goes back to the grid.
struct GeneratedImagePreview: View {
    let images: [GeneratedImage]
    @Binding var current: UUID?
    let pickNumber: (UUID) -> Int?
    /// Whether one more image can be picked.
    let canPick: Bool
    let onToggle: (UUID) -> Void

    var body: some View {
        if let index = images.firstIndex(where: { $0.id == current }) {
            let image = images[index]
            let number = pickNumber(image.id)
            VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
                    Text("Image \(index + 1) of \(images.count)")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Theme.text)
                    Text(image.model)
                        .font(.callout)
                        .foregroundStyle(Theme.muted)
                }
                RemoteThumbnail(url: image.url, maxPixelSize: 2048, contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.well, in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
                    .accessibilityLabel(image.prompt)
                Text(image.prompt)
                    .font(.caption)
                    .foregroundStyle(Theme.faint)
                    .lineLimit(2)
                    .textSelection(.enabled)
                HStack(spacing: Theme.Spacing.small) {
                    Button("Previous", systemImage: "chevron.left") { current = images[index - 1].id }
                        .buttonStyle(.secondaryAction)
                        .labelStyle(.iconOnly)
                        .keyboardShortcut(.leftArrow, modifiers: [])
                        .disabled(index == 0)
                    Button("Next", systemImage: "chevron.right") { current = images[index + 1].id }
                        .buttonStyle(.secondaryAction)
                        .labelStyle(.iconOnly)
                        .keyboardShortcut(.rightArrow, modifiers: [])
                        .disabled(index == images.count - 1)
                    Spacer(minLength: Theme.Spacing.small)
                    Button("Back to Results") { current = nil }
                        .buttonStyle(.secondaryAction)
                        .keyboardShortcut(.cancelAction)
                    Button {
                        onToggle(image.id)
                    } label: {
                        if image.isPicked {
                            Label("Added", systemImage: "checkmark")
                        } else if let number {
                            Label("Picked \(number)", systemImage: "checkmark")
                        } else {
                            Label("Pick", systemImage: "plus")
                        }
                    }
                    .buttonStyle(.primaryAction)
                    .keyboardShortcut(.space, modifiers: [])
                    .disabled(image.isPicked || (number == nil && !canPick))
                    .hoverHint(
                        number == nil
                            ? String(localized: "Add to references") : String(localized: "Unpick"))
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.background)
        }
    }
}
