import Foundation
import JutsuCore
import Testing

@testable import Presentation

enum HistoryFixture {
    static let cdn = "https://cdn.example"

    static func url(_ path: String) -> URL { URL(string: "\(cdn)/\(path)") ?? URL(fileURLWithPath: "/") }

    static let inputs = RemoteInputs(
        video: RemoteAsset(url: url("in.mp4"), id: "media-v"),
        images: [RemoteAsset(url: url("a.png"), id: "media-a"), RemoteAsset(url: url("b.png"), id: "media-b")])

    static func item(
        _ id: String, mode: Mode = .motionTransfer, isLiked: Bool = false, prompt: String = "dance"
    ) -> HistoryItem {
        HistoryItem(
            id: id, mode: mode, model: .genjutsu, createdAt: LibraryFixture.now.addingTimeInterval(-7200),
            isLiked: isLiked, outputURL: url("\(id).mp4"), duration: 8, pixelSize: PixelSize(width: 720, height: 1280),
            resolution: .p720, prompt: prompt, inputs: inputs)
    }

    static func page(_ ids: [String], next: String? = nil) -> HistoryPage {
        HistoryPage(items: ids.map { item($0) }, nextCursor: next.map(HistoryCursor.init))
    }
}

extension AccountHistory {
    /// `beginLoad` that must start a load.
    mutating func begin(refresh: Bool, sourceLocation: SourceLocation = #_sourceLocation) throws -> Request {
        let request = beginLoad(refresh: refresh)
        return try #require(request, sourceLocation: sourceLocation)
    }
}

@Suite struct AccountHistoryTests {
    @Test func pagesAppendInOrderUntilTheLastOne() throws {
        var history = AccountHistory(owner: "user_1")
        #expect(history.hasMore)

        let first = try history.begin(refresh: false)
        #expect(first.isRefresh && first.cursor == nil)
        let duplicate = history.beginLoad(refresh: false)
        #expect(duplicate == nil)
        history.receive(HistoryFixture.page(["a", "b"], next: "c1"), for: first)

        let second = try history.begin(refresh: false)
        #expect(second.cursor == HistoryCursor("c1") && !second.isRefresh)
        history.receive(HistoryFixture.page(["b", "c"]), for: second)

        #expect(history.items.map(\.id) == ["a", "b", "c"])
        #expect(!history.hasMore)
        let afterLast = history.beginLoad(refresh: false)
        #expect(afterLast == nil)
    }

    @Test func aLoadInFlightIsNotStartedTwiceButARefreshWins() throws {
        var history = AccountHistory(owner: "user_1")
        let first = try history.begin(refresh: true)
        history.receive(HistoryFixture.page(["a"], next: "c1"), for: first)

        let more = try history.begin(refresh: false)
        let duplicate = history.beginLoad(refresh: false)
        #expect(duplicate == nil)
        let refresh = try history.begin(refresh: true)
        history.receive(HistoryFixture.page(["late"]), for: more)
        history.receive(HistoryFixture.page(["new", "a"], next: "c2"), for: refresh)

        #expect(history.items.map(\.id) == ["new", "a"])
        #expect(history.nextCursor == HistoryCursor("c2"))
    }

    @Test func itemsKeepTheirLibraryIDAcrossRefreshes() throws {
        var history = AccountHistory(owner: "user_1")
        let first = try history.begin(refresh: true)
        history.receive(HistoryFixture.page(["a"]), for: first)
        let id = try #require(history.items.first?.jobID)

        let refresh = try history.begin(refresh: true)
        history.receive(HistoryFixture.page(["a"]), for: refresh)

        #expect(history.items.first?.jobID == id)
    }

    @Test func anEmptyPageAsksForTheNextUntilTooManyInARow() throws {
        var history = AccountHistory(owner: "user_1")
        var continues: [Bool] = []
        var request = try history.begin(refresh: true)
        for _ in 0..<AccountHistory.maxEmptyPagesInARow {
            continues.append(history.receive(HistoryFixture.page([], next: "more"), for: request))
            request = try history.begin(refresh: false)
        }
        #expect(continues == Array(repeating: true, count: AccountHistory.maxEmptyPagesInARow - 1) + [false])
        let continuesAfterItems = history.receive(HistoryFixture.page(["a"], next: "more"), for: request)
        #expect(!continuesAfterItems)
        #expect(history.hasMore)
    }

    @Test func pagingStoppedOnEmptyPagesWaitsForTheUserThenGoesOn() throws {
        var history = AccountHistory(owner: "user_1")
        var request = try history.begin(refresh: true)
        for _ in 1..<AccountHistory.maxEmptyPagesInARow {
            history.receive(HistoryFixture.page([], next: "more"), for: request)
            request = try history.begin(refresh: false)
        }
        let continues = history.receive(HistoryFixture.page([], next: "more"), for: request)
        #expect(!continues && history.isWaitingToLoadMore)

        let asked = try history.begin(refresh: false)
        #expect(!history.isWaitingToLoadMore)
        let continuesWhenAsked = history.receive(HistoryFixture.page([], next: "more"), for: asked)
        #expect(continuesWhenAsked)
    }

