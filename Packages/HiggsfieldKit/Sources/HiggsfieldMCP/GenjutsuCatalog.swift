import Foundation

// Read from the live server on 2026-10-14 with `get_presets` and `get_preset_instructions` only: the Motion Library
// tabs of higgsfield.ai/genjutsu and the Genjutsu Styles (Restyle) are galleries of `get_presets` with
// `source: "genjutsu"`. A style runs with `execute_preset`; a motion entry is an example clip to use as the source
// video of an ordinary `generate_video` job.

/// The Genjutsu galleries of `get_presets`.
public enum GenjutsuCategory: String, Sendable, CaseIterable {
    /// Motion Library examples picked by Higgsfield.
    case higgsfield = "genjutsu"
    /// Community examples, most popular first.
    case trending = "genjutsu-trending"
    /// Community examples, newest first.
    case new = "genjutsu-new"
    /// Looks that redraw the user's own video.
    case styles = "genjutsu-styles"
}

/// One gallery entry.
public struct GenjutsuPreset: Sendable, Hashable {
    /// As `execute_preset` takes it: `genjutsu:<uuid>`, `genjutsu:trending:<uuid>`, `genjutsu-style:<uuid>`.
    public var id: String
    public var name: String
    public var thumbnailURL: URL?
    /// The example result, a short MP4.
    public var previewURL: URL?
    /// Also says what the example did; see `drivingVideoURL` and `exampleModel`.
    public var description: String

    public init(id: String, name: String, thumbnailURL: URL?, previewURL: URL?, description: String) {
        self.id = id
        self.name = name
        self.thumbnailURL = thumbnailURL
        self.previewURL = previewURL
        self.description = description
    }

    /// The UUID that ends `id`.
    public var uuid: UUID? {
        id.split(separator: ":").last.flatMap { UUID(uuidString: String($0)) }
    }

    /// A motion entry's source clip, publicly downloadable. The server names it only inside the description:
    /// "… Driving video: https://….mp4. Use the user's …".
    public var drivingVideoURL: URL? {
        guard let start = description.range(of: "Driving video: ")?.upperBound else { return nil }
        var link = description[start...].prefix { !$0.isWhitespace }
        while link.last == "." { link = link.dropLast() }
        return URL(serverMedia: String(link))
    }

    /// What the example made from its driving video. The user's request decides the job's model, not this.
    public var exampleModel: VideoRequest.Model? {
        if description.hasPrefix("Motion transfer") { return .motionControl }
        if description.hasPrefix("Object replacement") { return .replaceObject }
        return nil
    }
}

/// One page of a gallery.
public struct GenjutsuPresetPage: Sendable, Hashable {
    public var items: [GenjutsuPreset]
    /// Opaque: sent back unchanged for the next page. `nil` on the last page.
    public var nextCursor: JSONValue?

    public init(items: [GenjutsuPreset], nextCursor: JSONValue?) {
        self.items = items
        self.nextCursor = nextCursor
    }
}

/// A Genjutsu Style run on uploaded files.
public struct StyleRun: Sendable, Hashable {
    /// `genjutsu-style:<uuid>`.
    public var styleID: String
    public var videoID: String
    /// Up to 5 images of subjects to put into the result.
    public var imageIDs: [String]
    /// Optional; empty is left out.
    public var prompt: String
    public var resolution: String

    public init(styleID: String, videoID: String, imageIDs: [String] = [], prompt: String = "", resolution: String) {
        self.styleID = styleID
        self.videoID = videoID
        self.imageIDs = imageIDs
        self.prompt = prompt
        self.resolution = resolution
    }

    /// The `inputs` of `execute_preset`, and the `initial_inputs` of a priced `get_presets` detail.
    var inputs: JSONValue {
        var inputs: [String: JSONValue] = [
            ToolKey.video: [.string(videoID)], ToolKey.resolution: .string(resolution),
        ]
        if !imageIDs.isEmpty { inputs[ToolKey.references] = .array(imageIDs.map(JSONValue.string)) }
        if !prompt.isEmpty { inputs[ToolKey.prompt] = .string(prompt) }
        return .object(inputs)
    }
}

extension GenjutsuPresetPage {
    /// `nil` when there is no `items` array. Items without an ID or name are left out.
    init?(_ value: JSONValue) {
        guard let items = value[ToolKey.items]?.arrayValue else { return nil }
        self.items = items.compactMap(GenjutsuPreset.init)
        let cursor = value[ToolKey.nextCursor]
        nextCursor = cursor == .null ? nil : cursor
    }
}

extension GenjutsuPreset {
    init?(_ value: JSONValue) {
        guard let id = value[ToolKey.id]?.stringValue, let name = value[ToolKey.name]?.stringValue else { return nil }
        self.init(
            id: id, name: name, thumbnailURL: value[ToolKey.thumbnailURL]?.stringValue.flatMap(URL.init(serverMedia:)),
            previewURL: value[ToolKey.previewURL]?.stringValue.flatMap(URL.init(serverMedia:)),
            description: value[ToolKey.description]?.stringValue ?? "")
    }
}

enum PresetQuote {
    /// The price a `get_presets` detail gives for its `initial_inputs`. The server puts it in the text answer only
    /// ("cost_credits: 57.5"), and leaves it out when the inputs aren't ready.
    static func credits(in result: MCPToolResult) -> Double? {
        if let credits = result.structuredContent?[ToolKey.execution]?[ToolKey.costCredits]?.numberValue {
            return credits
        }
        let text = result.text
        guard let start = text.range(of: "\(ToolKey.costCredits):")?.upperBound else { return nil }
        let number = text[start...].drop { $0 == " " }.prefix { $0.isNumber || $0 == "." }
        return Double(number)
    }

    /// The first job ID an `execute_preset` answer names. A live Style run on 2026-10-15 answered
    /// `{source: "marketing_studio", preset_id, job_ids: [id], status: "submitted"}`, so `job_ids[0]` is read first;
    /// the other forms the tool describes and `generate_video`'s are still read after it.
    static func jobID(in value: JSONValue) -> String? {
        if let id = value[ToolKey.jobIDs]?.arrayValue?.first?.stringValue { return id }
        if let id = value[ToolKey.jobIDs]?.arrayValue?.first?[ToolKey.id]?.stringValue { return id }
        if let id = value[ToolKey.jobs]?.arrayValue?.first?[ToolKey.id]?.stringValue { return id }
        if let id = value[ToolKey.results]?.arrayValue?.first?[ToolKey.id]?.stringValue { return id }
        return value[ToolKey.jobIDSingle]?.stringValue
    }
}
