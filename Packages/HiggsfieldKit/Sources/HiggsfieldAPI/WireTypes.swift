import Foundation
import HiggsfieldCore

/// Where to PUT a file and the URL the API reads it from afterwards.
public struct UploadTarget: Decodable, Sendable, Hashable {
    /// Presigned, valid about an hour. Never log it.
    public var uploadURL: URL
    public var publicURL: URL
    /// Headers the presigned signature covers, e.g. `x-amz-tagging`; the PUT fails without them.
    public var uploadHeaders: [String: String]?

    enum CodingKeys: String, CodingKey {
        case uploadURL = "upload_url"
        case publicURL = "public_url"
        case uploadHeaders = "upload_headers"
    }
}

struct UploadURLRequest: Encodable, Sendable, Hashable {
    var contentType: String

    enum CodingKeys: String, CodingKey {
        case contentType = "content_type"
    }
}

/// The model endpoints the app submits to, by their endpoint ID. Each takes its own body: `GenerationRequest` for
/// Genjutsu, `SeedanceRequest`, `SeedanceVideoRequest` for Seedance's Edit and Extend, `SeedanceFramesRequest` for
/// its image-to-video, and `KlingMotionRequest`; the image models `SoulImageRequest`, `GrokImageRequest` and
/// `QwenEditRequest` (ImageRequests.swift).
public enum ModelEndpoint: String, Sendable, CaseIterable {
    case motionTransfer = "higgsfield/genjutsu/motion-transfer/v1.0"
    case restyle = "higgsfield/genjutsu/restyle/v1.0"
    case objectSwap = "higgsfield/genjutsu/object-swap/v1.0"
    case seedanceTextToVideo = "bytedance/seedance-2.5/text-to-video"
    case seedanceReferenceToVideo = "bytedance/seedance-2.5/reference-to-video"
    case seedanceImageToVideo = "bytedance/seedance-2.5/image-to-video"
    case seedanceVideoEdit = "bytedance/seedance-2.5/video-edit"
    case seedanceVideoExtend = "bytedance/seedance-2.5/video-extend"
    /// Kling's quality is the endpoint, not a field.
    case klingMotionControlStandard = "kling-video/v3/motion-control/std"
    case klingMotionControlPro = "kling-video/v3/motion-control/pro"
    /// Kling O3 from one reference video; its quality is the `mode` field.
    case klingO3VideoReference = "kling-video/o3/video-reference"
    /// Kling O3's Edit; its quality is the `mode` field.
    case klingO3VideoEdit = "kling-video/o3/video-edit"
    /// Kling 2.6 Motion Control, the same body as 3.0's (`KlingMotionRequest`).
    case kling26MotionControlStandard = "kling-video/motion-control/std"
    case kling26MotionControlPro = "kling-video/motion-control/pro"
    /// `ReferenceToVideoRequest`.
    case wan30ReferenceToVideo = "alibaba/wan-3.0/reference-to-video"
    case wan30PrimeReferenceToVideo = "alibaba/wan-3.0-prime/reference-to-video"
    case wan27ReferenceToVideo = "wan/v2.7/reference-to-video"
    case cinemaStudio4 = "higgsfield/cinema-studio/4.0"
    case minimaxH3ReferenceToVideo = "minimax/h3/reference-to-video"
    /// Kling 4.0's four endpoints, one body (`Kling4Request`).
    case kling4TextToVideo = "kling-video/v4.0/text-to-video"
    case kling4ImageToVideo = "kling-video/v4.0/image-to-video"
    case kling4ReferenceToVideo = "kling-video/v4.0/reference-to-video"
    case kling4VideoEdit = "kling-video/v4.0/video-edit"
    case soulV2 = "higgsfield-ai/soul/v2/standard"
    /// Generates without `image_urls`, edits with them.
    case grokImage2 = "xai/grok-imagine-image-2.0"
    case qwenImage3Edit = "alibaba/qwen-image-3/edit"
}

/// Body of all three Genjutsu workflows. The API rejects `null`, so `prompt` and `image_urls` are always
/// sent, and `preset_id` is omitted (not null) outside restyle, whose schema forbids extra keys.
public struct GenerationRequest: Encodable, Sendable, Hashable {
    public var videoURL: URL
    public var imageURLs: [URL]
    public var prompt: String
    /// "480p", "720p" or "1080p".
    public var resolution: String
    /// Restyle only, where it is required.
    public var presetID: UUID?

    public init(videoURL: URL, imageURLs: [URL], prompt: String, resolution: String, presetID: UUID? = nil) {
        self.videoURL = videoURL
        self.imageURLs = imageURLs
        self.prompt = prompt
        self.resolution = resolution
        self.presetID = presetID
    }

