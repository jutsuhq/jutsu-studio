import Foundation
import JutsuTestSupport
import Testing

@testable import JobEngine
@testable import JutsuCore

/// Ordered record of what the fakes were asked to do, shared by all of them.
final class CallLog: @unchecked Sendable {
    // Safe: `entries` is only touched under `lock`.
    private let lock = NSLock()
    private var entries: [String] = []

    func append(_ entry: String) {
        lock.lock()
        defer { lock.unlock() }
        entries.append(entry)
    }

    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    func count(_ entry: String) -> Int { all.filter { $0 == entry }.count }
}

/// Virtual time: sleeping advances `now` and returns at once.
final class TestClock: EngineClock, @unchecked Sendable {
    // Safe: `current` and `slept` are only touched under `lock`.
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_791_892_800)
    private var slept: [TimeInterval] = []

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    var sleeps: [TimeInterval] {
        lock.lock()
        defer { lock.unlock() }
        return slept
    }

    func advance(by seconds: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        current += seconds
    }

    private func record(_ seconds: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        slept.append(seconds)
        current += seconds
    }

    func sleep(for seconds: TimeInterval) async throws {
        try Task.checkCancellation()
        record(seconds)
        await Task.yield()
        try Task.checkCancellation()
    }
}

actor InMemoryRepository: JobRepository {
    let log: CallLog
    private var stored: [UUID: Job] = [:]
    private var history: [UUID: [JobState]] = [:]
    private var waiters:
        [UUID: (predicate: @Sendable (Snapshot) -> Bool, continuation: CheckedContinuation<Void, Never>)] =
            [:]

    struct Snapshot: Sendable {
        var jobs: [UUID: Job]
        var history: [UUID: [JobState]]

        func reached(_ id: UUID, _ state: JobState) -> Bool { history[id]?.contains(state) == true }
        func count(in state: JobState) -> Int { jobs.values.filter { $0.state == state }.count }
    }

    private var held: HeldSave?
    private var failsNextLoad = false
    /// Active records `activeJobs()` skips, as the store does with records it can't decode.
    private var undecodable: Set<UUID> = []

    struct LoadFailed: Error {}

    /// The next `activeJobs()` throws `LoadFailed`, like a store that can't be read.
    func failNextLoad() { failsNextLoad = true }

    /// Stores an active record that `activeJobs()` can't return, like one written by a newer build.
    func saveUndecodable(id: UUID) { undecodable.insert(id) }

    func activeJobIDs() -> Set<UUID> {
        Set(stored.values.filter(\.state.isActive).map(\.id)).union(undecodable)
    }

    private struct HeldSave {
        let matches: @Sendable (Job) -> Bool
        let reached: Gate<Void>
        let release: Gate<Void>
    }

    init(log: CallLog) {
        self.log = log
    }

    func save(_ job: Job) async {
        log.append("save \(job.state)")
        stored[job.id] = job
        history[job.id, default: []].append(job.state)
        let snapshot = Snapshot(jobs: stored, history: history)
        for (id, waiter) in waiters where waiter.predicate(snapshot) {
            waiters[id] = nil
            waiter.continuation.resume()
        }
        if let held, held.matches(job) {
            self.held = nil
            await held.reached.open(.success(()))
            _ = try? await held.release.wait()
        }
    }

    /// The next save of a job that `matches` is stored, then doesn't return until `release` opens, like a slow
    /// disk; `reached` opens once that save is held.
    func holdSave(where matches: @escaping @Sendable (Job) -> Bool) -> (reached: Gate<Void>, release: Gate<Void>) {
        let gates = (reached: Gate<Void>(), release: Gate<Void>())
        held = HeldSave(matches: matches, reached: gates.reached, release: gates.release)
        return gates
    }

    func job(id: UUID) -> Job? { stored[id] }

    /// Every job saved so far, in no order.
    func snapshotJobs() -> [Job] { Array(stored.values) }

    func activeJobs() throws -> [Job] {
        if failsNextLoad {
            failsNextLoad = false
            throw LoadFailed()
        }
        return stored.values.filter { $0.state.isActive }.sorted { $0.createdAt < $1.createdAt }
    }

    func delete(id: UUID) { stored[id] = nil }

    func states(of id: UUID) -> [JobState] { history[id] ?? [] }

    /// Returns once `predicate` holds for what has been saved so far. Records an issue and returns after
    /// `timeout`, so a state that never comes fails the test instead of hanging the run.
    /// Unlike `Gate` (a single-shot value), this re-checks an evolving snapshot on every save.
    func wait(
        timeout: Duration = .seconds(10), sourceLocation: SourceLocation = #_sourceLocation,
        until predicate: @escaping @Sendable (Snapshot) -> Bool
    ) async {
        if predicate(Snapshot(jobs: stored, history: history)) { return }
        let id = UUID()
        let timer = Task {
            do { try await Task.sleep(for: timeout) } catch { return }
            guard let waiter = waiters.removeValue(forKey: id) else { return }
            Issue.record("Repository did not reach the state within \(timeout)", sourceLocation: sourceLocation)
            waiter.continuation.resume()
        }
        defer { timer.cancel() }
        await withCheckedContinuation { waiters[id] = (predicate, $0) }
    }

    /// Returns once the job has been saved in `state` at some point.
    @discardableResult
    func wait(for id: UUID, _ state: JobState, sourceLocation: SourceLocation = #_sourceLocation) async -> Job? {
        await wait(sourceLocation: sourceLocation) { $0.reached(id, state) }
        return stored[id]
    }
}

