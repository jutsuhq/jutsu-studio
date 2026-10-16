import Foundation
import JutsuCore
import JutsuTestSupport
import Testing

@testable import Presentation

/// A character sheet maker whose answers the test scripts: `statuses` are handed out in order, the last one repeated.
private actor FakeMaker: CharacterSheetMaker {
    nonisolated let owner: String? = "user_1"
    var credits = 23.2
    var quoteError: ProviderError?
    var submitError: ProviderError?
    var jobIDs = ["job-1", "job-2"]
    var statuses: [[String: ImageJobStatus]] = [
        ["job-1": .completed([URL(string: "https://cdn.example.com/1.png")!]), "job-2": .pending],
        ["job-2": .completed([URL(string: "https://cdn.example.com/2.png")!])],
    ]
    private(set) var designs: [CharacterDesign] = []
    private(set) var submitted: [CharacterQuote] = []
    private(set) var uploads = 0
    private(set) var polls = 0
    /// Holds the submit until opened, when set.
    var submitGate: Gate<Void>?
    /// Thrown by every poll while set: the statuses couldn't be read.
    var pollError: ProviderError?

    func set(
        quoteError: ProviderError? = nil, submitError: ProviderError? = nil,
        statuses: [[String: ImageJobStatus]]? = nil, submitGate: Gate<Void>? = nil
    ) {
        self.quoteError = quoteError
        self.submitError = submitError
        if let statuses { self.statuses = statuses }
        self.submitGate = submitGate
    }

    func failPolls(with error: ProviderError?) {
        pollError = error
    }

    func characterTraits(for tier: CharacterTier) async throws -> [CharacterTraitGroup] {
        [
            CharacterTraitGroup(
                id: "hair", title: "Hair", maxPicks: 2,
                traits: [
                    CharacterTrait(id: "curly", title: "Curly"), CharacterTrait(id: "bald", title: "Bald"),
                    CharacterTrait(id: "long", title: "Long"),
                ])
        ]
    }

    func characterPresets(after cursor: HistoryCursor?) async throws -> CharacterPresetPage {
        CharacterPresetPage(items: [], nextCursor: nil)
    }

    func characterSheets(after cursor: HistoryCursor?) async throws -> CharacterSheetPage {
        throw ProviderError.validation(field: nil, message: "Not available for this account")
    }

    func upload(_ file: PreparedFile) async throws -> RemoteAsset {
        uploads += 1
        return RemoteAsset(url: URL(string: "https://cdn.example.com/in.png")!, id: "media-\(uploads)")
    }

    func quoteCharacters(_ design: CharacterDesign) async throws -> CharacterQuote {
        designs.append(design)
        if let quoteError { throw quoteError }
        return CharacterQuote(credits: credits, count: design.count, request: Data("q\(designs.count)".utf8))
    }

    func generateCharacters(_ quote: CharacterQuote) async throws -> [RemoteJob] {
        submitted.append(quote)
        if let submitGate { try await submitGate.wait() }
        if let submitError { throw submitError }
        return jobIDs.map { RemoteJob(requestID: $0) }
    }

    func characterSheetStatuses(_ jobs: [RemoteJob]) async throws -> [String: ImageJobStatus] {
        polls += 1
        if let pollError { throw pollError }
        return statuses.count > 1 ? statuses.removeFirst() : statuses[0]
    }
}

private let face = LocalImage(fileURL: URL(fileURLWithPath: "/tmp/face.png"))
private let style = LocalImage(fileURL: URL(fileURLWithPath: "/tmp/style.png"))

@MainActor
@Suite struct CharacterBuilderTests {
    let spend = ImageSpendLog(folder: nil)
    let log = CharacterSheetLog(folder: nil)

    func builder() -> CharacterBuilder {
        CharacterBuilder(log: log, spend: spend, sleep: { _ in await Task.yield() })
    }

    /// Uploads through the fake maker, as the app uploads through the provider.
    fileprivate func upload(_ maker: FakeMaker) -> (LocalImage) async throws -> RemoteAsset {
        { _ in
            try await maker.upload(
                PreparedFile(
                    fileURL: URL(fileURLWithPath: "/tmp/x.png"), contentType: "image/png", byteCount: 1,
                    contentHash: "x"))
        }
    }

