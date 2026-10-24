import Foundation
import JutsuCore
import Observation

/// An image made in this session by Generate….
public struct GeneratedImage: Sendable, Hashable, Identifiable {
    public let id: UUID
    /// Where the provider serves it; downloaded only when picked.
    public var url: URL
    public var prompt: String
    public var model: String
    public var aspectRatio: String?
    /// The copy saved in the output folder's `Images` folder; `nil` until it is saved, or when saving failed.
    public var fileURL: URL?
    /// Added to Create's references.
    public var isPicked = false
    public var remote: MaterialRemote?
    public var parameters: Data?
    public var inputImages: [LocalImage] = []
    public var variantGroupID: UUID?
    /// An agent's name for the images (`JobSpec.title(from:)`): their card and file name use it instead of the prompt.
    public var title: String?

    public init(
        id: UUID = UUID(), url: URL, prompt: String, model: String, aspectRatio: String? = nil, fileURL: URL? = nil
    ) {
        self.id = id
        self.url = url
        self.prompt = prompt
        self.model = model
        self.aspectRatio = aspectRatio
        self.fileURL = fileURL
    }
}

/// One Generate… request and where it is.
public struct ImageRun: Sendable, Hashable, Identifiable {
    public enum State: Sendable, Hashable {
        case running
        case finished
        case failed(String)
        case canceled
        /// Following it stopped before it ended: the sign-in expired, its status couldn't be read, or another
        /// account was connected. Its jobs and price are kept, and it is followed again (`resume`).
        case interrupted(String)
        /// An agent's request the spending guard stopped before anything was sent: only the person sends it, after
        /// seeing why (`AgentImageQueue.approve`).
        case held(String)
    }

    public let id: UUID
    public var model: String
    public var count: Int
    public var state: State
    /// The agent that asked for it (`create_image`); `nil` for the person's own.
    public var agent: AgentOrigin?
    /// An agent's request: its price as the guard saw it, for the person's confirmation.
    public var price: Cost?
    /// An agent's name for the request, which its row starts with.
    public var name: String?

    /// Its row stays when a new request replaces the rows of the ones that are over.
    var keepsRow: Bool {
        switch state {
        case .running, .held: true
        default: false
        }
    }

    /// "Agent · claude-code", for the row of an agent's request.
    public var agentTitle: String? { agent.map(JobRowModel.originText) }

    /// "Allowed up to $2.00".
    public var agentDetail: String? {
        agent.map { String(localized: "Allowed up to \(JobRowModel.moneyText($0.maxCost))", bundle: .module) }
    }

    /// "Soul 2 · 4 images", after the agent's name for it when it gave one.
    public var title: String {
        (name.map { "\($0) · " } ?? "") + "\(model) · " + String(localized: "\(count) images", bundle: .module)
    }
}

/// What Generate… asks for and runs: a prompt, a model of the connection, a frame, the variants and an
/// optional image to edit, the price before Generate, the runs with their images and the images picked to become
/// references. The form, runs and results are shared by the References quick action and the Image side of Create,
/// so they outlive both. Image jobs
/// never enter the job engine: the runs are polled here and their prices go into the `ImageSpendLog`, which the daily
/// cap and Spending read.
///
/// Money: a request's price is written before it is sent, and it isn't sent when that write fails. Every job the
/// answer names goes into `ImageJobLog` and is followed until it ends, after a lost sign-in, a switch of account or
/// a relaunch too (`resume`). Only an answer that the job failed, was refused or was cancelled takes the price off; a
/// status that can't be read leaves it counted.
@MainActor
@Observable
public final class ReferenceGenerator {
    public var prompt = ""
    /// `nil` until a model is chosen; one of `models` whenever there are some. Without models (disconnected, or
    /// before they load) the last choice is kept for when they come back.
    public private(set) var modelID: String?
    /// The frame the user picked; `nil` follows `defaultAspectRatio`.
    public var chosenAspectRatio: String?
    public var count = 1
    /// The image to edit, for a model that takes one.
    public var inputImage: LocalImage?

