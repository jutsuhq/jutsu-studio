import Foundation
import JutsuAgent
import JutsuCore

/// An agent's `subtitles`: make starts a `SubtitleRuns` run by the sheet's rules, once for its request ID through the
/// request gate, followed with `jobs` as kind on_device like `enhance` on this Mac; get and export read the current
/// version's cues. Free, so no `max_cost`, budget or hold applies. Which runs agents started is kept in memory: a
/// relaunch forgets them.
@MainActor
public final class AgentSubtitleRuns {
    /// The video an agent named: its current version, its file and the file's bookmark, and the subtitles that version
    /// has.
    public struct Target: Sendable, Hashable {
        public var source: MaterialReference
        public var file: URL
        public var bookmark: Data?
        public var subtitles: Subtitles?

        public init(source: MaterialReference, file: URL, bookmark: Data? = nil, subtitles: Subtitles?) {
            self.source = source
            self.file = file
            self.bookmark = bookmark
            self.subtitles = subtitles
        }
    }

    private struct Record {
        var requestID: String
        var client: String?
    }

    public typealias Gate = AgentRequestGate<AgentCreated, AgentError>

    /// What `jobs` calls a subtitles run's operation.
    public static let operation = "subtitles"

    private let runs: SubtitleRuns
    private let models: SpeechModels?
    private let priceUnit: @MainActor () -> AgentBudgetUnit
    private var records: [UUID: Record] = [:]

    /// - Parameters:
    ///   - models: Parakeet Ultra's download, for `capabilities`; `nil` where it can't be downloaded.
    ///   - priceUnit: the unit the free price is given in: the connection's, else cents.
    public init(
        runs: SubtitleRuns, models: SpeechModels?, priceUnit: @escaping @MainActor () -> AgentBudgetUnit = { .usdCents }
    ) {
        self.runs = runs
        self.models = models
        self.priceUnit = priceUnit
    }

    /// Starts the run once for its request ID: the same request again answers with the run it started. `record` keeps
    /// the request with the run's ID before it starts; `target` reads the item.
    public func make(
        _ fields: SubtitlesCommand, client: String?, gate: Gate, refusals: Gate.Refusals,
        record: @escaping @MainActor ([UUID]) throws(AgentError) -> Void,
        target: @escaping @MainActor () async throws(AgentError) -> Target
    ) async throws(AgentError) -> AgentCreated {
        guard let requestID = fields.requestID, let fingerprint = fields.fingerprint else {
            throw .badRequest("make needs request_id")
        }
        return try await gate.run(
            requestID, fingerprint: fingerprint, refusals: refusals, discard: {},
            known: { [weak self] ids in
                AgentCreated(
                    requestID: requestID, known: true,
                    jobs: ids.map { self?.job($0) ?? AgentOnDeviceRuns.forgotten($0) })
            },
            queue: { [weak self] () throws(AgentError) in
                guard let self else { throw AgentError.agentsOff }
                if self.runs.availability == nil { await self.runs.loadAvailability() }
                return try self.start(
                    fields, requestID: requestID, client: client, on: try await target(), record: record)
            })
    }

    private func start(
        _ fields: SubtitlesCommand, requestID: String, client: String?, on target: Target,
        record: @MainActor ([UUID]) throws(AgentError) -> Void
    ) throws(AgentError) -> AgentCreated {
        let engine = fields.engine.map(Self.engine) ?? runs.defaultEngine
        let language = try language(fields.language, engine: engine)
        if let refusal = refusal(language: language, engine: engine, item: target.source.materialID) { throw refusal }
        let id = UUID()
        try record([id])
        let request = SubtitleRuns.Request(
            source: target.source, file: target.file, bookmark: target.bookmark, language: language, engine: engine)
        // An agent's language isn't the person's: the sheet keeps starting on theirs.
        guard runs.start(request, id: id, remembersLanguage: false) else {
            throw refusal(language: language, engine: engine, item: target.source.materialID)
                ?? AgentError(.failed, message: "The run didn't start.", retryable: true)
        }
        records[id] = Record(requestID: requestID, client: client)
        return AgentCreated(requestID: requestID, known: false, jobs: [job(id) ?? AgentOnDeviceRuns.forgotten(id)])
    }

