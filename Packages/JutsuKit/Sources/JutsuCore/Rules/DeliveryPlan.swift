import Foundation

/// One file of a delivery: an item in an output, under the name it gets.
public struct DeliveryTask: Sendable, Hashable, Identifiable {
    public var item: DeliverySet.Item
    public var output: DeliveryOutput
    public var fileName: String
    /// The crop it is written with; `nil` for an output that doesn't crop.
    public var frame: CropFrame?
    /// The set wrote this name for the same item and output before, so the new file takes its place. Any other
    /// existing file is never replaced.
    public var replacesExisting: Bool

    public init(
        item: DeliverySet.Item, output: DeliveryOutput, fileName: String, frame: CropFrame?, replacesExisting: Bool
    ) {
        self.item = item
        self.output = output
        self.fileName = fileName
        self.frame = frame
        self.replacesExisting = replacesExisting
    }

    public var id: String { "\(item.reference.versionID)/\(output.id)" }

    public func result(_ status: DeliveryResult.Status, message: String? = nil) -> DeliveryResult {
        DeliveryResult(
            item: item.reference, output: output, status: status, fileName: status == .done ? fileName : nil,
            frame: frame, message: message)
    }
}

/// Which files a delivery run writes, and their names (`ExportNaming.deliveryBaseName`). Image outputs take the
/// set's images and video outputs its videos.
public enum DeliveryPlan {
    public enum Scope: Sendable, Hashable {
        /// Every item in every output.
        case all
        /// What isn't exported as the set is now: never exported, failed or skipped, or exported with another crop
        /// or preset. After fixing one item's crop, only that item's files.
        case pending
        /// Only the files whose last run failed.
        case failed
    }

    /// - Parameter isTaken: whether a file of that name is already in the folder; compare case-insensitively on
    ///   the usual case-insensitive volumes.
    public static func tasks(
        for set: DeliverySet, scope: Scope, isTaken: (String) -> Bool
    ) -> [DeliveryTask] {
        let labels = ExportNaming.outputLabels(set.outputs)
        var planned: Set<String> = []
        var tasks: [DeliveryTask] = []
        for (offset, item) in set.items.enumerated() {
            for output in set.outputs where output.kind == item.kind {
                let previous = set.result(for: item, output: output)
                let frame = item.frame(for: output.aspect)
                guard includes(previous, output: output, frame: frame, scope: scope) else { continue }
                let base = ExportNaming.deliveryBaseName(
                    set: set.name, position: offset + 1, count: set.items.count, item: item.name,
                    output: labels[output.id] ?? output.summary)
                // A file this set wrote for the same item and output is written again under its name.
                let ownFile = previous.flatMap { $0.status == .done ? $0.fileName : nil }.flatMap { name in
                    name.hasSuffix(".\(output.fileExtension)") && !planned.contains(name.lowercased()) ? name : nil
                }
                let name =
                    ownFile
                    ?? OutputNamePattern.available("\(base).\(output.fileExtension)") { candidate in
                        planned.contains(candidate.lowercased()) || isTaken(candidate)
                    }
                planned.insert(name.lowercased())
                tasks.append(
                    DeliveryTask(
                        item: item, output: output, fileName: name, frame: frame, replacesExisting: ownFile != nil))
            }
        }
        return tasks
    }

    private static func includes(
        _ previous: DeliveryResult?, output: DeliveryOutput, frame: CropFrame?, scope: Scope
    ) -> Bool {
        switch scope {
        case .all:
            return true
        case .failed:
            return previous?.status == .failed
        case .pending:
            guard let previous, previous.status == .done else { return true }
            return previous.output != output || previous.frame != frame
        }
    }
}
