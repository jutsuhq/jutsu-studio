import Foundation
import JutsuCore
import JutsuTestSupport
import Testing

@testable import Presentation

/// An image provider whose answers the test scripts: `statuses` are handed out in order, the last one repeated.
private actor FakeImageProvider: ImageProvider {
    nonisolated let kind: ProviderKind
    nonisolated let owner: String?
    /// The media ID its uploads answer with: each account names its own media.
    let mediaID: String
    var estimate: Result<Cost, ProviderError> = .success(.usd(Decimal(string: "0.0128")!, isEstimate: false))
    var submitError: ProviderError?
    var statuses: [ImageJobStatus] = [.completed([URL(string: "https://cdn.example.com/1.png")!])]
    /// Thrown by every poll while set: the status couldn't be read.
    var pollError: ProviderError?
    var cancelError: ProviderError?
    /// Hold the submit or the upload until opened, when set.
    var submitGate: Gate<Void>?
    var uploadGate: Gate<Void>?
    private(set) var submitted: [ImageRequest] = []
    private(set) var polls = 0
    private(set) var cancels = 0
    private(set) var uploads = 0

    init(kind: ProviderKind = .apiKey, owner: String? = "key-1", mediaID: String = "media-1") {
        self.kind = kind
        self.owner = owner
        self.mediaID = mediaID
    }

    func failPolls(with error: ProviderError?, then statuses: [ImageJobStatus]? = nil) {
        pollError = error
        if let statuses { self.statuses = statuses }
    }

    func hold(submit: Gate<Void>? = nil, upload: Gate<Void>? = nil) {
        submitGate = submit
        uploadGate = upload
    }

    func set(
        estimate: Result<Cost, ProviderError>? = nil, submitError: ProviderError? = nil,
        statuses: [ImageJobStatus]? = nil, cancelError: ProviderError? = nil
    ) {
        if let estimate { self.estimate = estimate }
        self.submitError = submitError
        if let statuses { self.statuses = statuses }
        self.cancelError = cancelError
    }

    func imageModels() async throws -> [ImageModel] { [] }

    func imageEstimate(_ request: ImageRequest) async throws -> Cost {
        try estimate.get()
    }

    func upload(_ file: PreparedFile) async throws -> RemoteAsset {
        uploads += 1
        if let uploadGate { try await uploadGate.wait() }
        return RemoteAsset(url: URL(string: "https://cdn.example.com/in.png")!, id: mediaID)
    }

    func submitImages(_ request: ImageRequest, idempotencyKey: UUID) async throws -> [RemoteJob] {
        submitted.append(request)
        if let submitGate { try await submitGate.wait() }
        if let submitError { throw submitError }
        return [RemoteJob(requestID: "req-1")]
    }

    func imageStatus(_ job: RemoteJob) async throws -> ImageJobStatus {
        polls += 1
        if let pollError { throw pollError }
        return statuses.count > 1 ? statuses.removeFirst() : statuses[0]
    }

    func cancelImages(_ job: RemoteJob) async throws {
        cancels += 1
        if let cancelError { throw cancelError }
    }
}

private let soul = ImageModel(
    id: "soul", title: "Soul 2", variantCounts: [1, 4], aspectRatios: ["1:1", "3:4", "9:16", "16:9"],
    listPrice: .usd(Decimal(string: "0.0032")!, isEstimate: true))
private let qwen = ImageModel(
    id: "qwen", title: "Qwen Image 3 Edit", aspectRatios: ["1:1", "21:9"], input: .required,
    listPrice: .usd(Decimal(string: "0.04")!, isEstimate: true))
private let landscape = PixelSize(width: 1920, height: 1080)
private let input = LocalImage(fileURL: URL(fileURLWithPath: "/tmp/knight.png"))

@MainActor
@Suite struct ReferenceGeneratorTests {
    let spend = ImageSpendLog(folder: nil)
    let jobLog = ImageJobLog(folder: nil)

    func generator() -> ReferenceGenerator {
        let generator = ReferenceGenerator(spend: spend, jobLog: jobLog, sleep: { _ in await Task.yield() })
        generator.useModels([soul, qwen])
        generator.prompt = "a knight in silver armor"
        return generator
    }

    fileprivate nonisolated static func upload(
        _ provider: FakeImageProvider
    ) -> @Sendable (LocalImage) async throws -> RemoteAsset {
        { _ in
            try await provider.upload(
                PreparedFile(fileURL: input.fileURL, contentType: "image/png", byteCount: 1, contentHash: "h"))
        }
    }

