import Foundation
import JutsuCore
import Observation

/// One job of a Generate… request the provider accepted: kept from the moment its submit was answered until the
/// request ends, so a job that may be paid for is followed again after a quit, a lost sign-in or a switch of account.
public struct ImageJobRecord: Codable, Sendable, Hashable, Identifiable {
    public enum State: Codable, Sendable, Hashable {
        case pending
        case completed
        case failed(String?)
        case rejected
        case canceled
    }

    /// The provider's job, with where to poll it.
    public var job: RemoteJob
    /// `ImageProvider.owner` of the connection that started it.
    public var owner: String?
    /// The request it came from (`ImageRun.id`), which is also its `ImageCharge`'s ID.
    public var runID: UUID
    public var createdAt: Date
    public var prompt: String
    /// The model's title, as the images and the run row show it.
    public var model: String
    public var aspectRatio: String?
    /// Images the request makes.
    public var count: Int
    public var state: State
    public var providerKind: ProviderKind = .apiKey
    public var request: ImageRequest?
    public var inputImages: [LocalImage] = []

    public var id: String { job.requestID }

    /// It ended in a way Higgsfield doesn't bill: failed, refused by moderation, or cancelled.
    public var isUnbilled: Bool {
        switch state {
        case .failed, .rejected, .canceled: true
        case .pending, .completed: false
        }
    }

    public init(
        job: RemoteJob, owner: String?, runID: UUID, createdAt: Date, prompt: String, model: String,
        aspectRatio: String?, count: Int, state: State = .pending
    ) {
        self.job = job
        self.owner = owner
        self.runID = runID
        self.createdAt = createdAt
        self.prompt = prompt
        self.model = model
        self.aspectRatio = aspectRatio
        self.count = count
        self.state = state
    }
}

/// The accepted jobs of Generate… requests still being followed (`ImageJobRecord`), kept in `image-jobs.json` next
/// to the store. `ReferenceGenerator` adds them as soon as the submit is answered and drops a request's jobs once it
/// ended; the jobs still pending are followed again on the next launch or sign-in. Records that can't be read are
/// left out and their file kept aside (`LogFile`).
///
/// A write that fails keeps the records in memory, so their jobs are still followed in this launch, says why in
/// `saveError` and lists the job IDs only this launch knows in `unsavedIDs`, for the user to copy. The next change or
/// `retrySave` writes everything again.
@MainActor
@Observable
public final class ImageJobLog {
    public static let fileName = "image-jobs.json"

    /// Oldest first.
    public private(set) var records: [ImageJobRecord]
    /// Why the last write failed; `nil` once one goes through.
    public private(set) var saveError: LogWriteError?
    /// Jobs added since the last write that went through: a quit would lose track of them.
    public private(set) var unsavedIDs: [String] = []
    @ObservationIgnored private let file: LogFile<ImageJobRecord>

    /// - Parameter folder: where the file lives; `nil` keeps everything in memory, as tests and previews do.
    public init(folder: URL?) {
        file = LogFile(folder: folder, name: Self.fileName)
        records = file.read()
    }

    /// The jobs of `owner` still running.
    public func pending(of owner: String?) -> [ImageJobRecord] {
        records.filter { $0.owner == owner && $0.state == .pending }
    }

    public func add(_ new: [ImageJobRecord]) {
        let added = new.filter { record in !records.contains { $0.id == record.id } }
        records += added
        unsavedIDs += added.map(\.id)
        save()
    }

    public func update(_ id: String, state: ImageJobRecord.State) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].state = state
        save()
    }

    /// The request ended and its outcome is settled: its jobs needn't be followed again.
    public func forget(run: UUID) {
        guard records.contains(where: { $0.runID == run }) else { return }
        records.removeAll { $0.runID == run }
        save()
    }

    /// Writes the records again after `saveError`.
    public func retrySave() {
        save()
    }

    private func save() {
        do {
            try file.write(records)
            saveError = nil
            unsavedIDs = []
        } catch {
            saveError = error
        }
    }
}
