import Foundation
import JutsuCore

/// The results of one batch, kept together in the library and opened as a comparison grid.
public struct LibraryBatch: Sendable, Hashable, Identifiable {
    /// One result in the comparison grid.
    public struct Cell: Sendable, Hashable, Identifiable {
        public var item: LibraryItemModel
        /// The style's name, or "Character 2".
        public var label: String

        public var id: UUID { item.id }

        /// The result on the comparison player, labelled like the cell; `nil` without a local file.
        public var track: CompareTrack? {
            item.playback(.result).map {
                CompareTrack(id: CompareTrack.ID(itemID: item.id, side: .result), clip: $0, labels: [label])
            }
        }
    }

    public var id: UUID
    /// In the order they were queued, which is the order the styles or characters were picked.
    public var items: [LibraryItemModel]

    public init(id: UUID, items: [LibraryItemModel]) {
        self.id = id
        self.items = items.sorted { ($0.job.createdAt, $0.id.uuidString) < ($1.job.createdAt, $1.id.uuidString) }
    }

    /// The batch, or the variant group, in `items` with the given id; `nil` when fewer than two of its results are
    /// left.
    public init?(id: UUID, in items: [LibraryItemModel]) {
        let members = items.filter { $0.job.batchID == id || $0.job.variantGroupID == id }
        guard members.count > 1 else { return nil }
        self.init(id: id, items: members)
    }

    /// The card's image.
    public var cover: LibraryItemModel? { items.first }

    public var mode: Mode { items.first?.spec.mode ?? .restyle }

    /// "dance · 4 styles".
    public var title: String {
        let source = items.first?.sourceName ?? String(localized: "Batch", bundle: .module)
        return "\(source) · \(BatchGrouping.variantText(count: items.count, specs: items.map(\.spec)))"
    }

    /// "Draft 480p · $7.63 · 36 min ago", the prices added up and the time of the last result.
    public func subtitle(now: Date) -> String {
        let first = items.first?.spec
        let resolution = first?.resolutionTitle ?? ""
        var parts = [
            first?.isDraft == false
                ? String(localized: "Final \(resolution)", bundle: .module)
                : String(localized: "Draft \(resolution)", bundle: .module)
        ]
        if let total = Cost.total(items.map(\.job.price)) { parts.append(LibraryFormat.cost(total)) }
        let finished = items.map(\.finishedAt).max() ?? now
        parts.append(LibraryFormat.ago(finished, now: now))
        return parts.joined(separator: " · ")
    }

    public var isStarred: Bool { items.contains(where: \.isStarred) }

    /// What "Delete Unstarred" deletes: the results nobody starred, which lost the comparison.
    public var unstarred: [LibraryItemModel] { items.filter { !$0.isStarred } }

    /// What VoiceOver reads for the card: "Batch: dance · 4 styles, Draft 480p · $7.63 · 36 min ago".
    public func accessibilityLabel(now: Date) -> String {
        [
            String(localized: "Batch: \(title)", bundle: .module), subtitle(now: now),
            isStarred ? String(localized: "Has starred results", bundle: .module) : nil,
        ].compactMap { $0 }.joined(separator: ", ")
    }

    /// The grid's cells, labeled by style, by character number or by variant number.
    /// - Parameter presetNames: names of restyle presets the catalog knows.
    public func cells(presetNames: [UUID: String]) -> [Cell] {
        let areVariants = BatchGrouping.areVariants(items.map(\.spec))
        return items.enumerated().map { index, item in
            let label =
                if areVariants {
                    String(localized: "Variant \(index + 1)", bundle: .module)
                } else if item.spec.mode == .restyle {
                    item.spec.presetID.flatMap { presetNames[$0] }
                        ?? String(localized: "Style \(index + 1)", bundle: .module)
                } else {
                    String(localized: "Character \(index + 1)", bundle: .module)
                }
            return Cell(item: item, label: label)
        }
    }
}

/// One card of the library grid: a result, or a batch of results.
public enum LibraryEntry: Sendable, Hashable, Identifiable {
    case item(LibraryItemModel)
    case batch(LibraryBatch)

    public var id: UUID {
        switch self {
        case .item(let item): item.id
        case .batch(let batch): batch.id
        }
    }

    /// The results the card stands for.
    public var items: [LibraryItemModel] {
        switch self {
        case .item(let item): [item]
        case .batch(let batch): batch.items
        }
    }

    public var itemIDs: [UUID] { items.map(\.id) }

    /// Newest first in the grid: the result's finish, or the batch's last result.
    public var newestDate: Date {
        switch self {
        case .item(let item): item.finishedAt
        case .batch(let batch): batch.items.map(\.finishedAt).max() ?? .distantPast
        }
    }

    /// `items` in order, each batch with two or more results among them as one card at its newest result.
    /// - Parameter variants: results that belong to a variant group on screen; they stay cards of their own, since
    ///   their group already folds them.
    public static func group(_ items: [LibraryItemModel], variants: Set<UUID> = []) -> [LibraryEntry] {
        BatchGrouping.group(items) { variants.contains($0.id) ? nil : $0.job.batchID }.map { group in
            switch group {
            case .single(let item): .item(item)
            case .batch(let id, let members): .batch(LibraryBatch(id: id, items: members))
            }
        }
    }
}
