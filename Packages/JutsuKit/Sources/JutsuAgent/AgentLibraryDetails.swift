import Foundation

// library_get: the full details of Library items, beside library_search's short rows.

/// The Library item IDs a command takes: 1 to `limit`, and, unless `allowsRepeats`, none named twice.
enum AgentLibraryIDs {
    static func problem(_ ids: [UUID], limit: Int, allowsRepeats: Bool = false) -> String? {
        guard (1...limit).contains(ids.count) else { return "ids takes 1 to \(limit) Library item IDs" }
        guard allowsRepeats || Set(ids).count == ids.count else { return "ids names an item twice" }
        return nil
    }
}

/// The full details of Library items by ID: the whole prompt, what went into each, in order, and its settings.
/// Rejected items too, since an agent names them by ID, and results only on Higgsfield (no `file`); an ID no item
/// has is listed in `notFound` while the others are answered. Read-only.
public struct LibraryGetCommand: Codable, Equatable, Sendable, AgentFields {
    public static let maxIDs = 20

    public var ids: [UUID]

    public init(ids: [UUID]) {
        self.ids = ids
    }

    public var problem: String? { AgentLibraryIDs.problem(ids, limit: Self.maxIDs) }
}

/// One file that went into a result, in the order its job sent it.
public struct AgentLibraryInput: Codable, Equatable, Sendable {
    public enum Role: String, Codable, Sendable, CaseIterable {
        case source
        case startFrame = "start_frame"
        case endFrame = "end_frame"
        case reference
        /// The result an Enhance operation or an edit was made from.
        case editedFrom = "edited_from"
    }

    public var role: Role
    /// 1-based among the images the job sent, the N of its prompt's @ImageN; nil for the source and edited_from.
    public var position: Int?
    /// The file on this Mac, when it is still here.
    public var file: String?
    /// Its Library item, when the Library lists it.
    public var item: UUID?
    /// Higgsfield keeps a copy of it.
    public var onHiggsfield: Bool
    /// The source's range, in seconds from the start of its file.
    public var start: Double?
    public var end: Double?

    public init(
        role: Role, position: Int? = nil, file: String? = nil, item: UUID? = nil, onHiggsfield: Bool = false,
        start: Double? = nil, end: Double? = nil
    ) {
        self.role = role
        self.position = position
        self.file = file
        self.item = item
        self.onHiggsfield = onHiggsfield
        self.start = start
        self.end = end
    }
}

/// How a result was made, beside its model and mode; a setting that doesn't apply to it is left out.
public struct AgentLibrarySettings: Codable, Equatable, Sendable {
    public var resolution: String?
    // swiftlint:disable:next discouraged_optional_boolean
    public var draft: Bool?
    public var audio: String?
    /// Restyle's style ID.
    public var style: UUID?
    /// Seconds a clip without a source ran, or Extend added.
    public var length: Double?
    public var aspectRatio: String?
    /// The plan's unlimited generations paid for it.
    // swiftlint:disable:next discouraged_optional_boolean
    public var paidWithUnlimited: Bool?
    /// An Enhance operation's name, as `enhance` takes it.
    public var operation: String?
    /// Images its request made.
    public var count: Int?

    public init(
        // swiftlint:disable:next discouraged_optional_boolean
        resolution: String? = nil, draft: Bool? = nil, audio: String? = nil, style: UUID? = nil,
        // swiftlint:disable:next discouraged_optional_boolean
        length: Double? = nil, aspectRatio: String? = nil, paidWithUnlimited: Bool? = nil,
        operation: String? = nil, count: Int? = nil
    ) {
        self.resolution = resolution
        self.draft = draft
        self.audio = audio
        self.style = style
        self.length = length
        self.aspectRatio = aspectRatio
        self.paidWithUnlimited = paidWithUnlimited
        self.operation = operation
        self.count = count
    }
}

/// One Library item in full: its row with the whole prompt, its inputs and its settings.
public struct AgentLibraryDetails: Codable, Equatable, Sendable {
    /// What brings a result only on Higgsfield to this Mac.
    public static let downloadNext = "Call library_download with its ID to bring the file to this Mac."

    /// As `library_search` lists it, but with the whole prompt.
    public var item: AgentLibraryItem
    public var inputs: [AgentLibraryInput]
    public var settings: AgentLibrarySettings
    /// For a result with no file on this Mac yet: how to get it (`downloadNext`).
    public var next: String?

    public init(
        item: AgentLibraryItem, inputs: [AgentLibraryInput], settings: AgentLibrarySettings, next: String? = nil
    ) {
        self.item = item
        self.inputs = inputs
        self.settings = settings
        self.next = next
    }
}

public struct AgentLibraryDetailsPage: Codable, Equatable, Sendable {
    /// What finds the IDs `notFound` lists.
    public static let notFoundNext = "Call library_search, with include_higgsfield for the history, for the item IDs."

    /// In the order asked.
    public var items: [AgentLibraryDetails]
    /// The IDs asked for that no Library item has, in the order asked; left out when there are none.
    public var notFound: [UUID]?
    /// With `notFound`: how to find the IDs (`notFoundNext`).
    public var next: String?

    public init(items: [AgentLibraryDetails], notFound: [UUID] = []) {
        self.items = items
        self.notFound = notFound.isEmpty ? nil : notFound
        next = notFound.isEmpty ? nil : Self.notFoundNext
    }
}
