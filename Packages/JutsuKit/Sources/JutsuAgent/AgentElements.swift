import Foundation

// elements: the account's reference elements (characters, environments, props) by name, as References › From
// Higgsfield lists them, and the @ImageN tags a request's images get.

/// Lists the account's reference elements, in the account's order: name words, a category, a page at a time.
/// Read-only and free.
public struct ElementsCommand: Codable, Equatable, Sendable, AgentFields {
    public static let defaultLimit = 20
    public static let maxLimit = 50
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
        if let query, query.unicodeScalars.count > 200 { return "query is at most 200 characters" }
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

    public init(id: String, name: String, category: String? = nil, imageCount: Int? = nil) {
        self.id = id
        self.name = name
        self.category = category
        self.imageCount = imageCount
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
