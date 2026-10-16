import Foundation

/// An image model the connection offers for making reference images.
public struct ImageModel: Codable, Sendable, Hashable, Identifiable {
    /// What the input image of an edit may be.
    public enum Input: Codable, Sendable, Hashable {
        /// Text to image only.
        case none
        /// Generates from the prompt alone, or edits an image when one is given.
        case optional
        /// Edits only: an image is required.
        case required
    }

    /// The REST endpoint ID, or the account's model ID.
    public var id: String
    public var title: String
    /// How many images one request can make, ascending; `[1]` when it makes one.
    public var variantCounts: [Int]
    /// The frames the model takes, as "W:H".
    public var aspectRatios: [String]
    public var input: Input
    /// The public list price of one image, labelled as an estimate; `nil` when none is known.
    public var listPrice: Cost?

    public init(
        id: String, title: String, variantCounts: [Int] = [1], aspectRatios: [String], input: Input = .none,
        listPrice: Cost? = nil
    ) {
        self.id = id
        self.title = title
        self.variantCounts = variantCounts.isEmpty ? [1] : variantCounts
        self.aspectRatios = aspectRatios
        self.input = input
        self.listPrice = listPrice
    }

    /// The ratio of `aspectRatios` closest to `width` × `height`; the first one when the size is unusable.
    public func nearestAspectRatio(width: Int, height: Int) -> String? {
        guard width > 0, height > 0 else { return aspectRatios.first }
        let target = log(Double(width) / Double(height))
        return aspectRatios.compactMap { ratio in Self.widthOverHeight(ratio).map { (ratio, abs(log($0) - target)) } }
            .min { $0.1 < $1.1 }?.0 ?? aspectRatios.first
    }

    /// "16:9" as 1.78; `nil` for "auto" or anything that isn't two positive numbers.
    public static func widthOverHeight(_ ratio: String) -> Double? {
        let sides = ratio.split(separator: ":").compactMap { Double($0) }
        guard sides.count == 2, sides[0] > 0, sides[1] > 0 else { return nil }
        return sides[0] / sides[1]
    }
}

/// One request for reference images.
public struct ImageRequest: Codable, Sendable, Hashable {
    public var model: String
    public var prompt: String
    public var aspectRatio: String
    /// Images the request makes, one of the model's `variantCounts`.
    public var count: Int
    /// The uploaded images to edit; empty to generate from the prompt.
    public var inputImages: [RemoteAsset]

    public init(model: String, prompt: String, aspectRatio: String, count: Int, inputImages: [RemoteAsset] = []) {
        self.model = model
        self.prompt = prompt
        self.aspectRatio = aspectRatio
        self.count = count
        self.inputImages = inputImages
    }
}

/// Where a submitted image job is.
public enum ImageJobStatus: Sendable, Hashable {
    case pending
    /// The images, never empty.
    case completed([URL])
    case failed(message: String?)
    case rejected(Rejection)
    case canceled
}

/// Makes reference images: a small service beside `GenerationProvider`, not one of its modes. Its jobs never enter
/// the job engine or the Queue; whoever runs them polls `imageStatus` and counts their price toward the daily cap
/// (`ImageCharge`).
public protocol ImageProvider: Sendable {
    var kind: ProviderKind { get }
    /// The account or key the jobs belong to (`GenerationProvider.owner`), so they are followed again only there.
    var owner: String? { get }
    /// The curated models of this connection; empty when it can't make images.
    func imageModels() async throws -> [ImageModel]
    /// The price of the whole request, the provider's own quote when it gives one.
    func imageEstimate(_ request: ImageRequest) async throws -> Cost
    /// The input of an edit.
    func upload(_ file: PreparedFile) async throws -> RemoteAsset
    /// One job per request, or several when the provider makes a job per image.
    func submitImages(_ request: ImageRequest, idempotencyKey: UUID) async throws -> [RemoteJob]
    func imageStatus(_ job: RemoteJob) async throws -> ImageJobStatus
    /// Throws when the job can't be cancelled any more.
    func cancelImages(_ job: RemoteJob) async throws
}
