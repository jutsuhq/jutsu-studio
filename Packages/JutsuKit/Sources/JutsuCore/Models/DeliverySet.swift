import Foundation

/// A named set of exact catalog versions, images and videos, made from a Library selection and exported in several
/// outputs at once. Once a file of it has been exported the set is frozen: its versions never change, so a later
/// edit of an item never replaces what was delivered. `nextRound` starts a new set from the items' newest versions.
/// Frames, outputs, the note and the review link stay editable.
public struct DeliverySet: Codable, Sendable, Hashable, Identifiable {
    public struct Item: Codable, Sendable, Hashable, Identifiable {
        public var reference: MaterialReference
        public var kind: Material.Kind
        /// The item's part of the file names: its file's name when it joined the set.
        public var name: String
        /// Frame adjustments by `CropAspect.key`; an aspect without one is cropped centred.
        public var frames: [String: CropFrame]

        public init(reference: MaterialReference, kind: Material.Kind, name: String, frames: [String: CropFrame] = [:])
        {
            self.reference = reference
            self.kind = kind
            self.name = name
            self.frames = frames
        }

        public var id: MaterialReference { reference }

        /// The frame for an output of `aspect`; `nil` for an output that doesn't crop.
        public func frame(for aspect: CropAspect?) -> CropFrame? {
            aspect.map { frames[$0.key] ?? .centered }
        }
    }

    /// The folder a set was last exported to.
    public struct Folder: Codable, Sendable, Hashable {
        public var url: URL
        /// Security-scoped, so a retry or a fixed crop writes there again without asking.
        public var bookmark: Data?

        public init(url: URL, bookmark: Data? = nil) {
            self.url = url
            self.bookmark = bookmark
        }
    }

    public enum Status: Sendable, Hashable {
        case notExported
        case exported(Date, URL)
    }

    public var id: UUID
    public var name: String
    public var createdAt: Date
    public private(set) var items: [Item]
    public var outputs: [DeliveryOutput]
    public var note: String
    /// Text only: the app never opens or uploads to it.
    public var reviewLink: String
    /// The newest result of each item and output exported so far.
    public private(set) var results: [DeliveryResult]
    public private(set) var exportedAt: Date?
    public private(set) var folder: Folder?

    public init(
        id: UUID = UUID(), name: String, createdAt: Date = Date(), items: [Item],
        outputs: [DeliveryOutput] = DeliverySet.defaultOutputs
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.items = Self.unique(items)
        self.outputs = outputs
        note = ""
        reviewLink = ""
        results = []
    }

    /// A full-size JPEG for images and an H.264 file for videos.
    public static var defaultOutputs: [DeliveryOutput] {
        [
            DeliveryOutput(preset: .image(ImageExportPreset(format: .jpeg))),
            DeliveryOutput(preset: .video(.editingH264)),
        ]
    }

    /// The current version of each material, in order, named after its file or else its prompt.
    public static func items(from materials: [Material]) -> [Item] {
        materials.map { material in
            let version = material.current
            let fileName = version.fileURL?.deletingPathExtension().lastPathComponent
            let name = fileName ?? version.generation?.prompt ?? ""
            return Item(reference: material.reference, kind: material.kind, name: name)
        }
    }

    public var isFrozen: Bool { exportedAt != nil }

    public var status: Status {
        guard let exportedAt, let folder else { return .notExported }
        return .exported(exportedAt, folder.url)
    }

    /// Replaces the set's versions; refused once the set is frozen.
    public mutating func setItems(_ items: [Item]) throws {
        guard !isFrozen else { throw DeliverySetError.frozen }
        self.items = Self.unique(items)
    }

    /// Moves an item's crop for one aspect. Allowed on a frozen set: the version stays, and the item's files for
    /// outputs of that aspect become pending again.
    public mutating func setFrame(_ frame: CropFrame, for reference: MaterialReference, aspect: CropAspect) {
        guard let index = items.firstIndex(where: { $0.reference == reference }) else { return }
        items[index].frames[aspect.key] = frame == .centered ? nil : frame
    }

    public func result(for item: Item, output: DeliveryOutput) -> DeliveryResult? {
        results.first { $0.item == item.reference && $0.output.id == output.id }
    }

    /// Notes what a run did. The set freezes on its first exported file, and keeps the folder it went to.
    public mutating func record(_ new: [DeliveryResult], in folder: Folder, at date: Date) {
        for result in new {
            results.removeAll { $0.item == result.item && $0.output.id == result.output.id }
            results.append(result)
        }
        guard isFrozen || new.contains(where: { $0.status == .done }) else { return }
        exportedAt = date
        self.folder = folder
    }

    /// A new, unexported set of the same materials at `currentVersion` (their newest version), with the same outputs
    /// and frames. A material that is gone keeps the version this set holds.
    public func nextRound(
        name: String, at date: Date = Date(), currentVersion: (UUID) -> MaterialReference?
    ) -> DeliverySet {
        let next = items.map { item in
            var item = item
            item.reference = currentVersion(item.reference.materialID) ?? item.reference
            return item
        }
        return DeliverySet(name: name, createdAt: date, items: next, outputs: outputs)
    }

    /// One item per version, in the order given.
    private static func unique(_ items: [Item]) -> [Item] {
        var seen: Set<MaterialReference> = []
        return items.filter { seen.insert($0.reference).inserted }
    }
}

/// What one export did with one item in one output.
public struct DeliveryResult: Codable, Sendable, Hashable {
    public enum Status: String, Codable, Sendable {
        case done, failed, skipped
    }

    public var item: MaterialReference
    /// The output as it was when the file was written, so a changed preset makes the file pending again.
    public var output: DeliveryOutput
    public var status: Status
    /// The file written, for `done`.
    public var fileName: String?
    /// The crop it was written with; `nil` for an output that doesn't crop.
    public var frame: CropFrame?
    /// Why it failed or was skipped.
    public var message: String?

    public init(
        item: MaterialReference, output: DeliveryOutput, status: Status, fileName: String? = nil,
        frame: CropFrame? = nil, message: String? = nil
    ) {
        self.item = item
        self.output = output
        self.status = status
        self.fileName = fileName
        self.frame = frame
        self.message = message
    }
}

public enum DeliverySetError: Error, Equatable {
    /// The set has been exported, so its versions can't change.
    case frozen
    /// The item's file isn't on this Mac: removed, on a drive that isn't connected, or only on the account.
    case sourceUnavailable
}
