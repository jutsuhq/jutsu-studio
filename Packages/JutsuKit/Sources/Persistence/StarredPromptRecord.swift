import Foundation
import SwiftData

/// A starred prompt, pinned on top of the prompt history and kept when the history is cleared.
/// The history itself comes from `JobRecord.prompt`.
@Model
public final class StarredPromptRecord {
    /// Trimmed, as `PromptHistory.key` makes it.
    @Attribute(.unique) public private(set) var text: String
    public private(set) var starredAt: Date

    public init(text: String, starredAt: Date = Date()) {
        self.text = text
        self.starredAt = starredAt
    }

    /// Every starred prompt, most recently starred first.
    public static var newestFirst: FetchDescriptor<StarredPromptRecord> {
        FetchDescriptor<StarredPromptRecord>(sortBy: [SortDescriptor(\StarredPromptRecord.starredAt, order: .reverse)])
    }
}

extension JobRecord {
    /// Jobs with a prompt created after `date` (all of them for `nil`), newest first: the prompt history.
    public static func withPrompts(after date: Date?) -> FetchDescriptor<JobRecord> {
        let start = date ?? .distantPast
        return FetchDescriptor<JobRecord>(
            predicate: #Predicate<JobRecord> { $0.createdAt > start && $0.prompt != "" },
            sortBy: [SortDescriptor(\JobRecord.createdAt, order: .reverse)])
    }
}
