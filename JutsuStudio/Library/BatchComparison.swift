import JutsuCore
import Presentation
import SwiftUI

/// A batch's results on one clock in the compare player; "Pick winner" opens that result, whose page renders
/// the final, and Render Finals for Starred renders the finals of all the starred ones. On an account, Score
/// Variants puts a virality score on each cell; picking the winner stays the user's.
struct BatchComparison: View {
    let batch: LibraryBatch
    /// Opens one result's page.
    let open: (UUID) -> Void
    /// Asks to delete the given results, the ones not starred.
    let deleteUnstarred: ([LibraryItemModel]) -> Void
    /// Asks for the resolution and price of the starred drafts' finals.
    let renderFinals: () -> Void
    let close: () -> Void

    @Environment(AppEnvironment.self) private var environment
    @State private var presetNames: [UUID: String] = [:]

    var body: some View {
        let cells = batch.cells(presetNames: presetNames)
        let tracks = cells.filter { Self.isOnDisk($0) }.compactMap(\.track)
        VStack(alignment: .leading, spacing: Theme.Spacing.large) {
            header
            if tracks.isEmpty {
                EmptyState(systemImage: "film", title: "File not found")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ComparePlayer(tracks: tracks, aspect: CGFloat(batch.cover?.aspectRatio ?? 16 / 9))
                    .padding(Theme.Spacing.medium)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.well, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                            .strokeBorder(Theme.stroke, lineWidth: 1)
                    }
            }
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 240), spacing: Theme.Spacing.large)], alignment: .leading,
                spacing: Theme.Spacing.small
            ) {
                ForEach(cells) { cell in pickRow(cell) }
            }
        }
        .padding(.horizontal, Theme.Spacing.page)
        .padding(.top, Theme.Spacing.pageTop)
        .padding(.bottom, Theme.Spacing.page)
        .task(id: batch.id) {
            let ids = batch.items.compactMap(\.spec.presetID)
            presetNames = await Self.cachedNames(of: ids, in: environment.layout.presetCacheFolder)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.large) {
            HStack {
                Button("Library", systemImage: "chevron.left", action: close)
                    .buttonStyle(.secondaryAction)
                    .keyboardShortcut(.cancelAction)
                    .hoverHint("Back to Library (Esc)")
                Spacer(minLength: 0)
                ScoreVariantsButton(batch: batch)
                if batch.items.contains(where: \.canRenderFinal) {
                    RenderFinalsButton(batch: batch, action: renderFinals)
                        .buttonStyle(.secondaryAction)
                }
                let unstarred = batch.unstarred
                Button("Delete Unstarred…", systemImage: "trash") { deleteUnstarred(unstarred) }
                    .buttonStyle(.secondaryAction)
                    .disabled(unstarred.isEmpty)
                    .hoverHint("Delete unstarred")
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(batch.title)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Text(batch.subtitle(now: context.date))
                        .font(.system(size: 12, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(Theme.faint)
                }
            }
        }
    }

    private func pickRow(_ cell: LibraryBatch.Cell) -> some View {
        HStack(spacing: Theme.Spacing.small) {
            Text(cell.label)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Self.isOnDisk(cell) ? Theme.text : Theme.faint)
                .lineLimit(1)
            ViralityBadge(item: cell.item)
            Spacer(minLength: Theme.Spacing.small)
            if cell.item.canRenderFinal {
                Button("Pick winner", systemImage: "trophy") { open(cell.id) }
                    .buttonStyle(.secondaryAction)
                    .hoverHint("Open to render final")
            } else {
                Button("Open", systemImage: "arrow.right") { open(cell.id) }
                    .buttonStyle(.secondaryAction)
                    .hoverHint("Open this result")
            }
        }
    }

    private static func isOnDisk(_ cell: LibraryBatch.Cell) -> Bool {
        cell.item.outputFile.map { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) } ?? false
    }

    /// Reads the cached catalog off the main actor.
    private nonisolated static func cachedNames(of ids: [UUID], in folder: URL) async -> [UUID: String] {
        var names: [UUID: String] = [:]
        for id in ids {
            names[id] = PresetCatalog.cachedName(of: id, in: folder)
        }
        return names
    }
}