actor FakeProvider: GenerationProvider {
    enum SubmitStep {
        case fail(ProviderError)
        /// Never answers until the task is canceled: the response is lost in a crash.
        case hang
        /// Accepts the job, then answers once `gate` opens, even if the task is canceled meanwhile.
        case answer(after: Gate<Void>)
    }

    nonisolated let kind: ProviderKind
    nonisolated let owner: String?
    let log: CallLog
    /// `false` acts like an MCP submit tool without an idempotency argument.
    var isIdempotent = true
    var submitSteps: [SubmitStep] = []
    var statusSteps: [Result<RemoteStatus, ProviderError>] = []
    var uploadErrors: [ProviderError] = []
    /// Returned by every status call while set; `nil` completes the job.
    var heldStatus: RemoteStatus?
    /// What `serverEstimate` answers; `nil` acts like a provider that can't quote.
    var quote: Result<Cost, ProviderError>?
    /// Put into every accepted `RemoteJob` as the submit answer's status.
    var submitStatus: RemoteStatus?
    /// What `paysUnlimited` answers for every spec.
    var paysUnlimited = false
    /// Put into every accepted `RemoteJob`: how the submit answer says it was paid.
    var unlimitedAnswer: (paid: Bool, charged: Cost?) = (false, nil)
    /// How many jobs a submit's answer starts; `nil` starts one per variant the spec asks for.
    var variantsStarted: Int?
    let videoURL = URL(string: "https://cdn.example/out.mp4")!

    private(set) var uploads: [String] = []
    private(set) var submitKeys: [UUID] = []
    private(set) var submittedInputs: [RemoteInputs] = []
    private(set) var statusCalls = 0
    /// The request ID of each `status` call.
    private(set) var statusAsked: [String] = []
    private(set) var cancels: [String] = []
    private(set) var maxInFlight = 0
    private var accepted: [UUID: RemoteJob] = [:]
    private var inFlight: Set<String> = []

    /// What `statuses(of:)` does.
    enum BatchMode {
        /// Answers each job as `status` would, except `batchOmits`.
        case answer
        /// `nil`, like an account without `jobs_wait` or with an answer it can't read.
        case unavailable
        case fail(ProviderError)
        /// Answers once `gate` opens, even if the task is canceled meanwhile.
        case held(until: Gate<Void>)
    }

    /// Above 1, the engine polls through `statuses(of:)`; 0 acts like the API key, which polls each job.
    nonisolated let statusBatchLimit: Int
    var batchMode = BatchMode.answer
    /// Put into every batch answer.
    var batchPollAfter: TimeInterval?
    /// Request IDs every batch answer leaves out.
    var batchOmits: Set<String> = []
    /// Answers by request ID that override `heldStatus` in batch answers.
    var batchStatuses: [String: RemoteStatus] = [:]
    /// The request IDs of each `statuses(of:)` call.
    private(set) var batches: [[String]] = []

    init(kind: ProviderKind = .apiKey, owner: String? = "key-a", log: CallLog, statusBatchLimit: Int = 0) {
        self.kind = kind
        self.owner = owner
        self.log = log
        self.statusBatchLimit = statusBatchLimit
    }

    func setBatch(
        _ mode: BatchMode = .answer, pollAfter: TimeInterval? = nil, omitting: Set<String> = [],
        statuses: [String: RemoteStatus] = [:]
    ) {
        batchMode = mode
        batchPollAfter = pollAfter
        batchOmits = omitting
        batchStatuses = statuses
    }

    func statuses(of jobs: [RemoteJob]) async throws -> BatchStatus? {
        log.append("statuses")
        batches.append(jobs.map(\.requestID))
        switch batchMode {
        case .answer: break
        case .unavailable: return nil
        case .fail(let error): throw error
        case .held(let gate): try await gate.wait()
        }
        var statuses: [String: RemoteStatus] = [:]
        for job in jobs where !batchOmits.contains(job.requestID) {
            let status = batchStatuses[job.requestID] ?? heldStatus ?? .completed(videoURL: videoURL)
            switch status {
            case .queued, .inProgress: break
            default: inFlight.remove(job.requestID)
            }
            statuses[job.requestID] = status
        }
        return BatchStatus(statuses: statuses, pollAfter: batchPollAfter)
    }

    func setIdempotent(_ value: Bool) { isIdempotent = value }

    func startVariants(_ count: Int?) { variantsStarted = count }

    func submitIsIdempotent(_ spec: JobSpec) -> Bool { isIdempotent }

    var acceptedCount: Int { accepted.count }

    func script(submit: [SubmitStep] = [], status: [Result<RemoteStatus, ProviderError>] = []) {
        submitSteps += submit
        statusSteps += status
    }

    func failUploads(_ errors: [ProviderError]) { uploadErrors += errors }

    func stopFailingUploads() { uploadErrors = [] }

    func hold(_ status: RemoteStatus?) { heldStatus = status }

    func setQuote(_ quote: Result<Cost, ProviderError>?) { self.quote = quote }

    func answerSubmits(with status: RemoteStatus?) { submitStatus = status }

    func payUnlimited(_ value: Bool, answer: (paid: Bool, charged: Cost?) = (true, nil)) {
        paysUnlimited = value
        unlimitedAnswer = answer
    }

    func paysUnlimited(_ spec: JobSpec) -> Bool { paysUnlimited }

    func serverEstimate(_ spec: JobSpec, inputs: RemoteInputs) throws -> Cost? {
        guard let quote else { return nil }
        log.append("serverEstimate")
        return try quote.get()
    }

    func capabilities() -> Capabilities {
        Capabilities(
            modes: Set(Mode.allCases), resolutions: Set(Resolution.allCases), costUnit: .usd, maxConcurrency: nil)
    }

    func presets() -> [StylePreset] { [] }

    /// What `estimate` answers in place of $1.30 a variant, when set.
    var preliminary: Cost?
    /// What `charge(of:)` answers; `nil` acts like a provider that can't tell what it charged.
    var charge: Result<Cost, ProviderError>?

    func setPreliminary(_ cost: Cost?) { preliminary = cost }

    func setCharge(_ charge: Result<Cost, ProviderError>?) { self.charge = charge }

    func estimate(_ spec: JobSpec) -> Cost {
        log.append("estimate")
        return preliminary ?? Cost.usd(1.3, isEstimate: false).times(spec.variants)
    }

    func charge(of job: Job) throws -> Cost? {
        log.append("charge")
        return try charge?.get()
    }

    /// Takes linked files by their link, like an API key; `false` acts like the account, which uploads them.
    var takesLinks = false

    func setTakesLinks(_ value: Bool) { takesLinks = value }

    func linkedAsset(_ origin: URL, kind: MediaLink.Kind, byteCount: Int64) -> RemoteAsset? {
        log.append("linked \(kind.rawValue)")
        return takesLinks ? RemoteAsset(url: origin) : nil
    }

    /// Takes media its own account listed by ID, like the confirmed account; `false` uploads them.
    var takesServerMedia = false

    func setTakesServerMedia(_ value: Bool) { takesServerMedia = value }

    func serverAsset(_ media: ServerMedia) -> RemoteAsset? {
        log.append("server media")
        return takesServerMedia && media.owner == owner ? RemoteAsset(url: media.url, id: media.id) : nil
    }

    func upload(_ file: PreparedFile) throws -> RemoteAsset {
        log.append("upload")
        if !uploadErrors.isEmpty { throw uploadErrors.removeFirst() }
        uploads.append(file.contentHash)
        return RemoteAsset(url: URL(string: "https://upload.example/\(file.contentHash)")!)
    }

    func submit(_ spec: JobSpec, inputs: RemoteInputs, idempotencyKey: UUID) async throws -> RemoteJob {
        log.append("submit")
        submitKeys.append(idempotencyKey)
        submittedInputs.append(inputs)
        let step = submitSteps.isEmpty ? nil : submitSteps.removeFirst()
        switch step {
        case .fail(let error): throw error
        case .hang:
            _ = accept(idempotencyKey, spec: spec)
            try await Task.sleep(nanoseconds: 3_600_000_000_000)
            throw CancellationError()
        case .answer(let gate):
            let remote = accept(idempotencyKey, spec: spec)
            try await gate.wait()
            return remote
        case nil: return accept(idempotencyKey, spec: spec)
        }
    }

    /// Same key, same job: the server's idempotency. Variants past the first are "r1-v1", "r1-v2"…
    private func accept(_ key: UUID, spec: JobSpec) -> RemoteJob {
        if let known = accepted[key] { return known }
        var remote = RemoteJob(requestID: "r\(accepted.count + 1)", initialStatus: submitStatus)
        (remote.paidWithUnlimited, remote.charged) = unlimitedAnswer
        let started = variantsStarted ?? spec.variants
        remote.variants = (1..<max(started, 1)).map { RemoteJob(requestID: "\(remote.requestID)-v\($0)") }
        accepted[key] = remote
        inFlight.insert(remote.requestID)
        for variant in remote.variants { inFlight.insert(variant.requestID) }
        maxInFlight = max(maxInFlight, inFlight.count)
        return remote
    }

    func status(_ job: RemoteJob) throws -> RemoteStatus {
        log.append("status")
        statusCalls += 1
        statusAsked.append(job.requestID)
        let status: RemoteStatus
        if !statusSteps.isEmpty {
            status = try statusSteps.removeFirst().get()
        } else {
            status = heldStatus ?? .completed(videoURL: videoURL)
        }
        switch status {
        case .queued, .inProgress: break
        default: inFlight.remove(job.requestID)
        }
        return status
    }

    func cancel(_ job: RemoteJob) {
        log.append("cancel")
        cancels.append(job.requestID)
        inFlight.remove(job.requestID)
    }

    func balance() -> Balance? { nil }
}

