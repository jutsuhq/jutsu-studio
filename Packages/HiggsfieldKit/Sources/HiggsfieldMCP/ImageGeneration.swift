import Foundation
import HiggsfieldCore

/// The `params` of one `generate_image` call, as the catalog snapshot of 2026-10-15 states its `inputSchema`:
/// `model` (required), `prompt`, `aspect_ratio`, `count` 1–4, `medias: [{role, value}]` with the role the model's
/// `medias[].roles` names, `get_cost` and `use_unlim`. `use_unlim` is always sent, `false`: left out, the server
/// submits nothing for a model the plan's allowance covers and answers with `unlim_choice`, a question for the user.
public struct AccountImageRequest: Sendable, Hashable {
    /// An ID from `models_explore {type: "image"}`.
    public var model: String
    public var prompt: String
    /// Left out for the model's default.
    public var aspectRatio: String?
    /// Variants, 1–4.
    public var count: Int
    /// `media_id`s of images to edit.
    public var imageIDs: [String]
    /// The role the images go in under: the model's own (`AccountImageModel.imageRole`).
    public var imageRole: String

    public init(
        model: String, prompt: String, aspectRatio: String?, count: Int, imageIDs: [String] = [],
        imageRole: String = AccountImageModel.imageRoles[0]
    ) {
        self.model = model
        self.prompt = prompt
        self.aspectRatio = aspectRatio
        self.count = count
        self.imageIDs = imageIDs
        self.imageRole = imageRole
    }

    func arguments(getCost: Bool) -> [String: JSONValue] {
        var params: [String: JSONValue] = [
            ToolKey.model: .string(model), ToolKey.prompt: .string(prompt), ToolKey.count: .number(Double(count)),
            ToolKey.useUnlim: false,
        ]
        if let aspectRatio { params[ToolKey.aspectRatio] = .string(aspectRatio) }
        if !imageIDs.isEmpty {
            params[ToolKey.medias] = .array(
                imageIDs.map { [ToolKey.role: .string(imageRole), ToolKey.value: .string($0)] })
        }
        if getCost { params[ToolKey.getCost] = true }
        return [ToolKey.params: .object(params)]
    }
}

/// An image model as `models_explore {action: "list", type: "image"}` (or `get`) names it. The snapshot of 2026-10-15
/// shows each item with `id`, `name`, `aspect_ratios` and `medias: [{roles, max}]`: Soul 2 and GPT Image 2 take
/// images as `image` (Soul 2 at most one), Nano Banana as `image_references`, and Soul Cast none.
public struct AccountImageModel: Sendable, Hashable {
    public var id: String
    public var name: String
    /// The frames the model takes, as "W:H" (some list "auto" too).
    public var aspectRatios: [String]
    /// The `medias` role for an image to edit; `nil` when the model takes none.
    public var imageRole: String?
    /// The most images the model takes; `nil` when the answer doesn't say.
    public var maxImages: Int?

    public init(
        id: String, name: String, aspectRatios: [String] = [], imageRole: String? = nil, maxImages: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.aspectRatios = aspectRatios
        self.imageRole = imageRole
        self.maxImages = maxImages
    }

    static let nameKeys = [ToolKey.name, "title", ToolKey.displayName]
    /// The roles an image to edit goes in under, in the order they are preferred.
    public static let imageRoles = ["image", "image_references"]

    init?(item: JSONValue) {
        guard let id = UnlimitedAllowance.modelID(of: item), !id.isEmpty else { return nil }
        self.id = id
        name = Self.nameKeys.lazy.compactMap { item[$0]?.stringValue }.first ?? id
        aspectRatios = (item["aspect_ratios"]?.arrayValue ?? []).compactMap(\.stringValue)
        let media = (item[ToolKey.medias]?.arrayValue ?? []).first { entry in
            (entry["roles"]?.arrayValue ?? []).contains { Self.imageRoles.contains($0.stringValue ?? "") }
        }
        let roles = (media?["roles"]?.arrayValue ?? []).compactMap(\.stringValue)
        imageRole = Self.imageRoles.first(where: roles.contains)
        maxImages = media?["max"]?.numberValue.flatMap(ModelLimits.count)
    }
}

extension HiggsfieldAccount {
    /// `models_explore` `list` pages read for the image models, at most.
    static let maxImageModelPages = 3

