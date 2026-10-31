import Foundation

// elements: the account's reference elements (characters, environments, props) by name, as References › From
// Higgsfield lists them, and the @ImageN tags a request's images get. create_element makes one from the agent's
// images, as Save to Higgsfield… does from a batch character.

/// Lists the account's reference elements, in the account's order: name words, a category, a page at a time.
/// Read-only and free.
public struct ElementsCommand: Codable, Equatable, Sendable, AgentFields {
    public static let defaultLimit = 20
    public static let maxLimit = 50
    /// In Unicode scalars.
    public static let maxQueryLength = 200
    public static let categories = ["character", "environment", "prop"]

    /// Words that all appear in the name, in any case.
    public var query: String?
    public var category: String?
    public var limit: Int?
    /// `nextCursor` of the page before.
    public var cursor: String?

    public init(query: String? = nil, category: String? = nil, limit: Int? = nil, cursor: String? = nil) {
        self.query = query
        self.category = category
        self.limit = limit
        self.cursor = cursor
    }

    public var problem: String? {
        if let query, query.unicodeScalars.count > Self.maxQueryLength {
            return "query is at most \(Self.maxQueryLength) characters"
        }
        if let category, !Self.categories.contains(category) {
            return "category is one of \(Self.categories.joined(separator: ", "))"
        }
        if let limit, !(1...Self.maxLimit).contains(limit) { return "limit is 1 to \(Self.maxLimit)" }
        if let cursor, !(1...1024).contains(cursor.utf8.count) || cursor.contains(where: \.isNewline) {
            return "cursor is a nextCursor from an earlier answer"
        }
        return nil
    }
}

/// One reference element of the account.
public struct AgentElement: Codable, Equatable, Sendable {
    public var id: String
    /// What `create_video` and `create_image` take in `elements`.
    public var name: String
    public var category: String?
    /// Images it has, when the account's page named them; `nil` when it didn't say.
    public var imageCount: Int?
    /// create_element: `completed` once the account can use it; `processing` or `ip_checking` while Higgsfield still
    /// checks it, and `elements` lists it only once it is completed. `nil` in `elements`, which lists only those.
    public var status: String?

    public init(id: String, name: String, category: String? = nil, imageCount: Int? = nil, status: String? = nil) {
        self.id = id
        self.name = name
        self.category = category
        self.imageCount = imageCount
        self.status = status
    }
}

/// Makes a reference element on the account from the agent's images, idempotent by its request ID: sent again, it
/// answers with the element it made instead of making a second one. Free.
public struct CreateElementCommand: Codable, Equatable, Sendable, AgentFields {
    /// Higgsfield's own limit on an element's name ("max 32 chars").
    public static let maxNameLength = 32
    /// A bound of the protocol: an element is a few clear images of one subject.
    public static let maxImages = 10
    public static let defaultCategory = "character"

    public var requestID: String
    /// `AgentFingerprint` of the request as the agent sent it, with its images' paths and sizes.
    public var fingerprint: String
    public var name: String
    /// One of `ElementsCommand.categories`; `nil` is `defaultCategory`.
    public var category: String?
    /// The images' paths: the agent's own files, then the copies the helper handed the app.
    public var images: [String]

    public init(requestID: String, fingerprint: String, name: String, category: String? = nil, images: [String]) {
        self.requestID = requestID
        self.fingerprint = fingerprint
        self.name = name
        self.category = category
        self.images = images
    }

    private enum CodingKeys: String, CodingKey {
        case requestID = "requestId"
        case fingerprint, name, category, images
    }

    public var problem: String? {
        guard AgentNames.isValidRequestID(requestID) else { return AgentNames.requestIDRule }
        guard AgentNames.isValidFingerprint(fingerprint) else { return "fingerprint is 64 lowercase hex digits" }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.count > Self.maxNameLength {
            return "name is 1 to \(Self.maxNameLength) characters"
        }
        if let category, !ElementsCommand.categories.contains(category) {
            return "category is one of \(ElementsCommand.categories.joined(separator: ", "))"
        }
        if images.isEmpty { return "images takes the element's images, at least one" }
        if images.count > Self.maxImages { return "images takes at most \(Self.maxImages) images" }
        if let path = images.first(where: { !AgentVideoRequest.isValidPath($0) }) {
            return "images has a path that isn't one: \(path.prefix(80))"
        }
        return nil
    }
}

public struct AgentElementsPage: Codable, Equatable, Sendable {
    public var items: [AgentElement]
    /// Pass as `cursor` for the next page; nil on the last one.
    public var nextCursor: String?

    public init(items: [AgentElement], nextCursor: String? = nil) {
        self.items = items
        self.nextCursor = nextCursor
    }
}

/// One image a request sent, by the tag its prompt names it with: an element's images first, in the element's
/// order and the order `elements` named them, then the agent's own files.
public struct AgentReference: Codable, Equatable, Sendable {
    /// "@Image1", "@Image2"…
    public var tag: String
    /// The element it is an image of, by name; `nil` for the agent's own file.
    public var element: String?
    /// Its file on this Mac.
    public var file: String

    public init(tag: String, element: String? = nil, file: String) {
        self.tag = tag
        self.element = element
        self.file = file
    }
}

/// The checks `elements` gets in `create_video`, `quote` and `create_image`.
public enum AgentElementNames {
    /// A bound of the protocol, kept small: every element named has all its images downloaded before the job is
    /// checked against the model, whose own limit on references then refuses too many with a reason.
    public static let maxNames = 4
    public static let maxNameLength = 64

    public static func problem(_ names: [String]) -> String? {
        if names.count > maxNames { return "elements takes at most \(maxNames) names" }
        if names.contains(where: { $0.trimmingCharacters(in: .whitespaces).isEmpty || $0.count > maxNameLength }) {
            return "elements are names from the elements tool, 1 to \(maxNameLength) characters"
        }
        // Trimmed, as the lookup compares them.
        let trimmed = names.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        if Set(trimmed).count != names.count { return "elements names an element twice" }
        return nil
    }
}