    @Test func traitsKeepToTheGroupsLimitAndATierChangeDropsThem() async {
        let builder = builder()
        await builder.loadTraits(from: FakeMaker())
        let group = builder.traitGroups[0]

        for trait in group.traits { builder.toggle(trait, in: group) }
        #expect(builder.traits == ["hair": ["bald", "long"]])
        builder.toggle(group.traits[1], in: group)
        #expect(builder.traits == ["hair": ["long"]])

        builder.selectKind(.animal)
        #expect(builder.tier == .insects)
        #expect(builder.traits.isEmpty)
    }

    @Test func aPresetFillsTheFormAndKeepsItsDesign() {
        let builder = builder()
        let preset = CharacterPreset(
            id: "p", name: "Chef", previewURL: nil,
            settings: CharacterPresetSettings(tier: .cats, traits: ["fur": ["ginger"]], brief: "a chef", seed: 12))

        builder.apply(preset)

        #expect(builder.tier == .cats)
        #expect(builder.kind == .animal)
        #expect(builder.traits == ["fur": ["ginger"]])
        #expect(builder.brief == "a chef")
        #expect(builder.seed == 12)
        #expect(builder.randomize == false)
        builder.clearPreset()
        #expect(builder.seed == nil)
        #expect(builder.preset == nil)
    }

    @Test func theQuoteUploadsTheImagesOnceAndBelongsToTheFormItPriced() async {
        let maker = FakeMaker()
        let builder = builder()
        builder.face = face
        builder.addStyles([style, style, style, style])
        builder.count = 2
        #expect(builder.styles.count == 3)

        await builder.refreshQuote(maker: maker, upload: upload(maker))
        #expect(builder.currentQuote?.credits == 23.2)
        #expect(builder.currentQuote?.cost == .credits(Decimal(string: "23.2")!, isEstimate: false))
        builder.brief = "a magician"
        #expect(builder.currentQuote == nil)
        #expect(builder.isQuoting)
        await builder.refreshQuote(maker: maker, upload: upload(maker))

        let designs = await maker.designs
        #expect(designs.count == 2)
        #expect(designs[1].brief == "a magician")
        #expect(designs[1].count == 2)
        #expect(designs[1].face?.id != nil)
        #expect(designs[1].styles.count == 3)
        // Two distinct files: the face and the style, each uploaded once.
        #expect(await maker.uploads == 2)
    }

    @Test func aFailedQuoteSaysWhyAndGenerateStaysOff() async {
        let maker = FakeMaker()
        await maker.set(quoteError: .validation(field: nil, message: "Unknown trait"))
        let builder = builder()

        await builder.refreshQuote(maker: maker, upload: upload(maker))

        #expect(builder.quoteFailure == "Unknown trait")
        #expect(!builder.isQuoting)
        #expect(await builder.generate(maker: maker) == .notStarted)
        #expect(await maker.submitted.isEmpty)
    }

    @Test func generateSendsTheQuoteOnceTracksEveryJobAndSavesTheSheets() async throws {
        let maker = FakeMaker()
        let builder = builder()
        var saved: [String] = []
        builder.onSheets = { saved += $0.map(\.id) }
        builder.brief = "a magician"
        await builder.refreshQuote(maker: maker, upload: upload(maker))
        let quote = try #require(builder.currentQuote)

        #expect(await builder.generate(maker: maker) == .started)
        // A second click while the submit is out sends nothing.
        #expect(await builder.generate(maker: maker) == .notStarted)
        #expect(spend.charges.map(\.cost) == [.credits(Decimal(string: "23.2")!, isEstimate: false)])
        #expect(spend.charges.first?.purpose == .characterSheets)
        await eventually { builder.runs.first?.state == .finished }

        #expect(await maker.submitted == [quote])
        #expect(log.records.map(\.id) == ["job-1", "job-2"])
        #expect(log.records.allSatisfy { $0.state == .completed && $0.owner == "user_1" && $0.brief == "a magician" })
        #expect(saved == ["job-1", "job-2"])
        #expect(log.sheets(of: "user_1").map(\.id) == ["job-2", "job-1"])
        #expect(log.sheets(of: "user_2").isEmpty)
        #expect(spend.charges.first?.isPending == false)
        // The quote was used: the next Generate is quoted again.
        #expect(builder.currentQuote == nil)
    }

    @Test func aSubmitWithAnUnknownOutcomeIsNeverResentAndKeepsItsPrice() async throws {
        let maker = FakeMaker()
        await maker.set(submitError: .outcomeUnknown)
        let builder = builder()
        await builder.refreshQuote(maker: maker, upload: upload(maker))

        #expect(await builder.generate(maker: maker) == .started)
        await eventually { builder.runs.first?.state != .sending }

        #expect(builder.runs.first?.state == .failed(CharacterBuilder.mayHaveStarted))
        #expect(await maker.submitted.count == 1)
        #expect(spend.charges.count == 1)
        #expect(spend.charges.first?.isPending == false)
        #expect(log.records.isEmpty)
        #expect(!builder.isSubmitting)
    }

