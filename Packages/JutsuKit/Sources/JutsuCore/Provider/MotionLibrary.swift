import Foundation

/// A provider that offers ready-made source clips to run Motion or Swap on (Higgsfield's Motion Library), and the
/// videos the account uploaded before.
public protocol MotionLibrary: Sendable {
    /// One page of `shelf`, in the provider's order; `nil` for the first page.
    func motionPresets(on shelf: MotionShelf, after cursor: HistoryCursor?) async throws -> MotionPresetPage
}

/// The tabs of the library.
public enum MotionShelf: String, Sendable, Hashable, CaseIterable, Identifiable {
    /// Picked by Higgsfield.
    case featured
    /// The community's most used.
    case trending
    /// The community's newest.
    case new
    /// Videos the account uploaded, as sources of past jobs or on higgsfield.ai.
    case uploads

    public var id: Self { self }
}

/// A source clip from the library, with the example made from it.
public struct MotionPreset: Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    /// The clip a job starts from.
    public var videoURL: URL
    public var thumbnailURL: URL?
    /// The example result, a short video.
    public var previewURL: URL?
    /// What the example did with the clip; `nil` when the provider didn't say. Any mode can use it.
    public var exampleMode: Mode?

    public init(
        id: String, name: String, videoURL: URL, thumbnailURL: URL? = nil, previewURL: URL? = nil,
        exampleMode: Mode? = nil
    ) {
        self.id = id
        self.name = name
        self.videoURL = videoURL
        self.thumbnailURL = thumbnailURL
        self.previewURL = previewURL
        self.exampleMode = exampleMode
    }
}

public struct MotionPresetPage: Sendable, Hashable {
    public var items: [MotionPreset]
    /// `nil` on the last page.
    public var nextCursor: HistoryCursor?

    public init(items: [MotionPreset], nextCursor: HistoryCursor?) {
        self.items = items
        self.nextCursor = nextCursor
    }
}