    public private(set) var models: [ImageModel] = []
    /// Why no model can be offered; `nil` while loading or when there are models.
    public private(set) var unavailableReason: String?
    /// `models` are the ones saved at the last load, shown while the connection's own list loads; Generate waits for
    /// that list, since a saved model may be gone or changed.
    public private(set) var modelsAreSaved = false
    /// The price of the request as it stands; `nil` while it is being read or can't be.
    public internal(set) var price: Cost?
    public internal(set) var priceFailure: String?
    public internal(set) var runs: [ImageRun] = []
    public internal(set) var images: [GeneratedImage] = []
    /// The images picked to become references, in the order they were picked.
    public private(set) var selection: [UUID] = []

    /// Called with each run's images as they arrive, to save them (`setFile` reports where).
    @ObservationIgnored public var onImages: (([GeneratedImage]) -> Void)?
    /// Called when Higgsfield turned a poll down because the sign-in no longer works, to ask for it again.
    @ObservationIgnored public var onSignInExpired: (() -> Void)?
    /// Called when a run ends or stops being followed, with how: what `AgentImageQueue` records for an agent.
    @ObservationIgnored var onRunEnded: ((UUID, ImageRun.State) -> Void)?
    @ObservationIgnored public let jobLog: ImageJobLog
    @ObservationIgnored let spend: ImageSpendLog
    @ObservationIgnored let spendStatus: SpendStatusReader
    @ObservationIgnored let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored let now: @Sendable () -> Date
    /// The uploads and submits, by run. Not cut off by a new connection: a submit may already be paid for.
    @ObservationIgnored var submits: [UUID: Task<Void, Never>] = [:]
    /// The polls, by run.
    @ObservationIgnored var followers: [UUID: Task<Void, Never>] = [:]
    /// Runs the user cancelled while they were followed.
    @ObservationIgnored var canceling: Set<UUID> = []
    /// Goes up with each connection (`reset`), so an upload or a price of the old one isn't kept.
    @ObservationIgnored var generation = 0
    /// The last input uploaded on this connection, so pricing and Generate don't upload it again.
    @ObservationIgnored var uploaded: (image: LocalImage, asset: RemoteAsset)?

    /// - Parameter spendStatus: today's spend and the cap, read before each request is sent.
    public init(
        spend: ImageSpendLog, jobLog: ImageJobLog, spendStatus: @escaping SpendStatusReader = { _ in nil },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.spend = spend
        self.jobLog = jobLog
        self.spendStatus = spendStatus
        self.sleep = sleep
        self.now = now
    }

    // MARK: Form

    public var model: ImageModel? { models.first { $0.id == modelID } }

    /// The frame without a choice: the source clip's nearest, or 1:1 for Object Swap (the image is an object) and
    /// without a source.
    public func defaultAspectRatio(source: PixelSize?, mode: Mode) -> String? {
        guard let model else { return nil }
        if let source, mode != .objectSwap, source.isValid {
            return model.nearestAspectRatio(width: source.width, height: source.height)
        }
        return model.aspectRatios.contains("1:1") ? "1:1" : model.aspectRatios.first
    }

    /// The chosen frame when the model takes it, else the default.
    public func aspectRatio(source: PixelSize?, mode: Mode) -> String? {
        if let chosenAspectRatio, model?.aspectRatios.contains(chosenAspectRatio) == true { return chosenAspectRatio }
        return defaultAspectRatio(source: source, mode: mode)
    }

    public func selectModel(_ id: String) {
        guard let model = models.first(where: { $0.id == id }) else { return }
        modelID = id
        if !model.variantCounts.contains(count) { count = model.variantCounts[0] }
    }

    /// Takes the connection's models, keeping the chosen one when it is still offered. Without models the choice is
    /// kept, so a restored draft or a template applied before they load keeps its model.
    public func useModels(_ models: [ImageModel], unavailableReason: String? = nil) {
        self.models = models
        modelsAreSaved = false
        self.unavailableReason = models.isEmpty ? unavailableReason ?? Self.noModels : nil
        guard let first = models.first else { return }
        selectModel(models.contains { $0.id == modelID } ? modelID ?? first.id : first.id)
    }

    /// Shows the models saved at the last load until `useModels` hands over the connection's own; none saved keeps
    /// the current ones.
    public func useSavedModels(_ saved: [ImageModel]) {
        guard !saved.isEmpty else { return }
        useModels(saved)
        modelsAreSaved = true
    }

    /// Whether the model sends `inputImage`.
    public var sendsInput: Bool { inputImage != nil && model?.input != ImageModel.Input.none }