    /// The account's image models in the server's order; `nil` when the account has no `models_explore`.
    public func imageModels() async throws -> [AccountImageModel]? {
        guard try await lookUp(.modelsExplore, recheckingAfter: Self.optionalToolRecheck) != nil else { return nil }
        var arguments = Self.modelList(type: "image")
        var models: [AccountImageModel] = []
        var seenTokens: Set<String> = []
        for _ in 0..<Self.maxImageModelPages {
            let (result, next) = try await exploreModels(arguments)
            guard !result.isError, let page = result.value else { break }
            for model in UnlimitedAllowance.items(in: page).compactMap(AccountImageModel.init(item:))
            where !models.contains(where: { $0.id == model.id }) {
                models.append(model)
            }
            guard let next, seenTokens.insert(next).inserted else { break }
            arguments[ToolKey.after] = .string(next)
        }
        return models
    }

    /// One image model by its ID (`models_explore get`); `nil` when the account has no `models_explore` or the
    /// server doesn't describe the model.
    public func imageModel(id: String) async throws -> AccountImageModel? {
        guard try await lookUp(.modelsExplore, recheckingAfter: Self.optionalToolRecheck) != nil else { return nil }
        let (result, _) = try await exploreModels([
            ToolKey.action: .string(ToolKey.get), ToolKey.modelID: .string(id),
        ])
        guard !result.isError, let answer = result.value else { return nil }
        return AccountImageModel(item: answer)
    }

    /// Throws `HiggsfieldError.toolUnavailable` when the account has no `generate_image`.
    public func checkImageTool() async throws {
        guard try await lookUp(.generateImage, recheckingAfter: Self.optionalToolRecheck) != nil else {
            throw HiggsfieldError.toolUnavailable(ToolRole.generateImage.rawValue)
        }
    }

    /// The price in credits, read like `generate_video`'s quote; `nil` when the answer names none. Submits nothing.
    public func cost(of request: AccountImageRequest) async throws -> Double? {
        Self.credits(in: try await call(.generateImage, request.arguments(getCost: true))[ToolKey.cost])
    }

    /// Not idempotent, like `generate(_:)`. Every `results[].id` is a job to poll: one per variant, or one job for
    /// all of them. A reply that names no job and gives no reason throws `.server(status: 200)`, as it may have
    /// started one.
    public func generateImages(_ request: AccountImageRequest) async throws -> [Generation] {
        let value = try await call(.generateImage, request.arguments(getCost: false))
        let ids = (value[ToolKey.results]?.arrayValue ?? []).compactMap { $0[ToolKey.id]?.stringValue }
        guard !ids.isEmpty else { throw Self.noJobStarted(value) }
        let requestID = value[ToolKey.requestID]?.stringValue
        let credits = Self.credits(in: value[ToolKey.cost])
        // The answer's cost is the whole request's; it is kept on the first job only, so it isn't counted twice.
        return ids.enumerated().map { index, id in
            Generation(id: id, requestID: requestID, credits: index == 0 ? credits : nil)
        }
    }

    /// `job_status` of an image job: `generation.results.rawUrl`, as for a video (the tool's `outputSchema`
    /// describes one `results` object). Each variant of a request is its own job, so a job holds one image.
    public func imageStatus(of generationID: String) async throws -> ImageStatus {
        let value = try await call(.status, [ToolKey.jobID: .string(generationID)])
        // As for a video: a stated error ends the job, an answer with neither is polled again.
        guard let generation = value[ToolKey.generation] else {
            throw value[ToolKey.error] == nil
                ? HiggsfieldError.server(status: 200)
                : HiggsfieldError.validation(field: nil, message: "Unexpected result from the job_status tool")
        }
        return Self.imageStatus(of: generation, error: value[ToolKey.error])
    }

    static func imageStatus(of generation: JSONValue, error: JSONValue? = nil) -> ImageStatus {
        switch status(of: generation, error: error) {
        case .queued?: .queued
        case .inProgress?: .inProgress
        case .completed(let url)?: .completed(imageURLs: [url])
        case .failed(let message)?: .failed(message: message)
        case .rejected(let moderation)?: .rejected(moderation)
        case .canceled?: .canceled
        case nil: .failed(message: "Completed without an image URL.")
        }
    }
}