    @Test func anotherAccountStartsEmptyAndDropsAnswersForTheOldOne() throws {
        var history = AccountHistory(owner: "user_1")
        let first = try history.begin(refresh: true)
        history.receive(HistoryFixture.page(["a"]), for: first)
        let late = try history.begin(refresh: true)

        history.switchAccount(to: "user_2")
        history.receive(HistoryFixture.page(["b"]), for: late)
        #expect(history.items.isEmpty && !history.hasLoaded)

        history.switchAccount(to: nil)
        #expect(history.owner == nil)
    }

    @Test func aFailedLoadKeepsTheItemsAndOffersARetry() throws {
        var history = AccountHistory(owner: "user_1")
        let first = try history.begin(refresh: true)
        history.receive(HistoryFixture.page(["a"], next: "c1"), for: first)
        let more = try history.begin(refresh: false)

        history.fail(ProviderError.network, for: more)

        #expect(history.items.map(\.id) == ["a"])
        guard case .failed(let message) = history.phase else {
            Issue.record("Expected a failure, got \(history.phase)")
            return
        }
        #expect(!message.title.isEmpty)
        let retry = try history.begin(refresh: false)
        #expect(retry.cursor == HistoryCursor("c1"))
    }

    @Test func historyNeedsASignedInAccount() {
        #expect(HistoryAvailability(.account(AccountInfo(email: "me@example.com"))) == .available)
        guard case .unavailable(let title, _) = HistoryAvailability(.apiKey(keyID: "kid")) else {
            Issue.record("An API key can't read history")
            return
        }
        #expect(title == "History needs a Higgsfield account")
        #expect(HistoryAvailability(.none) != .available)
    }

    @Test func thePlaceholderFollowsTheFirstLoad() throws {
        var history = AccountHistory(owner: "user_1")
        let account = HistoryAvailability.available
        #expect(HistoryPlaceholder(availability: account, history: history, isEmpty: true) == .loading)

        let first = try history.begin(refresh: true)
        #expect(HistoryPlaceholder(availability: account, history: history, isEmpty: true) == .loading)
        history.fail(ProviderError.network, for: first)
        guard case .failed(let message) = HistoryPlaceholder(availability: account, history: history, isEmpty: true)
        else {
            Issue.record("Expected a failed first load")
            return
        }
        #expect(message.title == "Can't reach Higgsfield")

        let retry = try history.begin(refresh: true)
        history.receive(HistoryFixture.page([]), for: retry)
        #expect(HistoryPlaceholder(availability: account, history: history, isEmpty: true) == .empty)
        #expect(HistoryPlaceholder(availability: account, history: history, isEmpty: false) == nil)
    }

    @Test func aConnectionWithoutHistorySaysWhyEvenWithItems() {
        let availability = HistoryAvailability(.apiKey(keyID: "kid"))
        let placeholder = HistoryPlaceholder(availability: availability, history: AccountHistory(), isEmpty: false)
        #expect(
            placeholder
                == .unavailable(
                    title: "History needs a Higgsfield account",
                    detail: "An API key can't read past generations. Sign in to your account in Settings to see them."))
    }

    /// Neither history tool lists a finished Style job (issue #21), so Import says so.
    @Test func importSaysStylesMadeElsewhereArentListed() {
        #expect(
            HistoryAvailability.stylesNote
                == "Styles made outside Jutsu Studio aren't listed: Higgsfield's history doesn't return them.")
        #expect(HistoryAvailability.emptyDetail.hasSuffix(HistoryAvailability.stylesNote))
    }
}

@Suite struct LibraryHistoryTests {
    @Test func aHistoryItemReadsLikeALocalOneWithoutAPrice() throws {
        let item = LibraryItemModel(history: HistoryFixture.item("a", mode: .objectSwap))

        #expect(item.title == "Genjutsu · Object swap")
        #expect(item.modeTag == "Swap")
        #expect(item.durationText == "8 s")
        #expect(item.subtitle(now: LibraryFixture.now) == "720p · 2 h ago")
        #expect(item.billingSummary == "Made on Higgsfield · Higgsfield account")
        #expect(item.outputFile == nil)
        #expect(item.thumbnailURL == HistoryFixture.url("a.mp4"))
        #expect(item.playback(.result) == nil && item.playback(.source) == nil)
    }

    @Test func aLikeOnHiggsfieldIsTheStar() {
        let items = [
            LibraryItemModel(history: HistoryFixture.item("a", isLiked: true)),
            LibraryItemModel(history: HistoryFixture.item("b", prompt: "spin")),
        ]
        #expect(items[0].isStarred && items[0].likeID == "a")
        #expect(LibraryFilter(isStarredOnly: true).apply(items) == [items[0]])
        #expect(LibraryFilter(query: "spin").apply(items) == [items[1]])
    }

}

