import Foundation
import JutsuCore
import Testing

@testable import Presentation

/// A clock the tests move by hand.
private final class TestClock: @unchecked Sendable {
    // Only read and written by one test at a time, on the main actor, through `now`.
    var date = Date(timeIntervalSinceReferenceDate: 800_000_000)
    var now: @Sendable () -> Date { { self.date } }
}

/// Counts the reads of the server and answers with `answer`.
private actor Fetcher {
    var reads = 0
    var answer: Result<ModelConstraintTable?, any Error>

    init(_ answer: Result<ModelConstraintTable?, any Error>) {
        self.answer = answer
    }

    func fetch() throws -> ModelConstraintTable? {
        reads += 1
        return try answer.get()
    }

    func answer(_ new: Result<ModelConstraintTable?, any Error>) {
        answer = new
    }
}

@MainActor
@Suite struct ModelConstraintStoreTests {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
        "model-constraints-\(UUID().uuidString)", isDirectory: true)
    var cache: ModelConstraintCache { ModelConstraintCache(folder: folder) }

    nonisolated static let seedance45 = ModelConstraintTable(entries: [
        .init(model: .seedance25, mode: .motionTransfer, constraints: ModelConstraints(maxDuration: 45))
    ])

    /// The cache file as the app writes it, with `entries` for `account`.
    func writeFixture(
        account: String = "account|user_1", fetchedAt: String = "2026-10-15T08:00:00Z", entries: String
    )
        throws
    {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let json = """
            {"version": 1, "accounts": {"\(account)": {"fetchedAt": "\(fetchedAt)", "table": {"entries": \(entries)}}}}
            """
        try Data(json.utf8).write(to: cache.fileURL)
    }

    static func seedanceForm(seconds: TimeInterval) -> CreateForm {
        var form = CreateForm(mode: .motionTransfer)
        form.model = .seedance25
        form.setSource(CreateFixture.video(duration: seconds))
        form.addReferences(CreateFixture.references([CreateFixture.image(1)]))
        return form
    }

    // MARK: Create follows the cached JSON

    @Test func aLimitChangedInTheCachedJSONChangesWhatCreateAllows() async throws {
        let store = ModelConstraintStore(cache: cache)
        try writeFixture(
            entries: #"[{"model": "seedance25", "mode": "motionTransfer", "constraints": {"maxDuration": 45}}]"#)
        await store.switchAccount(to: "account|user_1")

        var form = Self.seedanceForm(seconds: 40)
        #expect(form.range == 0...30)  // the constants, before the app hands the table over
        form.constraints = store.table
        #expect(form.limits.duration == 4...45)
        form.setSource(CreateFixture.video(duration: 40))
        #expect(form.range == 0...40)
        #expect(form.validationBlocker(form.makeSpecs(isDraft: false)) == nil)

        try writeFixture(
            entries: #"[{"model": "seedance25", "mode": "motionTransfer", "constraints": {"maxDuration": 20}}]"#)
        await store.switchAccount(to: "account|user_1")
        form.constraints = store.table
        #expect(form.limits.duration == 4...20)
        #expect(form.range == 0...20)  // brought inside the new limit
    }

    @Test func fieldsMissingFromTheCacheFallBackToTheConstants() async throws {
        let store = ModelConstraintStore(cache: cache)
        try writeFixture(
            entries: #"[{"model": "seedance25", "mode": "motionTransfer", "constraints": {"maxReferenceImages": 3}}]"#)
        await store.switchAccount(to: "account|user_1")
        var form = Self.seedanceForm(seconds: 10)
        form.constraints = store.table
        #expect(form.limits == ModeLimits(referenceImages: 1...3, requiresPreset: false, duration: 4...30))
    }

    @Test(arguments: [
        "not json", "{}", #"{"version": 2, "accounts": {}}"#, #"{"version": 1, "accounts": []}"#,
        #"{"version": 1, "accounts": {"account|user_1": {"fetchedAt": "yesterday", "table": {"entries": []}}}}"#,
        #"{"version": 1, "accounts": {"account|user_1": {"fetchedAt": "2026-10-15T08:00:00Z", "table": {"entries": 7}}}}"#,
    ])
    func anUnreadableCacheIsIgnored(contents: String) async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: cache.fileURL)
        #expect(cache.read(account: "account|user_1") == nil)
        let store = ModelConstraintStore(cache: cache)
        await store.switchAccount(to: "account|user_1")
        #expect(store.table == .builtIn)
        #expect(store.isStale)
    }

    @Test func eachAccountHasItsOwnTable() async throws {
        let clock = TestClock()
        let store = ModelConstraintStore(cache: cache, now: clock.now)
        await store.switchAccount(to: "account|a")
        await store.refreshIfStale { Self.seedance45 }
        await store.switchAccount(to: "account|b")
        #expect(store.table == .builtIn)
        await store.switchAccount(to: nil)
        #expect(store.table == .builtIn)
        #expect(!store.isStale)  // nothing to read without an account
        await store.switchAccount(to: "account|a")
        #expect(store.table == Self.seedance45)
    }

    // MARK: Age

    @Test func aReadIsFreshForADay() {
        let read = CachedConstraints(fetchedAt: Date(timeIntervalSinceReferenceDate: 1_000), table: .builtIn)
        #expect(read.isFresh(at: read.fetchedAt))
        #expect(read.isFresh(at: read.fetchedAt + CachedConstraints.maxAge - 1))
        #expect(!read.isFresh(at: read.fetchedAt + CachedConstraints.maxAge))
        #expect(!read.isFresh(at: read.fetchedAt - 60))  // dated in the future: the clock was turned back
    }

    @Test func aFreshCacheIsNotReadAgainAndAStaleOneIs() async throws {
        let clock = TestClock()
        let fetcher = Fetcher(.success(Self.seedance45))
        let store = ModelConstraintStore(cache: cache, now: clock.now)
        try cache.write(CachedConstraints(fetchedAt: clock.date - 3600, table: .builtIn), account: "account|user_1")

        await store.switchAccount(to: "account|user_1")
        await store.refreshIfStale { try await fetcher.fetch() }
        #expect(await fetcher.reads == 0)
        #expect(store.table == .builtIn)

        clock.date += CachedConstraints.maxAge
        await store.refreshIfStale { try await fetcher.fetch() }
        #expect(await fetcher.reads == 1)
        #expect(store.table == Self.seedance45)
        #expect(
            cache.read(account: "account|user_1") == CachedConstraints(fetchedAt: clock.date, table: Self.seedance45))
    }

    @Test func repeatedLoadsReadTheServerOnceADay() async throws {
        let clock = TestClock()
        let fetcher = Fetcher(.success(Self.seedance45))
        let store = ModelConstraintStore(cache: cache, now: clock.now)
        await store.switchAccount(to: "account|user_1")
        var form = Self.seedanceForm(seconds: 40)
        for seconds in [10.0, 20, 35] {
            await store.refreshIfStale { try await fetcher.fetch() }
            form.constraints = store.table
            form.setSource(CreateFixture.video(duration: seconds))
            form.prompt = "take \(seconds)"
            form.resolution = .p1080
        }
        #expect(await fetcher.reads == 1)
        #expect(form.range == 0...35)
    }

    @Test func aFailedReadIsTriedAgainAndKeepsTheTable() async throws {
        let clock = TestClock()
        let fetcher = Fetcher(.failure(URLError(.notConnectedToInternet)))
        let store = ModelConstraintStore(cache: cache, now: clock.now)
        await store.switchAccount(to: "account|user_1")
        await store.refreshIfStale { try await fetcher.fetch() }
        #expect(store.table == .builtIn)
        #expect(store.isStale)
        #expect(cache.read(account: "account|user_1") == nil)

        await fetcher.answer(.success(Self.seedance45))
        await store.refreshIfStale { try await fetcher.fetch() }
        #expect(await fetcher.reads == 2)
        #expect(store.table == Self.seedance45)
    }

    @Test func noAnswerWaitsForTheNextDay() async throws {
        let clock = TestClock()
        let fetcher = Fetcher(.success(nil))
        let store = ModelConstraintStore(cache: cache, now: clock.now)
        await store.switchAccount(to: "account|user_1")
        await store.refreshIfStale { try await fetcher.fetch() }
        await store.refreshIfStale { try await fetcher.fetch() }
        #expect(await fetcher.reads == 1)
        #expect(store.table == .builtIn)
        clock.date += CachedConstraints.maxAge
        await store.refreshIfStale { try await fetcher.fetch() }
        #expect(await fetcher.reads == 2)
    }

    @Test func onChangeHearsOnlyRealChanges() async throws {
        let clock = TestClock()
        let store = ModelConstraintStore(cache: cache, now: clock.now)
        var heard: [ModelConstraintTable] = []
        store.onChange = { heard.append($0) }
        await store.switchAccount(to: "account|user_1")
        await store.refreshIfStale { Self.seedance45 }
        clock.date += CachedConstraints.maxAge
        await store.refreshIfStale { Self.seedance45 }
        #expect(heard == [Self.seedance45])
    }

    // MARK: The form

    @Test func aTighterTableBringsTheFormInside() {
        var form = Self.seedanceForm(seconds: 28)
        form.addReferences(CreateFixture.references([CreateFixture.image(2), CreateFixture.image(3)]))
        form.constraints = ModelConstraintTable(entries: [
            .init(
                model: .seedance25, mode: .motionTransfer,
                constraints: ModelConstraints(maxDuration: 12, maxReferenceImages: 2))
        ])
        #expect(form.range == 0...12)
        #expect(form.references.count == 2)
        form.constraints = nil
        #expect(form.limits.duration == 4...30)
    }

    @Test func aDraftSavedWithoutConstraintsStillDecodes() throws {
        var form = Self.seedanceForm(seconds: 10)
        form.constraints = Self.seedance45
        let data = try JSONEncoder().encode(form)
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["constraints"] = nil
        let decoded = try JSONDecoder().decode(CreateForm.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.constraints == nil)
        #expect(decoded.limits.duration == 4...30)
    }
}
