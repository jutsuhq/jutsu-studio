import Foundation
import HiggsfieldCore

/// The `type` filter of `show_generations`.
public enum GenerationType: String, Sendable, CaseIterable {
    case video
    case image
    case audio
    case threeD = "3d"
}

/// One page of the account's history, newest first.
public struct GenerationPage: Sendable, Hashable {
    public var items: [PastGeneration]
    /// Opaque: sent back unchanged for the next page. `nil` on the last page.
    public var nextCursor: JSONValue?

    public init(items: [PastGeneration], nextCursor: JSONValue?) {
        self.items = items
        self.nextCursor = nextCursor
    }
}

/// A generation from `show_generations`. Its `id` is the job ID `generate` returned and `status(of:)` takes.
public struct PastGeneration: Sendable, Hashable {
    public var id: String
    /// "video", "image", "audio" or "3d".
    public var type: String
    public var status: String
    /// The server's model ID, which may be one `VideoRequest.Model` doesn't know.
    public var model: String
    public var createdAt: Date
    public var isLiked: Bool
    /// `results.rawUrl`; `nil` until the generation finished.
    public var outputURL: URL?
    /// The output's size, not the source's.
    public var width: Int?
    public var height: Int?
    /// The output's length in seconds.
    public var duration: Double?
    /// What the user typed; the server's rewrite (`enhanced_prompt`) is not kept.
    public var prompt: String
    public var resolution: String?
    public var media: [PastMedia]
    /// `params.draft`: Seedance 2.5's native draft, finalizable at 1080p within seven days.
    public var isDraft = false
    /// `params.draft_job_id`: the draft this generation finalized; `nil` for any other.
    public var draftJobID: String?

    public init(
        id: String, type: String, status: String, model: String, createdAt: Date, isLiked: Bool = false,
        outputURL: URL? = nil, width: Int? = nil, height: Int? = nil, duration: Double? = nil, prompt: String = "",
        resolution: String? = nil, media: [PastMedia] = []
    ) {
        self.id = id
        self.type = type
        self.status = status
        self.model = model
        self.createdAt = createdAt
        self.isLiked = isLiked
        self.outputURL = outputURL
        self.width = width
        self.height = height
        self.duration = duration
        self.prompt = prompt
        self.resolution = resolution
        self.media = media
    }
}

/// An input of a past generation, as uploaded.
public struct PastMedia: Sendable, Hashable {
    /// `nil` for a role `VideoRequest` has no use for.
    public var role: MediaRole?
    /// What `VideoRequest.Media` takes, while the server still keeps the file.
    public var id: String
    public var url: URL?

    public init(role: MediaRole?, id: String, url: URL?) {
        self.role = role
        self.id = id
        self.url = url
    }
}

extension MediaRole {
    /// History names the inputs `video` and `image`; `generate_video` takes the `_references` names.
    public init?(historyRole: String) {
        switch historyRole {
        case "video", MediaRole.video.rawValue: self = .video
        case "image", MediaRole.image.rawValue: self = .image
        default: return nil
        }
    }
}

extension GenerationPage {
    /// `nil` when there is no `items` array. Items without an ID are left out.
    init?(_ value: JSONValue) {
        guard let items = value[ToolKey.items]?.arrayValue else { return nil }
        self.items = items.compactMap(PastGeneration.init)
        let cursor = value[ToolKey.nextCursor]
        nextCursor = cursor == .null ? nil : cursor
    }
}

extension PastGeneration {
    init?(_ value: JSONValue) {
        guard let id = value[ToolKey.id]?.stringValue else { return nil }
        let params = value[ToolKey.params]
        self.init(
            id: id, type: value[ToolKey.type]?.stringValue ?? "", status: value[ToolKey.status]?.stringValue ?? "",
            model: value[ToolKey.model]?.stringValue ?? "",
            // Unix seconds with a fraction.
            createdAt: Date(timeIntervalSince1970: value[ToolKey.createdAt]?.numberValue ?? 0),
            isLiked: value[ToolKey.liked] == true,
            outputURL: value[ToolKey.results]?[ToolKey.rawURL]?.stringValue.flatMap(URL.init(serverMedia:)),
            width: params?[ToolKey.width]?.numberValue.flatMap(ModelLimits.count),
            height: params?[ToolKey.height]?.numberValue.flatMap(ModelLimits.count),
            duration: params?[ToolKey.duration]?.numberValue,
            prompt: params?[ToolKey.prompt]?.stringValue ?? "",
            resolution: params?[ToolKey.resolution]?.stringValue,
            media: (params?[ToolKey.medias]?.arrayValue ?? []).compactMap(PastMedia.init))
        isDraft = params?[ToolKey.draft] == true
        draftJobID = params?[ToolKey.draftJobID]?.stringValue
    }
}

extension PastMedia {
    init?(_ value: JSONValue) {
        let data = value[ToolKey.data]
        guard let id = data?[ToolKey.id]?.stringValue else { return nil }
        self.init(
            role: value[ToolKey.role]?.stringValue.flatMap(MediaRole.init(historyRole:)), id: id,
            url: data?[ToolKey.url]?.stringValue.flatMap(URL.init(serverMedia:)))
    }
}

extension URL {
    /// A media URL the server sent, only when it is https: the app downloads these, and another scheme such as
    /// `file:` would reach local files. Percent-encodes characters `URL(string:)` refuses, which Linux
    /// Foundation doesn't do by itself.
    init?(serverMedia string: String) {
        let encoded = string.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
        guard let url = URL(string: string) ?? encoded.flatMap(URL.init(string:)),
            url.isHTTPS
        else { return nil }
        self = url
    }
}
