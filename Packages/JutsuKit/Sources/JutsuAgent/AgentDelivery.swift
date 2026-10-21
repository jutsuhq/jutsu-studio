import Foundation

// delivery_set and export: the Library's delivery sets and Export for Editing, as an agent asks for them.

// MARK: delivery_set

public enum AgentDeliveryAction: String, Codable, Sendable, CaseIterable {
    case create, list, export
}

/// Delivery sets as Library › Delivery Sets keeps them: a named set of exact versions, exported with its outputs.
public struct DeliverySetCommand: Codable, Equatable, Sendable, AgentFields {
    public static let maxItems = 200

    public var action: AgentDeliveryAction
    /// create: the set's name; the date's when left out.
    public var name: String?
    /// create: Library item IDs, at their current versions.
    public var items: [UUID]
    /// export: the set's ID.
    public var set: UUID?
    /// export: a folder the person already exported a set to (`folders` of list); left out, the output folder's
    /// Exports folder.
    public var folder: String?

    public init(
        action: AgentDeliveryAction, name: String? = nil, items: [UUID] = [], set: UUID? = nil, folder: String? = nil
    ) {
        self.action = action
        self.name = name
        self.items = items
        self.set = set
        self.folder = folder
    }

    private enum CodingKeys: String, CodingKey {
        case action, name, items, set, folder
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        action = try container.decode(AgentDeliveryAction.self, forKey: .action)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        items = try container.decodeIfPresent([UUID].self, forKey: .items) ?? []
        set = try container.decodeIfPresent(UUID.self, forKey: .set)
        folder = try container.decodeIfPresent(String.self, forKey: .folder)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(action, forKey: .action)
        try container.encodeIfPresent(name, forKey: .name)
        if !items.isEmpty { try container.encode(items, forKey: .items) }
        try container.encodeIfPresent(set, forKey: .set)
        try container.encodeIfPresent(folder, forKey: .folder)
    }

    public var problem: String? {
        if let name, name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.unicodeScalars.count > 120 {
            return "name is 1 to 120 characters"
        }
        if let folder, !AgentVideoRequest.isValidPath(folder) { return "folder is a folder path from list" }
        switch action {
        case .create:
            guard (1...Self.maxItems).contains(items.count) else {
                return "create needs items, 1 to \(Self.maxItems) Library item IDs"
            }
            if set != nil || folder != nil { return "create takes name and items" }
        case .list:
            if name != nil || !items.isEmpty || set != nil || folder != nil { return "list takes no other fields" }
        case .export:
            guard set != nil else { return "export needs set, a set ID" }
            if name != nil || !items.isEmpty { return "export takes set and folder" }
        }
        return nil
    }
}

public struct AgentDeliverySet: Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var createdAt: Date
    public var itemCount: Int
    /// Exported at least once: its versions no longer change.
    public var frozen: Bool
    public var exportedAt: Date?
    /// The folder of its last export.
    public var folder: String?
    /// "JPEG · sRGB", "Editing H.264"…
    public var outputs: [String]

    public init(
        id: UUID, name: String, createdAt: Date, itemCount: Int, frozen: Bool, exportedAt: Date?, folder: String?,
        outputs: [String]
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.itemCount = itemCount
        self.frozen = frozen
        self.exportedAt = exportedAt
        self.folder = folder
        self.outputs = outputs
    }
}

/// How one file of an export went.
public struct AgentExportFile: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        case done, failed, skipped
    }

    public var item: UUID
    public var status: Status
    /// The file written, for done.
    public var file: String?
    /// The JSON sidecar written next to it, for `export` with sidecar.
    public var sidecar: String?
    /// Why it failed or was skipped.
    public var message: String?
    /// The output it was written for, for a delivery set.
    public var output: String?

    public init(
        item: UUID, status: Status, file: String? = nil, sidecar: String? = nil, message: String? = nil,
        output: String? = nil
    ) {
        self.item = item
        self.status = status
        self.file = file
        self.sidecar = sidecar
        self.message = message
        self.output = output
    }
}

public struct AgentDelivery: Codable, Equatable, Sendable {
    public var action: AgentDeliveryAction
    /// create: the new set; export: the set as it is now.
    public var set: AgentDeliverySet?
    /// list: every set, newest first.
    public var sets: [AgentDeliverySet]?
    /// list: the folders the person exported sets to, which export takes.
    public var folders: [String]?
    /// export: where the files went, and each file.
    public var folder: String?
    public var files: [AgentExportFile]?

    public init(
        action: AgentDeliveryAction, set: AgentDeliverySet? = nil, sets: [AgentDeliverySet]? = nil,
        folders: [String]? = nil, folder: String? = nil, files: [AgentExportFile]? = nil
    ) {
        self.action = action
        self.set = set
        self.sets = sets
        self.folders = folders
        self.folder = folder
        self.files = files
    }
}

// MARK: export

/// The presets of Export for Editing.
public enum AgentExportPreset: String, Codable, Sendable, CaseIterable {
    case premiere
    case davinciResolve = "davinci_resolve"
    case finalCutPro = "final_cut_pro"
    case editingH264 = "editing_h264"
}

/// Exports video results for editing, as the result page's Export for Editing does, into the output folder's
/// Exports folder. Never replaces a file.
public struct ExportCommand: Codable, Equatable, Sendable, AgentFields {
    public static let maxItems = 20

    public var items: [UUID]
    public var preset: AgentExportPreset
    /// Also writes the JSON sidecar; true when left out.
    // swiftlint:disable:next discouraged_optional_boolean
    public var sidecar: Bool?

    // swiftlint:disable:next discouraged_optional_boolean
    public init(items: [UUID], preset: AgentExportPreset, sidecar: Bool? = nil) {
        self.items = items
        self.preset = preset
        self.sidecar = sidecar
    }

    public var problem: String? {
        guard (1...Self.maxItems).contains(items.count) else { return "items takes 1 to \(Self.maxItems) video IDs" }
        guard Set(items).count == items.count else { return "items names each video once" }
        return nil
    }
}

public struct AgentExported: Codable, Equatable, Sendable {
    public var folder: String
    public var files: [AgentExportFile]

    public init(folder: String, files: [AgentExportFile]) {
        self.folder = folder
        self.files = files
    }
}

extension AgentNames {
    /// An image model's ID: the account's or an API endpoint's, which may have slashes.
    public static func isValidImageModelID(_ id: String) -> Bool {
        (1...128).contains(id.utf8.count) && !id.hasPrefix(".") && !id.contains("..")
            && id.utf8.allSatisfy { isNameByte($0) || $0 == UInt8(ascii: "/") }
    }

    /// A `nextCursor`: letters, digits, '_' and '-'.
    public static func isValidCursor(_ cursor: String) -> Bool {
        (1...96).contains(cursor.utf8.count)
            && cursor.utf8.allSatisfy { isNameByte($0) && $0 != UInt8(ascii: ".") }
    }
}