    /// Why Generate is off; `nil` when it can run.
    public var blocker: String? {
        guard let model else { return unavailableReason ?? Self.noModels }
        if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return String(localized: "Describe the image to make", bundle: .module)
        }
        if model.input == .required && inputImage == nil {
            return String(localized: "\(model.title) edits an image: add one", bundle: .module)
        }
        if modelsAreSaved { return String(localized: "Checking the image models…", bundle: .module) }
        return nil
    }

    static let noModels = String(localized: "This connection offers no image models", bundle: .module)

    /// The form as it stands, before the input is uploaded; `nil` while Generate is off.
    struct Draft: Sendable, Hashable {
        var model: ImageModel
        var prompt: String
        var aspectRatio: String
        var count: Int
        /// The images to edit, in order: the form's one, or an agent's several.
        var inputs: [LocalImage]
        /// An agent's name for the images; `nil` for the person's own.
        var title: String?
    }

    func draft(source: PixelSize?, mode: Mode) -> Draft? {
        guard blocker == nil, let model, let ratio = aspectRatio(source: source, mode: mode) else { return nil }
        return Draft(
            model: model, prompt: prompt, aspectRatio: ratio, count: count,
            inputs: sendsInput ? inputImage.map { [$0] } ?? [] : [])
    }

    /// `draft` as a request, its inputs uploaded in order through `upload`, except the image uploaded last when it
    /// is one of them.
    func request(_ draft: Draft, upload: (LocalImage) async throws -> RemoteAsset) async throws -> ImageRequest {
        var inputs: [RemoteAsset] = []
        for input in draft.inputs {
            if let uploaded, uploaded.image == input {
                inputs.append(uploaded.asset)
            } else {
                let generation = generation
                let asset = try await upload(input)
                // An upload that outlived its connection is the old account's media: never offered to the new one.
                if generation == self.generation { uploaded = (input, asset) }
                inputs.append(asset)
            }
        }
        return ImageRequest(
            model: draft.model.id, prompt: draft.prompt, aspectRatio: draft.aspectRatio, count: draft.count,
            inputImages: inputs)
    }

    // MARK: Draft

    /// The form as a value: the Image side of the Create draft (`CreateDraftStore`), restored on the next launch.
    public func snapshot() -> ImageDraft {
        ImageDraft(
            prompt: prompt, modelID: modelID, chosenAspectRatio: chosenAspectRatio, count: count,
            inputImage: inputImage)
    }

    /// Restores a saved form. The saved model is kept when it is offered, else the current one stays; the count is
    /// kept when that model makes it. Before the models are loaded the choice is kept as it is, and `useModels`
    /// settles it once they arrive.
    public func restore(_ draft: ImageDraft) {
        prompt = draft.prompt
        chosenAspectRatio = draft.chosenAspectRatio
        inputImage = draft.inputImage
        count = max(1, draft.count)
        guard let first = models.first else {
            modelID = draft.modelID
            return
        }
        let offered = models.first { $0.id == draft.modelID }
        selectModel(offered?.id ?? modelID ?? first.id)
    }

    /// Fills the form from an image template. A model the connection doesn't offer runs on the current one, and
    /// the message says so; the count is kept when that model makes it.
    @discardableResult
    public func applyImageTemplate(_ template: JobTemplate) -> UserMessage? {
        let isOffered = models.isEmpty || models.contains { $0.id == template.imageModelID }
        restore(
            ImageDraft(
                prompt: template.prompt, modelID: template.imageModelID, chosenAspectRatio: template.imageAspectRatio,
                count: template.imageCount, inputImage: template.references.first))
        guard !isOffered, let model else { return nil }
        return UserMessage(
            title: String(localized: "Running on \(model.title)", bundle: .module),
            message: String(
                localized: """
                    "\(template.name)" uses an image model this connection doesn't offer, \
                    so it runs on \(model.title).
                    """, bundle: .module))
    }

    /// The form's inputs as an image template.
    public func makeImageTemplate(name: String, id: UUID = UUID(), createdAt: Date = Date()) -> JobTemplate {
        JobTemplate(
            id: id, name: name, createdAt: createdAt, imageModelID: modelID, imageModelTitle: model?.title,
            imageAspectRatio: aspectRatio(source: nil, mode: .motionTransfer), imageCount: count, prompt: prompt,
            references: inputImage.map { [$0] } ?? [])
    }

    // MARK: Price

    /// What the price key covers: everything the request is made of.
    public func priceKey(source: PixelSize?, mode: Mode) -> String {
        [
            modelID ?? "", prompt, aspectRatio(source: source, mode: mode) ?? "", String(count),
            sendsInput ? inputImage?.fileURL.absoluteString ?? "" : "",
        ].joined(separator: "\u{1F}")
    }

    /// Reads the price of the request as it stands: the provider's quote, or the model's list price when the
    /// provider can't give one.
    public func refreshPrice(
        provider: any ImageProvider, source: PixelSize?, mode: Mode,
        upload: (LocalImage) async throws -> RemoteAsset
    ) async {
        price = nil
        priceFailure = nil
        let generation = generation
        do {
            guard let draft = draft(source: source, mode: mode) else { return }
            let quote = try await provider.imageEstimate(try await request(draft, upload: upload))
            try Task.checkCancellation()
            guard generation == self.generation else { return }
            price = quote
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, generation == self.generation else { return }
            price = listPrice
            priceFailure = UserMessage(error)?.message
        }
    }

    /// The model's list price for `count` images, an estimate.
    public var listPrice: Cost? {
        guard let each = model?.listPrice else { return nil }
        switch each {
        case .usd(let amount, _): return .usd(amount * Decimal(count), isEstimate: true)
        case .credits(let amount, _): return .credits(amount * Decimal(count), isEstimate: true)
        }
    }

    // MARK: Runs

    /// Submits the request as it stands and follows it until its images arrive. Its price counts toward today's
    /// spend from the submit; a request that is refused, fails or is cancelled while queued is taken off again.
    /// Unless `overCapApproved`, today's spend is read first, and a price that takes today past the cap, or isn't
    /// known under one, sends nothing and asks (`capConfirmation`).
    /// - Parameters:
    ///   - price: the price shown to the user; `nil` counts as nothing until a quote exists.
    ///   - overCapApproved: the user agreed to go past today's cap with this request.
    @discardableResult
    public func generate(
        provider: any ImageProvider, source: PixelSize?, mode: Mode, price: Cost?, overCapApproved: Bool = false,
        upload: @escaping @Sendable (LocalImage) async throws -> RemoteAsset
    ) async -> PaidStart {
        guard let draft = draft(source: source, mode: mode) else { return .notStarted }
        do {
            let generation = generation
            let status = try await spendStatus(provider.kind)
            // Another account connected while today's spend was read: the request was the old one's.
            guard generation == self.generation else { return .notStarted }
            if !overCapApproved, let status,
                let question = Self.capConfirmation(
                    cost: price, committedToday: status.committedToday, cap: status.cap)
            {
                return .needsConfirmation(question)
            }
        } catch {
            runs.insert(
                ImageRun(id: UUID(), model: draft.model.title, count: draft.count, state: .failed(Self.message(error))),
                at: 0)
            return .notStarted
        }
        let id = UUID()
        // A new request replaces the rows of the ones that are over; their images stay.
        runs.removeAll { !$0.keepsRow }
        runs.insert(ImageRun(id: id, model: draft.model.title, count: draft.count, state: .running), at: 0)
        let cost = price ?? (provider.kind == .apiKey ? .usd(0, isEstimate: true) : .unknownCredits)
        submits[id] = Task { [weak self] in
            await self?.submit(id, draft: draft, cost: cost, provider: provider, upload: upload)
        }
        return .started
    }

    /// Stops following the run; a request still queued is cancelled and not charged, and an agent's request held
    /// before it was sent is dropped.
    public func cancel(_ id: UUID) {
        if let submit = submits[id] {
            submit.cancel()
        } else if let follower = followers[id] {
            canceling.insert(id)
            follower.cancel()
        } else if case .held? = runs.first(where: { $0.id == id })?.state {
            finish(id, .canceled)
        }
    }

    public var isRunning: Bool { runs.contains { $0.state == .running } }

    /// Requests whose upload or submit is out; quitting waits for them (`finishSubmits`).
    public var sendingCount: Int { submits.count }

    /// Requests being sent or followed until their images arrive.
    public var activeCount: Int { submits.count + followers.count }

    /// Waits for the submits already sent to be answered, so the jobs they start are in `jobLog` before a quit.
    public func finishSubmits() async {
        for task in Array(submits.values) { await task.value }
    }

    func finish(_ id: UUID, _ state: ImageRun.State) {
        if let index = runs.firstIndex(where: { $0.id == id }) { runs[index].state = state }
        if state != .running { onRunEnded?(id, state) }
    }

    static func message(_ error: any Error) -> String {
        UserMessage(error)?.message ?? couldNotMake
    }
}