    @Test func theFirstModelIsPickedAndTheCountFitsTheModel() {
        let generator = generator()
        #expect(generator.modelID == "soul")
        generator.count = 4
        generator.selectModel("qwen")
        #expect(generator.count == 1)
        generator.useModels([qwen])
        #expect(generator.modelID == "qwen")
        generator.useModels([], unavailableReason: "Waiting")
        #expect(generator.model == nil)
        #expect(generator.blocker == "Waiting")
        // Without models, as before the connection is up at launch, the choice is kept for when they come back.
        generator.useModels([soul, qwen])
        #expect(generator.modelID == "qwen")
    }

    @Test func savedModelsShowUntilTheConnectionsOwnArriveAndHoldGenerateMeanwhile() {
        let generator = ReferenceGenerator(spend: spend, jobLog: jobLog)
        generator.prompt = "a knight in silver armor"
        generator.useSavedModels([])
        #expect(generator.model == nil)
        generator.useSavedModels([soul, qwen])
        #expect(generator.modelID == "soul")
        #expect(generator.modelsAreSaved)
        #expect(generator.blocker == "Checking the image models…")
        generator.useModels([soul])
        #expect(!generator.modelsAreSaved)
        #expect(generator.blocker == nil)
    }

    /// An agent is told why there are no image models and what to do, and the list is read again, until the
    /// connection's own is in; a connection that has none is said once, not read again.
    @Test func agentsAreToldWhileTheConnectionsOwnModelsArentIn() throws {
        let generator = ReferenceGenerator(spend: spend, jobLog: jobLog)
        #expect(generator.needsModelRead)
        #expect(try #require(generator.agentModelsNote).contains("hasn't read"))
        #expect(generator.agentModelsNote?.contains("call show with page create") == true)
        generator.useSavedModels([soul])
        #expect(generator.needsModelRead && generator.agentModelsNote?.contains("saved at the last read") == true)
        generator.useModels([], unavailableReason: "The account's catalog didn't answer.")
        #expect(generator.needsModelRead)
        #expect(
            generator.agentModelsNote?.contains("couldn't read the image models: The account's catalog didn't answer.")
                == true)
        generator.useModels([soul])
        #expect(!generator.needsModelRead && generator.agentModelsNote == nil)
        generator.useModels([])
        #expect(!generator.needsModelRead && generator.agentModelsNote == nil)
    }

    @Test func theFrameFollowsTheSourceExceptForObjectSwap() {
        let generator = generator()
        #expect(generator.aspectRatio(source: landscape, mode: .motionTransfer) == "16:9")
        #expect(generator.aspectRatio(source: PixelSize(width: 1080, height: 1920), mode: .restyle) == "9:16")
        #expect(generator.aspectRatio(source: landscape, mode: .objectSwap) == "1:1")
        #expect(generator.aspectRatio(source: nil, mode: .motionTransfer) == "1:1")
        generator.chosenAspectRatio = "3:4"
        #expect(generator.aspectRatio(source: landscape, mode: .motionTransfer) == "3:4")
        generator.selectModel("qwen")
        #expect(generator.aspectRatio(source: landscape, mode: .motionTransfer) == "21:9")
    }

    @Test func generateNeedsAPromptAndTheImageAnEditModelTakes() {
        let generator = generator()
        generator.prompt = "  "
        #expect(generator.blocker == "Describe the image to make")
        generator.prompt = "add a cape"
        generator.selectModel("qwen")
        #expect(generator.blocker == "Qwen Image 3 Edit edits an image: add one")
        generator.inputImage = input
        #expect(generator.blocker == nil)
        #expect(generator.sendsInput)
        generator.selectModel("soul")
        #expect(!generator.sendsInput)
    }

    @Test func thePriceIsTheQuoteOrTheListPriceWhenThereIsNone() async {
        let provider = FakeImageProvider()
        let generator = generator()
        generator.count = 4
        await generator.refreshPrice(
            provider: provider, source: landscape, mode: .motionTransfer, upload: Self.upload(provider))
        #expect(generator.price == .usd(Decimal(string: "0.0128")!, isEstimate: false))

        await provider.set(estimate: .failure(.validation(field: nil, message: "Nope")))
        await generator.refreshPrice(
            provider: provider, source: landscape, mode: .motionTransfer, upload: Self.upload(provider))
        #expect(generator.price == .usd(Decimal(string: "0.0128")!, isEstimate: true))
        #expect(generator.priceFailure != nil)
    }

    @Test func theInputIsUploadedOnceForThePriceAndTheRun() async {
        let provider = FakeImageProvider()
        let generator = generator()
        generator.selectModel("qwen")
        generator.inputImage = input
        await generator.refreshPrice(
            provider: provider, source: nil, mode: .objectSwap, upload: Self.upload(provider))
        await generator.generate(
            provider: provider, source: nil, mode: .objectSwap, price: generator.price, upload: Self.upload(provider))
        await eventually { generator.runs.first?.state == .finished }
        #expect(await provider.uploads == 1)
        #expect(await provider.submitted.first?.inputImages.map(\.id) == ["media-1"])
    }

    @Test func aFinishedRunAddsItsImagesAndCountsItsPrice() async throws {
        let provider = FakeImageProvider()
        await provider.set(
            statuses: [
                .pending, .pending,
                .completed([
                    URL(string: "https://cdn.example.com/1.png")!, URL(string: "https://cdn.example.com/2.png")!,
                ]),
            ])
        let generator = generator()
        generator.count = 4
        let price = Cost.usd(Decimal(string: "0.0128")!, isEstimate: false)

        await generator.generate(
            provider: provider, source: landscape, mode: .motionTransfer, price: price, upload: Self.upload(provider))
        #expect(generator.isRunning)
        await eventually { generator.runs.first?.state == .finished }

        #expect(generator.images.map(\.url.lastPathComponent) == ["1.png", "2.png"])
        #expect(generator.images.allSatisfy { $0.prompt == "a knight in silver armor" && $0.model == "Soul 2" })
        #expect(generator.images.map { $0.remote?.output } == [0, 1])
        #expect(
            generator.images.allSatisfy { $0.remote?.owner == "key-1" && $0.variantGroupID == generator.runs.first?.id }
        )
        let parameters = try #require(generator.images.first?.parameters)
        let submitted = await provider.submitted.first
        #expect(try JSONDecoder().decode(ImageRequest.self, from: parameters) == submitted)
        #expect(await provider.submitted.map(\.count) == [4])
        #expect(await provider.submitted.map(\.aspectRatio) == ["16:9"])
        #expect(spend.charges.map(\.cost) == [price])
        #expect(spend.charges.map(\.isPending) == [false])
        #expect(await provider.polls == 3)
    }

    @Test(arguments: [
        ImageJobStatus.failed(message: "Bad prompt"), .rejected(.explicitContent),
    ])
    func aRunWithoutImagesIsNotCharged(status: ImageJobStatus) async {
        let provider = FakeImageProvider()
        await provider.set(statuses: [status])
        let generator = generator()

        await generator.generate(
            provider: provider, source: nil, mode: .motionTransfer, price: soul.listPrice,
            upload: Self.upload(provider))
        await eventually { generator.runs.first?.state != .running }

        guard case .failed = generator.runs.first?.state else {
            Issue.record("Expected a failed run, got \(String(describing: generator.runs.first?.state))")
            return
        }
        #expect(spend.charges.isEmpty)
        #expect(generator.images.isEmpty)
    }

    @Test func aRefusedSubmitIsNotCharged() async {
        let provider = FakeImageProvider()
        await provider.set(submitError: .insufficientFunds)
        let generator = generator()

        await generator.generate(
            provider: provider, source: nil, mode: .motionTransfer, price: soul.listPrice,
            upload: Self.upload(provider))
        await eventually { generator.runs.first?.state != .running }

        #expect(spend.charges.isEmpty)
    }

    @Test func anUnansweredSubmitKeepsCounting() async {
        let provider = FakeImageProvider()
        await provider.set(submitError: .network)
        let generator = generator()

        await generator.generate(
            provider: provider, source: nil, mode: .motionTransfer, price: soul.listPrice,
            upload: Self.upload(provider))
        await eventually { generator.runs.first?.state != .running }

        #expect(spend.charges.map(\.isPending) == [false])
    }

    @Test(arguments: [nil, ProviderError.validation(field: nil, message: "Already running")])
    func cancellingAQueuedRunDropsItsPriceUnlessItCantBeCancelled(cancelError: ProviderError?) async {
        let provider = FakeImageProvider()
        await provider.set(statuses: [.pending], cancelError: cancelError)
        let generator = generator()

        await generator.generate(
            provider: provider, source: nil, mode: .motionTransfer, price: soul.listPrice,
            upload: Self.upload(provider))
        await eventually { await provider.polls > 0 }
        generator.cancel(try! #require(generator.runs.first?.id))
        await eventually { generator.runs.first?.state == .canceled }

        #expect(await provider.cancels == 1)
        #expect(spend.charges.count == (cancelError == nil ? 0 : 1))
    }

    @Test func picksFollowTheRoomAndClosingDropsOnlyThePicks() async {
        let provider = FakeImageProvider()
        let generator = generator()
        generator.count = 1
        await generator.generate(
            provider: provider, source: nil, mode: .motionTransfer, price: nil, upload: Self.upload(provider))
        await eventually { generator.runs.first?.state == .finished }
        await generator.generate(
            provider: provider, source: nil, mode: .motionTransfer, price: nil, upload: Self.upload(provider))
        await eventually { generator.runs.first?.state == .finished }
        #expect(generator.runs.count == 1)
        let first = generator.images[1].id
        let second = generator.images[0].id

        #expect(generator.toggleSelection(first, room: 1))
        #expect(!generator.toggleSelection(second, room: 1))
        #expect(generator.toggleSelection(first, room: 1))
        #expect(generator.selection.isEmpty)
        generator.toggleSelection(second, room: 2)
        generator.toggleSelection(first, room: 2)
        #expect(generator.selectedImages.map(\.id) == [second, first])

        generator.markPicked(second)
        #expect(generator.selection == [first])
        #expect(!generator.toggleSelection(second, room: 2))

        // Closing the quick action drops the picks; the images stay for the Image side of Create.
        generator.clearSelection()
        #expect(generator.selection.isEmpty)
        #expect(generator.images.map(\.id) == [second, first])
        generator.toggleSelection(first, room: 2)

        #expect(generator.remove(first)?.id == first)
        #expect(generator.selection.isEmpty)
        #expect(!generator.contains(first))
        #expect(generator.remove(first) == nil)

        generator.clearResults()
        #expect(generator.images.isEmpty)
        #expect(generator.selection.isEmpty)
        #expect(generator.runs.isEmpty)
    }

    @Test func aPollTurnedDownForTheSignInKeepsTheJobAndItsPriceAndFollowsItAgainAfterReconnecting() async {
        let provider = FakeImageProvider()
        await provider.failPolls(with: .unauthorized)
        let generator = generator()
        var signInRequests = 0
        generator.onSignInExpired = { signInRequests += 1 }

        await generator.generate(
            provider: provider, source: nil, mode: .motionTransfer, price: soul.listPrice,
            upload: Self.upload(provider))
        await eventually {
            if case .interrupted = generator.runs.first?.state { return true }
            return false
        }

        // Higgsfield accepted the request: it may still finish and be charged.
        #expect(signInRequests == 1)
        #expect(spend.charges.map(\.isPending) == [true])
        #expect(jobLog.pending(of: "key-1").map(\.id) == ["req-1"])

        // Reconnected: the same job is followed again, not sent again.
        await provider.failPolls(with: nil)
        generator.reset()
        generator.resume(provider: provider)
        await eventually { generator.runs.first?.state == .finished }

        #expect(await provider.submitted.count == 1)
        #expect(generator.images.map(\.prompt) == ["a knight in silver armor"])
        #expect(spend.charges.map(\.isPending) == [false])
        #expect(jobLog.records.isEmpty)
    }

    @Test func anAcceptedRequestIsFollowedAgainAfterARelaunch() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let provider = FakeImageProvider()
        await provider.set(statuses: [.pending])
        let first = ReferenceGenerator(
            spend: ImageSpendLog(folder: folder), jobLog: ImageJobLog(folder: folder),
            sleep: { _ in await Task.yield() })
        first.useModels([soul])
        first.prompt = "a knight in silver armor"
        await first.generate(
            provider: provider, source: nil, mode: .motionTransfer, price: soul.listPrice,
            upload: Self.upload(provider))
        await eventually { await provider.polls > 0 }
        // The app quits while the image is being made.
        first.reset()

        await provider.set(statuses: [.completed([URL(string: "https://cdn.example.com/1.png")!])])
        let spend = ImageSpendLog(folder: folder)
        let second = ReferenceGenerator(
            spend: spend, jobLog: ImageJobLog(folder: folder), sleep: { _ in await Task.yield() })
        var saved: [GeneratedImage] = []
        second.onImages = { saved += $0 }
        second.resume(provider: provider)
        await eventually { second.runs.first?.state == .finished }

        #expect(saved.map(\.prompt) == ["a knight in silver armor"])
        #expect(saved.map(\.model) == ["Soul 2"])
        #expect(spend.charges.map(\.isPending) == [false])
        #expect(ImageJobLog(folder: folder).records.isEmpty)
        #expect(await provider.submitted.count == 1)
    }

    @Test func quittingCanWaitForASubmitAlreadySentAndItsJobIsWrittenDown() async {
        let provider = FakeImageProvider()
        let gate = Gate<Void>()
        await provider.hold(submit: gate)
        await provider.set(statuses: [.pending])
        let generator = generator()

        await generator.generate(
            provider: provider, source: nil, mode: .motionTransfer, price: soul.listPrice,
            upload: Self.upload(provider))
        await eventually { await gate.isWaiting }
        #expect(generator.sendingCount == 1)
        #expect(generator.activeCount == 1)

        let finished = Task { await generator.finishSubmits() }
        await gate.open(.success(()))
        await finished.value

        #expect(generator.sendingCount == 0)
        #expect(jobLog.pending(of: "key-1").map(\.id) == ["req-1"])
        #expect(generator.activeCount == 1)
        generator.reset()
    }

    @Test func aNewConnectionUploadsTheInputAgainAndALateUploadOfTheOldOneIsntKept() async {
        let first = FakeImageProvider(owner: "a", mediaID: "A-media")
        let second = FakeImageProvider(owner: "b", mediaID: "B-media")
        let cape = LocalImage(fileURL: URL(fileURLWithPath: "/tmp/cape.png"))
        let generator = generator()
        generator.selectModel("qwen")
        generator.inputImage = input

        await generator.refreshPrice(provider: first, source: nil, mode: .objectSwap, upload: Self.upload(first))
        // The connection switches, as `AppEnvironment.use` does.
        generator.reset()
        await generator.refreshPrice(provider: second, source: nil, mode: .objectSwap, upload: Self.upload(second))
        #expect(await second.uploads == 1)

        // An upload of the first account still out when the second one connects.
        let gate = Gate<Void>()
        await first.hold(upload: gate)
        generator.inputImage = cape
        let late = Task {
            await generator.refreshPrice(provider: first, source: nil, mode: .objectSwap, upload: Self.upload(first))
        }
        await eventually { await gate.isWaiting }
        generator.reset()
        await gate.open(.success(()))
        await late.value
        #expect(generator.price == nil)

        await generator.generate(
            provider: second, source: nil, mode: .objectSwap, price: nil, upload: Self.upload(second))
        await eventually { generator.runs.first?.state == .finished }

        #expect(await second.uploads == 2)
        #expect(await second.submitted.map { $0.inputImages.map(\.id) } == [["B-media"]])
    }

    @Test func aRequestWhosePriceCantBeWrittenIsNotSent() async throws {
        // A regular file where the data folder should be: nothing can be written under it.
        let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let provider = FakeImageProvider()
        let generator = ReferenceGenerator(
            spend: ImageSpendLog(folder: file), jobLog: jobLog, sleep: { _ in await Task.yield() })
        generator.useModels([soul])
        generator.prompt = "a knight in silver armor"

        await generator.generate(
            provider: provider, source: nil, mode: .motionTransfer, price: soul.listPrice,
            upload: Self.upload(provider))
        await eventually { generator.runs.first?.state != .running }

        guard case .failed(let message) = generator.runs.first?.state else {
            Issue.record("Expected a failed run, got \(String(describing: generator.runs.first?.state))")
            return
        }
        #expect(message.hasPrefix("Nothing was sent"))
        #expect(await provider.submitted.isEmpty)
    }

    /// Generate reads today's spend itself right before sending, so a screen can't skip the cap.
    @Test func generateAsksBeforeGoingPastTheCapAndSendsOnceAgreed() async {
        let provider = FakeImageProvider()
        var committed = Decimal(0)
        let generator = ReferenceGenerator(
            spend: spend, jobLog: jobLog,
            spendStatus: { kind in kind == .apiKey ? SpendStatus(committedToday: committed, cap: .usd(1)) : nil },
            sleep: { _ in await Task.yield() })
        generator.useModels([soul])
        generator.prompt = "a knight in silver armor"
        let price = Cost.usd(Decimal(string: "0.08")!, isEstimate: false)
        func generate(price: Cost?, approved: Bool = false) async -> PaidStart {
            await generator.generate(
                provider: provider, source: nil, mode: .motionTransfer, price: price, overCapApproved: approved,
                upload: Self.upload(provider))
        }

        // Under the cap: sent.
        #expect(await generate(price: price) == .started)
        await eventually { generator.runs.first?.state == .finished }

        // A price not known yet, under a cap: asks, sends nothing.
        guard case .needsConfirmation(let unknown) = await generate(price: nil) else {
            Issue.record("Expected a question about the unknown price")
            return
        }
        #expect(unknown.title == "Price not known yet")

        // Over the cap: asks, sends nothing.
        committed = Decimal(string: "0.95")!
        guard case .needsConfirmation(let over) = await generate(price: price) else {
            Issue.record("Expected a question about the cap")
            return
        }
        #expect(over.title == "Over today's spend cap")
        #expect(over.confirmTitle == "Generate anyway")
        #expect(await provider.submitted.count == 1)
        #expect(spend.charges.count == 1)

        // Agreed: sent without asking again.
        #expect(await generate(price: price, approved: true) == .started)
        await eventually { generator.runs.first?.state == .finished }
        #expect(await provider.submitted.count == 2)
        #expect(spend.charges.map(\.cost) == [price, price])
    }

    @Test func thePriceTextKeepsSmallAmounts() {
        CostText.$locale.withValue(.enUS) {
            #expect(
                ReferenceGenerator.priceText(.usd(Decimal(string: "0.0032")!, isEstimate: true))
                    == "About $0.0032 · Estimate")
            #expect(
                ReferenceGenerator.priceText(.usd(Decimal(string: "0.08")!, isEstimate: false))
                    == "$0.08 · Price from Higgsfield")
            #expect(ReferenceGenerator.priceText(.credits(3, isEstimate: false)) == "3 cr · Price from Higgsfield")
        }
    }

    @Test func theCapAsksWhenThePriceIsOverOrUnknown() {
        CostText.$locale.withValue(.enUS) {
            let cap = SpendCap.usd(1)
            let price = Cost.usd(Decimal(string: "0.08")!, isEstimate: true)
            #expect(ReferenceGenerator.capConfirmation(cost: price, committedToday: 0, cap: nil) == nil)
            #expect(ReferenceGenerator.capConfirmation(cost: price, committedToday: 0, cap: cap) == nil)
            let over = ReferenceGenerator.capConfirmation(
                cost: price, committedToday: Decimal(string: "0.95")!, cap: cap)
            #expect(over?.message == "These images add $0.08, bringing today to $1.03 against your $1.00 cap.")
            #expect(
                ReferenceGenerator.capConfirmation(cost: nil, committedToday: 0, cap: cap)?.title
                    == "Price not known yet")
            #expect(
                ReferenceGenerator.capConfirmation(cost: .unknownCredits, committedToday: 0, cap: .credits(100)) != nil)
        }
    }
}

