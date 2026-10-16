import Foundation
import HiggsfieldCore
import HiggsfieldMCP
import JutsuCore

/// Reference image requests and the account's image model catalog.
enum AccountImages {
    /// The account's models offered, by family of ID fragments: Soul, Grok, Qwen, Nano Banana and GPT Image, as the
    /// issue lists them. An account that lists none of them offers its first models instead.
    static let curated = [["soul"], ["grok"], ["qwen"], ["nano_banana", "nano-banana"], ["gpt_image", "gpt-image"]]
    static let maxModels = 6
    /// `generate_image`'s `count`.
    static let variantCounts = [1, 2, 3, 4]

    /// Each model with the frames it lists, taking an image to edit when it names a role for one, in the order the
    /// account lists them. A model that lists no frame (an animation tool) isn't offered, nor a second model by the
    /// same name: Higgsfield lists Soul 2.0 as both `soul_2` and `soul_v2`.
    static func models(_ listed: [AccountImageModel]) -> [ImageModel] {
        var names = Set<String>()
        let usable = listed.filter { !$0.aspectRatios.isEmpty && names.insert($0.name).inserted }
        let ids = picked(usable)
        let offered = ids.isEmpty ? Array(usable.prefix(maxModels)) : usable.filter { ids.contains($0.id) }
        return offered.map { model in
            ImageModel(
                id: model.id, title: model.name, variantCounts: variantCounts, aspectRatios: model.aspectRatios,
                input: model.imageRole == nil ? .none : .optional)
        }
    }

    /// Takes the families' models in turns, so the account's many Soul models don't crowd out the other families.
    private static func picked(_ usable: [AccountImageModel]) -> Set<String> {
        let families = curated.map { fragments in
            usable.filter { model in fragments.contains { model.id.lowercased().contains($0) } }
        }
        var ids = Set<String>()
        for turn in 0..<(families.map(\.count).max() ?? 0) {
            for family in families where turn < family.count && ids.count < maxModels {
                ids.insert(family[turn].id)
            }
        }
        return ids
    }

    /// - Parameter model: the model as `models_explore` describes it; needed only with images, for their role.
    static func request(_ request: ImageRequest, model: AccountImageModel?) throws -> AccountImageRequest {
        guard variantCounts.contains(request.count) else {
            throw ProviderError.validation(
                field: "count", message: String(localized: "Make 1 to 4 images.", bundle: .module))
        }
        let ids = try request.inputImages.map { asset in
            guard let id = asset.id else {
                throw ProviderError.validation(
                    field: nil,
                    message: String(localized: "Unexpected result from the media_upload tool", bundle: .module))
            }
            return id
        }
        var accountRequest = AccountImageRequest(
            model: request.model, prompt: request.prompt, aspectRatio: request.aspectRatio, count: request.count,
            imageIDs: ids)
        guard !ids.isEmpty else { return accountRequest }
        guard let role = model?.imageRole else {
            throw ProviderError.validation(
                field: nil, message: String(localized: "This model doesn't take an image.", bundle: .module))
        }
        if let maxImages = model?.maxImages, ids.count > maxImages {
            throw ProviderError.validation(
                field: nil, message: String(localized: "This model takes at most \(maxImages) images.", bundle: .module)
            )
        }
        accountRequest.imageRole = role
        return accountRequest
    }
}

extension HiggsfieldMCPProvider: ImageProvider {
    public static var offersImageGeneration: Bool { true }

    public func imageModels() async throws -> [ImageModel] {
        try await mapped { try await account.checkImageTool() }
        return AccountImages.models(try await mapped { try await account.imageModels() } ?? [])
    }

    /// `get_cost` for one image times `count`, exact; `Cost.unknownCredits` when the answer names no price.
    /// `get_cost` ignores `count`: on 2026-10-15 GPT Image 2 quoted 0.5 credits for 1, 2 and 4 images alike, and
    /// each image of a request was billed 0.5.
    public func imageEstimate(_ request: ImageRequest) async throws -> Cost {
        let accountRequest = try await accountImageRequest(request)
        let credits = try await mapped { try await account.cost(of: accountRequest) }
        return try credits.map { try .serverCredits($0 * Double(request.count)) } ?? .unknownCredits
    }

    /// Not idempotent: `generate_image` takes no key, like `generate_video`.
    public func submitImages(_ request: ImageRequest, idempotencyKey: UUID) async throws -> [RemoteJob] {
        let accountRequest = try await accountImageRequest(request)
        let generations = try await mapped { try await account.generateImages(accountRequest) }
        return generations.map { RemoteJob(requestID: $0.id, correlationID: $0.requestID) }
    }

    /// With images, asks `models_explore get` for the model's image role first.
    private func accountImageRequest(_ request: ImageRequest) async throws -> AccountImageRequest {
        guard !request.inputImages.isEmpty else { return try AccountImages.request(request, model: nil) }
        let model = try await mapped { try await account.imageModel(id: request.model) }
        return try AccountImages.request(request, model: model)
    }

    public func imageStatus(_ job: RemoteJob) async throws -> ImageJobStatus {
        return ImageJobStatus(try await mapped { try await account.imageStatus(of: job.requestID) })
    }

    public func cancelImages(_ job: RemoteJob) async throws {
        throw Self.notCancellable
    }

}
