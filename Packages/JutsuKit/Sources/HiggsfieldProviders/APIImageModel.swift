import Foundation
import HiggsfieldAPI
import HiggsfieldCore
import JutsuCore

/// The image models an API key offers for reference images (issue #42): a short list whose request schemas are
/// on their docs.higgsfield.ai pages. List prices per image are open.higgsfield.ai's (2026-10-15), shown as
/// estimates until `/estimate` quotes the exact body.
enum APIImageModel {
    static let soulRatios = ["1:1", "3:4", "4:3", "2:3", "3:2", "9:16", "16:9"]
    static let grokRatios = ["1:1", "3:4", "4:3", "2:3", "3:2", "9:16", "16:9", "1:2", "2:1"]
    static let qwenRatios = ["1:1", "3:4", "4:3", "2:3", "3:2", "9:16", "16:9", "7:9", "9:7", "21:9"]

    static let models = [
        // $0.0032 an image at 720p, the default resolution; `batch_size` takes 1 or 4.
        ImageModel(
            id: ModelEndpoint.soulV2.rawValue, title: "Soul 2", variantCounts: [1, 4], aspectRatios: soulRatios,
            listPrice: usd(32, exponent: -4)),
        // $0.04 (1k, low) to $0.08 (2k, medium); the request is 1k medium, whose own rate isn't published, so the
        // estimate is the upper bound.
        ImageModel(
            id: ModelEndpoint.grokImage2.rawValue, title: "Grok Image 2", aspectRatios: grokRatios, input: .optional,
            listPrice: usd(8, exponent: -2)),
        // $0.04 an image at 1k, the default resolution.
        ImageModel(
            id: ModelEndpoint.qwenImage3Edit.rawValue, title: "Qwen Image 3 Edit", aspectRatios: qwenRatios,
            input: .required, listPrice: usd(4, exponent: -2)),
    ]

    private static func usd(_ significand: Int, exponent: Int) -> Cost {
        .usd(Decimal(sign: .plus, exponent: exponent, significand: Decimal(significand)), isEstimate: true)
    }

    /// The endpoint and body of `request`, checked against the model: a known model, one of its variant counts,
    /// a prompt, and an input image where the model needs one.
    static func body(_ request: ImageRequest) throws -> (ModelEndpoint, any Encodable & Sendable) {
        guard let model = models.first(where: { $0.id == request.model }),
            let endpoint = ModelEndpoint(rawValue: request.model)
        else {
            throw ProviderError.validation(
                field: "model",
                message: String(localized: "This image model can't run with an API key.", bundle: .module))
        }
        guard model.variantCounts.contains(request.count) else {
            throw ProviderError.validation(
                field: "batch_size",
                message: String(localized: "\(model.title) can't make that many images.", bundle: .module))
        }
        guard !request.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProviderError.validation(
                field: "prompt", message: String(localized: "Describe the image to make.", bundle: .module))
        }
        let inputs = request.inputImages.map(\.url)
        switch endpoint {
        case .soulV2:
            return (
                endpoint,
                SoulImageRequest(
                    prompt: request.prompt, aspectRatio: request.aspectRatio, batchSize: request.count)
            )
        case .grokImage2:
            return (
                endpoint,
                GrokImageRequest(
                    prompt: request.prompt, aspectRatio: request.aspectRatio, imageURLs: inputs)
            )
        case .qwenImage3Edit:
            guard !inputs.isEmpty else {
                throw ProviderError.validation(
                    field: "image_urls",
                    message: String(localized: "\(model.title) needs an image to edit.", bundle: .module))
            }
            return (
                endpoint,
                QwenEditRequest(
                    prompt: request.prompt, imageURLs: inputs, aspectRatio: request.aspectRatio)
            )
        default:
            throw ProviderError.validation(
                field: "model",
                message: String(localized: "This image model can't run with an API key.", bundle: .module))
        }
    }

    /// The list price of `request`: the model's per image times the images.
    static func listPrice(of request: ImageRequest) -> Cost? {
        guard case .usd(let each, _)? = models.first(where: { $0.id == request.model })?.listPrice else { return nil }
        return .usd(each * Decimal(request.count), isEstimate: true)
    }
}

extension ProviderError {
    /// No answer, or one the client can't read: it says nothing about the request itself.
    fileprivate var isOutage: Bool {
        switch self {
        case .network, .server: true
        default: false
        }
    }
}

extension ImageJobStatus {
    init(_ status: ImageStatus) {
        self =
            switch status {
            case .queued, .inProgress: .pending
            case .completed(let urls): .completed(urls)
            case .failed(let message): .failed(message: message)
            case .rejected(let moderation): .rejected(Rejection(moderation))
            case .canceled: .canceled
            }
    }
}

extension HiggsfieldAPIProvider: ImageProvider {
    public func imageModels() async throws -> [ImageModel] {
        APIImageModel.models
    }

    /// `/estimate` with the exact body; the list price, labelled an estimate, when the server can't answer now.
    public func imageEstimate(_ request: ImageRequest) async throws -> Cost {
        let (endpoint, body) = try APIImageModel.body(request)
        do {
            return .usd(try await mapped { try await client.estimate(endpoint, body) }, isEstimate: false)
        } catch let error as ProviderError where error.isOutage {
            guard let price = APIImageModel.listPrice(of: request) else { throw error }
            return price
        }
    }

    public func submitImages(_ request: ImageRequest, idempotencyKey: UUID) async throws -> [RemoteJob] {
        let (endpoint, body) = try APIImageModel.body(request)
        let submitted = try await mapped { try await client.submit(endpoint, body, idempotencyKey: idempotencyKey) }
        return [
            RemoteJob(
                requestID: submitted.requestID, correlationID: submitted.correlationID,
                statusURL: submitted.statusURL, cancelURL: submitted.cancelURL)
        ]
    }

    public func imageStatus(_ job: RemoteJob) async throws -> ImageJobStatus {
        ImageJobStatus(
            try await mapped { try await client.imageStatus(requestID: job.requestID, statusURL: job.statusURL) })
    }

    public func cancelImages(_ job: RemoteJob) async throws {
        try await cancel(job)
    }
}