struct FakeMedia: MediaPreparing {
    enum AudioMode {
        /// The result already has sound.
        case keep
        /// Writes "video+audio" to the output.
        case mux
        case fail
        /// The first call finds the disk full, later ones mux.
        case diskFullOnce
    }

    struct MuxFailed: Error {}

    let log: CallLog
    var audio = AudioMode.keep
    var progressSteps: [Double] = [0.5, 1]
    /// What `imageSize(of:)` reads for every image.
    var imageSize: PixelSize?
    /// What `outputMedia(of:)` reads for every result.
    var outputMedia: OutputMedia?

    func imageSize(of image: LocalImage) -> PixelSize? { imageSize }

    func outputMedia(of file: URL) -> OutputMedia? { outputMedia }

    func prepareVideo(_ source: SourceClip, progress: @escaping @Sendable (Double) -> Void) -> PreparedFile {
        log.append("prepareVideo")
        for step in progressSteps { progress(step) }
        return PreparedFile(fileURL: source.fileURL, contentType: "video/mp4", byteCount: 1, contentHash: "video")
    }

    func prepareImage(_ image: LocalImage) -> PreparedFile {
        log.append("prepareImage")
        return PreparedFile(
            fileURL: image.fileURL, contentType: "image/jpeg", byteCount: 1,
            contentHash: "image-\(image.fileURL.lastPathComponent)")
    }

