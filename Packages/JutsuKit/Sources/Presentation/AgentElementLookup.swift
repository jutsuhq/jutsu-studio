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
        /// Not every element was read (`maxPages`): one of the name, or a second one, may come later.
        case unchecked
    }

    /// One answer of `elements`: at most `limit` elements that match `query` and `category`, read page after page from
    /// `cursor` until there are `limit`, the last page or `maxPages`, and the cursor to go on from, `nil` after the
    /// last element. A page cut short hands out a cursor into it (`Position`), so no element is skipped or repeated.
    public static func page(
        in source: any AccountElements, query: String, category: ElementCategory?, limit: Int, after cursor: String?
    ) async throws -> (items: [AccountElement], nextCursor: String?) {
        let limit = max(1, limit)
        var position = cursor.map(Position.init(text:)) ?? Position(page: nil, skip: 0)
        var items: [AccountElement] = []
        for _ in 0..<maxPages {
            let read = try await source.elements(after: position.page)
            for (index, element) in read.items.enumerated().dropFirst(position.skip)
            where matches(element, query: query, category: category) {
                items.append(element)
                guard items.count == limit else { continue }
                if index + 1 < read.items.count { return (items, Position(page: position.page, skip: index + 1).text) }
                return (items, read.nextCursor.map { Position(page: $0, skip: 0).text })
            }
            guard let next = read.nextCursor else { return (items, nil) }
            position = Position(page: next, skip: 0)
        }
        return (items, position.text)
    }

    /// Where a page of `elements` ended: the account's cursor of the page it ended in (`nil` for the first) and how
    /// many of that page's elements came before. As text, the account's cursor alone when none did, else
    /// `<skip>@<cursor>`.
    struct Position: Hashable {
        var page: HistoryCursor?
        var skip: Int

        init(page: HistoryCursor?, skip: Int) {
            self.page = page
            self.skip = skip
        }

        init(text: String) {
            let parts = text.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2, let skip = Int(parts[0]), skip > 0 {
                self.init(page: parts[1].isEmpty ? nil : HistoryCursor(String(parts[1])), skip: skip)
            } else {
                self.init(page: HistoryCursor(text), skip: 0)
            }
        }

        var text: String {
            skip > 0 ? "\(skip)@\(page?.value ?? "")" : page?.value ?? ""
        }
    }

    /// The account's elements, page after page until the last or `maxPages`, and whether that was all of them: a name
    /// is known to be one element only once they are all read, as a second one of that name may be on a later page.
    public static func all(
        in source: any AccountElements
    ) async throws -> (elements: [AccountElement], isComplete: Bool) {
        var elements: [AccountElement] = []
        var cursor: HistoryCursor?
        for _ in 0..<maxPages {
            let read = try await source.elements(after: cursor)
            elements += read.items
            cursor = read.nextCursor
            if cursor == nil { return (elements, true) }
        }
        return (elements, false)
    }

    /// The element named `name`, in any case, among `elements`; `isComplete` false when they aren't all the
    /// account's, so only two of the name are certain.
    public static func find(_ name: String, in elements: [AccountElement], isComplete: Bool = true) -> Found {
        let wanted = name.trimmingCharacters(in: .whitespaces).lowercased()
        let named = elements.filter { $0.name.trimmingCharacters(in: .whitespaces).lowercased() == wanted }
        if named.count > 1 { return .ambiguous(count: named.count) }
        guard isComplete else { return .unchecked }
        return named.first.map(Found.element) ?? .missing
    }

    /// A named element's images as files on this Mac, in the element's order, as a request sends them.
    public struct ElementImages: Sendable, Hashable {
        public var name: String
        public var images: [LocalImage]

        public init(name: String, images: [LocalImage]) {
            self.name = name
            self.images = images
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
        elements: [ElementImages], files: [LocalImage]
    ) -> [Reference] {
        let all =
            elements.flatMap { element in element.images.map { (Optional(element.name), $0) } }
            + files.map { (String?.none, $0) }
        return all.enumerated().map { index, pair in
            Reference(tag: "@Image\(index + 1)", element: pair.0, image: pair.1)
        }
    }
}
