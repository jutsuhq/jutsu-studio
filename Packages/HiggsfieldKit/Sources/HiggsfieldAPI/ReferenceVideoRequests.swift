import Foundation

/// Body of Kling O3's `video-edit`: the one source video (3–15.5 s) changed as the prompt (required) says, with up
/// to four images. No `duration`: the output follows the source. `elements` is left out.
public struct KlingVideoEditRequest: Encodable, Sendable, Hashable {
    public var prompt: String
    /// The one source video (`video_urls`, exactly one item).
    public var videoURL: URL
    /// 0–4, in order; left out when empty.
    public var imageURLs: [URL]
    /// `mode`: `std` or `pro` (server default `pro`); `4k` isn't sent.
    public var quality: KlingVideoReferenceRequest.Quality

    public init(prompt: String, videoURL: URL, imageURLs: [URL] = [], quality: KlingVideoReferenceRequest.Quality) {
        self.prompt = prompt
        self.videoURL = videoURL
        self.imageURLs = imageURLs
        self.quality = quality
    }

    enum CodingKeys: String, CodingKey {
        case prompt
        case videoURLs = "video_urls"
        case imageURLs = "image_urls"
        case quality = "mode"
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(prompt, forKey: .prompt)
        try container.encode([videoURL], forKey: .videoURLs)
        if !imageURLs.isEmpty { try container.encode(imageURLs, forKey: .imageURLs) }
        try container.encode(quality.rawValue, forKey: .quality)
    }
}

/// Body of the reference-to-video endpoints that take a prompt (required), reference videos and images, a length
/// and a resolution: Wan 3.0 and 3.0 Prime, Wan 2.7, Cinema Studio 4.0 and MiniMax H3. Their schemas differ only in
/// the optional fields, so `aspect_ratio`, `generate_audio` and Cinema Studio's creative controls are sent only when
/// set; empty arrays are left out (Wan 2.7 refuses an empty one). Seeds, negative prompts, documents, audio
/// references and MiniMax's `aigc_watermark` aren't sent.
public struct ReferenceToVideoRequest: Encodable, Sendable, Hashable {
    public var prompt: String
    /// The source video, the one item of `video_urls`.
    public var videoURL: URL
    /// In order; left out when empty.
    public var imageURLs: [URL]
    /// Whole seconds of the generated clip.
    public var duration: Int
    /// "480p", "720p", "1080p" or MiniMax H3's "2K", from the model's own list.
    public var resolution: String
    /// One of the endpoint's frames; left out for the server's default.
    public var aspectRatio: String?
    /// Left out for a model without a soundtrack (Wan 2.7).
    // swiftlint:disable:next discouraged_optional_boolean
    public var generateAudio: Bool?
    /// Cinema Studio's creative controls by their field (`camera_model`, `genre`, …), each one of the schema's
    /// values; empty for the other models, and for the controls the director picks.
    public var controls: [String: String]

    public init(
        prompt: String, videoURL: URL, imageURLs: [URL] = [], duration: Int, resolution: String,
        // swiftlint:disable:next discouraged_optional_boolean
        aspectRatio: String? = nil, generateAudio: Bool? = nil, controls: [String: String] = [:]
    ) {
        self.prompt = prompt
        self.videoURL = videoURL
        self.imageURLs = imageURLs
        self.duration = duration
        self.resolution = resolution
        self.aspectRatio = aspectRatio
        self.generateAudio = generateAudio
        self.controls = controls
    }

    enum CodingKeys: String, CodingKey {
        case prompt
        case videoURLs = "video_urls"
        case imageURLs = "image_urls"
        case duration
        case resolution
        case aspectRatio = "aspect_ratio"
        case generateAudio = "generate_audio"
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(prompt, forKey: .prompt)
        try container.encode([videoURL], forKey: .videoURLs)
        if !imageURLs.isEmpty { try container.encode(imageURLs, forKey: .imageURLs) }
        try container.encode(duration, forKey: .duration)
        try container.encode(resolution, forKey: .resolution)
        try container.encodeIfPresent(aspectRatio, forKey: .aspectRatio)
        try container.encodeIfPresent(generateAudio, forKey: .generateAudio)
        var fields = encoder.container(keyedBy: FieldKey.self)
        for (field, value) in controls { try fields.encode(value, forKey: FieldKey(field)) }
    }
}

