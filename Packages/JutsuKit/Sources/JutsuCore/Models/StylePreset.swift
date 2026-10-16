import Foundation

/// A restyle preset from the provider's catalog.
public struct StylePreset: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    /// A still image.
    public var previewURL: URL
    /// A short example video, played on hover; `nil` when the provider offers none.
    public var previewVideoURL: URL?

    public init(id: UUID, name: String, previewURL: URL, previewVideoURL: URL? = nil) {
        self.id = id
        self.name = name
        self.previewURL = previewURL
        self.previewVideoURL = previewVideoURL
    }
}
