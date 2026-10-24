import Foundation
import JobEngine
import JutsuAgent
import JutsuCore
import Presentation
import os

private let logger = Logger(subsystem: "com.jutsustudio", category: "Agents")

// quote, create_video, jobs and job_action: the commands that make videos. Every job is built from a fresh Create
// form (`AgentVideoOrder`), never the Create screen's draft, and every paid submit passes the engine's spending
// guard (`JobEngine.clearAgentSpend`); nothing here decides what may be spent.
extension AgentService {
    // MARK: Uploads

    /// Checks an upload's request before a byte of it is read: only `create_video` takes files, a request ID taken by
    /// other parameters is refused (`request_conflict`), and one already queued with these needs no file again
    /// (`request_known`).
    func admit(_ upload: UploadCommand) throws(AgentError) {
        guard let request = upload.request, ["create_video", "create_image", "frames"].contains(request.command)
        else {
            throw AgentError(
                .fileRefused, message: "Only create_video, create_image and frames take files.", retryable: false,
                next: "Send files with create_video, create_image or frames.")
        }
        // Free and never logged as a request: its files are removed once its frames are written.
        if request.command == "frames" { return }
        let state: AgentRequestGate<AgentCreated, AgentError>.State
        do {
            state = try requests.state(of: request.requestID, fingerprint: request.fingerprint)
        } catch {
            logger.error("Can't read the agent requests: \(error.localizedDescription, privacy: .private)")
            throw Self.requestsUnreadable
        }
        switch state {
        case .new, .running: return
        case .conflict: throw .requestConflict
        case .known:
            throw AgentError(
                .requestKnown, message: "This request was already queued; its files aren't needed again.",
                retryable: false, next: "Send \(request.command) without uploading to get its job.")
        }
    }

    static let requestsUnreadable = AgentError(
        .failed, message: "Jutsu Studio can't read its record of agent requests, so nothing is queued.",
        retryable: true, next: "Ask the person to check the app's data folder, then send the request again.")

