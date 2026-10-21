import Foundation
import JutsuCore
import JutsuTestSupport
import Testing

@testable import Presentation

/// An image provider for agents' requests: a scripted quote and submit, every job done at the first poll.
actor ImageFake: ImageProvider {
    nonisolated let kind: ProviderKind = .apiKey
    nonisolated let owner: String? = "key-1"
    var estimate: Result<Cost, ProviderError> = .success(.usd(Decimal(string: "0.08")!, isEstimate: false))
    var submitError: ProviderError?
    /// How each job of a request ends, one job per entry; empty makes one job that completes.
    var outcomes: [ImageJobStatus] = []
    /// Refuses to cancel, as for a job that already started.
    var refusesCancel = false
    private(set) var submitted: [ImageRequest] = []
    private(set) var uploads = 0

    func set(estimate: Result<Cost, ProviderError>? = nil, submitError: ProviderError? = nil) {
        if let estimate { self.estimate = estimate }
        self.submitError = submitError
    }

    func set(outcomes: [ImageJobStatus], refusesCancel: Bool = false) {
        self.outcomes = outcomes
        self.refusesCancel = refusesCancel
    }

    func imageModels() async throws -> [ImageModel] { [] }
    func imageEstimate(_ request: ImageRequest) async throws -> Cost { try estimate.get() }

    func upload(_ file: PreparedFile) async throws -> RemoteAsset {
        uploads += 1
        return RemoteAsset(url: URL(string: "https://cdn.example.com/in.png")!, id: "media-1")
    }

    func submitImages(_ request: ImageRequest, idempotencyKey: UUID) async throws -> [RemoteJob] {
        submitted.append(request)
        if let submitError { throw submitError }
        guard !outcomes.isEmpty else { return [RemoteJob(requestID: "req-1")] }
        return outcomes.indices.map { RemoteJob(requestID: "req-\($0)") }
    }

    func imageStatus(_ job: RemoteJob) async throws -> ImageJobStatus {
        guard let index = Int(job.requestID.dropFirst(4)), outcomes.indices.contains(index) else {
            return .completed([URL(string: "https://cdn.example.com/1.png")!])
        }
        return outcomes[index]
    }

    func cancelImages(_ job: RemoteJob) async throws {
        if refusesCancel { throw ProviderError.validation(field: nil, message: "already running") }
    }
}

/// The agent spend ledger in memory, with the budget check `AgentSpendFile` makes.
actor MemoryLedger: AgentSpendLedger {
    struct Broken: Error {}

    private(set) var spends: [AgentSpend] = []
    var isBroken = false

    func breakIt() { isBroken = true }

    func reserve(_ spend: AgentSpend, dailyLimit: Int?) throws -> Bool {
        if isBroken { throw Broken() }
        let taken = spends.reduce(0) { $0 + $1.money.amount }
        if let dailyLimit, taken + spend.money.amount > dailyLimit { return false }
        spends.append(spend)
        return true
    }

    func release(_ id: UUID) throws {
        if isBroken { throw Broken() }
        spends.removeAll { $0.id == id }
    }

    func settle(_ id: UUID, amount: Int?) throws {
        guard let index = spends.firstIndex(where: { $0.id == id }) else { return }
        spends[index].isSettled = true
        if let amount { spends[index].money.amount = amount }
    }

    func unbill(_ id: UUID, part: String, of parts: Int) throws {
        guard let index = spends.firstIndex(where: { $0.id == id }),
            spends[index].unbilled?.contains(part) != true
        else { return }
        spends[index].parts = parts
        spends[index].unbilled = (spends[index].unbilled ?? []) + [part]
    }

    func total(on day: Date, unit: AgentMoney.Unit) throws -> AgentSpendTotal {
        AgentSpendTotal(
            spent: spends.filter(\.isSettled).reduce(0) { $0 + $1.counted },
            reserved: spends.filter { !$0.isSettled }.reduce(0) { $0 + $1.counted })
    }

    func unsettled() throws -> [AgentSpend] { spends.filter { !$0.isSettled } }
}

private let soul = ImageModel(
    id: "soul", title: "Soul 2", variantCounts: [1, 4], aspectRatios: ["1:1", "16:9"],
    listPrice: .usd(Decimal(string: "0.02")!, isEstimate: true))
