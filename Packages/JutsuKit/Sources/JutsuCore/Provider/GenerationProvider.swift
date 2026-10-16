import Foundation

/// A way to run Genjutsu jobs: the REST API with a key, or a Higgsfield account over MCP.
/// The engine and UI only talk to the provider of the active connection.
public protocol GenerationProvider: Sendable {
    var kind: ProviderKind { get }
    /// Who pays: the key ID, or the signed-in account. Stable across launches and token refreshes;
    /// `nil` when the account can't be identified.
    var owner: String? { get }
    func capabilities() async throws -> Capabilities
    func presets() async throws -> [StylePreset]
    /// The preliminary price, before anything is uploaded.
    func estimate(_ spec: JobSpec) async throws -> Cost
    /// The provider's own price for the exact request `submit` would send; `nil` when it can't quote one.
    func serverEstimate(_ spec: JobSpec, inputs: RemoteInputs) async throws -> Cost?
    /// What the provider charged for `job`, which it finished without a price known beforehand
    /// (`Job.priceIsUnknown`); `nil` when it can't tell which charge was the job's.
    func charge(of job: Job) async throws -> Cost?
    func upload(_ file: PreparedFile) async throws -> RemoteAsset
    /// An input the provider can take straight from `origin`, the public `https:` link its file was downloaded
    /// from, so the file isn't uploaded; `nil` when it has to be uploaded. `byteCount` is the file's size.
    func linkedAsset(_ origin: URL, kind: MediaLink.Kind, byteCount: Int64) async throws -> RemoteAsset?
    /// `media` as an input of this connection, so its file isn't uploaded; `nil` when it has to be uploaded, as for
    /// media another account listed.
    func serverAsset(_ media: ServerMedia) async throws -> RemoteAsset?
    /// Reuse `idempotencyKey` for every resubmit of the same attempt so it can't charge twice. A provider
    /// that can't send the key throws `ProviderError.outcomeUnknown` instead of any error the engine retries
    /// once the request may have reached the server.
    func submit(_ spec: JobSpec, inputs: RemoteInputs, idempotencyKey: UUID) async throws -> RemoteJob
    /// Whether `submit` sends the idempotency key for `spec`, so it can be sent again after a crash.
    func submitIsIdempotent(_ spec: JobSpec) async throws -> Bool
    func status(_ job: RemoteJob) async throws -> RemoteStatus
    /// How many jobs `statuses(of:)` takes in one call. Below 2, the engine polls each job with `status` alone.
    var statusBatchLimit: Int { get }
    /// The statuses of up to `statusBatchLimit` jobs in one call; `nil` when the provider can't give them this
    /// time, and the engine then asks `status` for each job.
    func statuses(of jobs: [RemoteJob]) async throws -> BatchStatus?
    func cancel(_ job: RemoteJob) async throws
    /// `nil` when the provider can't report a balance.
    func balance() async throws -> Balance?
    /// Whether `spec` is to be paid from the plan's unlimited allowance: the user opted in and the provider read
    /// that the account has it for the spec's model now. The engine asks when the job is queued.
    func paysUnlimited(_ spec: JobSpec) async -> Bool
}

extension GenerationProvider {
    public func serverEstimate(_ spec: JobSpec, inputs: RemoteInputs) async throws -> Cost? {
        nil
    }

    public func charge(of job: Job) async throws -> Cost? {
        nil
    }

    public func linkedAsset(_ origin: URL, kind: MediaLink.Kind, byteCount: Int64) async throws -> RemoteAsset? {
        nil
    }

    public func serverAsset(_ media: ServerMedia) async throws -> RemoteAsset? {
        nil
    }

    public func paysUnlimited(_ spec: JobSpec) async -> Bool {
        false
    }

    public var statusBatchLimit: Int { 0 }

    public func statuses(of jobs: [RemoteJob]) async throws -> BatchStatus? {
        nil
    }

    /// The connection `job` was queued with: the same kind and the same owner.
    public func owns(_ job: Job) -> Bool {
        kind == job.providerKind && owner == job.owner
    }
}

public enum ProviderKind: String, Codable, Sendable, CaseIterable {
    case apiKey
    case account
}