    func restoreAudio(of spec: JobSpec, result: URL, to output: URL) throws -> Bool {
        log.append("restoreAudio")
        switch audio {
        case .keep:
            return false
        case .mux:
            try (Data(contentsOf: result) + Data("+audio".utf8)).write(to: output)
            return true
        case .fail:
            throw MuxFailed()
        case .diskFullOnce where log.count("restoreAudio") == 1:
            throw CocoaError(.fileWriteOutOfSpace)
        case .diskFullOnce:
            try (Data(contentsOf: result) + Data("+audio".utf8)).write(to: output)
            return true
        }
    }
}

actor FakeUploadCache: UploadCache {
    private var entries: [String: (asset: RemoteAsset, date: Date)] = [:]

    func asset(forContentHash contentHash: String, uploadedAfter date: Date) -> RemoteAsset? {
        guard let entry = entries[contentHash], entry.date >= date else { return nil }
        return entry.asset
    }

    func store(_ asset: RemoteAsset, contentHash: String, uploadedAt: Date) {
        entries[contentHash] = (asset, uploadedAt)
    }

    func removeAssets(uploadedBefore date: Date) {
        entries = entries.filter { $0.value.date >= date }
    }

    var contentHashes: Set<String> { Set(entries.keys) }
}

/// Every subscriber gets the current state, then every change.
final class FakeConnectivity: Connectivity, @unchecked Sendable {
    // Safe: `online` and `subscribers` are only touched under `lock`.
    private let lock = NSLock()
    private var online: Bool
    private var subscribers: [AsyncStream<Bool>.Continuation] = []