private let edit = ImageModel(id: "edit", title: "Edit", aspectRatios: ["1:1"], input: .required, maxInputs: 3)
private let picture = LocalImage(fileURL: URL(fileURLWithPath: "/tmp/agent-input.png"))

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct AgentImageQueueTests {
    let folder = FileManager.default.temporaryDirectory.appending(path: "agent-images-\(UUID().uuidString)")
    let jobLog = ImageJobLog(folder: nil)
    let ledger = MemoryLedger()
    let provider = ImageFake()

    func generator(cap: SpendStatus? = nil) -> ReferenceGenerator {
        let generator = ReferenceGenerator(
            spend: ImageSpendLog(folder: nil), jobLog: jobLog, spendStatus: { _ in cap },
            sleep: { _ in await Task.yield() })
        generator.useModels([soul, edit])
        return generator
    }

    func queue(
        _ generator: ReferenceGenerator, limit: Int = 1_000, ledger: (any AgentSpendLedger)? = nil
    )
        -> AgentImageQueue
    {
        AgentImageQueue(folder: folder, generator: generator, ledger: ledger ?? self.ledger, dailyLimit: { _ in limit })
    }

    func origin(maxCents: Int = 50) -> AgentOrigin {
        AgentOrigin(client: "claude-code", requestID: "img-1", maxCost: AgentMoney(maxCents, .usdCents))
    }

    func order(_ prompt: String = "a red fox", count: Int? = nil, model: String? = nil) -> AgentImageOrder {
        AgentImageOrder(model: model, prompt: prompt, aspectRatio: nil, count: count)
    }

    nonisolated static func upload(_ provider: ImageFake) -> @Sendable (LocalImage) async throws -> RemoteAsset {
        { _ in
            try await provider.upload(
                PreparedFile(fileURL: picture.fileURL, contentType: "image/png", byteCount: 1, contentHash: "h"))
        }
    }

    @discardableResult
    func create(_ queue: AgentImageQueue, _ order: AgentImageOrder, origin: AgentOrigin? = nil) throws -> UUID {
        let id = UUID()
        _ = try queue.create(
            order, id: id, origin: origin ?? self.origin(), provider: provider, upload: Self.upload(provider))
        return id
    }

    // MARK: The order

    @Test func theRequestIsBuiltAsTheImageSideBuildsIt() throws {
        let models = [soul, edit]
        let made = try order(count: 4).draft(models: models, modelsAreSaved: false).get()
        #expect(made.model.id == "soul")
        #expect(made.aspectRatio == "1:1")
        #expect(made.count == 4)
        func refusal(_ order: AgentImageOrder, saved: Bool = false) -> String? {
            if case .failure(let refusal) = order.draft(models: models, modelsAreSaved: saved) {
                return refusal.message
            }
            return nil
        }
        #expect(refusal(order(model: "nope"))?.contains("no image model nope") == true)
        #expect(refusal(order("  ")) != nil)
        #expect(refusal(order(count: 3))?.contains("1, 4") == true)
        #expect(refusal(order(model: "edit"))?.contains("send inputs") == true)
        #expect(refusal(AgentImageOrder(model: nil, prompt: "x", aspectRatio: "21:9", count: nil)) != nil)
        #expect(refusal(order(), saved: true) != nil)
    }

    /// Several images go in order, up to the model's own limit from its catalog; a text-only model takes none.
    @Test func inputsKeepTheirOrderUpToTheModelsLimit() throws {
        let models = [soul, edit]
        let pictures = (1...4).map { LocalImage(fileURL: URL(fileURLWithPath: "/tmp/agent-input-\($0).png")) }
        func draft(_ model: String, _ inputs: [LocalImage]) -> Result<ReferenceGenerator.Draft, AgentImageRefusal> {
            AgentImageOrder(model: model, prompt: "x", aspectRatio: nil, count: nil, inputs: inputs)
                .draft(models: models, modelsAreSaved: false)
        }
        #expect(try draft("edit", Array(pictures.prefix(3))).get().inputs == Array(pictures.prefix(3)))
        guard case .failure(let over) = draft("edit", pictures) else {
            Issue.record("four inputs on a model that takes three")
            return
        }
        #expect(over.message.contains("at most 3 input images"))
        guard case .failure(let textOnly) = draft("soul", [pictures[0]]) else {
            Issue.record("an input on a text-only model")
            return
        }
        #expect(textOnly.message.contains("leave out inputs"))
        #expect(soul.inputLimit == 0)
        #expect(ImageModel(id: "g", title: "G", aspectRatios: ["1:1"], input: .optional).inputLimit == 1)
    }

    /// A record of one input holds only `input`, as a 0.2.0 record does; several are kept in order.
    @Test func severalInputsAreRecordedAndSentInOrder() async throws {
        let generator = generator()
        let queue = queue(generator)
        let pictures = (1...3).map { LocalImage(fileURL: URL(fileURLWithPath: "/tmp/agent-input-\($0).png")) }
        let id = try create(
            queue, AgentImageOrder(model: "edit", prompt: "swap", aspectRatio: nil, count: nil, inputs: pictures))
        await eventually { queue.record(id)?.state == .finished }
        let record = try #require(queue.record(id))
        #expect(record.inputs == pictures)
        #expect(record.input == pictures[0])
        #expect(await provider.submitted.first?.inputImages.count == 3)
        let single = try create(
            queue, AgentImageOrder(model: "edit", prompt: "one", aspectRatio: nil, count: nil, inputs: [picture]))
        #expect(queue.record(single)?.severalInputs == nil)
        #expect(queue.record(single)?.inputs == [picture])
    }

    @Test func theVisibleFormIsNeverTouched() throws {
        let generator = generator()
        generator.prompt = "the person's own prompt"
        let queue = queue(generator)
        try create(queue, order(count: 4))
        #expect(generator.prompt == "the person's own prompt")
        #expect(generator.count == 1)
    }

    // MARK: The guard

    @Test func aRequestUnderEveryLimitIsReservedSentAndSettled() async throws {
        let generator = generator()
        let queue = queue(generator)
        let id = try create(queue, order())

        await eventually { queue.record(id)?.state == .finished }

        #expect(await provider.submitted.count == 1)
        let record = try #require(queue.record(id))
        #expect(record.mayHaveBeenSent)
        #expect(record.origin.reservation != nil)
        #expect(await ledger.spends.map(\.isSettled) == [true])
        #expect(await ledger.spends.map(\.money) == [AgentMoney(8, .usdCents)])
        #expect(generator.runs.first?.agent?.client == "claude-code")
    }

    @Test func aPriceOverMaxCostIsHeldAndNothingIsSent() async throws {
        let generator = generator()
        let queue = queue(generator)
        let id = try create(queue, order(), origin: origin(maxCents: 7))

        await eventually { queue.record(id)?.state == .held }

        #expect(queue.record(id)?.hold == .overMaxCost)
        #expect(await provider.submitted.isEmpty)
        #expect(await ledger.spends.isEmpty)
        #expect(generator.runs.first?.state == .held(AgentImageQueue.text(of: .overMaxCost)))
        let status = AgentJobStatus(try #require(queue.record(id)), files: [])
        #expect(status.state == "paused")
        #expect(status.needsPerson)
        #expect(status.hold == "over_max_cost")
    }

    @Test func anUnknownPriceIsHeld() async throws {
        await provider.set(estimate: .failure(.server(status: 500)))
        let queue = queue(generator())
        let id = try create(queue, order())

        await eventually { queue.record(id)?.state == .held }

        // The list price is only an estimate: never trusted for an agent.
        #expect(queue.record(id)?.hold == .unknownPrice)
        #expect(await provider.submitted.isEmpty)
    }

    /// A model whose catalog states no limit takes up to the bound; Higgsfield's quote refuses more than it takes.
    /// The quote comes before anything is reserved or sent, so the refusal fails the request and costs nothing.
    @Test func aQuoteThatRefusesTheInputsFailsTheRequestBeforeAnythingIsSent() async throws {
        await provider.set(estimate: .failure(.validation(field: nil, message: "This model takes at most 4 images.")))
        let open = ImageModel(
            id: "open", title: "Open", aspectRatios: ["1:1"], input: .optional,
            unstatedInputLimit: ImageModel.inputBound)
        let generator = generator()
        generator.useModels([soul, edit, open])
        let queue = queue(generator)
        let pictures = (1...6).map { LocalImage(fileURL: URL(fileURLWithPath: "/tmp/agent-input-\($0).png")) }
        let id = try create(
            queue, AgentImageOrder(model: "open", prompt: "x", aspectRatio: nil, count: nil, inputs: pictures))

        await eventually { queue.record(id)?.state == .failed }

        #expect(queue.record(id)?.error?.contains("at most 4 images") == true)
        #expect(queue.record(id)?.mayHaveBeenSent == false)
        #expect(await provider.submitted.isEmpty)
        #expect(await ledger.spends.isEmpty)
        #expect(open.inputLimit == 14 && open.inputLimitIsBound)
    }

    @Test func overTheDailyAgentBudgetIsHeld() async throws {
        let queue = queue(generator(), limit: 5)
        let id = try create(queue, order())
        await eventually { queue.record(id)?.state == .held }
        #expect(queue.record(id)?.hold == .overDailyBudget)
        #expect(await provider.submitted.isEmpty)
    }

    @Test func reservationsInFlightCountAgainstTheBudget() async throws {
        _ = try await ledger.reserve(
            AgentSpend(jobID: UUID(), money: AgentMoney(95, .usdCents), at: Date()), dailyLimit: nil)
        let queue = queue(generator(), limit: 100)
        let id = try create(queue, order())
        await eventually { queue.record(id)?.state == .held }
        #expect(queue.record(id)?.hold == .overDailyBudget)
    }

    @Test func aLedgerThatCantBeWrittenSendsNothing() async throws {
        await ledger.breakIt()
        let queue = queue(generator())
        let id = try create(queue, order())
        await eventually { queue.record(id)?.state == .held }
        #expect(queue.record(id)?.hold == .ledgerUnavailable)
        #expect(await provider.submitted.isEmpty)
    }

    @Test func thePersonsOwnCapHoldsItToo() async throws {
        let cap = SpendStatus(committedToday: Decimal(string: "0.95")!, cap: .usd(1))
        let queue = queue(generator(cap: cap))
        let id = try create(queue, order())
        await eventually { queue.record(id)?.state == .held }
        #expect(queue.record(id)?.hold == .priceAboveCap)
        #expect(AgentJobStatus(try #require(queue.record(id)), files: []).pauseReason == "price_above_cap")
        #expect(await provider.submitted.isEmpty)
    }

    @Test func onlyThePersonSendsAHeldRequest() async throws {
        let generator = generator()
        let queue = queue(generator)
        let id = try create(queue, order(), origin: origin(maxCents: 7))
        await eventually { queue.record(id)?.state == .held }

        queue.approve(id, provider: provider, upload: Self.upload(provider))
        await eventually { queue.record(id)?.state == .finished }

        #expect(await provider.submitted.count == 1)
        #expect(queue.record(id)?.origin.approvedByPerson == true)
        #expect(await ledger.spends.count == 1)
    }

    /// The person approved the price they saw: a higher quote right before the submit waits for them again.
    @Test func aPriceAboveTheApprovedOneIsHeldAgain() async throws {
        let generator = generator()
        let queue = queue(generator)
        let id = try create(queue, order(), origin: origin(maxCents: 7))
        await eventually { queue.record(id)?.state == .held }

        await provider.set(estimate: .success(.usd(0.2, isEstimate: false)))
        queue.approve(id, provider: provider, upload: Self.upload(provider))
        await eventually { queue.record(id)?.hold == .aboveApprovedPrice }
        #expect(queue.record(id)?.state == .held)
        #expect(await provider.submitted.isEmpty)
        #expect(AgentJobStatus(try #require(queue.record(id)), files: []).hold == "above_approved_price")

        queue.approve(id, provider: provider, upload: Self.upload(provider))
        await eventually { queue.record(id)?.state == .finished }
        #expect(await provider.submitted.count == 1)
        #expect(await ledger.spends.map(\.money) == [AgentMoney(20, .usdCents)])
    }

    @Test func aRefusedSubmitGivesTheReservationBack() async throws {
        await provider.set(submitError: .validation(field: nil, message: "No"))
        let queue = queue(generator())
        let id = try create(queue, order())
        await eventually { queue.record(id)?.state == .failed }
        #expect(await ledger.spends.isEmpty)
        #expect(queue.record(id)?.mayHaveBeenSent == false)
    }

    @Test func anUnansweredSubmitKeepsTheReservation() async throws {
        await provider.set(submitError: .network)
        let queue = queue(generator())
        let id = try create(queue, order())
        await eventually { queue.record(id)?.state == .failed }
        #expect(await ledger.spends.map(\.isSettled) == [false])
        #expect(queue.record(id)?.mayHaveBeenSent == true)
        #expect(AgentJobStatus(try #require(queue.record(id)), files: []).charged)
    }

    // MARK: What it was charged

    func spent() async -> Int {
        (try? await ledger.total(on: Date(), unit: .usdCents).spent) ?? -1
    }

    /// Higgsfield bills only the jobs that made images: the others' share goes back once all of them ended.
    @Test func aRequestCountsOnlyTheJobsThatMadeImages() async throws {
        let image = ImageJobStatus.completed([URL(string: "https://cdn.example.com/1.png")!])
        await provider.set(outcomes: [image, .failed(message: nil), .rejected(.explicitContent), image])
        let queue = queue(generator())
        let id = try create(queue, order(count: 4))

        await eventually { queue.record(id)?.state == .finished }
        await eventually { await spent() == 4 }

        #expect(await ledger.spends.map(\.money) == [AgentMoney(8, .usdCents)])
    }

    @Test func aRequestWhoseJobsAllFailedCountsNothing() async throws {
        await provider.set(outcomes: [.failed(message: "Boom")])
        let queue = queue(generator())
        let id = try create(queue, order())

        await eventually { queue.record(id)?.state == .failed }
        await eventually { await spent() == 0 }
        #expect(await ledger.spends.count == 1)
    }

    /// Cancelled while its jobs waited: none ran, so none is billed. One the provider wouldn't cancel may have run,
    /// and keeps its whole price.
    @Test(arguments: [false, true])
    func aCanceledRequestCountsNothingUnlessTheCancelWasRefused(refused: Bool) async throws {
        await provider.set(outcomes: [.pending, .pending], refusesCancel: refused)
        let generator = generator()
        let queue = queue(generator)
        let id = try create(queue, order(count: 4))
        await eventually { queue.record(id)?.state == .following }
        await eventually { generator.jobLog.records.contains { $0.runID == id } }

        #expect(queue.cancel(id))
        await eventually { queue.record(id)?.isOver == true }
        await eventually { await spent() == (refused ? 8 : 0) }

        #expect(queue.record(id)?.state == .canceled)
    }

    @Test func aHeldRequestCanceledWasNeverSent() async throws {
        let generator = generator()
        let queue = queue(generator)
        let id = try create(queue, order(), origin: origin(maxCents: 1))
        await eventually { queue.record(id)?.state == .held }

        #expect(queue.cancel(id))
        #expect(queue.record(id)?.state == .canceled)
        #expect(!queue.cancel(id))
        #expect(await provider.submitted.isEmpty)
    }

    // MARK: Relaunch

    @Test func aRelaunchReleasesOrphansFailsLostAnswersAndShowsHeldRequests() async throws {
        let first = queue(generator())
        let held = try create(first, order(), origin: origin(maxCents: 1))
        await eventually { first.record(held)?.state == .held }

        // Another launch's request: reserved and saved as being sent, then the app quit before an answer.
        var sending = try #require(first.record(held))
        let sent = AgentSpend(jobID: UUID(), money: AgentMoney(8, .usdCents), at: Date())
        let orphan = AgentSpend(jobID: held, money: AgentMoney(8, .usdCents), at: Date())
        _ = try await ledger.reserve(orphan, dailyLimit: nil)
        _ = try await ledger.reserve(sent, dailyLimit: nil)
        let file = folder.appending(path: "agent-images.json")
        var records = try JSONDecoder.iso.decode([AgentImageRecord].self, from: Data(contentsOf: file))
        sending = AgentImageRecord(
            id: sent.jobID, origin: sending.origin, providerKind: .apiKey, owner: "key-1", model: soul, prompt: "x",
            aspectRatio: "1:1", count: 1, state: .sending, priceIsKnown: true, sentAt: Date(), createdAt: Date())
        sending.origin.reservation = sent.id
        records.append(sending)
        try JSONEncoder.iso.encode(records).write(to: file)

        let generator = generator()
        let relaunched = queue(generator)
        await relaunched.restore()

        #expect(await ledger.spends.map(\.id) == [sent.id])
        #expect(relaunched.record(sent.jobID)?.state == .failed)
        #expect(relaunched.record(sent.jobID)?.mayHaveBeenSent == true)
        #expect(generator.runs.map(\.id) == [held])
        #expect(generator.runs.first?.agent?.requestID == "img-1")
    }

    @Test func aRecordThatCantBeReadTakesNothing() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: folder.appending(path: "agent-images.json"))
        let queue = queue(generator())
        #expect(throws: AgentImageRefusal.self) { try create(queue, order()) }
    }
}

extension JSONDecoder {
    fileprivate static var iso: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

extension JSONEncoder {
    fileprivate static var iso: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