/// A body field named at run time.
struct FieldKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }

    init(_ name: String) { stringValue = name }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

/// Body of Kling 4.0's endpoints (open.higgsfield.ai, read 2026-10-28), whose schemas share these fields:
/// `text-to-video` (`prompt`*, `aspect_ratio` 21:9, 16:9, 9:16 or 1:1, default 16:9), `image-to-video` (`image_url`*
/// the start frame, `end_image_url`, `prompt` optional, no `aspect_ratio`: the frames set it), `reference-to-video`
/// (`prompt`*, `image_urls` ≤10 and `video_urls` ≤5, at least one of them non-empty, named `@image_1`… and
/// `@video_1`… in the prompt) and `video-edit` (`prompt`*, `video_url`* the clip to edit, with the same references; the
/// clip is `@video_1`). Each takes `duration` 3–30 (the output's, also for an edit) and `resolution` 720p or 1080p;
/// the reference and edit endpoints add `adaptive` to the frames, their default. Unset fields and empty arrays are left
/// out. `elements` (Kling element IDs) and image-to-video's middle frames aren't sent.
public struct Kling4Request: Encodable, Sendable, Hashable {
    /// Left out when blank, which only `image-to-video` allows.
    public var prompt: String
    /// `image-to-video`'s start frame.
    public var imageURL: URL?
    /// `image-to-video`'s end frame.
    public var endImageURL: URL?
    /// `video-edit`'s clip.
    public var videoURL: URL?
    /// References, in order.
    public var imageURLs: [URL]
    /// Reference videos, in order: the source of a clip made from references.
    public var videoURLs: [URL]
    /// Whole seconds, 3–30.
    public var duration: Int
    /// "720p" or "1080p".
    public var resolution: String
    /// One of the endpoint's frames, or `adaptive`; left out for the server's default.
    public var aspectRatio: String?

    public init(
        prompt: String, imageURL: URL? = nil, endImageURL: URL? = nil, videoURL: URL? = nil, imageURLs: [URL] = [],
        videoURLs: [URL] = [], duration: Int, resolution: String, aspectRatio: String? = nil
    ) {
        self.prompt = prompt
        self.imageURL = imageURL
        self.endImageURL = endImageURL
        self.videoURL = videoURL
        self.imageURLs = imageURLs
        self.videoURLs = videoURLs
        self.duration = duration
        self.resolution = resolution
        self.aspectRatio = aspectRatio
    }

    /// `aspect_ratio` of the reference and edit endpoints that follows the references.
    public static let adaptive = "adaptive"

    enum CodingKeys: String, CodingKey {
        case prompt
        case imageURL = "image_url"
        case endImageURL = "end_image_url"
        case videoURL = "video_url"
        case imageURLs = "image_urls"
        case videoURLs = "video_urls"
        case duration
        case resolution
        case aspectRatio = "aspect_ratio"
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        // A blank prompt is none, as `Validation` reads it; the schemas refuse an empty one.
        if !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try container.encode(prompt, forKey: .prompt)
        }
        try container.encodeIfPresent(imageURL, forKey: .imageURL)
        try container.encodeIfPresent(endImageURL, forKey: .endImageURL)
        try container.encodeIfPresent(videoURL, forKey: .videoURL)
        if !imageURLs.isEmpty { try container.encode(imageURLs, forKey: .imageURLs) }
        if !videoURLs.isEmpty { try container.encode(videoURLs, forKey: .videoURLs) }
        try container.encode(duration, forKey: .duration)
        try container.encode(resolution, forKey: .resolution)
        try container.encodeIfPresent(aspectRatio, forKey: .aspectRatio)
    }
}