    @Test func aRefusedSubmitIsNotCharged() async throws {
        let maker = FakeMaker()
        await maker.set(submitError: .validation(field: nil, message: "Price is above max_credits"))
        let builder = builder()
        await builder.refreshQuote(maker: maker, upload: upload(maker))

        #expect(await builder.generate(maker: maker) == .started)
        await eventually { builder.runs.first?.state != .sending }

        #expect(builder.runs.first?.state == .failed("Price is above max_credits"))
        #expect(spend.charges.isEmpty)
    }

    @Test func sheetsThatAllFailAreTakenOffTheSpend() async throws {
        let maker = FakeMaker()
        await maker.set(statuses: [["job-1": .failed(message: "Server error"), "job-2": .rejected(.explicitContent)]])
        let builder = builder()
        await builder.refreshQuote(maker: maker, upload: upload(maker))

        await builder.generate(maker: maker)
        await eventually {
            if case .failed = builder.runs.first?.state { return true }
            return false
        }

        #expect(builder.runs.first?.state == .failed("Server error"))
        #expect(spend.charges.isEmpty)
        #expect(log.sheets(of: "user_1").isEmpty)
    }

    @Test func sheetsStillRunningAreFollowedAgainAfterARelaunch() async throws {
        let maker = FakeMaker()
        let request = UUID()
        log.add([
            CharacterSheetRecord(id: "job-1", owner: "user_1", requestID: request, createdAt: .now, brief: ""),
            CharacterSheetRecord(id: "job-2", owner: "user_1", requestID: request, createdAt: .now, brief: ""),
            CharacterSheetRecord(id: "job-9", owner: "user_2", requestID: UUID(), createdAt: .now, brief: ""),
        ])
        let builder = builder()

        builder.resume(maker: maker)
        await eventually { log.pending(of: "user_1").isEmpty }

        #expect(log.sheets(of: "user_1").count == 2)
        // Another account's sheet waits for that account.
        #expect(log.pending(of: "user_2").map(\.id) == ["job-9"])
    }

    @Test func quittingCanWaitForTheSubmitAlreadySentAndItsJobsAreWrittenDown() async throws {
        let maker = FakeMaker()
        let gate = Gate<Void>()
        await maker.set(statuses: [[:]], submitGate: gate)
        let builder = builder()
        await builder.refreshQuote(maker: maker, upload: upload(maker))

        #expect(await builder.generate(maker: maker) == .started)
        await eventually { await gate.isWaiting }
        #expect(builder.activeCount == 1)
        let finished = Task { await builder.finishSubmit() }
        await gate.open(.success(()))
        await finished.value

        #expect(log.pending(of: "user_1").map(\.id) == ["job-1", "job-2"])
        #expect(!builder.isSubmitting)
        builder.stopFollowing()
    }

    @Test func aSubmitWhosePriceCantBeWrittenIsNotSent() async throws {
        // A regular file where the data folder should be: nothing can be written under it.
        let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let maker = FakeMaker()
        let builder = CharacterBuilder(log: log, spend: ImageSpendLog(folder: file), sleep: { _ in await Task.yield() })
        await builder.refreshQuote(maker: maker, upload: upload(maker))

        #expect(await builder.generate(maker: maker) == .notStarted)

        guard case .failed(let message) = builder.runs.first?.state else {
            Issue.record("Expected a failed run, got \(String(describing: builder.runs.first?.state))")
            return
        }
        #expect(message.hasPrefix("Nothing was sent"))
        #expect(await maker.submitted.isEmpty)
        #expect(!builder.isSubmitting)
    }

    @Test func jobsThatCantBeWrittenAreStillFollowedAndListedToCopy() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let log = CharacterSheetLog(folder: file)

        log.add([CharacterSheetRecord(id: "job-1", owner: "user_1", requestID: UUID(), createdAt: .now, brief: "")])