// MARK: Results

extension ReferenceGenerator {
    public var selectedImages: [GeneratedImage] {
        selection.compactMap { id in images.first { $0.id == id } }
    }

    /// Picks `id`, or unpicks it when it is picked. A pick is refused once `room` images are picked (`room` is how many
    /// references Create can still take) and for an image already added; returns whether the selection changed.
    @discardableResult
    public func toggleSelection(_ id: UUID, room: Int) -> Bool {
        if let index = selection.firstIndex(of: id) {
            selection.remove(at: index)
            return true
        }
        guard selection.count < room, images.contains(where: { $0.id == id && !$0.isPicked }) else { return false }
        selection.append(id)
        return true
    }

    /// Where the image was saved.
    public func setFile(_ fileURL: URL, for id: UUID) {
        guard let index = images.firstIndex(where: { $0.id == id }) else { return }
        images[index].fileURL = fileURL
    }

    /// Takes a result off the list and out of the picks; returns it, `nil` when it isn't there.
    @discardableResult
    public func remove(_ id: UUID) -> GeneratedImage? {
        guard let index = images.firstIndex(where: { $0.id == id }) else { return nil }
        selection.removeAll { $0 == id }
        return images.remove(at: index)
    }

    public func contains(_ id: UUID) -> Bool { images.contains { $0.id == id } }

