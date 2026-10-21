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
        guard let request = upload.request, ["create_video", "create_image"].contains(request.command) else {
            throw AgentError(
                .fileRefused, message: "Only create_video and create_image take files.", retryable: false,
                next: "Send files with create_video or create_image.")
        }
        if let running = creating[request.requestID] ?? creatingImages[request.requestID] {
            guard running.fingerprint == request.fingerprint else { throw .requestConflict }
            return
        }
        switch try lookup(request.requestID, fingerprint: request.fingerprint) {
        case .new: return
        case .conflict: throw .requestConflict
        case .known:
            throw AgentError(
                .requestKnown, message: "This request was already queued; its files aren't needed again.",
                retryable: false, next: "Send \(request.command) without uploading to get its job.")
        }
    }

    func lookup(_ requestID: String, fingerprint: String) throws(AgentError) -> AgentRequestLog.Lookup {
        do {
            return try environment.agentRequests.lookup(requestID, fingerprint: fingerprint)
        } catch {
            logger.error("Can't read the agent requests: \(error.localizedDescription, privacy: .private)")
            throw AgentError(
                .failed, message: "Jutsu Studio can't read its record of agent requests, so nothing is queued.",
                retryable: true, next: "Ask the person to check the app's data folder, then send the request again.")
        }
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
        let order = Self.order(video, source: source, images: AgentVideoOrder.quoteImages(video.referenceCount))
        let spec = try await spec(for: order)
        let cost = await environment.estimate(spec)
        let kind = environment.connection.state.kind
        let money = cost.flatMap(AgentMoney.init)
        let price = money.map { AgentAmount($0.amount, Self.unit(of: $0.unit)) }
        var remaining: Int?
        if let kind {
            let taken = try await agentSpendToday(for: kind)
            remaining = taken.remaining(of: preferences.dailyBudget(for: kind))
        }
        let isExact = cost.map { !$0.isEstimate && !$0.isUnknownPrice } ?? false
        return AgentQuote(
            price: price, isExact: isExact, mode: video.mode, model: spec.model.rawValue,
            resolution: spec.resolution.rawValue, duration: spec.duration, remainingToday: remaining,
            blocker: Self.quoteBlocker(price: money, remaining: remaining))
    }

    /// What `create_video` would pause the job for, as far as a quote can tell before upload.
    private static func quoteBlocker(price: AgentMoney?, remaining: Int?) -> String? {
        guard let price else {
            return "The price isn't known before upload; unless Higgsfield quotes it then, the job waits for the "
                + "person."
        }
        if let remaining, price.amount > remaining {
            return "It costs more than is left of today's agent budget (\(remaining)); the job would wait for the "
                + "person."
        }
        return nil
    }

    // MARK: create_video

    func createVideo(_ fields: CreateVideoCommand, client: String?) async throws(AgentError) -> AgentCreated {
        let files = [fields.video.source?.path].compactMap(\.self) + fields.video.images
        if let running = creating[fields.requestID] {
            guard running.fingerprint == fields.fingerprint else {
                discard(files)
                throw .requestConflict
            }
            return try await running.task.value.get()
        }
        switch try lookup(fields.requestID, fingerprint: fields.fingerprint) {
        case .conflict:
            discard(files)
            throw .requestConflict
        case .known(let ids):
            discard(files)
            let jobs = try await knownJobs(ids)
            guard jobs.isEmpty else {
                return AgentCreated(requestID: fields.requestID, known: true, jobs: jobs.map(Self.agentJob))
            }
            // Recorded, but the app quit before the job was saved: nothing was queued or paid, so it is forgotten and
            // sent again as new, with its files.
            try? environment.agentRequests.remove(fields.requestID)
            throw AgentError(
                .failed, message: "The request was recorded but its job was never queued.", retryable: true,
                next: "Send the same create_video again.")
        case .new:
            break
        }
        return try await run(fields, client: client)
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

    private func run(_ fields: CreateVideoCommand, client: String?) async throws(AgentError) -> AgentCreated {
        let task = Task { [weak self] () -> Result<AgentCreated, AgentError> in
            guard let self else { return .failure(.agentsOff) }
            do throws(AgentError) {
                return .success(try await self.queue(fields, client: client))
            } catch {
                return .failure(error)
            }
        }
        creating[fields.requestID] = (fields.fingerprint, task)
        defer { creating[fields.requestID] = nil }
        let result = await task.value
        Task { await sweepInbox() }
        return try result.get()
    }

    /// Builds the job as Create would, records the request with the job's ID, then queues it. A request that
    /// can't be queued is forgotten, and its files removed, so the agent can fix it and send it again.
    private func queue(_ fields: CreateVideoCommand, client: String?) async throws(AgentError) -> AgentCreated {
        let video = fields.video
        let files = [video.source?.path].compactMap(\.self) + video.images
        do throws(AgentError) {
            guard let kind = environment.connection.state.kind else { throw Self.notConnected }
            try Self.checkUnit(of: fields.maxCost, on: kind)
            var source: AgentVideoOrder.Source?
            if let given = video.source { source = try await sourceClip(given) }
            var images: [LocalImage] = []
            for path in video.images { images.append(LocalImage(fileURL: try inboxFile(path))) }
            if let style = video.style,
                let refusal = PresetCatalog.agentStyleRefusal(style, in: environment.layout.presetCacheFolder)
            {
                throw .invalidRequest(refusal)
            }
            let spec = try await spec(for: Self.order(video, source: source, images: images))
            let jobID = UUID()
            try recordRequest(fields.requestID, fingerprint: fields.fingerprint, jobIDs: [jobID])
            let origin = AgentOrigin(
                client: client, requestID: fields.requestID,
                maxCost: AgentMoney(fields.maxCost.amount, Self.unit(of: fields.maxCost.unit)))
            do {
                let job = try await environment.engine.enqueue(spec, id: jobID, agent: origin)
                return AgentCreated(requestID: fields.requestID, known: false, jobs: [Self.agentJob(job)])
            } catch {
                try? environment.agentRequests.remove(fields.requestID)
                throw Self.agentError(enqueueing: error)
            }
        } catch {
            discard(files)
            throw error
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
            try environment.agentRequests.add(
                AgentRequestLog.Record(requestID: requestID, fingerprint: fingerprint, jobIDs: jobIDs, createdAt: .now))
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
            aspectRatio: video.aspectRatio, audio: video.audio, variants: video.variants)
    }

    /// The one job `order` makes, built and checked as Create does, on the connection as it is now.
    private func spec(for order: AgentVideoOrder) async throws(AgentError) -> JobSpec {
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
        case .success(let spec): return spec
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
                .compactMap { $0.input?.fileURL.path(percentEncoded: false) }
            let removed = inbox.sweep(keeping: Set(kept), before: now.addingTimeInterval(-86_400))
            if removed > 0 { logger.info("Removed \(removed, privacy: .private) old agent upload(s)") }
        } catch {
            logger.error("Can't check the agent inbox: \(String(describing: error), privacy: .private)")
        }
    }

    // MARK: jobs

    func jobs(_ fields: JobsCommand) async throws(AgentError) -> AgentJobs {
        var ids = fields.ids
        var next: String?
        if ids.isEmpty {
            let videos = environment.liveJobs.all.filter { $0.agent != nil }.map { ($0.createdAt, $0.id) }
            let images = ((try? environment.agentImages.records()) ?? []).map { ($0.createdAt, $0.id) }
            (ids, next) = AgentJobPage.page(videos + images, limit: fields.limit ?? 10, after: fields.cursor)
        }
        for id in ids {
            guard await job(id) == nil, environment.agentImages.record(id) == nil else { continue }
            throw AgentError(
                .notFound, message: "There's no job \(id.uuidString).", retryable: false,
                next: "Call jobs without ids to list the latest agent jobs.")
        }
        let live = environment.liveJobs
        let images = environment.agentImages
        let timedOut =
            fields.waitSeconds > 0
            ? await agentWait(seconds: fields.waitSeconds) {
                ids.allSatisfy { id in
                    if let job = live.job(id) { return AgentJobStatus.isSettled(job.state) }
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
            }
        }
        return AgentJobs(jobs: jobs, timedOut: timedOut, nextCursor: next)
    }

    // MARK: job_action

    func act(_ fields: JobActionCommand) async throws(AgentError) -> AgentActed {
        let engine = environment.engine
        guard let id = fields.job else {
            switch fields.action {
            case .pauseQueue: await engine.pauseAll()
            case .resumeQueue: await engine.resumeAll()
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
