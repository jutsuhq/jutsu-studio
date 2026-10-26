import Foundation

// library_download: a result of the account's Higgsfield history into the Library on this Mac.

/// Downloads results of the Higgsfield history (`library_search` with `include_higgsfield`, `onHiggsfield`) into the
/// Library, as From Higgsfield's download does: the item keeps its ID and gains a file. Free; never spends credits.
public struct LibraryDownloadCommand: Codable, Equatable, Sendable, AgentFields {
    public static let maxIDs = 20

    public var ids: [UUID]

    public init(ids: [UUID]) {
        self.ids = ids
    }

    public var problem: String? { AgentLibraryIDs.problem(ids, limit: Self.maxIDs) }
}

/// What came of one download, in the order asked.
public struct AgentDownload: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable, CaseIterable {
        case downloaded
        /// It had a file on this Mac already; nothing was downloaded.
        case alreadyHere = "already_here"
        case failed
    }

    public var id: UUID
    public var status: Status
    /// Its file on this Mac, when it has one now.
    public var file: String?
    public var message: String?

    public init(id: UUID, status: Status, file: String? = nil, message: String? = nil) {
        self.id = id
        self.status = status
        self.file = file
        self.message = message
    }
}

public struct AgentDownloads: Codable, Equatable, Sendable {
    public var items: [AgentDownload]

    public init(items: [AgentDownload]) {
        self.items = items
    }
}
