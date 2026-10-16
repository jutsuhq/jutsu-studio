import Foundation
import JutsuCore
import Testing

@testable import Presentation

/// Records every like it is asked for; refuses the IDs in `refused`.
private struct FakeLikes: GenerationLikes {
    var refused: Set<String> = []
    let calls = Box<[String]>([])

    func setLiked(_ requestID: String, _ isLiked: Bool) async throws {
        calls.update { $0.append("\(requestID) \(isLiked)") }
        if refused.contains(requestID) { throw ProviderError.server(status: 500) }
    }
}

@MainActor
private final class FakeStars: LibraryStarStore {
    private(set) var writes: [String] = []

    func setStarred(_ isStarred: Bool, for id: UUID) {
        writes.append("\(id.uuidString.prefix(4)) \(isStarred)")
    }
}

@MainActor
@Suite struct LibraryStarringTests {
    /// A result the account `owner` ran, with `requestID` as its like.
    static func accountItem(_ requestID: String, owner: String? = "user_1", isStarred: Bool = false) -> LibraryItemModel
    {
        var item = LibraryFixture.item()
        item.job.providerKind = .account
        item.job.owner = owner
        item.job.remote = RemoteJob(requestID: requestID)
        item.isStarred = isStarred
        return item
    }

    static func key(_ item: LibraryItemModel, _ isStarred: Bool) -> String {
        "\(item.id.uuidString.prefix(4)) \(isStarred)"
    }

    @Test func theLikeFollowsTheStarOnlyForTheConnectedAccountsResults() {
        let account = LibraryStarring(likes: FakeLikes(), owner: "user_1")
        let apiKey = LibraryStarring(likes: nil, owner: nil)
        let history = LibraryItemModel(history: HistoryFixture.item("h"))

        #expect(account.syncsLike(Self.accountItem("a")))
        #expect(!account.syncsLike(Self.accountItem("a", owner: "user_2")))
        #expect(account.syncsLike(history))
        #expect(!account.syncsLike(LibraryFixture.item()))
        #expect(!apiKey.syncsLike(Self.accountItem("a")))

        #expect(apiKey.canStar(Self.accountItem("a")))
        #expect(!apiKey.canStar(history))
        #expect(account.canStar(history))
    }

    @Test func anAcceptedLikeKeepsTheStarAndReachesTheHistory() async throws {
        let likes = FakeLikes()
        let stars = FakeStars()
        let item = Self.accountItem("a")
        var liked: [String] = []

        try await LibraryStarring(likes: likes, owner: "user_1").setStarred(true, for: item, in: stars) {
            liked.append("\($0) \($1)")
        }

        #expect(stars.writes == [Self.key(item, true)])
        #expect(likes.calls.value == ["a true"])
        #expect(liked == ["a true"])
    }

    @Test func aRefusedLikePutsTheStarBackAndIsRethrown() async {
        let likes = FakeLikes(refused: ["a"])
        let stars = FakeStars()
        let item = Self.accountItem("a", isStarred: true)
        var liked: [String] = []

        await #expect(throws: ProviderError.server(status: 500)) {
            try await LibraryStarring(likes: likes, owner: "user_1").setStarred(false, for: item, in: stars) {
                liked.append("\($0) \($1)")
            }
        }

        #expect(stars.writes == [Self.key(item, false), Self.key(item, true)])
        #expect(liked.isEmpty)
    }

    @Test func aLocalStarNeverAsksHiggsfield() async throws {
        let likes = FakeLikes()
        let stars = FakeStars()
        let item = LibraryFixture.item()

        try await LibraryStarring(likes: likes, owner: "user_1").setStarred(true, for: item, in: stars) { _, _ in }

        #expect(stars.writes == [Self.key(item, true)])
        #expect(likes.calls.value.isEmpty)
    }

    @Test func aBatchSkipsResultsAlreadySoAndStopsAtTheFirstRefusal() async {
        let likes = FakeLikes(refused: ["b"])
        let stars = FakeStars()
        let items = [
            Self.accountItem("done", isStarred: true), Self.accountItem("a"), Self.accountItem("b"),
            Self.accountItem("c"),
        ]

        await #expect(throws: ProviderError.server(status: 500)) {
            try await LibraryStarring(likes: likes, owner: "user_1").setStarred(true, items, in: stars) { _, _ in }
        }

        #expect(likes.calls.value == ["a true", "b true"])
        #expect(stars.writes == [Self.key(items[1], true), Self.key(items[2], true), Self.key(items[2], false)])
    }
}
