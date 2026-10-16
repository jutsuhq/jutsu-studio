import Foundation
import HiggsfieldAPI
import HiggsfieldCore
import JutsuCore

/// `GenerationProvider` for an API key: pays from the prepaid USD balance of the key's account.
public struct HiggsfieldAPIProvider: GenerationProvider {
    public let kind = ProviderKind.apiKey
    public var owner: String? { client.keyID }
    public let client: HiggsfieldAPIClient
    private let pricing: Pricing?
    /// `/estimate` quotes before upload (`quoteBeforeUpload`), for as long as this connection lasts.
    private let quotes = QuoteCache<JobSpec, Decimal>()

    /// `pricing` defaults to the bundled `pricing.json`.
    public init(client: HiggsfieldAPIClient, pricing: Pricing? = nil) {
        self.client = client
        self.pricing = pricing
    }

    public func capabilities() async throws -> Capabilities {
        Capabilities(
            modes: Set(Mode.allCases), models: Set(VideoModel.allCases.filter(\.runsWithAPIKey)),
            resolutions: Set(Resolution.allCases), costUnit: .usd, maxConcurrency: nil, parameters: APIModel.parameters)
    }

    public func presets() async throws -> [StylePreset] {
        try await mapped { try await client.presets() }.map {
            StylePreset(id: $0.id, name: $0.name, previewURL: $0.previewURL)
        }
    }

    /// Higgsfield's quote for a job with nothing to upload (`quoteBeforeUpload`), else the list price from
    /// pricing.json: `POST /estimate/{endpoint}` takes the body `submit` sends, so a job with media is quoted once
    /// they are uploaded (`serverEstimate`).
    public func estimate(_ spec: JobSpec) async throws -> Cost {
        guard spec.operation == nil else { throw APIModel.needsAccount }
        try Self.checkVariants(spec)
        if let quoted = try await quoteBeforeUpload(spec) { return quoted }
        return try (pricing ?? Pricing.bundled()).cost(for: spec)
    }

    /// The free `POST /estimate/{endpoint}` quote of a job without a source or images (Seedance from a prompt), whose
    /// request is complete before anything is uploaded. The docs say the estimate takes the same body as the submit,
    /// so it is the job's own body; jobs that differ only in their prompt share a quote. `nil` for a job with media
    /// or without a prompt (the request needs one), and when the quote fails: the list price stands then.
    func quoteBeforeUpload(_ spec: JobSpec) async throws -> Cost? {
        guard spec.source == nil, spec.references.isEmpty,
            !spec.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            let request = try? APIModel(spec, inputs: RemoteInputs(video: nil, images: []))
        else { return nil }
        var key = spec
        key.prompt = ""
        let (client, endpoint, body) = (client, request.endpoint, request.body)
        do {
            let usd = try await quotes.value(for: key) { try await client.estimate(endpoint, body) }
            return .usd(usd, isEstimate: false)
        } catch {
            try Task.checkCancellation()
            return nil
        }
    }

    public func serverEstimate(_ spec: JobSpec, inputs: RemoteInputs) async throws -> Cost? {
        try Self.checkVariants(spec)
        let request = try APIModel(spec, inputs: inputs)
        let usd = try await mapped { try await client.estimate(request.endpoint, request.body) }
        return .usd(usd, isEstimate: false)
    }

    public func upload(_ file: PreparedFile) async throws -> RemoteAsset {
        try await mapped {
            let target = try await client.uploadTarget(contentType: file.contentType)
            try await client.put(
                fileAt: file.fileURL, contentType: file.contentType, to: target.uploadURL,
                headers: target.uploadHeaders ?? [:])
            return RemoteAsset(url: target.publicURL)
        }
    }

    /// Every REST input is a public HTTPS URL, so a file that is online already is sent by its link. Restyle takes
    /// at most 200 MiB; a larger file is uploaded after the local conversion that brings it under that.
    public func linkedAsset(_ origin: URL, kind: MediaLink.Kind, byteCount: Int64) async throws -> RemoteAsset? {
        guard origin.isHTTPS, byteCount > 0, byteCount <= Self.maxLinkedBytes else {
            return nil
        }
        return RemoteAsset(url: origin)
    }

    static let maxLinkedBytes: Int64 = 200 * 1024 * 1024

    public func submit(_ spec: JobSpec, inputs: RemoteInputs, idempotencyKey: UUID) async throws -> RemoteJob {
        try Self.checkVariants(spec)
        let request = try APIModel(spec, inputs: inputs)
        let submitted = try await mapped {
            try await client.submit(request.endpoint, request.body, idempotencyKey: idempotencyKey)
        }
        return RemoteJob(
            requestID: submitted.requestID, correlationID: submitted.correlationID, statusURL: submitted.statusURL,
            cancelURL: submitted.cancelURL, initialStatus: submitted.initialStatus.map(RemoteStatus.init))
    }

    /// The REST API makes one generation per request; variants (`JobSpec.variants`) are the account's `count`.
    /// Refused before anything is sent.
    static func checkVariants(_ spec: JobSpec) throws {
        guard spec.variants == 1 else {
            throw ProviderError.validation(
                field: "count", message: String(localized: "Variants need a Higgsfield account.", bundle: .module))
        }
    }

    /// Every submit sends the `Idempotency-Key` header.
    public func submitIsIdempotent(_ spec: JobSpec) async throws -> Bool {
        true
    }

    public func status(_ job: RemoteJob) async throws -> RemoteStatus {
        RemoteStatus(try await mapped { try await client.status(requestID: job.requestID, statusURL: job.statusURL) })
    }

    public func cancel(_ job: RemoteJob) async throws {
        try await mapped { try await client.cancel(requestID: job.requestID, cancelURL: job.cancelURL) }
    }

    // note: the public REST docs list no balance endpoint, so the UI shows none; read it here once one exists.
    public func balance() async throws -> Balance? {
        nil
    }
}