@MainActor
@Suite struct ImageDraftGeneratorTests {
    let spend = ImageSpendLog(folder: nil)
    let jobLog = ImageJobLog(folder: nil)

    func generator() -> ReferenceGenerator {
        let generator = ReferenceGenerator(spend: spend, jobLog: jobLog, sleep: { _ in await Task.yield() })
        generator.useModels([soul, qwen])
        return generator
    }

    fileprivate nonisolated static func upload(
        _ provider: FakeImageProvider
    ) -> @Sendable (LocalImage) async throws -> RemoteAsset {
        { _ in
            try await provider.upload(
                PreparedFile(fileURL: input.fileURL, contentType: "image/png", byteCount: 1, contentHash: "h"))
        }
    }

    /// The image panel drives the same generator as the sheet: a form restored from its draft makes the same
    /// request as the same form set by hand.
    @Test func aRestoredFormMakesTheSameRequestAsTheSheet() async throws {
        let provider = FakeImageProvider()
        let sheet = generator()
        sheet.prompt = "a knight in silver armor"
        sheet.count = 4
        sheet.chosenAspectRatio = "16:9"
        let sheetDraft = try #require(sheet.draft(source: landscape, mode: .motionTransfer))
        let sheetRequest = try await sheet.request(sheetDraft, upload: Self.upload(provider))

        let panel = generator()
        panel.restore(sheet.snapshot())
        #expect(panel.snapshot() == sheet.snapshot())
        let panelDraft = try #require(panel.draft(source: nil, mode: .motionTransfer))
        let panelRequest = try await panel.request(panelDraft, upload: Self.upload(provider))

        #expect(panelRequest == sheetRequest)
        #expect(panelRequest.aspectRatio == "16:9")
        #expect(panelRequest.count == 4)
    }

