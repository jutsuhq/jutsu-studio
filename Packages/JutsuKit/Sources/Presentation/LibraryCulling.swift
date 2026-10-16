import Foundation
import JutsuCore

/// What a culling key or button does to the versions it acts on. Pressing it again changes nothing.
public enum CullingAction: String, Sendable, Hashable, CaseIterable {
    case keep, reject, clear

    public var result: Culling {
        switch self {
        case .keep: .kept
        case .reject: .rejected
        case .clear: .unreviewed
        }
    }

    public var title: String {
        switch self {
        case .keep: String(localized: "Keep", bundle: .module)
        case .reject: String(localized: "Reject", bundle: .module)
        case .clear: String(localized: "Clear Keep or Reject", bundle: .module)
        }
    }

    public var systemImage: String {
        switch self {
        case .keep: "checkmark.circle"
        case .reject: "xmark.circle"
        case .clear: "circle.dashed"
        }
    }

    /// The Settings › Shortcuts entry that sets its key.
    public var shortcut: ShortcutAction {
        switch self {
        case .keep: .keep
        case .reject: .reject
        case .clear: .clearCulling
        }
    }

    /// What pressing it does to results that have the verdicts `current`: Keep or Reject on results that all have
    /// that verdict already takes it back, like a toggle, so a rejected result can be brought back where it shows.
    public func toggled(against current: [Culling]) -> CullingAction {
        guard self != .clear, !current.isEmpty, current.allSatisfy({ $0 == result }) else { return self }
        return .clear
    }

    /// The action a key press in the grid or the large viewer runs; `nil` for any other key.
    public static func pressed(_ press: Shortcut, assigned: [ShortcutAction: Shortcut]) -> CullingAction? {
        allCases.first { assigned[$0.shortcut] == press }
    }
}

/// The catalog facts the grid needs beyond each row's own model: the current version's culling, the variant group
/// and the chosen face. Built once per snapshot from the decoded materials, in one pass.
public struct LibraryCatalogIndex: Sendable {
    public struct Entry: Sendable, Hashable {
        public var reference: MaterialReference
        public var culling: Culling
        public var variantGroupID: UUID?
        public var isVariantPrimary: Bool

        public init(_ material: Material) {
            reference = material.reference
            culling = material.current.culling
            variantGroupID = material.variantGroupID
            isVariantPrimary = material.isVariantPrimary
        }
    }

    public private(set) var entries: [UUID: Entry]

    /// Keyed by material ID, which is also the ID of the material's grid row.
    public init(_ materials: [Material]) {
        entries = Dictionary(materials.map { ($0.id, Entry($0)) }, uniquingKeysWith: { first, _ in first })
    }

    public func culling(of id: UUID) -> Culling { entries[id]?.culling ?? .unreviewed }

    public func isRejected(_ id: UUID) -> Bool { culling(of: id) == .rejected }
}

/// One undoable culling step: what each version was before and after.
public struct CullingStep: Sendable, Hashable {
    public var before: [MaterialReference: Culling]
    public var after: [MaterialReference: Culling]
}

/// The culling changes made in this Library session, newest last, so ⌘Z takes back the last one.
public struct CullingHistory: Sendable, Hashable {
    /// Older steps drop off past this.
    public static let limit = 100

    public private(set) var steps: [CullingStep] = []

    public init() {}

    public var canUndo: Bool { !steps.isEmpty }

    /// Records `action` on `ids` and returns what to write; `nil` when it changes nothing, so a repeated key
    /// doesn't take an Undo of its own. IDs the index doesn't know are skipped.
    public mutating func apply(
        _ action: CullingAction, to ids: [UUID], in index: LibraryCatalogIndex
    ) -> [MaterialReference: Culling]? {
        var step = CullingStep(before: [:], after: [:])
        for id in ids {
            guard let entry = index.entries[id], entry.culling != action.result else { continue }
            step.before[entry.reference] = entry.culling
            step.after[entry.reference] = action.result
        }
        guard !step.after.isEmpty else { return nil }
        steps.append(step)
        if steps.count > Self.limit { steps.removeFirst(steps.count - Self.limit) }
        return step.after
    }

    /// Takes back the last step and returns what to write to restore it; `nil` with nothing to undo.
    public mutating func undo() -> [MaterialReference: Culling]? {
        steps.popLast()?.before
    }
}

/// What a culling key or a bulk button acts on: the visible selected cards when there are any, else the current
/// one. Hidden members of a collapsed group or rejected results never count.
public enum CullingTargets {
    /// - Parameters:
    ///   - visible: the IDs of the results on screen, in grid order.
    ///   - selected: the selected IDs, which may include results hidden since they were picked.
    ///   - current: the card the arrow keys moved to, or the result the large viewer shows.
    public static func resolve(visible: [UUID], selected: Set<UUID>, current: UUID?) -> [UUID] {
        let chosen = visible.filter(selected.contains)
        if !chosen.isEmpty { return chosen }
        guard let current, visible.contains(current) else { return [] }
        return [current]
    }

    /// "12 selected", the scope a bulk button names.
    public static func title(count: Int) -> String {
        String(localized: "\(count) selected", bundle: .module)
    }
}

/// The card the arrow keys move between. Left and right step one card, up and down a row of `columns`.
public enum LibraryCursor {
    public enum Move: Sendable, Hashable { case left, right, up, down }

    /// The card after the move; the first card when none is current yet or the current one is gone.
    public static func moved(_ current: UUID?, _ move: Move, in ids: [UUID], columns: Int) -> UUID? {
        guard let current, let index = ids.firstIndex(of: current) else { return ids.first }
        let step =
            switch move {
            case .left: -1
            case .right: 1
            case .up: -max(columns, 1)
            case .down: max(columns, 1)
            }
        return ids[min(max(index + step, 0), ids.count - 1)]
    }

    /// Where the cursor goes once `acted` is culled: the next card, so a series is culled key after key. At the end
    /// it stays, unless the card leaves the grid (`leaves`), when it goes back one.
    public static func advanced(after acted: UUID, in ids: [UUID], leaves: Bool) -> UUID? {
        guard let index = ids.firstIndex(of: acted) else { return acted }
        if ids.indices.contains(index + 1) { return ids[index + 1] }
        guard leaves else { return acted }
        return index > 0 ? ids[index - 1] : nil
    }

    /// How many cards a row of the adaptive grid holds at `width`.
    public static func columns(width: Double, minimum: Double, spacing: Double) -> Int {
        max(1, Int((width + spacing) / (minimum + spacing)))
    }
}
