import Foundation
import JutsuCore

/// Enhance's runs on this Mac (`OnDeviceAction`): one at a time, at background priority, each adding a new version to
/// the item it was started on, linked to the exact version it was made from; that version and its file stay as they
/// are. Free, so neither the queue nor the daily cap sees them. A canceled or failed run leaves no file behind.
@MainActor
@Observable
public final class OnDeviceRuns {
    public struct Request: Sendable, Hashable {
        /// The exact version the result is made from, and its file.
        public var source: MaterialReference
        public var file: URL
        public var action: OnDeviceAction
        /// The folder the result goes in.
        public var destination: URL
        /// Where the result is written until it is done, as a hidden `.ondevice-<UUID>.partial` (`partialName`): on
        /// the destination's volume, so it moves in at once. JobEngine's leftover sweep doesn't take these for a
        /// download's; `removeLeftovers(in:)` clears the ones a crash left, at launch.
        public var scratch: URL

        public init(source: MaterialReference, file: URL, action: OnDeviceAction, destination: URL, scratch: URL) {
            self.source = source
            self.file = file
            self.action = action
            self.destination = destination
            self.scratch = scratch
        }
    }

    public struct Run: Identifiable, Sendable, Hashable {
        public let id: UUID
        public let request: Request
        public internal(set) var state: State
        public internal(set) var createdAt = Date()
    }

    /// How a run ended.
    enum Outcome: Sendable, Hashable {
        /// The result's file, now the item's current version.
        case done(URL)
        case failed(String)
        case canceled
    }

    /// A run that ended, as `jobs` reports it (`AgentOnDeviceRuns`).
    struct Finished: Sendable, Hashable {
        let run: Run
        let outcome: Outcome
        let finishedAt: Date
    }

    public enum State: Sendable, Hashable {
        case waiting
        /// 0…1 of the engine's model, which macOS downloads before the engine's first run.
        case downloadingModel(Double)
        /// 0…1.
        case working(Double)

        var isDownloadingModel: Bool {
            if case .downloadingModel = self { true } else { false }
        }

        /// How far the model or the frames are; `nil` while waiting.
        public var fraction: Double? {
            switch self {
            case .waiting: nil
            case .downloadingModel(let fraction), .working(let fraction): fraction
            }
        }
    }

    /// Adds the finished file as the new version of `request.source`'s material.
    public typealias Register =
        @MainActor (_ request: Request, _ file: URL, _ output: OnDeviceOutput) async throws ->
        Void

    /// Waiting and running, in the order they run: the first one is running.
    public private(set) var runs: [Run] = []
    /// What went wrong with the last run that failed, until it is shown.
    public var failure: UserMessage?
    /// The last runs that ended, oldest first, at most `keptFinished` of them.
    @ObservationIgnored private(set) var finished: [Finished] = []
    /// Whether each engine's model was here when a run on it last ended: read off the main actor then, as asking
    /// VideoToolbox makes a scaler configuration, and never outside a run, which may start the download.
    @ObservationIgnored private var readyModels: [OnDeviceEngine: Bool] = [:]

    static let keptFinished = 100

    @ObservationIgnored private let engine: any OnDeviceEnhancing
    @ObservationIgnored private let consent: OnDeviceModelConsent
    @ObservationIgnored private let register: Register
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private let log = PresentationLog(category: "OnDevice")

    public init(engine: any OnDeviceEnhancing, consent: OnDeviceModelConsent, register: @escaping Register) {
        self.engine = engine
        self.consent = consent
        self.register = register
    }

    /// Whether this Mac has the engine; asks nothing about its model.
    public func supports(_ engine: OnDeviceEngine) -> Bool {
        self.engine.supports(engine)
    }

    /// Whether a run on `engine` waits for the person to agree to macOS downloading its model.
    public func needsConsent(_ engine: OnDeviceEngine) -> Bool {
        !consent.allows(engine)
    }

    public func agree(to engine: OnDeviceEngine) {
        consent.agree(to: engine)
    }