    init(online: Bool) {
        self.online = online
    }

    func updates() -> AsyncStream<Bool> {
        let (stream, continuation) = AsyncStream.makeStream(of: Bool.self)
        lock.lock()
        defer { lock.unlock() }
        continuation.yield(online)
        subscribers.append(continuation)
        return stream
    }

    func set(online: Bool) {
        lock.lock()
        defer { lock.unlock() }
        self.online = online
        for subscriber in subscribers { subscriber.yield(online) }
    }
}

/// Appends what `file` is still missing of "video", like a resuming download.
struct FakeDownloader: Downloader {
    enum Mode {
        case complete
        /// The first call gets "vid", then the connection drops.
        case dropOnce
        /// Gets "vid", then never finishes until the task is canceled.
        case hang
        /// The first call hangs like `hang`, later ones complete.
        case hangOnce
        /// The first call gets "vid", then waits for the gate to open before it completes; later ones complete.
        case holdOnce(Gate<Void>)
        /// Call n is refused with the n-th status, later calls complete. 404 is an expired result.
        case refuse([Int])
        /// The first call gets "vid", then `error` (a full disk); later calls complete.
        case failOnce(any Error)
    }

    let log: CallLog
    var mode = Mode.complete
    /// The size of `file` at the start of every call.
    let starts = CallLog()

    func download(_ url: URL, to file: URL) async throws {
        log.append("download")
        let body = Data("video".utf8)
        let existing = (try? Data(contentsOf: file)) ?? Data()
        starts.append("\(existing.count)")
        switch mode {
        case .complete:
            try (existing + body.dropFirst(existing.count)).write(to: file)
        case .dropOnce where log.count("download") == 1:
            try body.prefix(3).write(to: file)
            throw ProviderError.network
        case .dropOnce:
            try (existing + body.dropFirst(existing.count)).write(to: file)
        case .hang,
            .hangOnce where log.count("download") == 1:
            try body.prefix(3).write(to: file)
            try await Task.sleep(nanoseconds: 3_600_000_000_000)
        case .hangOnce:
            try (existing + body.dropFirst(existing.count)).write(to: file)
        case .holdOnce(let gate) where log.count("download") == 1:
            try body.prefix(3).write(to: file)
            try await gate.wait()
            try body.write(to: file)
        case .holdOnce:
            try (existing + body.dropFirst(existing.count)).write(to: file)
        case .refuse(let statuses) where log.count("download") <= statuses.count:
            throw JobEngineError.downloadFailed(status: statuses[log.count("download") - 1])
        case .refuse:
            try body.write(to: file)
        case .failOnce(let error) where log.count("download") == 1:
            try body.prefix(3).write(to: file)
            throw error
        case .failOnce:
            try (existing + body.dropFirst(existing.count)).write(to: file)
        }
    }
}