        #expect(log.pending(of: "user_1").map(\.id) == ["job-1"])
        #expect(log.unsavedIDs == ["job-1"])
        #expect(log.saveError?.file == CharacterSheetLog.fileName)
    }

    /// Generate reads today's spend itself right before sending, so a screen can't skip the cap.
    @Test func generateAsksBeforeGoingPastTheCapAndSendsOnceAgreed() async {
        let maker = FakeMaker()
        var committed = Decimal(0)
        let builder = CharacterBuilder(
            log: log, spend: spend,
            spendStatus: { kind in kind == .account ? SpendStatus(committedToday: committed, cap: .credits(30)) : nil },
            sleep: { _ in await Task.yield() })

        // 10 + 23.2 credits goes past 30: asks, sends nothing.
        committed = 10
        await builder.refreshQuote(maker: maker, upload: upload(maker))
        guard case .needsConfirmation(let question) = await builder.generate(maker: maker) else {
            Issue.record("Expected a question about the cap")
            return
        }
        #expect(question.title == "Over today's spend cap")
        #expect(await maker.submitted.isEmpty)
        #expect(spend.charges.isEmpty)
        #expect(builder.runs.isEmpty)

        // Agreed: sent without asking again.
        #expect(await builder.generate(maker: maker, overCapApproved: true) == .started)
        await eventually { builder.runs.first?.state == .finished }
        #expect(await maker.submitted.count == 1)

        // Under the cap: sent.
        committed = 0
        await builder.refreshQuote(maker: maker, upload: upload(maker))
        #expect(await builder.generate(maker: maker) == .started)
        #expect(spend.charges.count == 2)
        await eventually { !builder.isSubmitting }
        #expect(await maker.submitted.count == 2)
        builder.stopFollowing()
    }

    @Test func aPollTurnedDownForTheSignInStopsAsksForItAndFollowsAgainAfterReconnecting() async {
        let maker = FakeMaker()
        await maker.failPolls(with: .unauthorized)
        let builder = builder()
        var signInRequests = 0
        builder.onSignInExpired = { signInRequests += 1 }
        await builder.refreshQuote(maker: maker, upload: upload(maker))

        #expect(await builder.generate(maker: maker) == .started)
        await eventually {
            if case .interrupted = builder.runs.first?.state { return true }
            return false
        }

        // Stopped at once instead of polling on, and the connection was flagged.
        #expect(signInRequests == 1)
        #expect(await maker.polls == 1)
        #expect(builder.activeCount == 0)
        // Higgsfield accepted the request: it may still finish and be charged.
        #expect(spend.charges.map(\.isPending) == [true])
        #expect(log.pending(of: "user_1").map(\.id) == ["job-1", "job-2"])

        // Reconnected: the same sheets are followed again, not sent again.
        await maker.failPolls(with: nil)
        builder.reset()
        builder.resume(maker: maker)
        await eventually { builder.runs.first?.state == .finished }

        #expect(await maker.submitted.count == 1)
        #expect(spend.charges.map(\.isPending) == [false])
        #expect(log.pending(of: "user_1").isEmpty)
    }

    @Test func thePriceLineShowsTheQuoteAsHiggsfieldGivesIt() {
        // Live: one sheet is 1.125 credits, four are 4.5, and today's spend counts them so.
        let one = CharacterQuote(credits: 1.125, count: 1, request: Data())
        let four = CharacterQuote(credits: 4.5, count: 4, request: Data())
        // Written with a point whatever the locale: a decimal comma made "1,125" read as eleven hundred.
        #expect(one.price == "1.125 cr")
        #expect(four.price == "4.5 cr")
        #expect(CharacterQuote(credits: 10, count: 4, request: Data()).price == "10 cr")
        // Never shown lower than the quote.
        #expect(CharacterQuote(credits: 1.1251, count: 1, request: Data()).price == "1.126 cr")
        #expect(four.priceText == "4.5 cr · Price from Higgsfield")
        #expect(one.cost == .credits(1.125, isEstimate: false))
        #expect(four.cost == .credits(4.5, isEstimate: false))
    }

    @Test func theLogSurvivesARelaunch() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = CharacterSheetLog(folder: folder)
        // Whole seconds: the file keeps ISO 8601 dates.
        let date = Date(timeIntervalSince1970: 1_760_000_000)
        first.add([CharacterSheetRecord(id: "job-1", owner: "user_1", requestID: UUID(), createdAt: date, brief: "x")])
        first.update("job-1", state: .completed, imageURL: URL(string: "https://cdn.example.com/1.png"))
        first.setFile(URL(fileURLWithPath: "/tmp/1.png"), for: "job-1")

        let second = CharacterSheetLog(folder: folder)

        #expect(second.records == first.records)
        #expect(second.sheets(of: "user_1").first?.fileURL == URL(fileURLWithPath: "/tmp/1.png"))
    }
}
