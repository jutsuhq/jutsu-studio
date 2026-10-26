import Foundation
import JobEngine
import JutsuAgent
import JutsuCore
import Presentation
import os

private let logger = Logger(subsystem: "com.jutsustudio", category: "Agents")

// quote and create_video: the commands that make videos. Every job is built from a fresh Create form
// (`AgentVideoOrder`), never the Create screen's draft, and every paid submit passes the engine's spending
// guard (`JobEngine.clearAgentSpend`); nothing here decides what may be spent. jobs and job_action are in
// AgentService+Jobs.swift, uploads and the request record in AgentService+Requests.swift.
extension AgentService {
    // MARK: quote

    func quote(_ fields: QuoteCommand) async throws(AgentError) -> AgentQuote {
        let video = fields.video
        var source: AgentVideoOrder.Source?
        if let given = video.source {
            guard let end = given.end else {
                throw .badRequest("quote: source needs end, where the job's range ends in seconds")
            }
            source = AgentVideoOrder.quoteSource(start: given.start, end: end)
        }
        // An element's images count as the references they become; reading them is free.
        let elementImages = try await namedElements(video.elements).reduce(0) { $0 + $1.images.count }
        let order = Self.order(
            video, source: source, images: AgentVideoOrder.quoteImages(video.referenceCount + elementImages))
        let (spec, paysUnlimited) = try await spec(for: order)
        let kind = environment.connection.state.kind
        var taken: AgentSpendTotal?
        if let kind { taken = try await agentSpendToday(for: kind) }
        // The plan's unlimited allowance pays it: nothing counts against the budget or the cap.
        let unlimited = AgentSpendDecision.paysUnlimited(
            paysUnlimited, allowsUnlimited: preferences.allowsUnlimited, chargedToday: taken?.unlimitedCharged == true)
        let cost: Cost? = unlimited ? .credits(0, isEstimate: false) : await environment.estimate(spec)
        let money = cost.flatMap(AgentMoney.init)
        let price = money.map(AgentAmount.init)
        var remaining: Int?
        if let kind, let taken { remaining = taken.remaining(of: preferences.dailyBudget(for: kind)) }
        let isExact = cost.map { !$0.isEstimate && !$0.isUnknownPrice } ?? false
        let limits = spec.limits(in: environment.navigation.modelConstraints).referenceImages
        let variants = AgentVideoOrder.variants(
            of: spec.model, in: spec.mode, capabilities: environment.lastCapabilities,
            unlimitedOptIn: AppSettings.usesUnlimited(in: environment.defaults))
        return AgentQuote(
            price: price, isExact: isExact, mode: video.mode, model: spec.model.rawValue,
            resolution: spec.resolution.rawValue, duration: spec.duration, remainingToday: remaining,
            paysUnlimited: paysUnlimited,
            blocker: AgentQuote.blocker(
                price: money?.amount, remaining: remaining, paysUnlimited: unlimited,
                unlimitedAllowed: preferences.allowsUnlimited),
            priceNote: AgentQuote.priceNote(isEstimate: !isExact, hasPrice: money != nil, paysUnlimited: unlimited),
            maxVariants: variants.maximum, variantsUnavailable: variants.reason, images: spec.references.count,
            minImages: limits.lowerBound, maxImages: limits.upperBound, aspectRatio: AgentVideoOrder.frame(of: spec))
    }

    // MARK: create_video

    func createVideo(_ fields: CreateVideoCommand, client: String?) async throws(AgentError) -> AgentCreated {
        let started = ContinuousClock.now
        let files = [fields.video.source?.path].compactMap(\.self) + fields.video.images
        defer { Task { await sweepInbox() } }
        let created = try await requests.run(
            fields.requestID, fingerprint: fields.fingerprint, parameters: fields.parameters,
            refusals: Self.refusals("create_video", made: "its job was never queued"), discard: { discard(files) },
            known: { ids throws(AgentError) in
                let jobs = try await knownJobs(ids)
                return jobs.isEmpty
                    ? nil : AgentCreated(requestID: fields.requestID, known: true, jobs: jobs.map(AgentJob.init))
            },
            otherMaxCost: { [weak self] ids throws(AgentError) in
                guard let self else { throw .agentsOff }
                return try await self.raiseMaxCost(fields, of: ids)
            },
            queue: { [weak self] () throws(AgentError) in
                guard let self else { throw .agentsOff }
                return try await self.queue(fields, client: client)
            })
        guard fields.waitSeconds > 0 else { return created }
        let seconds = AgentProtocol.waitSeconds(fields.waitSeconds, after: ContinuousClock.now - started)
        return await waitForPrice(of: created, seconds: seconds)
    }

    /// The jobs of a known request. Throws when the store can't be read: a job not found there could still exist.
    func knownJobs(_ ids: [UUID]) async throws(AgentError) -> [Job] {
        var jobs: [Job] = []
        for id in ids {
            if let live = environment.liveJobs.job(id) {
                jobs.append(live)
                continue
            }
            do {
                if let stored = try await environment.store.job(id: id) { jobs.append(stored) }
            } catch {
                throw AgentError(
                    .failed, message: "Jutsu Studio can't read its jobs right now.", retryable: true,
                    next: "Send the same create_video again in a moment.")
            }
        }
        return jobs
    }