    enum CodingKeys: String, CodingKey {
        case videoURL = "video_url"
        case imageURLs = "image_urls"
        case prompt
        case resolution
        case presetID = "preset_id"
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(videoURL, forKey: .videoURL)
        try container.encode(imageURLs, forKey: .imageURLs)
        try container.encode(prompt, forKey: .prompt)
        try container.encode(resolution, forKey: .resolution)
        try container.encodeIfPresent(presetID?.uuidString.lowercased(), forKey: .presetID)
    }
}

/// Body of Seedance 2.5 `text-to-video` (no media) and `reference-to-video`. Both schemas forbid unknown keys and
/// reject `null`, an empty prompt and empty arrays, so those are omitted rather than sent empty. Seedance has no
/// `mode` field: the endpoint is the mode.
public struct SeedanceRequest: Encodable, Sendable, Hashable {
    /// Required by `text-to-video`.
    public var prompt: String
    public var imageURLs: [URL]
    /// The source clip first; `reference-to-video` only.
    public var videoURLs: [URL]
    /// Whole seconds, 4–30.
    public var duration: Int
    /// "480p", "720p" or "1080p".
    public var resolution: String
    /// "16:9", "9:16", …; the server's default (16:9) when `nil`.
    public var aspectRatio: String?
    public var generateAudio: Bool
    /// `bitrate_mode`, "standard" or "high"; the server's default (`high`) when `nil`.
    public var bitrateMode: String?

    public init(
        prompt: String, imageURLs: [URL] = [], videoURLs: [URL] = [], duration: Int, resolution: String,
        aspectRatio: String? = nil, generateAudio: Bool, bitrateMode: String? = nil
    ) {
        self.prompt = prompt
        self.imageURLs = imageURLs
        self.videoURLs = videoURLs
        self.duration = duration
        self.resolution = resolution
        self.aspectRatio = aspectRatio
        self.generateAudio = generateAudio
        self.bitrateMode = bitrateMode
    }

    enum CodingKeys: String, CodingKey {
        case prompt
        case imageURLs = "image_urls"
        case videoURLs = "video_urls"
        case duration
        case resolution
        case aspectRatio = "aspect_ratio"
        case generateAudio = "generate_audio"
        case bitrateMode = "bitrate_mode"
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if !prompt.isEmpty { try container.encode(prompt, forKey: .prompt) }
        if !imageURLs.isEmpty { try container.encode(imageURLs, forKey: .imageURLs) }
        if !videoURLs.isEmpty { try container.encode(videoURLs, forKey: .videoURLs) }
        try container.encode(duration, forKey: .duration)
        try container.encode(resolution, forKey: .resolution)
        try container.encodeIfPresent(aspectRatio, forKey: .aspectRatio)
        try container.encode(generateAudio, forKey: .generateAudio)
        try container.encodeIfPresent(bitrateMode, forKey: .bitrateMode)
    }
}

/// Body of Seedance 2.5 `image-to-video`: the clip starts on `image_url` and, when given, ends on `end_image_url`.
/// The output's frame follows the start image, so there is no `aspect_ratio`. Like the other Seedance schemas it
/// forbids unknown keys and rejects `null` and an empty prompt, so unset fields are omitted.
public struct SeedanceFramesRequest: Encodable, Sendable, Hashable {
    /// Optional here; at least one character when sent.
    public var prompt: String
    /// The start frame.
    public var imageURL: URL
    /// The end frame.
    public var endImageURL: URL?
    /// Whole seconds, 4–30.
    public var duration: Int
    /// "480p", "720p" or "1080p".
    public var resolution: String
    public var generateAudio: Bool
    /// `bitrate_mode`, "standard" or "high"; the server's default (`high`) when `nil`.
    public var bitrateMode: String?

    public init(
        prompt: String, imageURL: URL, endImageURL: URL? = nil, duration: Int, resolution: String,
        generateAudio: Bool, bitrateMode: String? = nil
    ) {
        self.prompt = prompt
        self.imageURL = imageURL
        self.endImageURL = endImageURL
        self.duration = duration
        self.resolution = resolution
        self.generateAudio = generateAudio
        self.bitrateMode = bitrateMode
    }

    enum CodingKeys: String, CodingKey {
        case prompt
        case imageURL = "image_url"
        case endImageURL = "end_image_url"
        case duration
        case resolution
        case generateAudio = "generate_audio"
        case bitrateMode = "bitrate_mode"
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if !prompt.isEmpty { try container.encode(prompt, forKey: .prompt) }
        try container.encode(imageURL, forKey: .imageURL)
        try container.encodeIfPresent(endImageURL, forKey: .endImageURL)
        try container.encode(duration, forKey: .duration)
        try container.encode(resolution, forKey: .resolution)
        try container.encode(generateAudio, forKey: .generateAudio)
        try container.encodeIfPresent(bitrateMode, forKey: .bitrateMode)
    }
}

