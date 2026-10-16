import Foundation

/// A prompt and when it was used or starred.
public struct PromptUse: Equatable, Sendable {
    public var text: String
    public var date: Date

    public init(text: String, date: Date) {
        self.text = text
        self.date = date
    }
}

/// One row of the prompt picker.
public struct PromptHistoryItem: Equatable, Sendable, Identifiable {
    /// Trimmed; also the identity, since history is deduplicated by it.
    public var text: String
    /// The newest job with this prompt since the last clearing; `nil` for a starred prompt with none.
    public var lastUsed: Date?
    public var isStarred: Bool

    public var id: String { text }

    public init(text: String, lastUsed: Date?, isStarred: Bool) {
        self.text = text
        self.lastUsed = lastUsed
        self.isStarred = isStarred
    }
}

/// Prompt history is derived from submitted jobs; only stars and the clearing date are stored.
public enum PromptHistory {
    /// The text prompts are compared and starred by.
    public static func key(_ prompt: String) -> String {
        prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Starred prompts first, most recently starred first, then the rest by last use, newest first.
    /// Uses at or before `clearedAt` are dropped; starred prompts stay whatever their date.
    public static func items(uses: [PromptUse], starred: [PromptUse], clearedAt: Date?) -> [PromptHistoryItem] {
        var lastUsed: [String: Date] = [:]
        for use in uses {
            let text = key(use.text)
            guard !text.isEmpty, clearedAt.map({ use.date > $0 }) ?? true else { continue }
            lastUsed[text] = max(lastUsed[text] ?? use.date, use.date)
        }

        var starDates: [String: Date] = [:]
        for star in starred {
            let text = key(star.text)
            guard !text.isEmpty else { continue }
            starDates[text] = max(starDates[text] ?? star.date, star.date)
        }

        let pinned = starDates.sorted { newestFirst(($0.value, $0.key), ($1.value, $1.key)) }
            .map { PromptHistoryItem(text: $0.key, lastUsed: lastUsed[$0.key], isStarred: true) }
        let recent = lastUsed.filter { starDates[$0.key] == nil }
            .sorted { newestFirst(($0.value, $0.key), ($1.value, $1.key)) }
            .map { PromptHistoryItem(text: $0.key, lastUsed: $0.value, isStarred: false) }
        return pinned + recent
    }

    /// Items containing every word of `query`, ignoring case and accents, in their order.
    public static func search(_ items: [PromptHistoryItem], query: String) -> [PromptHistoryItem] {
        let words = query.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).map(String.init)
        guard !words.isEmpty else { return items }
        return items.filter { item in
            words.allSatisfy { item.text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }

    /// Ties on the date are ordered by text so the list doesn't reshuffle between renders.
    private static func newestFirst(_ lhs: (Date, String), _ rhs: (Date, String)) -> Bool {
        lhs.0 == rhs.0 ? lhs.1 < rhs.1 : lhs.0 > rhs.0
    }
}
