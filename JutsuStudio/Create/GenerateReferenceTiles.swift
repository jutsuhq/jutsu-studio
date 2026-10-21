import Presentation
import SwiftUI

/// One request on a line: a spinner and Cancel while it runs, else why it stopped. Its images show as placeholders in
/// the grid, so the row needs no progress bar.
struct ImageRunRow: View {
    let run: ImageRun
    let onCancel: () -> Void
    /// For an agent's request the spending guard held: the person's decision.
    var onReview: (() -> Void)?

    var body: some View {
        RequestRow(
            title: run.title, status: status,
            subtitle: run.agentTitle.map { title in run.agentDetail.map { "\(title) · \($0)" } ?? title },
            onCancel: onCancel, onReview: onReview)
    }

    private var status: RequestRow.Status {
        switch run.state {
        case .running: .working(String(localized: "Making the images…"))
        case .finished: .finished(nil)
        case .failed(let message): .failed(message)
        case .canceled: .canceled
        case .interrupted(let message): .failed(message)
        case .held(let message): .waiting(message)
        }
    }
}

/// A generated image in Generate…'s results. A click picks it, with its place among the picks as the badge; a double
/// click or the expand button opens it large, the trash button deletes it. An image already added shows Added and
/// can't be picked again or deleted.
struct GeneratedResultTile: View {
    let image: GeneratedImage
    /// Its place among the picks, from 1; `nil` when it isn't picked.
    let pickNumber: Int?
    /// Whether one more image can be picked: Create has room for it.
    let canPick: Bool
    let isAdding: Bool
    let onToggle: () -> Void
    let onPreview: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false

    private var isSelectable: Bool { !image.isPicked && (pickNumber != nil || canPick) }

    var body: some View {
        Theme.well
            .aspectRatio(1, contentMode: .fit)
            .overlay { RemoteThumbnail(url: image.url, maxPixelSize: 480) }
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                    .strokeBorder(pickNumber != nil ? Theme.accent : Theme.stroke, lineWidth: pickNumber != nil ? 2 : 1)
            }
            .overlay(alignment: .topLeading) { badge.padding(6) }
            .overlay(alignment: .topTrailing) {
                if isHovered {
                    HStack(spacing: 0) {
                        if !image.isPicked && !isAdding {
                            TileButton(
                                systemImage: "trash", help: String(localized: "Move to Trash"), action: onDelete)
                        }
                        TileButton(
                            systemImage: "arrow.up.left.and.arrow.down.right", help: String(localized: "Open large"),
                            action: onPreview)
                    }
                    .padding(3)
                }
            }
            .overlay {
                if isAdding {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .opacity(isSelectable || pickNumber != nil || image.isPicked ? 1 : 0.45)
            .contentShape(Rectangle())
            .onTapGesture(count: 2, perform: onPreview)
            .onTapGesture { if isSelectable { onToggle() } }
            .onHover { isHovered = $0 }
            .pointerCursor()
            .hoverHint(image.prompt)
            .accessibilityElement()
            .accessibilityAddTraits(pickNumber != nil ? [.isButton, .isSelected] : .isButton)
            .accessibilityLabel(accessibilityText)
            .accessibilityAction { if isSelectable { onToggle() } }
            .accessibilityAction(named: String(localized: "Open large"), onPreview)
            .accessibilityAction(named: String(localized: "Move to Trash")) { if !image.isPicked { onDelete() } }
    }

    @ViewBuilder private var badge: some View {
        if image.isPicked {
            Label("Added", systemImage: "checkmark")
                .font(.system(size: 10, weight: .heavy))
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 7)
                .frame(height: 20)
                .background(Theme.accent, in: Capsule())
        } else if let pickNumber {
            Text("\(pickNumber)")
                .font(.system(size: 11, weight: .heavy))
                .monospacedDigit()
                .foregroundStyle(Theme.ink)
                .frame(width: 20, height: 20)
                .background(Theme.accent, in: Circle())
        } else if isHovered && isSelectable {
            Circle()
                .strokeBorder(Theme.text, lineWidth: 1.5)
                .background(Theme.scrim, in: Circle())
                .frame(width: 20, height: 20)
        }
    }

    private var accessibilityText: String {
        if image.isPicked { return String(localized: "Generated image, added to the references") }
        if let pickNumber { return String(localized: "Generated image, picked \(pickNumber)") }
        return String(localized: "Generated image")
    }
}

/// The place of an image a running request will make.
struct PendingTile: View {
    var body: some View {
        Theme.well
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                    .strokeBorder(Theme.stroke, style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            }
            .overlay { ProgressView().controlSize(.small) }
            .accessibilityElement()
            .accessibilityLabel(String(localized: "Image being made"))
    }
}
