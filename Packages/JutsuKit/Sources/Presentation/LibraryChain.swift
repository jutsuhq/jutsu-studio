import Foundation
import JutsuCore

/// The draft-to-final chain an item belongs to, e.g. "draft 480p → final 720p → final 1080p": the oldest known
/// ancestor first, then everything made from it, oldest first. A deleted parent stays in as a `deleted` step.
public struct LibraryChain: Sendable, Hashable {
    public struct Step: Sendable, Hashable, Identifiable {
        public var id: UUID
        /// "draft 480p", "final 1080p" or "deleted".
        public var title: String
        public var isDeleted: Bool
        public var isCurrent: Bool
    }

    public var steps: [Step]

    /// Worth showing only when the item has a parent or a child.
    public var isEmpty: Bool { steps.count < 2 }

    /// - Parameter items: the library; only these can be steps besides a deleted parent.
    public init(for id: UUID, in items: [LibraryItemModel]) {
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        guard let item = byID[id] else {
            steps = []
            return
        }
        var children: [UUID: [LibraryItemModel]] = [:]
        for item in items {
            if let parent = item.job.parentID { children[parent, default: []].append(item) }
        }

        var root = item
        var visited: Set<UUID> = [root.id]
        while let parentID = root.job.parentID, let parent = byID[parentID], visited.insert(parentID).inserted {
            root = parent
        }
        var steps: [Step] = []
        var start = root.id
        if let missing = root.job.parentID, byID[missing] == nil {
            steps.append(
                Step(
                    id: missing, title: String(localized: "deleted", bundle: .module), isDeleted: true, isCurrent: false
                ))
            start = missing
        }

        var descendants: [LibraryItemModel] = []
        var pending = [start]
        var seen: Set<UUID> = [start]
        while let next = pending.popLast() {
            if let node = byID[next] { descendants.append(node) }
            for child in children[next] ?? [] where seen.insert(child.id).inserted {
                pending.append(child.id)
            }
        }
        descendants.sort { ($0.job.createdAt, $0.id.uuidString) < ($1.job.createdAt, $1.id.uuidString) }
        steps += descendants.map {
            Step(id: $0.id, title: Self.title(of: $0), isDeleted: false, isCurrent: $0.id == id)
        }
        self.steps = steps
    }

    static func title(of item: LibraryItemModel) -> String {
        if let operation = item.spec.operation { return operation.action.tag.lowercased() }
        return "\(item.spec.isDraft ? "draft" : "final") \(item.spec.resolutionTitle)"
    }
}
