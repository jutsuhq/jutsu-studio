import Foundation
import HiggsfieldCore
import HiggsfieldMCP
import JutsuCore

/// Reference image requests and the account's image model catalog.
enum AccountImages {
    /// The account's models offered, by family of ID fragments: Soul, Grok, Qwen, Nano Banana and GPT Image, as the
    /// issue lists them, then Seedream and MiniMax (catalog of 2026-11-10: Seedream 5.5, MiniMax H3 Image). Each
    /// family offers its newest model first, by the version its IDs name (`version(of:after:)`), as the account lists
    /// older ones before newer (`gpt_image_2` before `gpt_image_2_6`, `grok_image` before `grok_image_2_0`). An
    /// account that lists none of them offers its first models instead.
    static let curated = [
        ["soul"], ["grok"], ["qwen"], ["nano_banana", "nano-banana"], ["gpt_image", "gpt-image"], ["seedream"],
        ["minimax"],
    ]
    /// The newest model of each of the six families the catalog lists, and a second Soul.
    static let maxModels = 7
    /// `generate_image`'s `count`.
    static let variantCounts = [1, 2, 3, 4]
    /// The frame offered for a model that lists none (MiniMax H3 Image): the model's own default, sent as no
    /// `aspect_ratio` at all, as its schema lists none to send.
    static let anyFrame = "auto"

    /// Each model with the frames it lists, taking images to edit when it names a role for them, in the order the
    /// account lists them. As many as its `medias` entry's `max`; where the catalog states none (`models_explore list`
    /// names no `max` for GPT Image 2 or Nano Banana Pro), up to `ImageModel.inputBound`, and `get_cost`, quoted
    /// before anything is sent, refuses more than the model takes. A model that lists no frame (an animation tool, an
    /// upscaler, Image Command) isn't offered, except one of a curated family that takes images, offered with
    /// `anyFrame`; nor is a second model by the same name: Higgsfield lists Soul 2.0 as both `soul_2` and `soul_v2`.
    static func models(_ listed: [AccountImageModel]) -> [ImageModel] {
        var names = Set<String>()
        let usable = listed.filter { model in
            let framed = !model.aspectRatios.isEmpty || (model.imageRole != nil && isCurated(model))
            return framed && names.insert(model.name).inserted
        }
        let ids = picked(usable)
        let offered = ids.isEmpty ? Array(usable.prefix(maxModels)) : usable.filter { ids.contains($0.id) }
        return offered.map { model in
            ImageModel(
                id: model.id, title: model.name, variantCounts: variantCounts,
                aspectRatios: model.aspectRatios.isEmpty ? [anyFrame] : model.aspectRatios,
                input: model.imageRole == nil ? .none : .optional, maxInputs: model.maxImages,
                unstatedInputLimit: model.imageRole != nil && model.maxImages == nil ? ImageModel.inputBound : nil)
        }
    }

    private static func isCurated(_ model: AccountImageModel) -> Bool {
        let id = model.id.lowercased()
        return curated.contains { fragments in fragments.contains(where: id.contains) }
    }

    /// Takes the families' models in turns, newest first within a family, so the account's many Soul models and a
    /// family's older versions don't crowd out the other families.
    private static func picked(_ usable: [AccountImageModel]) -> Set<String> {
        let families = curated.map { fragments in
            usable.enumerated().compactMap { index, model -> (version: [Int], index: Int)? in
                let id = model.id.lowercased()
                guard let fragment = fragments.first(where: id.contains) else { return nil }
                return (version(of: id, after: fragment), index)
            }
            .sorted { first, second in
                first.version == second.version
                    ? first.index < second.index : second.version.lexicographicallyPrecedes(first.version)
            }
            .map { usable[$0.index].id }
        }
        var ids = Set<String>()
        for turn in 0..<(families.map(\.count).max() ?? 0) {
            for family in families where turn < family.count && ids.count < maxModels {
                ids.insert(family[turn])
            }
        }
        return ids
    }

    /// The version an ID names after its family's fragment: its first run of numbers, a leading "v" dropped.
    /// "seedream_5_5" is [5, 5], "seedream_v5_pro" [5], "grok_image_2_0" [2, 0], "nano_banana_pro" none.
    static func version(of id: String, after fragment: String) -> [Int] {
        guard let range = id.range(of: fragment) else { return [] }
        var numbers: [Int] = []
        for part in id[range.upperBound...].split(whereSeparator: { "_-.".contains($0) }) {
            if let number = Int(part.hasPrefix("v") ? part.dropFirst() : part) {
                numbers.append(number)
            } else if !numbers.isEmpty {
                break
            }
        }
        return numbers
    }

    /// - Parameter model: the model as `models_explore` describes it; needed with images, for their role, and with
    ///   `anyFrame`, which a model that lists no frame doesn't get as `aspect_ratio`.
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
            model: request.model, prompt: request.prompt,
            aspectRatio: model?.aspectRatios.isEmpty == true ? nil : request.aspectRatio, count: request.count,
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

    /// With images, asks `models_explore get` for the model's image role first, and with `anyFrame` whether the
    /// model lists frames at all.
    private func accountImageRequest(_ request: ImageRequest) async throws -> AccountImageRequest {
        guard !request.inputImages.isEmpty || request.aspectRatio == AccountImages.anyFrame else {
            return try AccountImages.request(request, model: nil)
        }
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
