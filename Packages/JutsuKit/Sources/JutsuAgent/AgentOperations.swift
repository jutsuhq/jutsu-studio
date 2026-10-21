import Foundation

/// An export an agent started (`export`, or `delivery_set` with action export). It runs in the app on its own, so a
/// call that started it answers at once with its ID, and `jobs` follows it like a job: the server mints the handle, the
/// agent passes it back as an ordinary argument.
public struct AgentOperation: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case export
        case deliveryExport = "delivery_export"
    }

    public enum State: Equatable, Sendable {
        case running
        /// Every file was tried; each says how it went.
        case done
        /// It stopped before trying them all, for this reason.
        case failed(String)
    }

    public let id: UUID
    public let kind: Kind
    public var state: State
    /// Where the files go.
    public let folder: String
    /// How many files it writes, skipped ones included.
    public let total: Int
    /// The files finished so far, then all of them in the order asked.
    public var files: [AgentExportFile]
    /// A delivery export's set.
    public let set: UUID?
    public let createdAt: Date
    public var finishedAt: Date?

    /// As `jobs` lists it.
    public var job: AgentJob {
        let (name, error): (String, String?) =
            switch state {
            case .running: ("processing", nil)
            case .done: ("done", nil)
            case .failed(let message): ("failed", message)
            }
        let written = files.filter { $0.status == .done }.compactMap(\.file)
        return AgentJob(
            id: id, state: name, progress: total == 0 ? 1 : min(1, Double(files.count) / Double(total)),
            error: error, results: written.isEmpty ? nil : written, kind: kind.rawValue, folder: folder, files: files,
            set: set, createdAt: createdAt, finishedAt: finishedAt)
    }
}

/// The exports agents started, kept in memory: a relaunch forgets them, and `jobs` then answers `unknown` for their
/// IDs (`AgentJob.unknown`). Each runs in a task of its own, which neither the call that started it nor the agent
/// going away stops. Finished ones are kept for a day.
@MainActor
public final class AgentOperations {
    /// Reports one file as it finishes.
    public typealias Report = @MainActor (AgentExportFile) -> Void
    /// Writes the files, reporting each, and returns all of them in the order asked, or why it stopped.
    public typealias Work = @MainActor (_ report: @escaping Report) async -> Result<[AgentExportFile], AgentError>

    private var operations: [UUID: AgentOperation] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private let now: () -> Date

    static let keptFor: TimeInterval = 86_400

    public init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    /// Starts `work` and returns the export as it is now, running.
    public func start(
        _ kind: AgentOperation.Kind, folder: String, total: Int, set: UUID? = nil, work: @escaping Work
    ) -> AgentOperation {
        forgetOld()
        let operation = AgentOperation(
            id: UUID(), kind: kind, state: .running, folder: folder, total: max(0, total), files: [], set: set,
            createdAt: now(), finishedAt: nil)
        let id = operation.id
        operations[id] = operation
        tasks[id] = Task { [weak self] in
            let result = await work { file in self?.operations[id]?.files.append(file) }
            self?.finish(id, result)
        }
        return operation
    }

    public func operation(_ id: UUID) -> AgentOperation? { operations[id] }

    public var all: [AgentOperation] { Array(operations.values) }

    /// Returns once `id` has finished; at once for one that isn't running.
    public func finished(_ id: UUID) async {
        await tasks[id]?.value
    }

    private func finish(_ id: UUID, _ result: Result<[AgentExportFile], AgentError>) {
        tasks[id] = nil
        guard var operation = operations[id] else { return }
        switch result {
        case .success(let files):
            operation.files = files
            operation.state = .done
        case .failure(let error):
            operation.state = .failed(error.message)
        }
        operation.finishedAt = now()
        operations[id] = operation
    }

    private func forgetOld() {
        let cutoff = now().addingTimeInterval(-Self.keptFor)
        operations = operations.filter { $0.value.finishedAt.map { $0 >= cutoff } ?? true }
    }
}

extension AgentJob {
    /// An ID Jutsu Studio has no job, image request or export for, as `jobs` answers it: a relaunch forgets exports.
    public static func unknown(_ id: UUID) -> AgentJob {
        AgentJob(
            id: id, state: "unknown", error: "Jutsu Studio has no job, image request or export with this ID.",
            kind: "unknown",
            next: "An export's ID is forgotten when Jutsu Studio quits: look for its files in the folder export "
                + "answered with, or send export again. Call jobs without ids to list the latest work.",
            createdAt: nil)
    }
}