    /// The image was added to Create's references.
    public func markPicked(_ id: UUID) {
        guard let index = images.firstIndex(where: { $0.id == id }) else { return }
        images[index].isPicked = true
        selection.removeAll { $0 == id }
    }

    /// The References quick action was closed: its picks go, the images stay for the Image side of Create.
    public func clearSelection() {
        selection.removeAll()
    }

    /// Drops the images, picks and finished requests; a request still running keeps its row, and its images join
    /// the next results.
    public func clearResults() {
        images.removeAll()
        selection.removeAll()
        runs.removeAll { !$0.keepsRow }
    }
}

extension ReferenceGenerator {
    /// "$0.0128 · Price from Higgsfield", "About $0.08 · Estimate".
    public static func priceText(_ cost: Cost) -> String {
        if cost == .unknownCredits { return PostOperationText.unknownPriceNotice }
        let amount = CostText.imagePrice(cost)
        return cost.isEstimate
            ? String(localized: "About \(amount) · Estimate", bundle: .module)
            : String(localized: "\(amount) · Price from Higgsfield", bundle: .module)
    }

    /// The question to ask before Generate when the price takes today past the cap, or isn't known under one;
    /// `nil` to go ahead. Create Character asks the same.
    public static func capConfirmation(cost: Cost?, committedToday: Decimal, cap: SpendCap?) -> CapConfirmation? {
        guard let cap else { return nil }
        let capText = CostText.amount(cap.amount, unit: cap.unit)
        guard let cost, cost != .unknownCredits else {
            return CapConfirmation(
                title: String(localized: "Price not known yet", bundle: .module),
                message: String(
                    localized: """
                        These images' price isn't known, so they may take today past your \(capText) cap. Today is \
                        at \(CostText.amount(committedToday, unit: cap.unit)) so far.
                        """, bundle: .module),
                confirmTitle: String(localized: "Generate anyway", bundle: .module))
        }
        guard case .needsConfirmation(let total) = Budget.allows(cost: cost, committedToday: committedToday, cap: cap)
        else { return nil }
        return CapConfirmation(
            title: String(localized: "Over today's spend cap", bundle: .module),
            message: String(
                localized: """
                    These images add \(CostText.imagePrice(cost)), bringing today to \
                    \(CostText.amount(total, unit: cap.unit)) against your \(capText) cap.
                    """, bundle: .module),
            confirmTitle: String(localized: "Generate anyway", bundle: .module))
    }
}
