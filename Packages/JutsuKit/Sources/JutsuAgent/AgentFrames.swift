import Foundation

// frames: still frames and a contact sheet, for checking a result without a video player.

/// PNG frames of a Library result or a file at the times asked, and with a comparison, the same times of a second
/// clip and a contact sheet of both. Written into the output folder's Exports folder under names no file has; free,
/// and a history item's source is read from its Higgsfield link.
public struct FramesCommand: Codable, Equatable, Sendable, AgentFields {
    public static let maxTimes = 12

    /// A Library item, a video or an image.
    public var item: UUID?
    /// Else a file, a path in the app's inbox from an upload.
    public var file: String?
    /// Seconds from the start of the clip; an image has one frame whatever the time.
    public var times: [Double]
    /// Compares with another Library item at the same times.
    public var compareItem: UUID?
    /// Compares with another file at the same times.
    public var compareFile: String?
    /// Compares with the item's own source clip, at the same times from the start of its range: what was swapped.
    public var compareSource: Bool

    public init(
        item: UUID? = nil, file: String? = nil, times: [Double], compareItem: UUID? = nil, compareFile: String? = nil,
        compareSource: Bool = false
    ) {
        self.item = item
        self.file = file
        self.times = times
        self.compareItem = compareItem
        self.compareFile = compareFile
        self.compareSource = compareSource
    }

    private enum CodingKeys: String, CodingKey {
        case item, file, times, compareItem, compareFile, compareSource
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        item = try container.decodeIfPresent(UUID.self, forKey: .item)
        file = try container.decodeIfPresent(String.self, forKey: .file)
        times = try container.decode([Double].self, forKey: .times)
        compareItem = try container.decodeIfPresent(UUID.self, forKey: .compareItem)
        compareFile = try container.decodeIfPresent(String.self, forKey: .compareFile)
        compareSource = try container.decodeIfPresent(Bool.self, forKey: .compareSource) ?? false
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(item, forKey: .item)
        try container.encodeIfPresent(file, forKey: .file)
        try container.encode(times, forKey: .times)
        try container.encodeIfPresent(compareItem, forKey: .compareItem)
        try container.encodeIfPresent(compareFile, forKey: .compareFile)
        if compareSource { try container.encode(compareSource, forKey: .compareSource) }
    }

    /// The files it sends, in order.
    public var files: [String] { [file, compareFile].compactMap(\.self) }

    public var problem: String? {
        guard (item != nil) != (file != nil) else { return "frames takes exactly one of item or file" }
        let compared = [compareItem != nil, compareFile != nil, compareSource].filter(\.self).count
        guard compared <= 1 else { return "frames compares with one of compare_item, compare_file or compare_source" }
        if compareSource, item == nil { return "compare_source is the item's own source clip; it needs item" }
        guard (1...Self.maxTimes).contains(times.count) else { return "times takes 1 to \(Self.maxTimes) seconds" }
        if times.contains(where: { !($0.isFinite && (0...AgentSource.maxSeconds).contains($0)) }) {
            return "times are seconds from 0 to \(Int(AgentSource.maxSeconds))"
        }
        if let path = files.first(where: { !AgentVideoRequest.isValidPath($0) }) {
            return "\(path.prefix(80)) isn't a file path"
        }
        return nil
    }
}

/// What `frames` wrote.
public struct AgentFrames: Codable, Equatable, Sendable {
    public struct Frame: Codable, Equatable, Sendable {
        /// "main", the item or file asked for, or "compare".
        public var clip: String
        /// Seconds into that clip; for compare_source, into the source file.
        public var time: Double
        public var file: String

        public init(clip: String, time: Double, file: String) {
            self.clip = clip
            self.time = time
            self.file = file
        }
    }

    /// The output folder's Exports folder.
    public var folder: String
    /// In the order asked, the main clip's first, then the comparison's.
    public var frames: [Frame]
    /// With a comparison or several times: every frame on one image, a row per clip (main on top), a column per time.
    public var sheet: String?

    public init(folder: String, frames: [Frame], sheet: String? = nil) {
        self.folder = folder
        self.frames = frames
        self.sheet = sheet
    }
}