    /// The language as the sheet offers it: the one asked for, matched exactly and then by its code ("en" takes
    /// "en-US"), else the person's; refused when no model here takes it.
    private func language(_ asked: String?, engine: SubtitleEngine) throws(AgentError) -> String {
        let offered = runs.languages
        let asked = asked ?? runs.preferredLanguage ?? ""
        let code = SpeechSelection.languageCode(asked)
        let match =
            offered.first { $0.caseInsensitiveCompare(asked) == .orderedSame }
            ?? offered.first { runs.model(for: $0, engine: engine) != nil && SpeechSelection.languageCode($0) == code }
            ?? offered.first { SpeechSelection.languageCode($0) == code }
        guard let match else {
            throw AgentError(
                .invalidRequest, message: "No speech model on this Mac takes \(asked.prefix(35)).",
                retryable: false, next: "Pick one of capabilities' onDevice.subtitles languages.")
        }
        return match
    }

    /// Why the sheet wouldn't start the run now, in the order an agent can act on: the engine and language, a run
    /// already on the item, and last what only the person can do.
    private func refusal(language: String, engine: SubtitleEngine, item: UUID) -> AgentError? {
        guard runs.model(for: language, engine: engine) != nil else {
            return AgentError(
                .invalidRequest, message: "\(engine.rawValue) doesn't take \(language).", retryable: false,
                next: "Use engine auto, or one whose languages in capabilities' onDevice.subtitles list it.")
        }
        if let run = runs.run(for: item) {
            return AgentError(
                .busy,
                message: "Item \(item.uuidString) already has subtitles being made, \(run.id.uuidString).",
                retryable: true,
                next: "Follow it with jobs (ids [\(run.id.uuidString)]) and send make again once it is over, or "
                    + "cancel it with job_action if an agent started it.")
        }
        let show = "Call show with item \(item.uuidString) and sheet subtitles, and tell the person; "
        if runs.needsDownload(language, engine: engine) {
            return AgentError(
                .needsPerson,
                message: "Nothing was started: \(language) needs Parakeet Ultra, which isn't downloaded, and only the "
                    + "person downloads it.",
                retryable: true,
                next: show + "once they downloaded it in Settings › Subtitles, send make again with a new request_id.")
        }
        if runs.needsConsent(language, engine: engine) {
            return AgentError(
                .needsPerson,
                message: "Nothing was started: \(language) needs macOS to download its speech model from Apple once, "
                    + "and only the person can agree to that.",
                retryable: true,
                next: show + "once they agreed (and may make the subtitles there), send make again with a new "
                    + "request_id.")
        }
        return nil
    }

    private static func engine(_ engine: AgentSubtitleEngine) -> SubtitleEngine {
        switch engine {
        case .auto: .auto
        case .builtIn: .builtIn
        case .parakeet: .parakeet
        }
    }

    // MARK: Following

    /// The runs agents started, for `jobs` without IDs.
    public var started: [(createdAt: Date, id: UUID)] {
        records.keys.compactMap { id in runs.run(id).map { ($0.run.createdAt, id) } }
    }

    /// Whether `id` is a subtitles run this Mac still knows, waiting, running or over.
    public func knows(_ id: UUID) -> Bool { runs.run(id) != nil }

    /// Over, or not known: what `jobs`' wait waits for.
    public func isSettled(_ id: UUID) -> Bool { runs.run(id)?.finished != nil || runs.run(id) == nil }