    /// What the request gate answers a paid command with instead of running it.
    static func refusals(_ command: String, made: String) -> AgentRequestGate<AgentCreated, AgentError>.Refusals {
        AgentRequestGate.Refusals(
            conflict: .requestConflict, unreadable: requestsUnreadable,
            neverQueued: AgentError(
                .failed, message: "The request was recorded but \(made).", retryable: true,
                next: "Send the same \(command) again."))
    }

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
        let price = money.map { AgentAmount($0.amount, Self.unit(of: $0.unit)) }
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
            minImages: limits.lowerBound, maxImages: limits.upperBound)
    }

    // MARK: create_video

    func createVideo(_ fields: CreateVideoCommand, client: String?) async throws(AgentError) -> AgentCreated {
        let started = ContinuousClock.now
        let files = [fields.video.source?.path].compactMap(\.self) + fields.video.images
        defer { Task { await sweepInbox() } }
        let created = try await requests.run(
            fields.requestID, fingerprint: fields.fingerprint,
            refusals: Self.refusals("create_video", made: "its job was never queued"), discard: { discard(files) },
            known: { ids throws(AgentError) in
                let jobs = try await knownJobs(ids)
                return jobs.isEmpty
                    ? nil : AgentCreated(requestID: fields.requestID, known: true, jobs: jobs.map(Self.agentJob))
            },
            queue: { [weak self] () throws(AgentError) in
                guard let self else { throw .agentsOff }
                return try await self.queue(fields, client: client)
            })
        guard fields.waitSeconds > 0 else { return created }
        let seconds = AgentProtocol.waitSeconds(fields.waitSeconds, after: ContinuousClock.now - started)
        return await waitForPrice(of: created, seconds: seconds)
    }

    /// The answer once every job's price is known or it is held (`AgentJobStatus.isPriced`), or when the wait ran
    /// out. A job gone from the live jobs has finished; waiting stops nothing.
    private func waitForPrice(of created: AgentCreated, seconds: Int) async -> AgentCreated {
        let ids = created.jobs.map(\.id)
        let live = environment.liveJobs
        let timedOut = await agentWait(seconds: seconds) {
            ids.allSatisfy { id in live.job(id).map(AgentJobStatus.isPriced) ?? true }
        }
        var answer = created
        var jobs: [AgentJob] = []
        for job in created.jobs { jobs.append(await self.job(job.id).map(Self.agentJob) ?? job) }
        answer.jobs = jobs
        answer.timedOut = timedOut
        return answer
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
        try recordRequest(fields.requestID, fingerprint: fields.fingerprint, jobIDs: [jobID])
        let origin = AgentOrigin(
            client: client, requestID: fields.requestID,
            maxCost: AgentMoney(fields.maxCost.amount, Self.unit(of: fields.maxCost.unit)))
        do {
            let job = try await environment.engine.enqueue(spec, id: jobID, agent: origin)
            return AgentCreated(
                requestID: fields.requestID, known: false, jobs: [Self.agentJob(job)],
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
        guard unit(for: kind) != maxCost.unit else { return }
        throw .badRequest("max_cost is in \(unit(for: kind) == .usdCents ? "usd" : "credits") on this connection")
    }

    /// Records the request with the IDs of what it makes, before anything is queued or sent.
    func recordRequest(_ requestID: String, fingerprint: String, jobIDs: [UUID]) throws(AgentError) {
        do {
            try requests.record(requestID, fingerprint: fingerprint, ids: jobIDs, at: .now)
        } catch {
            throw AgentError(
                .failed, message: "Jutsu Studio can't record the request, so nothing is queued or sent.",
                retryable: true, next: "Ask the person to check the Mac has room, then send the request again.")
        }
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

    /// A path the helper's upload answered with: a file in the app's own inbox, and nowhere else.
    func inboxFile(_ path: String) throws(AgentError) -> URL {
        guard let inbox = server?.inbox, inbox.uploadFolder(of: path) != nil,
            FileManager.default.fileExists(atPath: path)
        else {
            throw AgentError(
                .fileRefused, message: "\(path) isn't a file the helper sent to Jutsu Studio.", retryable: false,
                next: "Pass the file's path on this Mac; the jutsu helper sends it to the app.")
        }
        return URL(filePath: path)
    }

    func discard(_ files: [String]) {
        server?.inbox.remove(files)
    }

    /// Removes the inbox's files that no job still reads, a day after they came: refused requests, and jobs gone
    /// from the store or finished more than a week ago. Skipped when the store can't be read.
    func sweepInbox() async {
        guard let inbox = server?.inbox else { return }
        let now = Date.now
        do {
            let jobs = try await environment.store.jobsUnfinishedOrFinished(since: now.addingTimeInterval(-7 * 86_400))
            let kept: [String] =
                jobs.flatMap { job -> [String] in
                    let files: [URL?] = [job.spec.source?.fileURL] + job.spec.references.map(\.fileURL)
                    return files.compactMap { $0?.path(percentEncoded: false) }
                }
                + ((try? environment.agentImages.records()) ?? []).filter { !$0.isOver }
                .flatMap { $0.inputs.map { $0.fileURL.path(percentEncoded: false) } }
            let removed = inbox.sweep(keeping: Set(kept), before: now.addingTimeInterval(-86_400))
            if removed > 0 { logger.info("Removed \(removed, privacy: .private) old agent upload(s)") }
        } catch {
            logger.error("Can't check the agent inbox: \(String(describing: error), privacy: .private)")
        }
    }

    // MARK: jobs

    func jobs(_ fields: JobsCommand) async throws(AgentError) -> AgentJobs {
        let started = ContinuousClock.now
        var ids = fields.ids
        var next: String?
        let operations = operations
        if ids.isEmpty {
            let videos = environment.liveJobs.all.filter { $0.agent != nil }.map { ($0.createdAt, $0.id) }
            let images = ((try? environment.agentImages.records()) ?? []).map { ($0.createdAt, $0.id) }
            let exports = operations.all.map { ($0.createdAt, $0.id) }
            (ids, next) = AgentJobPage.page(videos + images + exports, limit: fields.limit ?? 10, after: fields.cursor)
        }
        let live = environment.liveJobs
        let images = environment.agentImages
        // Cut to what is left of the answer deadline, as create_video's wait is, so the answer keeps its margin
        // before the deadline whatever reading the page took.
        let seconds = AgentProtocol.waitSeconds(fields.waitSeconds, after: ContinuousClock.now - started)
        let timedOut =
            fields.waitSeconds > 0
            ? await agentWait(seconds: seconds) {
                ids.allSatisfy { id in
                    if let job = live.job(id) { return AgentJobStatus.isSettled(job.state) }
                    if let operation = operations.operation(id) { return operation.state != .running }
                    guard let record = images.record(id) else { return true }
                    return (record.isOver && !images.files(of: id).isEmpty) || record.state == .held
                        || record.state == .failed || record.state == .canceled
                }
            } : false
        var jobs: [AgentJob] = []
        for id in ids {
            if let job = await job(id) {
                jobs.append(Self.agentJob(job))
            } else if let image = await imageJob(id) {
                jobs.append(image)
            } else if let operation = operations.operation(id) {
                jobs.append(operation.job)
            } else {
                jobs.append(.unknown(id))
            }
        }
        return AgentJobs(jobs: jobs, timedOut: timedOut, nextCursor: next)
    }

    // MARK: job_action

    func act(_ fields: JobActionCommand) async throws(AgentError) -> AgentActed {
        let engine = environment.engine
        guard let id = fields.job else {
            switch fields.action {
            // Agents' jobs only: an agent never pauses the person's jobs or lifts their own Pause all.
            case .pauseQueue: await engine.pauseAll(agentsOnly: true)
            case .resumeQueue: await engine.resumeAll(agentsOnly: true)
            case .cancel, .retry, .runNext: throw .badRequest("\(fields.action.rawValue) needs job")
            }
            return AgentActed(action: fields.action)
        }
        guard let job = await job(id) else {
            if environment.agentImages.record(id) != nil { return try await actOnImage(fields.action, id) }
            throw AgentError(.notFound, message: "There's no job \(id.uuidString).", retryable: false)
        }
        let refusal: String? =
            switch fields.action {
            case .cancel: AgentJobRules.cancelRefusal(job)
            case .retry:
                AgentJobRules.retryRefusal(job) {
                    FileManager.default.fileExists(atPath: $0.path(percentEncoded: false))
                }
            case .runNext: AgentJobRules.runNextRefusal(job)
            case .pauseQueue, .resumeQueue: nil
            }
        if let refusal {
            throw AgentError(
                .needsPerson, message: refusal, retryable: false, next: "Ask the person to decide in the Queue.")
        }
        do {
            switch fields.action {
            case .cancel: try await engine.cancel(id)
            case .retry: try await engine.retry(id)
            case .runNext: try await engine.runNext(id)
            case .pauseQueue, .resumeQueue: break
            }
        } catch {
            throw AgentError(
                .notApplicable, message: error.localizedDescription,
                retryable: Self.isSubmitInProgress(error),
                next: "Call jobs to see the job's state now.")
        }
        return AgentActed(action: fields.action, job: await self.job(id).map(Self.agentJob))
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

    static func unit(for kind: ProviderKind) -> AgentBudgetUnit {
        AgentMoney.unit(for: kind) == .usdCents ? .usdCents : .credits
    }

    static func unit(of unit: AgentMoney.Unit) -> AgentBudgetUnit {
        unit == .usdCents ? .usdCents : .credits
    }

    static func unit(of unit: AgentBudgetUnit) -> AgentMoney.Unit {
        unit == .usdCents ? .usdCents : .credits
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
        case JobEngineError.overCap:
            AgentError(
                .overCap, message: "The job would take today's spending over the person's daily cap.",
                retryable: false, next: "Ask the person to raise the cap in Settings or queue it themselves.")
        case JobEngineError.notConnected:
            notConnected
        default:
            AgentError(.failed, message: error.localizedDescription, retryable: true)
        }
    }

    static func agentJob(_ job: Job) -> AgentJob {
        let status = AgentJobStatus(job)
        return AgentJob(
            id: job.id, state: status.state, pauseReason: status.pauseReason, hold: status.hold,
            needsPerson: status.needsPerson, progress: status.progress,
            price: status.price.map { AgentAmount($0.amount, unit(of: $0.unit)) }, isPriceExact: status.isPriceExact,
            charged: status.charged, error: status.error, result: status.result, requestID: job.agent?.requestID,
            client: job.agent?.client, mode: AgentVideoOrder.name(of: job.spec.mode), model: job.spec.model.rawValue,
            createdAt: job.createdAt, finishedAt: job.finishedAt)
    }
}
