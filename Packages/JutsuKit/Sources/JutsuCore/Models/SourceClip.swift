import Foundation

/// A local source video and the part of it the user picked.
public struct SourceClip: Codable, Sendable, Hashable {
    public var fileURL: URL
    /// Length of the whole file, in seconds.
    public var duration: TimeInterval
    public var pixelSize: PixelSize
    /// Selected range, in seconds from the start of the file.
    public var range: ClosedRange<TimeInterval>
    /// The user allowed upscaling a frame that is too small for object swap.
    public var allowsUpscale: Bool
    /// Security-scoped bookmark of `fileURL`, so the sandbox lets a later launch read it.
    /// `nil` for jobs stored before bookmarks existed and where one couldn't be made.
    public var bookmark: Data?
    /// The `https:` link the file was downloaded from; `nil` for a file the user picked. Optional, so jobs and
    /// drafts stored before it existed still decode.
    public var remoteOrigin: URL?
    public var material: MaterialReference?

    public init(
        fileURL: URL, duration: TimeInterval, pixelSize: PixelSize, range: ClosedRange<TimeInterval>,
        allowsUpscale: Bool = false, bookmark: Data? = nil, remoteOrigin: URL? = nil,
        material: MaterialReference? = nil
    ) {
        self.fileURL = fileURL
        self.duration = duration
        self.pixelSize = pixelSize
        self.range = range
        self.allowsUpscale = allowsUpscale
        self.bookmark = bookmark
        self.remoteOrigin = remoteOrigin
        self.material = material
    }

    public var selectedDuration: TimeInterval { range.upperBound - range.lowerBound }
}
