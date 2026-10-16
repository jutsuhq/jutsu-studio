import Foundation
import Presentation
import SwiftUI

/// "draft 480p → final 720p → final 1080p"; every step but the current and a deleted one opens that result.
struct ChainSteps: View {
    let chain: LibraryChain
    let open: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            SectionLabel(title: "Chain")
            FlowLayout(spacing: 6) {
                ForEach(Array(chain.steps.enumerated()), id: \.element.id) { index, step in
                    HStack(spacing: 6) {
                        if index > 0 {
                            Image(systemName: "arrow.right")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(Theme.faint)
                        }
                        stepButton(step)
                    }
                }
            }
        }
    }

    private func stepButton(_ step: LibraryChain.Step) -> some View {
        Button {
            open(step.id)
        } label: {
            Text(step.title)
                .font(.system(size: 11.5, weight: .semibold))
                .strikethrough(step.isDeleted)
                .foregroundStyle(step.isCurrent ? Theme.ink : (step.isDeleted ? Theme.faint : Theme.text))
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(step.isCurrent ? Theme.accent : Theme.glass, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .disabled(step.isCurrent || step.isDeleted)
        .hoverHint(step.isDeleted ? "Deleted from the library" : "Open this result")
        .accessibilityAddTraits(step.isCurrent ? .isSelected : [])
    }
}

/// The player on a dark stage that takes all the room the details leave.
struct ResultStage: View {
    let item: LibraryItemModel
    let aspect: CGFloat

    var body: some View {
        player
            .padding(Theme.Spacing.medium)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.well, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(Theme.stroke, lineWidth: 1)
            }
    }

    /// Before/after when both files are on disk, otherwise whichever one is.
    @ViewBuilder
    private var player: some View {
        let source = item.playback(.source).flatMap { isReadable($0) ? $0 : nil }
        let result = item.playback(.result).flatMap { isReadable($0) ? $0 : nil }
        switch (result, source) {
        case (let result?, let source?):
            ComparePlayer(
                tracks: [
                    CompareTrack(
                        id: .init(itemID: item.id, side: .source), clip: source, labels: [String(localized: "Before")]),
                    CompareTrack(
                        id: .init(itemID: item.id, side: .result), clip: result, labels: [String(localized: "After")]),
                ],
                layout: .divider, aspect: aspect
            )
            .id(item.id)
        case (let result?, nil):
            LibraryPlayer(clip: result, aspect: aspect)
        case (nil, let source?):
            LibraryPlayer(clip: source, aspect: aspect)
        case (nil, nil):
            ContentUnavailableView("File not found", systemImage: "questionmark.video")
        }
    }

    /// Checked through the bookmark: after a relaunch the plain path of a picked source isn't readable.
    private func isReadable(_ clip: PlaybackClip) -> Bool {
        withScopedAccess(to: clip.url, bookmark: clip.bookmark) { access in
            FileManager.default.isReadableFile(atPath: access.url.path(percentEncoded: false))
        }
    }
}

/// What the result cost and, when recorded, how long it waited and generated.
struct RecordLines: View {
    let item: LibraryItemModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            Text(item.billingSummary)
            if let timing = item.timingSummary {
                Text(timing)
                    .hoverHint("Queue wait: until generation started")
            }
        }
        .font(.system(size: 11.5, weight: .medium))
        .monospacedDigit()
        .foregroundStyle(Theme.faint)
        .textSelection(.enabled)
    }
}