    @Test func aRestoredFormQuotesTheSamePrice() async {
        let provider = FakeImageProvider()
        let sheet = generator()
        sheet.prompt = "a knight in silver armor"
        sheet.count = 4
        await sheet.refreshPrice(
            provider: provider, source: landscape, mode: .motionTransfer, upload: Self.upload(provider))

        let panel = generator()
        panel.restore(sheet.snapshot())
        await panel.refreshPrice(
            provider: provider, source: nil, mode: .motionTransfer, upload: Self.upload(provider))

        #expect(panel.price == sheet.price)
        #expect(panel.price == .usd(Decimal(string: "0.0128")!, isEstimate: false))
    }

    @Test func restoreKeepsTheSavedModelAndAFittingCount() {
        let generator = generator()
        generator.restore(ImageDraft(prompt: "knight", modelID: "qwen", count: 4))
        // Qwen makes one image: the count falls back to what it makes.
        #expect(generator.modelID == "qwen")
        #expect(generator.count == 1)
        #expect(generator.prompt == "knight")

        generator.restore(ImageDraft(prompt: "knight", modelID: "soul", chosenAspectRatio: "9:16", count: 4))
        #expect(generator.modelID == "soul")
        #expect(generator.count == 4)
        #expect(generator.aspectRatio(source: nil, mode: .motionTransfer) == "9:16")
    }

