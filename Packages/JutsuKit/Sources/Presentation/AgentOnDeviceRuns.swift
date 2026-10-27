import Foundation
import JutsuAgent
import JutsuCore

/// An agent's `enhance` that runs on this Mac (`EnhanceCommand.isOnDevice`): refused by the sheet's own rules, run once
/// for its request ID through the request gate, and followed with `jobs` as kind on_device. Free, so no `max_cost`,
/// agent budget or hold applies. The runs are `OnDeviceRuns`', the person's too; this keeps which ones agents started,
/// in memory: a relaunch forgets them, as it forgets exports.
@MainActor
public final class AgentOnDeviceRuns {
    /// What the app read of the item an agent named.
    public struct Target: Sendable, Hashable {
        /// The item's current version, which the run is made from.
        public var source: MaterialReference
        public var file: URL
        public var media: AgentOnDeviceMedia
        /// Where the result goes, and where it is written until it is done (`OnDeviceRuns.Request`).
        public var destination: URL
        public var scratch: URL

        public init(source: MaterialReference, file: URL, media: AgentOnDeviceMedia, destination: URL, scratch: URL) {
            self.source = source
            self.file = file
            self.media = media
            self.destination = destination
            self.scratch = scratch
        }
    }

    private struct Record {
        var requestID: String
        var client: String?
        var estimate: TimeInterval?
    }

    public typealias Gate = AgentRequestGate<AgentCreated, AgentError>

    private let runs: OnDeviceRuns
    private let priceUnit: @MainActor () -> AgentBudgetUnit
    private var records: [UUID: Record] = [:]

    /// - Parameter priceUnit: the unit the free price is given in: the connection's, else cents.
    public init(runs: OnDeviceRuns, priceUnit: @escaping @MainActor () -> AgentBudgetUnit = { .usdCents }) {
        self.runs = runs
        self.priceUnit = priceUnit
    }

    /// Starts the run once for its request ID: the same request again answers with the run it started, and is never
    /// run twice. `record` keeps the request with the run's ID before it starts; `target` reads the item.
    public func enhance(
        _ fields: EnhanceCommand, client: String?, gate: Gate, refusals: Gate.Refusals,
        record: @escaping @MainActor ([UUID]) throws(AgentError) -> Void,
        target: @escaping @MainActor () async throws(AgentError) -> Target
    ) async throws(AgentError) -> AgentCreated {
        try await gate.run(
            fields.requestID, fingerprint: fields.fingerprint, refusals: refusals, discard: {},
            known: { [weak self] ids in
                AgentCreated(
                    requestID: fields.requestID, known: true, jobs: ids.map { self?.job($0) ?? Self.forgotten($0) })
            },
            queue: { [weak self] () throws(AgentError) in
                guard let self else { throw AgentError.agentsOff }
                return try self.start(fields, client: client, on: try await target(), record: record)
            })
    }

    private func start(
        _ fields: EnhanceCommand, client: String?, on target: Target,
        record: @MainActor ([UUID]) throws(AgentError) -> Void
    ) throws(AgentError) -> AgentCreated {
        let action = try Self.action(fields, on: target.media)
        if let refusal = Self.refusal(action, on: target, runs: runs) { throw refusal }
        let id = UUID()
        try record([id])
        let request = OnDeviceRuns.Request(
            source: target.source, file: target.file, action: action, destination: target.destination,
            scratch: target.scratch)
        guard runs.start(request, id: id) else {
            throw Self.refusal(action, on: target, runs: runs)
                ?? AgentError(.failed, message: "The run didn't start.", retryable: true)
        }
        records[id] = Record(requestID: fields.requestID, client: client, estimate: Self.estimate(action, target.media))
        return AgentCreated(requestID: fields.requestID, known: false, jobs: [job(id) ?? Self.forgotten(id)])
    }

    // MARK: Following