    /// The run as `jobs` lists it: an agent's or the person's, while this Mac knows it.
    public func job(_ id: UUID) -> AgentJob? {
        guard let (run, finished) = runs.run(id) else { return nil }
        let record = records[id]
        var job = AgentJob(
            id: id, state: "processing", price: AgentAmount(0, priceUnit()), isPriceExact: true,
            kind: AgentOnDeviceRuns.kind, requestID: record?.requestID, client: record?.client,
            model: run.model.rawValue, operation: Self.operation, item: run.request.source.materialID,
            createdAt: run.createdAt, finishedAt: finished?.finishedAt)
        switch (finished?.outcome, run.state) {
        case (.done?, _):
            job.state = "done"
            job.progress = 1
            job.next = "subtitles get with the item reads the cues; export writes them as SRT or VTT."
        case (.failed(let message)?, _):
            job.state = "failed"
            job.error = message
        case (.canceled?, _):
            job.state = "canceled"
        case (nil, .waiting):
            job.state = "queued"
            job.next = "Subtitles runs go one at a time; it starts when the one before it is done."
        case (nil, .downloadingModel(let fraction)):
            job.state = "downloading"
            job.progress = fraction
            job.next = "macOS is downloading the language's speech model once; the words follow."
        case (nil, .working(let fraction)):
            job.progress = fraction
        }
        return job
    }

    /// Cancels a run an agent started and answers with it as it is now; `nil` when `id` isn't a subtitles run.
    public func cancel(_ id: UUID) async throws(AgentError) -> AgentJob? {
        guard let (_, finished) = runs.run(id) else { return nil }
        guard records[id] != nil else {
            throw AgentError(
                .needsPerson, message: "The person started these subtitles; only they can cancel them.",
                retryable: false, next: "Ask the person, or leave it be.")
        }
        if finished == nil {
            runs.cancel(id)
            await runs.over(id)
        }
        return job(id)
    }

    // MARK: Reading

    /// get and export: the version's subtitles, with the file's text for `format`.
    public static func answer(
        _ subtitles: Subtitles?, of source: MaterialReference, format: AgentSubtitleFormat? = nil, file: URL? = nil
    ) throws(AgentError) -> AgentSubtitles {
        guard let subtitles else {
            throw AgentError(
                .notFound, message: "The current version of \(source.materialID.uuidString) has no subtitles.",
                retryable: false, next: "Make them with subtitles make; a new version starts without any.")
        }
        return AgentSubtitles(
            item: source.materialID, versionID: source.versionID, language: subtitles.language,
            model: subtitles.transcript.model.rawValue,
            cues: subtitles.cues.map { AgentCue(start: $0.start, end: $0.end, text: $0.lines.joined(separator: "\n")) },
            text: file == nil ? format.map { text(subtitles, $0) } : nil, file: file?.path(percentEncoded: false))
    }

    /// The file's text, as Export for Editing writes it.
    public static func text(_ subtitles: Subtitles, _ format: AgentSubtitleFormat) -> String {
        (format == .srt ? SubtitleFormat.srt : .vtt).text(of: subtitles.cues)
    }

    /// The export's file name: the video's own name with the language, never one `existing` has.
    public static func fileName(
        for video: URL, language: String, format: AgentSubtitleFormat, existing: Set<String>
    ) -> String {
        let name = "\(video.deletingPathExtension().lastPathComponent).\(language).\(format.rawValue)"
        return OutputNamePattern.available(name, isTaken: { existing.contains($0.lowercased()) })
    }

    // MARK: Capabilities

    /// What `capabilities` says of subtitles on this Mac; reads what `loadAvailability` last read.
    public func capabilities() -> AgentSubtitleCapabilities {
        let availability = runs.availability ?? .none
        let builtIn = SpeechSelection.languages(
            in: SpeechAvailability(
                languages: availability.languages.filter { $0.key.isBuiltIn }))
        let parakeet = availability.languages[.parakeetUltra] ?? []
        let needsConsent = builtIn.filter { runs.needsConsent($0, engine: .builtIn) }
        let parakeetModel: String =
            switch models?.state {
            case .ready?: "ready"
            case .downloading?: "downloading"
            default: "not_downloaded"
            }
        return AgentSubtitleCapabilities(
            defaultEngine: runs.defaultEngine.rawValue,
            engines: [
                .init(
                    engine: AgentSubtitleEngine.builtIn.rawValue, available: !builtIn.isEmpty, languages: builtIn,
                    model: needsConsent.isEmpty ? "agreed" : "needs_consent", needsConsent: needsConsent),
                .init(
                    engine: AgentSubtitleEngine.parakeet.rawValue, available: !parakeet.isEmpty, languages: parakeet,
                    model: parakeetModel),
            ])
    }
}