    @Test func restoreBeforeTheModelsArriveKeepsTheChoice() {
        let generator = ReferenceGenerator(spend: spend, jobLog: jobLog, sleep: { _ in await Task.yield() })
        generator.restore(ImageDraft(prompt: "knight", modelID: "soul", count: 4))
        generator.useModels([qwen, soul])
        #expect(generator.modelID == "soul")
        #expect(generator.count == 4)

        let unknown = ReferenceGenerator(spend: spend, jobLog: jobLog, sleep: { _ in await Task.yield() })
        unknown.restore(ImageDraft(prompt: "knight", modelID: "flux"))
        unknown.useModels([soul, qwen])
        #expect(unknown.modelID == "soul")
    }

    @Test func applyingAnImageTemplateFillsTheForm() {
        let generator = generator()
        let template = JobTemplate(
            name: "Cape", imageModelID: "qwen", imageModelTitle: "Qwen Image 3 Edit", imageAspectRatio: "21:9",
            imageCount: 1, prompt: "add a cape", references: [input])

        #expect(generator.applyImageTemplate(template) == nil)
        #expect(generator.modelID == "qwen")
        #expect(generator.prompt == "add a cape")
        #expect(generator.chosenAspectRatio == "21:9")
        #expect(generator.count == 1)
        #expect(generator.inputImage == input)
        #expect(generator.blocker == nil)
    }