@Suite struct RemoteInputsFormTests {
    static func remoteVideo(duration: TimeInterval = 8) -> SourceVideo {
        SourceVideo(
            fileURL: HistoryFixture.inputs.video!.url, duration: duration,
            pixelSize: PixelSize(width: 720, height: 1280), codec: "avc1", fileSize: 0)
    }

    static func loaded() -> CreateForm {
        var form = CreateForm()
        let spec = HistoryFixture.item("a").spec(sourceDuration: 8)
        form.load(spec, source: remoteVideo())
        return form
    }

    @Test func editInputsReusesTheMediaIDsAndTheWholeSource() throws {
        let form = Self.loaded()
        let spec = try #require(form.makeSpecs(isDraft: false).first)

        #expect(form.isSourceRemote)
        #expect(spec.remoteInputs == HistoryFixture.inputs)
        #expect(spec.source?.range == 0...8)
        #expect(spec.prompt == "dance")
        #expect(form.makeSpecs(isDraft: true).first?.source?.range == 0...8)
        #expect(!form.showsDraftLength && !form.canAddRange)
        #expect(form.stagePills.contains("On Higgsfield · the whole clip is used"))
        #expect(Self.remoteVideo().name == "Source on Higgsfield")
        #expect(Self.remoteVideo().fileText == "H.264")
    }

    @Test func aRemoteSourceCantBeTrimmed() {
        var form = Self.loaded()
        form.setStart(2)
        form.setEnd(6)
        form.moveRange(toStart: 1)
        form.addRange()
        #expect(form.ranges == [0...8])
    }

    @Test func removedOrReorderedReferencesKeepTheirIDs() throws {
        var form = Self.loaded()
        form.moveReference(at: 1, to: 0)
        form.removeReference(at: 1)

        let inputs = try #require(form.makeSpecs(isDraft: false).first?.remoteInputs)
        #expect(inputs.images.map(\.id) == ["media-b"])
    }

    @Test func aCharacterBatchUploadsEachCharactersOwnImages() throws {
        var form = Self.loaded()
        form.isBatch = true
        _ = form.addCharacterSet(CreateFixture.references([CreateFixture.image(1)]))
        let specs = form.makeSpecs(isDraft: false)

        #expect(specs.count == 2)
        #expect(specs[0].remoteInputs == HistoryFixture.inputs)
        #expect(specs[1].remoteInputs == nil)
    }

    @Test func aLocalFileMeansEverythingIsUploaded() {
        var form = Self.loaded()
        form.addReferences(CreateFixture.references([CreateFixture.image(1)]))
        #expect(form.makeSpecs(isDraft: false).first?.remoteInputs == nil)

        form.setSource(CreateFixture.video())
        #expect(form.remoteInputs == nil && !form.isSourceRemote)
    }
}

/// An imported job's length and size come from its downloaded file, not the params `show_generations` gave (issue
/// #134): a live Seedance Edit's params said 854×480 and 5 s of a 480×854, 3.71 s file.
@Suite struct ImportedOutputMediaTests {
    static let file = OutputMedia(duration: 3.71, pixelSize: PixelSize(width: 480, height: 854))

    static func misstatedEdit() -> HistoryItem {
        HistoryItem(
            id: "edit-1", mode: .edit, model: .seedance25, createdAt: LibraryFixture.now,
            outputURL: HistoryFixture.url("e.mp4"), duration: 5, pixelSize: PixelSize(width: 854, height: 480),
            resolution: .p480, inputs: HistoryFixture.inputs)
    }

    static func imported() -> LibraryItemModel {
        var job = Job(importing: misstatedEdit(), owner: "user_1", importedAt: LibraryFixture.now)
        job.outputFile = URL(fileURLWithPath: "/tmp/edit-1.mp4")
        job.outputMedia = file
        return LibraryItemModel(job: job)
    }

    @Test func beforeTheDownloadTheParamsAreAHint() throws {
        let item = LibraryItemModel(history: Self.misstatedEdit())
        #expect(item.durationText == "5 s")
        #expect(try #require(item.aspectRatio) > 1)
    }

    @Test func theLibraryShowsTheFilesLengthAndShape() throws {
        let item = Self.imported()
        #expect(item.durationText == "4 s")
        #expect(item.facts.contains("4 s") && !item.facts.contains("5 s"))
        #expect(abs(try #require(item.aspectRatio) - 480.0 / 854) < 0.001)
    }

    @Test func operationsAndFollowUpsStartFromTheFile() throws {
        let job = Self.imported().job
        let reframe = try #require(job.operationSpec(.reframe(.square), owner: "user_1"))
        #expect(reframe.source?.range == 0...3.71)
        #expect(reframe.source?.pixelSize == Self.file.pixelSize)
        #expect(reframe.operation?.sourceJobID == "edit-1")

        let extend = try #require(job.followUp(.extend))
        #expect(extend.source?.duration == 3.71)
        #expect(extend.source?.range == 0...3.71)
        #expect(extend.source?.pixelSize == Self.file.pixelSize)
    }
}