    /// Builds the job as Create would, records the request with the job's ID, then queues it.
    private func queue(_ fields: CreateVideoCommand, client: String?) async throws(AgentError) -> AgentCreated {
        let video = fields.video
        guard let kind = environment.connection.state.kind else { throw Self.notConnected }
        try Self.checkUnit(of: fields.maxCost, on: kind)
        var source: AgentVideoOrder.Source?
        if let given = video.source { source = try await sourceClip(given) }
        var files: [LocalImage] = []
        for path in video.images { files.append(LocalImage(fileURL: try inboxFile(path))) }
        let elements = try await elementImages(video.elements)
        let images = elements.flatMap(\.images) + files
        if let style = video.style,
            let refusal = PresetCatalog.agentStyleRefusal(style, in: environment.layout.presetCacheFolder)
        {
            throw .invalidRequest(refusal)
        }
        let (spec, _) = try await spec(for: Self.order(video, source: source, images: images))
        let jobID = UUID()
        try recordRequest(
            fields.requestID, fingerprint: fields.fingerprint, parameters: fields.parameters, jobIDs: [jobID])
        let origin = AgentOrigin(
            client: client, requestID: fields.requestID,
            maxCost: AgentMoney(fields.maxCost))
        do {
            let job = try await environment.engine.enqueue(spec, id: jobID, agent: origin)
            return AgentCreated(
                requestID: fields.requestID, known: false, jobs: [AgentJob(job)],
                references: Self.references(elements: elements, files: files))
        } catch {
            throw Self.agentError(enqueueing: error)
        }
    }

    /// The agent's source clip, probed as Create probes a dropped one.
    private func sourceClip(_ given: AgentSource) async throws(AgentError) -> AgentVideoOrder.Source {
        guard let path = given.path else { throw .badRequest("create_video: source needs path, the clip on this Mac") }
        let file = try inboxFile(path)
        do {
            let probed = try await AppEnvironment.probeSource(file, bookmark: nil)
            return AgentVideoOrder.Source(video: probed, start: given.start, end: given.end)
        } catch {
            throw .invalidRequest("The source clip can't be read as a video: \(error.localizedDescription)")
        }
    }

    /// Refuses a `max_cost` in another unit than the connection's.
    static func checkUnit(of maxCost: AgentAmount, on kind: ProviderKind) throws(AgentError) {
        let unit = AgentBudgetUnit(for: kind)
        guard unit != maxCost.unit else { return }
        throw .badRequest("max_cost is in \(unit == .usdCents ? "usd" : "credits") on this connection")
    }

    /// The request's fields as an order, with its files as the app holds them.
    private static func order(
        _ video: AgentVideoRequest, source: AgentVideoOrder.Source?, images: [LocalImage]
    ) -> AgentVideoOrder {
        AgentVideoOrder(
            mode: video.mode, model: video.model, prompt: video.prompt ?? "", source: source, images: images,
            style: video.style, resolution: video.resolution, isDraft: video.draft, length: video.length,
            aspectRatio: video.aspectRatio, audio: video.audio, variants: video.variants, title: video.title)
    }

    /// The one job `order` makes, built and checked as Create does, on the connection as it is now, and whether the
    /// plan's unlimited allowance would pay for it as things stand (the engine decides again when it is queued).
    private func spec(for order: AgentVideoOrder) async throws(AgentError) -> (JobSpec, paysUnlimited: Bool) {
        let state = environment.connection.state
        guard let kind = state.kind else { throw Self.notConnected }
        let capabilities = await environment.capabilities()
        if let models = capabilities?.models { environment.lastOfferedModels = models }
        let context = CreateContext(
            connection: state, capabilities: capabilities, pricing: try? Pricing.bundled(),
            cap: environment.spendCap(for: kind),
            unlimitedOptIn: AppSettings.usesUnlimited(in: environment.defaults))
        let constraints = environment.navigation.modelConstraints
        let base = CreateForm(settings: environment.defaults)
        switch order.spec(from: base, in: context, constraints: constraints == .builtIn ? nil : constraints) {
        case .success(let spec): return (spec, context.paysUnlimited(spec))
        case .failure(let refusal): throw .invalidRequest(refusal.message)
        }
    }

    // MARK: Helpers

    /// What agents took today on `kind`'s connection.
    func agentSpendToday(for kind: ProviderKind) async throws(AgentError) -> AgentSpendTotal {
        do {
            return try await environment.agentSpend.total(on: .now, unit: AgentMoney.unit(for: kind))
        } catch {
            logger.error("Can't read the agent spend: \(String(describing: error), privacy: .private)")
            throw AgentError(
                .failed, message: "Jutsu Studio can't read what agents spent today, so agents can't spend.",
                retryable: true, next: "Ask the person to check the app's data folder.")
        }
    }

    static func isSubmitInProgress(_ error: any Error) -> Bool {
        if case JobEngineError.submitInProgress = error { return true }
        return false
    }

    static let notConnected = AgentError(
        .notConnected, message: "Jutsu Studio isn't connected to Higgsfield.", retryable: true,
        next: "Ask the person to connect Higgsfield in Settings, then send the request again.")

    static func agentError(enqueueing error: any Error) -> AgentError {
        switch error {
        case JobEngineError.overCap(let over):
            AgentError(
                .overCap,
                message: AgentCap.overCapMessage(
                    cap: over.cap, committedToday: over.committedToday, price: over.price),
                retryable: false, next: "Ask the person to raise the cap in Settings or queue it themselves.")
        case JobEngineError.notConnected:
            notConnected
        default:
            AgentError(.failed, message: error.localizedDescription, retryable: true)
        }
    }
}
