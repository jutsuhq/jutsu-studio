import Foundation

// Bodies of the image endpoints, from each model's page at docs.higgsfield.ai/docs/models (checked 2026-10-15).
// Every field left out takes the server's documented default; the API rejects `null`, so nothing is sent as one.

/// `higgsfield-ai/soul/v2/standard`: text to image, 720p unless asked otherwise.
public struct SoulImageRequest: Encodable, Sendable, Hashable {
    public var prompt: String
    /// One of 9:16, 16:9, 4:3, 3:4, 1:1, 2:3, 3:2; the server's default is 1:1.
    public var aspectRatio: String
    /// 1 or 4 only.
    public var batchSize: Int

    public init(prompt: String, aspectRatio: String, batchSize: Int) {
        self.prompt = prompt
        self.aspectRatio = aspectRatio
        self.batchSize = batchSize
    }

    enum CodingKeys: String, CodingKey {
        case prompt
        case aspectRatio = "aspect_ratio"
        case batchSize = "batch_size"
    }
}

/// `xai/grok-imagine-image-2.0`: one image, generated from the prompt or, with `image_urls`, an edit of up to 10
/// images. Quality (medium) and resolution (1k) stay at the server's defaults.
public struct GrokImageRequest: Encodable, Sendable, Hashable {
    public var prompt: String
    /// `auto`, 1:1, 1:2, 2:1, 3:2, 2:3, 4:3, 3:4, 16:9 or 9:16.
    public var aspectRatio: String
    /// Left out when empty: the request then generates rather than edits.
    public var imageURLs: [URL]

    public init(prompt: String, aspectRatio: String, imageURLs: [URL] = []) {
        self.prompt = prompt
        self.aspectRatio = aspectRatio
        self.imageURLs = imageURLs
    }

    enum CodingKeys: String, CodingKey {
        case prompt
        case aspectRatio = "aspect_ratio"
        case imageURLs = "image_urls"
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(prompt, forKey: .prompt)
        try container.encode(aspectRatio, forKey: .aspectRatio)
        if !imageURLs.isEmpty { try container.encode(imageURLs, forKey: .imageURLs) }
    }
}

/// `alibaba/qwen-image-3/edit`: one edited image from 1–3 input images, 1k.
public struct QwenEditRequest: Encodable, Sendable, Hashable {
    /// At least one non-blank character.
    public var prompt: String
    public var imageURLs: [URL]
    /// 1:1, 2:3, 3:2, 3:4, 4:3, 7:9, 9:7, 9:16, 16:9 or 21:9.
    public var aspectRatio: String

    public init(prompt: String, imageURLs: [URL], aspectRatio: String) {
        self.prompt = prompt
        self.imageURLs = imageURLs
        self.aspectRatio = aspectRatio
    }

    enum CodingKeys: String, CodingKey {
        case prompt
        case imageURLs = "image_urls"
        case aspectRatio = "aspect_ratio"
    }
}