    /// The runs agents started, for `jobs` without IDs.
    public var started: [(createdAt: Date, id: UUID)] {
        records.keys.compactMap { id in runs.run(id).map { ($0.run.createdAt, id) } }
    }

    /// Whether `id` is an on-device run this Mac still knows, waiting, running or over.
    public func knows(_ id: UUID) -> Bool { runs.run(id) != nil }

    /// Over, or not known: what `jobs`' wait waits for.
    public func isSettled(_ id: UUID) -> Bool { runs.run(id)?.finished != nil || runs.run(id) == nil }

    /// The run as `jobs` lists it: an agent's or the person's, while this Mac knows it.
    public func job(_ id: UUID) -> AgentJob? {
        guard let (run, finished) = runs.run(id) else { return nil }
        let record = records[id]
        var job = AgentJob(
            id: id, state: "processing", price: AgentAmount(0, priceUnit()), isPriceExact: true, kind: Self.kind,
            requestID: record?.requestID, client: record?.client, mode: Self.mode(of: run.request.action),
            operation: Self.operation(of: run.request.action), item: run.request.source.materialID,
            estimatedSeconds: record?.estimate, createdAt: run.createdAt, finishedAt: finished?.finishedAt)
        switch (finished?.outcome, run.state) {
        case (.done(let file)?, _):
            job.state = "done"
            job.progress = 1
            job.result = file.path(percentEncoded: false)
            job.next =
                "The result is now the item's current version: library_get with its ID shows it and the version "
                + "it was made from; frames checks it."
        case (.failed(let message)?, _):
            job.state = "failed"
            job.error = message
        case (.canceled?, _):
            job.state = "canceled"
        case (nil, .waiting):
            job.state = "queued"
            job.next = "Runs on this Mac go one at a time; it starts when the one before it is done."
        case (nil, .downloadingModel(let fraction)):
            job.state = "downloading"
            job.progress = fraction
            job.next = "macOS is downloading the model once; the frames follow."
        case (nil, .working(let fraction)):
            job.progress = fraction
        }
        return job
    }

    /// Cancels a run an agent started and answers with it as it is now; `nil` when `id` isn't an on-device run.
    public func cancel(_ id: UUID) async throws(AgentError) -> AgentJob? {
        guard let (_, finished) = runs.run(id) else { return nil }
        guard records[id] != nil else {
            throw AgentError(
                .needsPerson, message: "The person started this run on this Mac; only they can cancel it.",
                retryable: false, next: "Ask the person, or leave it be.")
        }
        if finished == nil {
            runs.cancel(id)
            await runs.over(id)
        }
        return job(id)
    }

    /// Why `show` can't open the sheet that starts `action`: this Mac has no engine for it.
    public func sheetRefusal(_ action: OnDeviceAction) -> AgentError? {
        runs.supports(action.engine) ? nil : Self.unavailable(action)
    }

    /// What `capabilities` says of this Mac's engines.
    public func capabilities() -> AgentCapabilities.OnDevice {
        let video = OnDeviceUpscale.videoLimit
        let image = OnDeviceUpscale.scalerLimit
        return AgentCapabilities.OnDevice(
            smoothMotion: engine(.frameRateConversion),
            upscaleVideo: engine(.videoSuperResolution, limit: video),
            upscaleImage: engine(.imageSuperResolution, limit: image))
    }

    private func engine(_ engine: OnDeviceEngine, limit: PixelSize? = nil) -> AgentOnDeviceEngine {
        let model: String
        if !engine.downloadsModel {
            model = "none"
        } else if runs.needsConsent(engine) {
            model = "needs_consent"
        } else if runs.runs.contains(where: { $0.request.action.engine == engine && $0.state.isDownloadingModel }) {
            model = "downloading"
        } else {
            model = runs.supports(engine) && runs.modelIsReady(engine) ? "ready" : "agreed"
        }
        return AgentOnDeviceEngine(
            available: runs.supports(engine), maxLongSide: limit?.width, maxShortSide: limit?.height, model: model)
    }
}