    /// Whether the engine's model is known to be here: as a run on it found it, after the person agreed to its
    /// download; `false` before any such run since launch. Asks VideoToolbox nothing.
    public func modelIsReady(_ engine: OnDeviceEngine) -> Bool {
        consent.allows(engine) && readyModels[engine] == true
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

    /// Refused, returning `false`, while the engine's model download waits for the person's agreement
    /// (`OnDeviceModelConsent`): until then nothing may ask macOS about the model, which would start the download.
    /// Refused too while a run on the same item waits or runs: each is made from the version it was started on, so
    /// runs aren't chained.
    /// - Parameter id: the run's ID, which an agent's request records before it starts.
    @discardableResult
    public func start(_ request: Request, id: UUID = UUID()) -> Bool {
        guard consent.allows(request.action.engine), run(for: request.source.materialID) == nil else { return false }
        runs.append(Run(id: id, request: request, state: .waiting))
        next()
        return true
    }

    /// A waiting run is dropped; the running one stops, and its file is deleted.
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

    /// Cancels the runs waiting or running on `materialIDs` and returns once they are over, so none adds a version
    /// afterwards: Delete from Library calls it before it trashes the items.
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
            await self?.readModel(of: run.request.action.engine)
        }
    }

    /// Notes whether `engine`'s model is here, asked off the main actor once a run on it ended: the run had the model
    /// or downloaded it with the person's agreement, so asking starts nothing.
    private func readModel(of engine: OnDeviceEngine) async {
        guard engine.downloadsModel, consent.allows(engine) else { return }
        let enhancer = self.engine
        readyModels[engine] = await Task.detached(priority: .utility) { enhancer.modelIsReady(engine) }.value
    }

    private func end(_ run: Run, _ outcome: Outcome) {
        finished.append(Finished(run: run, outcome: outcome, finishedAt: Date()))
        if finished.count > Self.keptFinished { finished.removeFirst(finished.count - Self.keptFinished) }
    }

    private func execute(_ run: Run) async -> Outcome {
        let request = run.request
        let partial = request.scratch.appending(path: Self.partialName(run.id), directoryHint: .notDirectory)
        let engine = engine
        let throttles = (model: ProgressThrottle(), frames: ProgressThrottle())
        let progress: @Sendable (OnDeviceProgress) -> Void = { [weak self] progress in
            let state: State
            switch progress {
            case .downloadingModel(let fraction):
                guard throttles.model.admits(fraction) else { return }
                state = .downloadingModel(fraction)
            case .working(let fraction):
                guard throttles.frames.admits(fraction) else { return }
                state = .working(fraction)
            }
            Task { @MainActor in self?.update(run.id, to: state) }
        }
        update(run.id, to: .working(0))
        try? FileManager.default.createDirectory(at: request.scratch, withIntermediateDirectories: true)
        let work = Task.detached(priority: .background) {
            try await engine.run(request.action, on: request.file, to: partial, progress: progress)
        }
        do {
            let output = try await withTaskCancellationHandler {
                try await work.value
            } onCancel: {
                work.cancel()
            }
            try Task.checkCancellation()
            let file = try Self.place(partial, for: request, output: output)
            do {
                try await register(request, file, output)
            } catch {
                // Not in the catalog, so taken back: a second try doesn't leave a second file.
                try? FileManager.default.removeItem(at: file)
                throw error
            }
            return .done(file)
        } catch {
            try? FileManager.default.removeItem(at: partial)
            guard !(error is CancellationError), !Task.isCancelled else { return .canceled }
            log.error("An on-device run failed", detail: String(describing: error))
            failure = UserMessage(title: OnDeviceText.failureTitle(request.action), message: error.localizedDescription)
            return .failed(error.localizedDescription)
        }
    }

    private func update(_ id: UUID, to state: State) {
        guard let index = runs.firstIndex(where: { $0.id == id }) else { return }
        runs[index].state = state
    }

    static let partialPrefix = ".ondevice-"

    /// ".ondevice-<UUID>.partial": not a job's scratch name (`.<UUID>.partial`), so JobEngine's sweep leaves it alone.
    static func partialName(_ id: UUID) -> String {
        "\(partialPrefix)\(id.uuidString).partial"
    }

    /// Deletes the partial files a crash or a quit left in `folder`. Call before the first run starts: it would
    /// delete a running one's too.
    public static func removeLeftovers(in folder: URL) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? []
        for name in names where name.hasPrefix(partialPrefix) && name.hasSuffix(".partial") {
            try? FileManager.default.removeItem(at: folder.appending(path: name, directoryHint: .notDirectory))
        }
    }

    /// Moves the finished file in under a name of its own: "rooftop 60fps.mp4", "rooftop 60fps 2.mp4".
    static func place(_ partial: URL, for request: Request, output: OnDeviceOutput) throws -> URL {
        let stem = request.file.deletingPathExtension().lastPathComponent
        let file = request.destination.appending(
            path: "\(stem) \(request.action.fileSuffix).\(output.fileExtension)", directoryHint: .notDirectory
        ).unusedFileURL()
        try FileManager.default.createDirectory(at: request.destination, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: partial, to: file)
        return file
    }
}
