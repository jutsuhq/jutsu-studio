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
    }

    public enum State: Sendable, Hashable {
        case waiting
        /// 0…1 of the engine's model, which macOS downloads before the engine's first run.
        case downloadingModel(Double)
        /// 0…1.
        case working(Double)

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

    /// The first run, waiting or running, started on `materialID`.
    public func run(for materialID: UUID) -> Run? {
        runs.first { $0.request.source.materialID == materialID }
    }

    /// Refused, returning `false`, while the engine's model download waits for the person's agreement
    /// (`OnDeviceModelConsent`): until then nothing may ask macOS about the model, which would start the download.
    /// Refused too while a run on the same item waits or runs: each is made from the version it was started on, so
    /// runs aren't chained.
    @discardableResult
    public func start(_ request: Request) -> Bool {
        guard consent.allows(request.action.engine), run(for: request.source.materialID) == nil else { return false }
        runs.append(Run(id: UUID(), request: request, state: .waiting))
        next()
        return true
    }

    /// A waiting run is dropped; the running one stops, and its file is deleted.
    public func cancel(_ id: UUID) {
        guard let index = runs.firstIndex(where: { $0.id == id }) else { return }
        if index == 0, let loop {
            loop.cancel()
        } else {
            runs.remove(at: index)
        }
    }

    /// Cancels the runs waiting or running on `materialIDs` and returns once they are over, so none adds a version
    /// afterwards: Delete from Library calls it before it trashes the items.
    public func stop(_ materialIDs: Set<UUID>) async {
        let ids = Set(runs.filter { materialIDs.contains($0.request.source.materialID) }.map(\.id))
        for id in ids { cancel(id) }
        // A waiting run is gone at once; the running one when its loop ends.
        while let loop, let first = runs.first, ids.contains(first.id) { await loop.value }
    }

    /// Waits until every run started so far is over.
    public func finish() async {
        while let loop { await loop.value }
    }

    private func next() {
        guard loop == nil, let run = runs.first else { return }
        loop = Task { [weak self] in
            await self?.execute(run)
            self?.runs.removeAll { $0.id == run.id }
            self?.loop = nil
            self?.next()
        }
    }

    private func execute(_ run: Run) async {
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
        } catch {
            try? FileManager.default.removeItem(at: partial)
            guard !(error is CancellationError), !Task.isCancelled else { return }
            log.error("An on-device run failed", detail: String(describing: error))
            failure = UserMessage(title: OnDeviceText.failureTitle(request.action), message: error.localizedDescription)
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
