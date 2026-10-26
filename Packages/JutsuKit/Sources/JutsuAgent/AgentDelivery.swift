import Foundation

// delivery_set and export: the Library's delivery sets and Export for Editing, as an agent asks for them.

// MARK: delivery_set

public enum AgentDeliveryAction: String, Codable, Sendable, CaseIterable {
    case create, list, export
}

/// Delivery sets as Library › Delivery Sets keeps them: a named set of exact versions, exported with its outputs.
public struct DeliverySetCommand: Codable, Equatable, Sendable, AgentFields {
    public static let maxItems = 200
    /// In Unicode scalars.
    public static let maxNameLength = 120

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
    /// export: how long to wait for it to finish before answering, 0 to `JobsCommand.maxWaitSeconds`; it runs on
    /// either way.
    public var waitSeconds: Int?

    public init(
        action: AgentDeliveryAction, name: String? = nil, items: [UUID] = [], set: UUID? = nil, folder: String? = nil,
        waitSeconds: Int? = nil
    ) {
        self.action = action
        self.name = name
        self.items = items
        self.set = set
        self.folder = folder
        self.waitSeconds = waitSeconds
    }

    private enum CodingKeys: String, CodingKey {
        case action, name, items, set, folder, waitSeconds
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        action = try container.decode(AgentDeliveryAction.self, forKey: .action)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        items = try container.decodeIfPresent([UUID].self, forKey: .items) ?? []
        set = try container.decodeIfPresent(UUID.self, forKey: .set)
        folder = try container.decodeIfPresent(String.self, forKey: .folder)
        waitSeconds = try container.decodeIfPresent(Int.self, forKey: .waitSeconds)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(action, forKey: .action)
        try container.encodeIfPresent(name, forKey: .name)
        if !items.isEmpty { try container.encode(items, forKey: .items) }
        try container.encodeIfPresent(set, forKey: .set)
        try container.encodeIfPresent(folder, forKey: .folder)
        try container.encodeIfPresent(waitSeconds, forKey: .waitSeconds)
    }

    public var problem: String? {
        if let name,
            name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || name.unicodeScalars.count > Self.maxNameLength
        {
            return "name is 1 to \(Self.maxNameLength) characters"
        }
        if let folder, !AgentVideoRequest.isValidPath(folder) { return "folder is a folder path from list" }
        if let waitSeconds {
            guard action == .export else { return "wait_seconds is for export" }
            if let problem = JobsCommand.waitProblem(waitSeconds) { return problem }
        }
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
    /// export: the export, running in the app; follow it with `jobs` by its ID (kind delivery_export).
    public var job: AgentJob?
    /// export: `wait_seconds` ran out before it finished; nothing was stopped.
    // swiftlint:disable:next discouraged_optional_boolean
    public var timedOut: Bool?

    public init(
        action: AgentDeliveryAction, set: AgentDeliverySet? = nil, sets: [AgentDeliverySet]? = nil,
        // swiftlint:disable:next discouraged_optional_boolean
        folders: [String]? = nil, job: AgentJob? = nil, timedOut: Bool? = nil
    ) {
        self.action = action
        self.set = set
        self.sets = sets
        self.folders = folders
        self.job = job
        self.timedOut = timedOut
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
/// Exports folder. Never replaces a file. It runs in the app and answers at once, or after `waitSeconds`, with the
/// export to follow with `jobs`.
public struct ExportCommand: Codable, Equatable, Sendable, AgentFields {
    public static let maxItems = 20

    public var items: [UUID]
    public var preset: AgentExportPreset
    /// Also writes the JSON sidecar; true when left out.
    // swiftlint:disable:next discouraged_optional_boolean
    public var sidecar: Bool?
    /// How long to wait for it to finish before answering, 0 to `JobsCommand.maxWaitSeconds`; it runs on either way.
    public var waitSeconds: Int?

    // swiftlint:disable:next discouraged_optional_boolean
    public init(items: [UUID], preset: AgentExportPreset, sidecar: Bool? = nil, waitSeconds: Int? = nil) {
        self.items = items
        self.preset = preset
        self.sidecar = sidecar
        self.waitSeconds = waitSeconds
    }

    public var problem: String? {
        guard (1...Self.maxItems).contains(items.count) else { return "items takes 1 to \(Self.maxItems) video IDs" }
        guard Set(items).count == items.count else { return "items names each video once" }
        if let problem = waitSeconds.flatMap(JobsCommand.waitProblem) { return problem }
        return nil
    }
}

/// The answer to `export`: the export, running in the app or finished, to follow with `jobs` by its ID.
public struct AgentExported: Codable, Equatable, Sendable {
    /// kind export: its state, progress, folder and the files so far.
    public var job: AgentJob
    /// `waitSeconds` ran out before it finished; nothing was stopped.
    public var timedOut: Bool

    public init(job: AgentJob, timedOut: Bool = false) {
        self.job = job
        self.timedOut = timedOut
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