/// Body of Seedance 2.5 `video-edit` and `video-extend`. Like the other Seedance schemas they forbid unknown keys and
/// reject `null` and empty arrays, so unset fields are omitted. `video-edit` takes no `duration` (the output follows
/// the source); for `video-extend` it is the length of the new part. `video_urls` and `audio_urls` aren't sent.
public struct SeedanceVideoRequest: Encodable, Sendable, Hashable {
    /// Required by both, at least one character.
    public var prompt: String
    /// The clip to edit or extend.
    public var videoURL: URL
    public var imageURLs: [URL]
    /// Whole seconds, 4–30; `video-extend` only.
    public var duration: Int?
    /// "480p", "720p" or "1080p".
    public var resolution: String
    public var generateAudio: Bool
    /// `bitrate_mode`, "standard" or "high"; the server's default (`high`) when `nil`.
    public var bitrateMode: String?

    public init(
        prompt: String, videoURL: URL, imageURLs: [URL] = [], duration: Int? = nil, resolution: String,
        generateAudio: Bool, bitrateMode: String? = nil
    ) {
        self.prompt = prompt
        self.videoURL = videoURL
        self.imageURLs = imageURLs
        self.duration = duration
        self.resolution = resolution
        self.generateAudio = generateAudio
        self.bitrateMode = bitrateMode
    }

    enum CodingKeys: String, CodingKey {
        case prompt
        case videoURL = "video_url"
        case imageURLs = "image_urls"
        case duration
        case resolution
        case generateAudio = "generate_audio"
        case bitrateMode = "bitrate_mode"
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(prompt, forKey: .prompt)
        try container.encode(videoURL, forKey: .videoURL)
        if !imageURLs.isEmpty { try container.encode(imageURLs, forKey: .imageURLs) }
        try container.encodeIfPresent(duration, forKey: .duration)
        try container.encode(resolution, forKey: .resolution)
        try container.encode(generateAudio, forKey: .generateAudio)
        try container.encodeIfPresent(bitrateMode, forKey: .bitrateMode)
    }
}

/// Body of Kling 3.0 Motion Control, Standard and Pro alike. There is no `duration` (the output follows the source)
/// and no background parameter.
public struct KlingMotionRequest: Encodable, Sendable, Hashable {
    /// `keep_original_sound`: whether the result keeps the motion video's sound (server default `yes`).
    public enum OriginalSound: String, Sendable, Hashable {
        case keep = "yes"
        case drop = "no"
    }

    /// `character_orientation`: the character faces as in the image or as in the video (server default `video`).
    public enum Orientation: String, Sendable, Hashable {
        case image
        case video
    }

    /// The character.
    public var imageURL: URL
    /// The motion, 3–30 s.
    public var videoURL: URL
    public var prompt: String
    /// The server's default when `nil`.
    public var keepOriginalSound: OriginalSound?
    /// The server's default when `nil`.
    public var characterOrientation: Orientation?

    public init(
        imageURL: URL, videoURL: URL, prompt: String, keepOriginalSound: OriginalSound? = nil,
        characterOrientation: Orientation? = nil
    ) {
        self.imageURL = imageURL
        self.videoURL = videoURL
        self.prompt = prompt
        self.keepOriginalSound = keepOriginalSound
        self.characterOrientation = characterOrientation
    }

    enum CodingKeys: String, CodingKey {
        case imageURL = "image_url"
        case videoURL = "video_url"
        case prompt
        case keepOriginalSound = "keep_original_sound"
        case characterOrientation = "character_orientation"
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(imageURL, forKey: .imageURL)
        try container.encode(videoURL, forKey: .videoURL)
        if !prompt.isEmpty { try container.encode(prompt, forKey: .prompt) }
        try container.encodeIfPresent(keepOriginalSound?.rawValue, forKey: .keepOriginalSound)
        try container.encodeIfPresent(characterOrientation?.rawValue, forKey: .characterOrientation)
    }
}

/// Body of Kling O3's `video-reference`: a clip from the prompt (required), one reference video and up to four
/// images. `elements` and `aspect_ratio` are left out, so the server's defaults apply.
public struct KlingVideoReferenceRequest: Encodable, Sendable, Hashable {
    /// `mode`: Standard or Pro (server default `pro`).
    public enum Quality: String, Sendable, Hashable {
        case standard = "std"
        case pro
    }

    public var prompt: String
    /// The one reference video (`video_urls`, exactly one item).
    public var videoURL: URL
    /// 0–4, in order; left out when empty.
    public var imageURLs: [URL]
    public var quality: Quality
    /// Whole seconds of the generated clip, 3–10.
    public var duration: Int