    /// The menu bar's New from Template can run before Create has loaded the models.
    @Test func anImageTemplateAppliedBeforeTheModelsArriveKeepsItsModel() {
        let generator = ReferenceGenerator(spend: spend, jobLog: jobLog, sleep: { _ in await Task.yield() })
        let template = JobTemplate(
            name: "Knight", imageModelID: "soul", imageAspectRatio: "16:9", imageCount: 4, prompt: "a knight")

        #expect(generator.applyImageTemplate(template) == nil)
        generator.useModels([qwen, soul])

        #expect(generator.modelID == "soul")
        #expect(generator.count == 4)
        #expect(generator.prompt == "a knight")
    }

    @Test func applyingATemplateOfAnUnofferedModelKeepsTheCurrentOneWithANotice() {
        let generator = generator()
        generator.selectModel("soul")
        let template = JobTemplate(
            name: "Cape", imageModelID: "flux", imageModelTitle: "Flux", imageAspectRatio: "16:9", imageCount: 2,
            prompt: "a cape")
        // Flux isn't offered, and Soul doesn't make 2: the count stays at what it makes.
        let notice = generator.applyImageTemplate(template)
        #expect(notice?.title == "Running on Soul 2")
        #expect(generator.modelID == "soul")
        #expect(generator.count == 1)
        #expect(generator.prompt == "a cape")
        #expect(generator.chosenAspectRatio == "16:9")
    }

