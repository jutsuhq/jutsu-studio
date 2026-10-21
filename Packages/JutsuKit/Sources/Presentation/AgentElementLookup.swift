import Foundation
import JutsuCore

/// The account's reference elements as agents name them: `elements` lists them with References › From Higgsfield's
/// own source, and `create_video`, `quote` and `create_image` take them by name.
public enum AgentElementLookup {
    /// Pages read for one answer, so a name that matches nothing never walks a whole account.
    public static let maxPages = 20

    /// Whether `element` has every word of `query` in its name, in any case, and is of `category`.
    public static func matches(_ element: AccountElement, query: String, category: ElementCategory?) -> Bool {
        if let category, element.category != category { return false }
        let name = element.name.lowercased()
        return query.lowercased().split(whereSeparator: \.isWhitespace).allSatisfy { name.contains($0) }
    }

    public enum Found: Sendable, Hashable {
        case element(AccountElement)
        /// Several elements have the name: the agent names one by its exact name, or the person renames one.
        case ambiguous(count: Int)
        case missing
    }

    /// The account's elements, page after page until the last or `maxPages`: a name is known to be one element only
    /// once they are all read, as a second one of that name may be on a later page.
    public static func all(in source: any AccountElements) async throws -> [AccountElement] {
        var elements: [AccountElement] = []
        var cursor: HistoryCursor?
        for _ in 0..<maxPages {
            let read = try await source.elements(after: cursor)
            elements += read.items
            cursor = read.nextCursor
            if cursor == nil { break }
        }
        return elements
    }

    /// The element named `name`, in any case, among `elements`.
    public static func find(_ name: String, in elements: [AccountElement]) -> Found {
        let wanted = name.trimmingCharacters(in: .whitespaces).lowercased()
        let named = elements.filter { $0.name.trimmingCharacters(in: .whitespaces).lowercased() == wanted }
        switch named.count {
        case 0: return .missing
        case 1: return .element(named[0])
        default: return .ambiguous(count: named.count)
        }
    }

    /// One image a request sends, by the tag its prompt names it with.
    public struct Reference: Sendable, Hashable {
        /// "@Image1", "@Image2"…
        public var tag: String
        /// The element's name; `nil` for the agent's own file.
        public var element: String?
        public var image: LocalImage
    }

    /// Each image of a request, in the order it is sent, with the element it belongs to: the elements' images first,
    /// in the order named, then the agent's own files.
    public static func references(
        elements: [(name: String, images: [LocalImage])], files: [LocalImage]
    ) -> [Reference] {
        let all =
            elements.flatMap { element in element.images.map { (Optional(element.name), $0) } }
            + files.map { (String?.none, $0) }
        return all.enumerated().map { index, pair in
            Reference(tag: "@Image\(index + 1)", element: pair.0, image: pair.1)
        }
    }
}