/// All fakes for one test; engines made from it share them, as two launches of the app would.
struct Harness {
    let log = CallLog()
    let clock = TestClock()
    let provider: FakeProvider
    let repository: InMemoryRepository
    let cache = FakeUploadCache()
    let connectivity: FakeConnectivity
    let outputDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "JobEngineTests-\(UUID().uuidString)")
    let maxConcurrency: Int
    let downloader: FakeDownloader
    let audio: FakeMedia.AudioMode
    let progressSteps: [Double]
    /// What the engine's spend check sees; `nil` skips it.
    var spendStatus: SpendStatus?
    /// Unbounded by default: the virtual clock runs hours ahead while a test holds a status.
    let generationDeadline: TimeInterval
    /// What the media reads as every image's size.
    var imageSize: PixelSize?
    /// What the media reads from every downloaded result.
    var outputMedia: OutputMedia?

    init(
        online: Bool = true, maxConcurrency: Int = 2, download: FakeDownloader.Mode = .complete,
        audio: FakeMedia.AudioMode = .keep, progressSteps: [Double] = [0.5, 1], spendStatus: SpendStatus? = nil,
        generationDeadline: TimeInterval = .greatestFiniteMagnitude, statusBatchLimit: Int = 0
    ) {
        self.spendStatus = spendStatus
        self.generationDeadline = generationDeadline
        provider = FakeProvider(log: log, statusBatchLimit: statusBatchLimit)
        repository = InMemoryRepository(log: log)
        connectivity = FakeConnectivity(online: online)
        self.maxConcurrency = maxConcurrency
        downloader = FakeDownloader(log: log, mode: download)
        self.audio = audio
        self.progressSteps = progressSteps
    }

    /// - Parameter readSpend: replaces the fixed `spendStatus`, e.g. to count what the repository holds.
    /// - Parameter agentPolicy: the agent spend ledger and budgets; `nil` sends no agent's job.
    func makeEngine(
        readSpend: (@Sendable (Job) async throws -> SpendStatus?)? = nil, agentPolicy: AgentSpendPolicy? = nil
    ) async throws -> JobEngine {
        let settings = EngineSettings(
            outputDirectory: outputDirectory, maxConcurrency: maxConcurrency, jitter: 0, uploadMaxAge: 3600,
            generationDeadline: generationDeadline)
        let engine = JobEngine(
            provider: provider, repository: repository, uploadCache: cache,
            media: FakeMedia(
                log: log, audio: audio, progressSteps: progressSteps, imageSize: imageSize, outputMedia: outputMedia),
            connectivity: connectivity, settings: settings, downloader: downloader, clock: clock,
            spendStatus: readSpend ?? { [spendStatus] _ in spendStatus }, agentPolicy: agentPolicy)
        try await engine.start()
        return engine
    }
}

func makeSpec(references: Int = 1) -> JobSpec {
    let source = SourceClip(
        fileURL: URL(fileURLWithPath: "/tmp/source.mov"), duration: 60,
        pixelSize: PixelSize(width: 1280, height: 720), range: 0...10)
    let images = (0..<references).map { LocalImage(fileURL: URL(fileURLWithPath: "/tmp/ref\($0).jpg")) }
    return JobSpec(mode: .motionTransfer, source: source, references: images, resolution: .p480)
}

/// Lets stray tasks run; only for asserting that nothing more happens (quiescence), where no
/// gated condition exists. Whenever progress itself can be awaited, prefer `eventually` or
/// `InMemoryRepository.wait` — they fail loudly instead of depending on wall-clock time.
func quiesce() async {
    try? await Task.sleep(for: .milliseconds(200))
}