    @Test func anImageTemplateRoundTripsThroughTheForm() {
        let generator = generator()
        generator.prompt = "a knight in silver armor"
        generator.count = 4
        generator.chosenAspectRatio = "3:4"
        let template = generator.makeImageTemplate(name: "Knight")
        #expect(template.kind == .image)
        #expect(template.imageModelID == "soul")
        #expect(template.imageModelTitle == "Soul 2")
        #expect(template.imageAspectRatio == "3:4")
        #expect(template.imageCount == 4)

        let fresh = self.generator()
        #expect(fresh.applyImageTemplate(template) == nil)
        #expect(fresh.snapshot() == generator.snapshot())
    }

    @Test func imageTemplateSummaryNamesTheModelAndTheFrame() {
        CostText.$locale.withValue(.enUS) {
            let template = JobTemplate(
                name: "Knight", imageModelID: "soul", imageModelTitle: "Soul 2", imageAspectRatio: "16:9",
                imageCount: 4, prompt: "knight")
            #expect(template.summary == "Image · Soul 2 · 16:9 · 4 variants")
            let edit = JobTemplate(
                name: "Cape", imageModelID: "qwen", imageAspectRatio: "1:1", imageCount: 1, prompt: "cape",
                references: [input])
            #expect(edit.summary == "Image · 1:1 · 1 image")
        }
    }

    @Test func imageTemplateNamesUseTheKindAndThePrompt() {
        #expect(TemplateNaming.suggestedName(kind: .image, prompt: "  a knight\nsecond") == "Image · a knight")
        #expect(TemplateNaming.suggestedName(kind: .image, prompt: "") == "Image")
    }
}

@MainActor
@Suite struct ImageSpendLogTests {
    let day = Date(timeIntervalSince1970: 1_760_310_000)

