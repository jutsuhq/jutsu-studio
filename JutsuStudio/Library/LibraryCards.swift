import JutsuCore
import Persistence
import Presentation
import SwiftUI

/// A finished result in the library grid: its frame, mode, cost and age.
struct LibraryCard: View {
    let item: LibraryItemModel
    let now: Date
    /// The result is being downloaded from Higgsfield.
    var isImporting = false
    /// Picked to compare.
    var isPicked = false
    /// In the selection bulk actions act on.
    var isSelected = false
    /// An Enhance run on this Mac making the item's next version.
    var onDeviceRun: OnDeviceRuns.Run?
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            LibraryThumbnail(url: item.thumbnailURL)
                .overlay(alignment: .topLeading) {
                    HStack(spacing: 4) {
                        MediaTag(text: item.modeTag)
                        if item.spec.isDraft { MediaTag(text: String(localized: "Draft")) }
                    }
                    .padding(8)
                }
                .overlay(alignment: .topTrailing) {
                    HStack(spacing: 4) {
                        if item.isStarred { badge("star.fill", label: String(localized: "Starred")) }
                        if item.needsImport {
                            badge("icloud", label: String(localized: "On Higgsfield, not downloaded yet"))
                        }
                    }
                    .padding(8)
                }
                .overlay(alignment: .bottomTrailing) {
                    MediaTag(text: item.durationText).padding(8)
                }
                .overlay {
                    if isImporting {
                        ProgressView().controlSize(.small).accessibilityLabel("Downloading")
                    } else if let onDeviceRun {
                        OnDeviceRunBadge(run: onDeviceRun)
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    if isPicked {
                        SelectionCheck(label: "Picked to compare")
                    } else if isSelected {
                        SelectionCheck(label: "Selected")
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.media, style: .continuous))
                .card(radius: Theme.Radius.media, isHighlighted: isHovered || isPicked || isSelected)
                .padding(.bottom, 7)
            Text(item.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
            Text(item.subtitle(now: now))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.faint)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .motionAnimation(.easeOut(duration: 0.12), value: isHovered)
    }

    private func badge(_ systemImage: String, label: String) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 9, weight: .heavy))
            .foregroundStyle(Theme.accent)
            .frame(width: 17, height: 17)
            .background(Theme.scrim, in: Circle())
            .accessibilityLabel(label)
    }
}

/// A batch as one card: its first result's frame on a stack, with the count of results.
struct BatchCard: View {
    let batch: LibraryBatch
    let now: Date
    /// All its results are in the selection.
    var isSelected = false
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            LibraryThumbnail(url: batch.cover?.outputFile)
                .overlay(alignment: .topLeading) {
                    HStack(spacing: 4) {
                        if let cover = batch.cover { MediaTag(text: cover.modeTag) }
                        MediaTag(text: String(localized: "Batch × \(batch.items.count)"))
                    }
                    .padding(8)
                }
                .overlay(alignment: .topTrailing) {
                    if batch.isStarred {
                        Image(systemName: "star.fill")
                            .font(.system(size: 9, weight: .heavy))
                            .foregroundStyle(Theme.accent)
                            .frame(width: 17, height: 17)
                            .background(Theme.scrim, in: Circle())
                            .padding(8)
                            .accessibilityLabel("Has starred results")
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    if isSelected { SelectionCheck(label: "Selected") }
                }
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.media, style: .continuous))
                .card(radius: Theme.Radius.media, isHighlighted: isHovered || isSelected)
                // The edge of a second card behind, so a batch reads as a stack.
                .background(alignment: .top) {
                    RoundedRectangle(cornerRadius: Theme.Radius.media, style: .continuous)
                        .fill(Theme.card)
                        .padding(.horizontal, 10)
                        .offset(y: -5)
                }
                .padding(.bottom, 7)
            Text(batch.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
            Text(batch.subtitle(now: now))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.faint)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .motionAnimation(.easeOut(duration: 0.12), value: isHovered)
    }
}

/// The lime check on a card that is picked to compare or selected.
struct SelectionCheck: View {
    let label: LocalizedStringKey

    var body: some View {
        Image(systemName: "checkmark")
            .font(.system(size: 10, weight: .heavy))
            .foregroundStyle(Theme.ink)
            .frame(width: 20, height: 20)
            .background(Theme.accent, in: Circle())
            .padding(8)
            .accessibilityLabel(label)
    }
}
