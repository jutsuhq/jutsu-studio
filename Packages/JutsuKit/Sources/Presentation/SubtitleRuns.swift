import Foundation
import JutsuCore

/// Subtitles made on-device (`SpeechTranscribing`): one run at a time, at background priority, each hearing the file of
/// the exact version it was started on and saving its subtitles on that version. Free, so neither the queue nor the
/// daily cap sees them. A canceled or failed run saves nothing.
@MainActor
@Observable
public final class SubtitleRuns {
    public struct Request: Sendable, Hashable {
        /// The exact version the subtitles are for, its file, and the file's bookmark when it lies outside the
        /// app's folders.
        public var source: MaterialReference
        public var file: URL
        public var bookmark: Data?
        /// BCP 47, "en-US".
        public var language: String
        public var engine: SubtitleEngine

        public init(
            source: MaterialReference, file: URL, bookmark: Data? = nil, language: String,
            engine: SubtitleEngine = .builtIn
        ) {
            self.source = source
            self.file = file
            self.bookmark = bookmark
            self.language = language
            self.engine = engine
        }
    }

    public struct Run: Identifiable, Sendable, Hashable {
        public let id: UUID
        public let request: Request
        /// The model that hears it.
        public let model: SpeechModel
        public internal(set) var state: OnDeviceRuns.State
        public internal(set) var createdAt = Date()
    }

    enum Outcome: Sendable, Hashable {
        case done(Subtitles)
        case failed(String)
        case canceled
    }

    /// A run that ended, as `jobs` reports it.
    struct Finished: Sendable, Hashable {
        let run: Run
        let outcome: Outcome
        let finishedAt: Date
    }

    /// Saves the subtitles on `request.source`.
    public typealias Register = @MainActor (_ request: Request, _ subtitles: Subtitles) async throws -> Void
    /// Runs `hear` on the file with sandbox access through its bookmark, then gives the access up.
    public typealias Access =
        @Sendable (
            _ file: URL, _ bookmark: Data?, _ hear: @Sendable (URL) async throws -> Transcript
        ) async throws -> Transcript

    /// Waiting and running, in the order they run: the first one is running.
    public private(set) var runs: [Run] = []
    /// What went wrong with the last run that failed, until it is shown.
    public var failure: UserMessage?
    /// The models and languages this Mac has; `nil` until `loadAvailability` read them.
    public private(set) var availability: SpeechAvailability?
    /// Languages whose built-in model a run found missing although macOS listed it as installed: the sheet asks for
    /// the person's agreement for them all the same.
    public private(set) var missingModels: Set<String> = []
    @ObservationIgnored private(set) var finished: [Finished] = []

    static let keptFinished = 100

    @ObservationIgnored private let engine: any SpeechTranscribing
    @ObservationIgnored private let consent: OnDeviceModelConsent
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let register: Register
    @ObservationIgnored private let access: Access
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private let log = PresentationLog(category: "Subtitles")

    /// - Parameters:
    ///   - defaults: where the person's agreement to model downloads and the last language used are kept.
    ///   - access: opens the file through its bookmark; without one, the file is read as it is.
    public init(
        engine: any SpeechTranscribing, defaults: UserDefaults,
        access: @escaping Access = { file, _, hear in try await hear(file) }, register: @escaping Register
    ) {
        self.engine = engine
        consent = OnDeviceModelConsent(defaults: defaults)
        self.defaults = defaults
        self.access = access
        self.register = register
    }

    static let lastLanguageKey = "subtitles.lastLanguage"

    /// The language the sheet starts on: the last one a run was started in, then the system's.
    public var preferredLanguage: String? {
        SpeechSelection.preferred(
            languages, last: defaults.string(forKey: Self.lastLanguageKey), system: Locale.preferredLanguages)
    }

    /// Reads which models and languages this Mac has, which downloads nothing.
    public func loadAvailability() async {
        let engine = engine
        availability = await Task.detached(priority: .utility) { await engine.availability() }.value
    }

    /// The languages the Subtitles sheet offers; none until `loadAvailability` read them.
    public var languages: [String] {
        availability.map(SpeechSelection.languages) ?? []
    }

    /// The model `engine` would hear `language` with; `nil` when it doesn't take it, or before `loadAvailability`.
    public func model(for language: String, engine: SubtitleEngine = .builtIn) -> SpeechModel? {
        availability.flatMap { SpeechSelection.model(engine, for: language, in: $0) }
    }

    /// Whether a run in `language` waits for the person to agree to macOS downloading that language's model: only
    /// for a built-in model that isn't on this Mac, or that a run found missing, before they agreed for the language.
    public func needsConsent(_ language: String, engine: SubtitleEngine = .builtIn) -> Bool {
        guard !consent.allowsSpeechModel(for: language) else { return false }
        guard let availability, let model = model(for: language, engine: engine) else { return true }
        guard model.isBuiltIn else { return false }
        return !availability.isInstalled(model, language) || missingModels.contains(language)
    }