    @Test func anUnreadableSpendingFileCannotBeOverwrittenOrForgottenOnRelaunch() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(ImageSpendLog.fileName)
        let damaged = Data("[{\"cost\":80}]".utf8)
        try damaged.write(to: file)
        let charge = ImageCharge(
            date: day, cost: .credits(30, isEstimate: false), providerKind: .account, model: "Soul", images: 1)
        for _ in 0..<2 {
            let log = ImageSpendLog(folder: folder, now: day)
            #expect(throws: LogWriteError.self) { try log.add(charge) }
            #expect(log.charges.isEmpty)
            #expect(try Data(contentsOf: file) == damaged)
        }
        let log = ImageSpendLog(folder: folder, now: day)
        try Data("[]".utf8).write(to: file)
        log.retrySave()
        try log.add(charge)
        #expect(ImageSpendLog(folder: folder, now: day).charges.map(\.id) == [charge.id])
    }

    @Test func chargesSurviveARelaunchAndOldOnesAreDropped() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = ImageSpendLog(folder: folder, now: day)
        let recent = ImageCharge(
            date: day, cost: .usd(Decimal(string: "0.08")!, isEstimate: false), providerKind: .apiKey,
            model: "Grok Image 2", images: 1)
        let old = ImageCharge(
            date: day - 40 * 86_400, cost: .usd(1, isEstimate: false), providerKind: .apiKey, model: "Soul 2",
            images: 4, isPending: false)
        let dropped = ImageCharge(
            date: day, cost: .usd(1, isEstimate: false), providerKind: .apiKey, model: "Soul 2", images: 1)
        try log.add(old)
        try log.add(recent)
        try log.add(dropped)
        log.settle(recent.id)
        log.remove(dropped.id)

        let reopened = ImageSpendLog(folder: folder, now: day)

        #expect(reopened.charges.map(\.id) == [recent.id])
        #expect(reopened.charges.first?.isPending == false)
        #expect(reopened.charges.first?.cost == recent.cost)
    }

    @Test func aWriteThatFailsIsToldToTheCallerAndAcceptedJobsStayListedToCopy() throws {
        // A regular file where the data folder should be: nothing can be written under it.
        let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let spend = ImageSpendLog(folder: file, now: day)
        let jobs = ImageJobLog(folder: file)
        let charge = ImageCharge(
            date: day, cost: .usd(1, isEstimate: false), providerKind: .apiKey, model: "Soul 2", images: 1)

        #expect(throws: LogWriteError.self) { try spend.add(charge) }
        jobs.add([
            ImageJobRecord(
                job: RemoteJob(requestID: "req-1"), owner: "key-1", runID: charge.id, createdAt: day, prompt: "",
                model: "Soul 2", aspectRatio: nil, count: 1)
        ])

        // The price isn't counted, so the request isn't sent; the accepted job is still followed, and listed.
        #expect(spend.charges.isEmpty)
        #expect(spend.saveError?.file == ImageSpendLog.fileName)
        #expect(jobs.pending(of: "key-1").map(\.id) == ["req-1"])
        #expect(jobs.unsavedIDs == ["req-1"])
        #expect(jobs.saveError?.file == ImageJobLog.fileName)
    }

    @Test func todayCountsRunningRequestsAndTodaysFinishedOnes() {
        let calendar = Calendar(identifier: .gregorian)
        let usd = { (text: String) in Cost.usd(Decimal(string: text)!, isEstimate: false) }
        let charges = [
            ImageCharge(date: day, cost: usd("0.08"), providerKind: .apiKey, model: "a", images: 1, isPending: false),
            ImageCharge(date: day - 86_400 * 2, cost: usd("0.5"), providerKind: .apiKey, model: "b", images: 1),
            ImageCharge(
                date: day - 86_400 * 2, cost: usd("3"), providerKind: .apiKey, model: "c", images: 1, isPending: false),
            ImageCharge(date: day, cost: .credits(9, isEstimate: false), providerKind: .account, model: "d", images: 1),
        ]
        #expect(DailySpend.committed([], images: charges, on: day, calendar: calendar) == Decimal(string: "0.58"))
        #expect(DailySpend.committed([], images: charges, on: day, in: .credits, calendar: calendar) == 9)
    }

    @Test func spendingAndTheCSVListFinishedRequests() {
        let calendar = Calendar(identifier: .gregorian)
        let charge = ImageCharge(
            date: day, cost: .usd(Decimal(string: "0.0128")!, isEstimate: false), providerKind: .apiKey,
            model: "Soul 2", images: 4, isPending: false)
        let running = ImageCharge(
            date: day, cost: .usd(1, isEstimate: true), providerKind: .apiKey, model: "Soul 2", images: 1)

        let summary = SpendingSummary([], images: [charge, running], period: .today, now: day, calendar: calendar)
        let csv = SpendingCSV.csv([], images: [charge, running], timeZone: TimeZone(secondsFromGMT: 0)!)

        #expect(summary.charged.usd == Decimal(string: "0.0128"))
        #expect(summary.byMode.map(\.title) == ["Reference images"])
        #expect(summary.byMode.map(\.jobs) == [1])
        #expect(
            csv.components(separatedBy: "\r\n").dropFirst().first
                == "2025-10-12T23:00:00Z,Reference images,,No,0,0.0128,USD,Done,Yes,")
    }
}
