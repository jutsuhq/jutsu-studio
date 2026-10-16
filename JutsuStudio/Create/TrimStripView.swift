import JutsuCore
import MediaKit
import Presentation
import SwiftUI

/// Thumbnails of the whole clip with two handles on the range being edited, and the list of ranges.
/// The form clamps every move to 4–30 s and keeps ranges apart. The handles and the selection also move
/// with the arrow keys once focused, and with VoiceOver's adjust actions.
struct TrimStripView: View {
    @Binding var form: CreateForm
    /// The active connection's kind, which decides the seconds billed; `nil` while disconnected.
    let connection: ProviderKind?
    /// Called with the time under the handle being dragged, to show that frame.
    let onScrub: (TimeInterval) -> Void

    @State private var thumbnails: [CGImage] = []
    @State private var dragOrigin: ClosedRange<TimeInterval>?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                SectionLabel(title: "Trim")
                    .fixedSize()
                Text(form.rangeText)
                    .monospacedDigit()
                    .foregroundStyle(Theme.text)
                    .fixedSize()
                Spacer(minLength: Theme.Spacing.small)
                Text(form.trimSummary(on: connection))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
            }
            GeometryReader { proxy in
                strip(width: proxy.size.width)
            }
            .frame(height: 56)
            rangeList
        }
        .task(id: form.source?.fileURL) {
            await loadThumbnails()
        }
    }

    private func strip(width: CGFloat) -> some View {
        let total = max(form.source?.duration ?? 0, 0.001)
        let x = { (time: TimeInterval) in width * CGFloat(time / total) }
        let startX = x(form.range.lowerBound)
        let endX = x(form.range.upperBound)
        return ZStack(alignment: .leading) {
            frames
            ForEach(form.uncoveredRanges, id: \.lowerBound) { gap in
                Theme.scrim
                    .frame(width: max(0, x(gap.upperBound) - x(gap.lowerBound)))
                    .offset(x: x(gap.lowerBound))
            }
            ForEach(form.ranges.indices, id: \.self) { index in
                if index != form.selectedRangeIndex {
                    let range = form.ranges[index]
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Theme.accent.opacity(0.5), lineWidth: 1)
                        .contentShape(Rectangle())
                        .frame(width: max(0, x(range.upperBound) - x(range.lowerBound)))
                        .offset(x: x(range.lowerBound))
                        .onTapGesture { select(index) }
                }
            }
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(Theme.accent, lineWidth: 2)
                .contentShape(Rectangle())
                .frame(width: max(0, endX - startX))
                .modifier(TrimControls(form: $form, part: .selection, onScrub: onScrub))
                .offset(x: startX)
                .gesture(drag(.selection, width: width, total: total))
            handle
                .modifier(TrimControls(form: $form, part: .start, onScrub: onScrub))
                .offset(x: startX - 5)
                .gesture(drag(.start, width: width, total: total))
            handle
                .modifier(TrimControls(form: $form, part: .end, onScrub: onScrub))
                .offset(x: endX - 5)
                .gesture(drag(.end, width: width, total: total))
        }
        .frame(width: width)
    }

    /// "+ Add range", and once there are several, one chip per range to edit or remove it.
    private var rangeList: some View {
        HStack(spacing: Theme.Spacing.small) {
            if form.hasSeveralRanges {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(form.ranges.indices, id: \.self) { index in
                            RangeChip(
                                text: form.rangeText(at: index), isSelected: index == form.selectedRangeIndex,
                                onSelect: { select(index) }, onRemove: { form.removeRange(at: index) })
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            Button {
                form.addRange()
                onScrub(form.range.lowerBound)
            } label: {
                Label("Add range", systemImage: "plus")
                    .font(.callout)
            }
            .buttonStyle(.plain)
            .foregroundStyle(form.canAddRange ? Theme.accent : Theme.faint)
            .pointerCursor()
            .disabled(!form.canAddRange)
            .hoverHint("Add a 4–30 s range")
            .fixedSize()
        }
    }

    private func select(_ index: Int) {
        form.selectRange(at: index)
        onScrub(form.range.lowerBound)
    }

    private var frames: some View {
        HStack(spacing: 0) {
            ForEach(thumbnails.indices, id: \.self) { index in
                Color.clear
                    .overlay {
                        Image(decorative: thumbnails[index], scale: 1)
                            .resizable()
                            .scaledToFill()
                    }
                    .clipped()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.track)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
    }

    private var handle: some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(Theme.accent)
            .frame(width: 10)
    }

    /// Moves relative to where the drag started, so the handle follows the pointer exactly.
    private func drag(_ part: TrimPart, width: CGFloat, total: TimeInterval) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let origin = dragOrigin ?? form.range
                if dragOrigin == nil { dragOrigin = origin }
                let shift = Double(value.translation.width / max(width, 1)) * total
                switch part {
                case .start: form.setStart(origin.lowerBound + shift)
                case .end: form.setEnd(origin.upperBound + shift)
                case .selection: form.moveRange(toStart: origin.lowerBound + shift)
                }
                onScrub(form.time(of: part))
            }
            .onEnded { _ in
                dragOrigin = nil
            }
    }

    private func loadThumbnails() async {
        guard let source = form.source else {
            thumbnails = []
            return
        }
        thumbnails = await withScopedAccess(to: source.fileURL, bookmark: source.bookmark) { access in
            (try? await ThumbnailStrip.images(for: access.url, count: 12)) ?? []
        }
    }
}

/// One range in the trim list: tap to edit it on the strip, × to remove it.
private struct RangeChip: View {
    let text: String
    let isSelected: Bool
    let onSelect: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Button(action: onSelect) {
                Text(text)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(isSelected ? Theme.text : Theme.muted)
            }
            .buttonStyle(.plain)
            .pointerCursor()
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.muted)
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .hoverHint("Remove range")
            .accessibilityLabel("Remove range \(text)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .overlay {
            Capsule()
                .strokeBorder(isSelected ? Theme.accent : Theme.stroke, lineWidth: 1)
        }
    }
}

/// Arrow keys and VoiceOver move one part of the trim as a drag does, like `DividerControls` in Compare.
private struct TrimControls: ViewModifier {
    @Binding var form: CreateForm
    let part: TrimPart
    let onScrub: (TimeInterval) -> Void

    func body(content: Content) -> some View {
        content
            .focusable()
            .onMoveCommand { direction in
                switch direction {
                case .left: nudge(by: -1)
                case .right: nudge(by: 1)
                default: break
                }
            }
            .accessibilityElement()
            .accessibilityLabel(part.accessibilityLabel)
            .accessibilityValue(form.accessibilityValue(of: part))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: nudge(by: 1)
                case .decrement: nudge(by: -1)
                @unknown default: break
                }
            }
    }

    private func nudge(by steps: Int) {
        form.nudge(part, by: steps)
        onScrub(form.time(of: part))
    }
}