    /// Whether `engine` hears `language` with a model the app downloads, and it isn't downloaded yet.
    public func needsDownload(_ language: String, engine: SubtitleEngine) -> Bool {
        guard let availability, let model = model(for: language, engine: engine), !model.isBuiltIn else {
            return false
        }
        return !availability.isInstalled(model, language)
    }

    /// Whether the person agreed to macOS downloading the speech model of `language`.
    public func agreedToModel(for language: String) -> Bool { consent.allowsSpeechModel(for: language) }

    public func agreeToModel(for language: String) {
        consent.agreeToSpeechModel(for: language)
    }

    /// The first run, waiting or running, started on `materialID`.
    public func run(for materialID: UUID) -> Run? {
        runs.first { $0.request.source.materialID == materialID }
    }

    /// The run waiting or running as `id`, else the one that ended so, while it is kept.
    func run(_ id: UUID) -> (run: Run, finished: Finished?)? {
        if let run = runs.first(where: { $0.id == id }) { return (run, nil) }
        return finished.last { $0.run.id == id }.map { ($0.run, $0) }
    }

    /// Refused, returning `false`, when the engine doesn't take the language, while its model download waits for the
    /// person's agreement or Parakeet isn't downloaded, and while a run on the same item waits or runs.
    @discardableResult
    public func start(_ request: Request, id: UUID = UUID()) -> Bool {
        guard let model = model(for: request.language, engine: request.engine),
            !needsConsent(request.language, engine: request.engine),
            !needsDownload(request.language, engine: request.engine), run(for: request.source.materialID) == nil
        else { return false }
        defaults.set(request.language, forKey: Self.lastLanguageKey)
        runs.append(Run(id: id, request: request, model: model, state: .waiting))
        next()
        return true
    }

    /// A waiting run is dropped; the running one stops.
    public func cancel(_ id: UUID) {
        guard let index = runs.firstIndex(where: { $0.id == id }) else { return }
        if index == 0, let loop {
            loop.cancel()
        } else {
            end(runs.remove(at: index), .canceled)
        }
    }

    /// Returns once the run `id` is over; at once when it isn't the running one.
    func over(_ id: UUID) async {
        guard runs.first?.id == id, let loop else { return }
        await loop.value
    }

    /// Cancels the runs on `materialIDs` and returns once they are over, so none saves afterwards.
    public func stop(_ materialIDs: Set<UUID>) async {
        let ids = runs.filter { materialIDs.contains($0.request.source.materialID) }.map(\.id)
        for id in ids { cancel(id) }
        for id in ids { await over(id) }
    }

    /// Waits until every run started so far is over.
    public func finish() async {
        while let loop { await loop.value }
    }

    private func next() {
        guard loop == nil, let run = runs.first else { return }
        loop = Task { [weak self] in
            guard let outcome = await self?.execute(run) else { return }
            if let ended = self?.runs.first(where: { $0.id == run.id }) { self?.end(ended, outcome) }
            self?.runs.removeAll { $0.id == run.id }
            self?.loop = nil
            self?.next()
            await self?.loadAvailability()
        }
    }

    private func end(_ run: Run, _ outcome: Outcome) {
        finished.append(Finished(run: run, outcome: outcome, finishedAt: Date()))
        if finished.count > Self.keptFinished { finished.removeFirst(finished.count - Self.keptFinished) }
    }

    private func execute(_ run: Run) async -> Outcome {
        let request = run.request
        let (engine, access) = (engine, access)
        let mayDownload = consent.allowsSpeechModel(for: request.language)
        let throttles = (model: ProgressThrottle(), words: ProgressThrottle())
        let progress: @Sendable (OnDeviceProgress) -> Void = { [weak self] progress in
            let state: OnDeviceRuns.State
            switch progress {
            case .downloadingModel(let fraction):
                guard throttles.model.admits(fraction) else { return }
                state = .downloadingModel(fraction)
            case .working(let fraction):
                guard throttles.words.admits(fraction) else { return }
                state = .working(fraction)
            }
            Task { @MainActor in self?.update(run.id, to: state) }
        }
        update(run.id, to: .working(0))
        let work = Task.detached(priority: .background) {
            try await access(request.file, request.bookmark) { file in
                try await engine.transcribe(
                    file, language: request.language, model: run.model, mayDownload: mayDownload, progress: progress)
            }
        }
        do {
            let transcript = try await withTaskCancellationHandler {
                try await work.value
            } onCancel: {
                work.cancel()
            }
            try Task.checkCancellation()
            let subtitles = Subtitles(transcript: transcript)
            try await register(request, subtitles)
            return .done(subtitles)
        } catch {
            guard !(error is CancellationError), !Task.isCancelled else { return .canceled }
            if error as? TranscriptionError == .modelNeeded { missingModels.insert(request.language) }
            let message = SubtitleText.message(for: error)
            if error as? TranscriptionError == nil {
                log.error("A subtitles run failed", detail: String(describing: error))
            }
            failure = UserMessage(title: SubtitleText.failureTitle, message: message)
            return .failed(message)
        }
    }

    private func update(_ id: UUID, to state: OnDeviceRuns.State) {
        guard let index = runs.firstIndex(where: { $0.id == id }) else { return }
        runs[index].state = state
    }
}
