import Foundation
import JutsuCore
import Observation

/// The server's model constraints of one account, as last read, with when.
public struct CachedConstraints: Sendable, Hashable, Codable {
    public var fetchedAt: Date
    public var table: ModelConstraintTable

    public init(fetchedAt: Date, table: ModelConstraintTable) {
        self.fetchedAt = fetchedAt
        self.table = table
    }

    /// Read again after a day.
    public static let maxAge: TimeInterval = 24 * 60 * 60

    /// Read less than `maxAge` ago. A read dated after `now` (the clock was turned back) is stale too, or it would
    /// stay fresh for as long as the clock is off.
    public func isFresh(at now: Date) -> Bool {
        Self.isFresh(readAt: fetchedAt, now: now)
    }

    static func isFresh(readAt date: Date, now: Date) -> Bool {
        let age = now.timeIntervalSince(date)
        return age >= 0 && age < maxAge
    }
}

/// The file the constraints of every account the app connected are cached in, by `GenerationProvider.owner`. One
/// that is missing, unreadable or of another version reads as empty, so the constants are used.
public struct ModelConstraintCache: Sendable {
    public static let fileName = "model-constraints.json"
    static let version = 1

    public let fileURL: URL

    public init(folder: URL) {
        fileURL = folder.appendingPathComponent(Self.fileName)
    }

    private struct File: Codable {
        var version: Int
        var accounts: [String: CachedConstraints]
    }

    /// The constraints cached for `account`; `nil` when there are none or the file can't be read.
    public func read(account: String) -> CachedConstraints? {
        readAll()[account]
    }

    /// Replaces `account`'s constraints, keeping the other accounts'.
    public func write(_ constraints: CachedConstraints, account: String) throws {
        var accounts = readAll()
        accounts[account] = constraints
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(File(version: Self.version, accounts: accounts)).write(to: fileURL, options: .atomic)
    }

    private func readAll() -> [String: CachedConstraints] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: fileURL),
            let file = try? decoder.decode(File.self, from: data), file.version == Self.version
        else { return [:] }
        return file.accounts
    }
}

/// The model constraints Create's limits are read through (`CreateForm.constraints`): the active account's cached
/// table, read again from the server when the account connects and at most once a day after that. Never on a form
/// edit: nothing here runs unless the app calls `switchAccount` or `refreshIfStale`. Without a cache, or for a
/// connection that can't report constraints, the table is `builtIn`, the constants.
@MainActor
@Observable
public final class ModelConstraintStore {
    public private(set) var table = ModelConstraintTable.builtIn

    @ObservationIgnored private let cache: ModelConstraintCache
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var account: String?
    /// When the active account's table was read from the server, or a read found nothing to read.
    @ObservationIgnored private var checkedAt: Date?
    @ObservationIgnored private var isRefreshing = false
    /// Called with the new table whenever it changes.
    @ObservationIgnored public var onChange: (@MainActor (ModelConstraintTable) -> Void)?

    public init(cache: ModelConstraintCache, now: @escaping @Sendable () -> Date = { Date() }) {
        self.cache = cache
        self.now = now
    }

    /// Shows `account`'s cached table, or the constants for `nil` (no connection, or one without constraints).
    /// The file is read off the main actor.
    public func switchAccount(to account: String?) async {
        self.account = account
        checkedAt = nil
        let cached: CachedConstraints? =
            if let account { await Self.read(cache, account: account) } else { nil }
        guard self.account == account else { return }
        checkedAt = cached?.fetchedAt
        use(cached?.table ?? .builtIn)
    }

    private nonisolated static func read(_ cache: ModelConstraintCache, account: String) async -> CachedConstraints? {
        cache.read(account: account)
    }

    /// Whether `refreshIfStale` would read the server now.
    public var isStale: Bool {
        guard account != nil else { return false }
        guard let checkedAt else { return true }
        return !CachedConstraints.isFresh(readAt: checkedAt, now: now())
    }

    /// Reads the table with `fetch` when the account's is a day old or missing, and caches it. `fetch` answering
    /// `nil` (the connection can't report constraints) keeps the table there is until the next day; a failed read
    /// keeps it too, and the next call tries again.
    public func refreshIfStale(_ fetch: @Sendable () async throws -> ModelConstraintTable?) async {
        guard isStale, !isRefreshing, let account else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let fetched: ModelConstraintTable?
        do {
            fetched = try await fetch()
        } catch {
            return
        }
        let readAt = now()
        if let fetched { try? cache.write(CachedConstraints(fetchedAt: readAt, table: fetched), account: account) }
        guard self.account == account else { return }
        checkedAt = readAt
        if let fetched { use(fetched) }
    }

    private func use(_ table: ModelConstraintTable) {
        guard table != self.table else { return }
        self.table = table
        onChange?(table)
    }
}