    public init(prompt: String, videoURL: URL, imageURLs: [URL] = [], quality: Quality, duration: Int) {
        self.prompt = prompt
        self.videoURL = videoURL
        self.imageURLs = imageURLs
        self.quality = quality
        self.duration = duration
    }

    enum CodingKeys: String, CodingKey {
        case prompt
        case videoURLs = "video_urls"
        case imageURLs = "image_urls"
        case quality = "mode"
        case duration
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(prompt, forKey: .prompt)
        try container.encode([videoURL], forKey: .videoURLs)
        if !imageURLs.isEmpty { try container.encode(imageURLs, forKey: .imageURLs) }
        try container.encode(quality.rawValue, forKey: .quality)
        try container.encode(duration, forKey: .duration)
    }
}

/// A submitted request as the API answered it.
public struct SubmittedRequest: Sendable, Hashable {
    public var requestID: String
    /// `X-Correlation-ID`, for support requests.
    public var correlationID: String?
    /// Where the API said to poll and cancel; pass them back to `status` and `cancel`, which check the host.
    public var statusURL: URL?
    public var cancelURL: URL?
    /// What the submit answer said about the job, when it said anything.
    public var initialStatus: GenerationStatus?

    public init(
        requestID: String, correlationID: String? = nil, statusURL: URL? = nil, cancelURL: URL? = nil,
        initialStatus: GenerationStatus? = nil
    ) {
        self.requestID = requestID
        self.correlationID = correlationID
        self.statusURL = statusURL
        self.cancelURL = cancelURL
        self.initialStatus = initialStatus
    }
}

/// A Restyle preset.
public struct Preset: Sendable, Hashable {
    public var id: UUID
    public var name: String
    public var previewURL: URL

    public init(id: UUID, name: String, previewURL: URL) {
        self.id = id
        self.name = name
        self.previewURL = previewURL
    }
}

/// The submit answer has the shape of a status answer, with the polling and cancel URLs.
struct SubmitResponse: Decodable, Sendable {
    var requestID: String
    var status: String?
    var statusURL: URL?
    var cancelURL: URL?
    var video: StatusResponse.Video?
    var error: String?

    enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case status
        case statusURL = "status_url"
        case cancelURL = "cancel_url"
        case video
        case error
    }

    /// `nil` when the answer leaves the state to the first poll, including a `completed` without a video URL:
    /// the job is paid for, so the poll fetches the result instead of failing it here.
    var initialStatus: GenerationStatus? {
        guard let status, status != "completed" || video?.url != nil else { return nil }
        return StatusResponse.generationStatus(status, videoURL: video?.url, error: error)
    }
}

struct StatusResponse: Decodable, Sendable {
    struct Video: Decodable, Sendable {
        var url: URL?
    }

    var status: String
    var video: Video?
    /// Image models answer `images: [{url}]` instead of `video`.
    var images: [Video]?
    var error: String?

    var generationStatus: GenerationStatus { Self.generationStatus(status, videoURL: video?.url, error: error) }

    /// As `generationStatus`, for an image model: completed with at least one https image, else failed, since
    /// polling again won't bring one.
    var imageStatus: ImageStatus {
        switch generationStatus {
        case .queued: return .queued
        case .inProgress: return .inProgress
        case .failed(let message) where status != "completed": return .failed(message: message)
        case .failed, .completed:
            let urls = (images ?? []).compactMap(\.url).filter(\.isHTTPS)
            return urls.isEmpty ? .failed(message: "Completed without an image URL.") : .completed(imageURLs: urls)
        case .rejected(let moderation): return .rejected(moderation)
        case .canceled: return .canceled
        }
    }

    static func generationStatus(_ status: String, videoURL: URL?, error: String?) -> GenerationStatus {
        switch status {
        case "queued": return .queued
        case "in_progress": return .inProgress
        case "completed":
            guard let videoURL else { return .failed(message: "Completed without a video URL.") }
            return .completed(videoURL: videoURL)
        case "failed": return .failed(message: error)
        case "nsfw": return .rejected(.explicitContent)
        case "canceled", "cancelled": return .canceled
        // A status added later is most likely another intermediate stage; keep polling it.
        default: return .inProgress
        }
    }
}

/// `POST /estimate/{model}`: both amounts are decimal strings.
struct EstimateResponse: Decodable, Sendable {
    var credits: String?
    var usd: String
}

struct PresetCatalog: Decodable, Sendable {
    var items: [PresetItem]

    var presets: [Preset] {
        items.map { Preset(id: $0.id, name: $0.name, previewURL: $0.previewURL) }
    }
}

struct PresetItem: Decodable, Sendable {
    var id: UUID
    var name: String
    var previewURL: URL

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case previewURL = "preview_url"
    }
}
