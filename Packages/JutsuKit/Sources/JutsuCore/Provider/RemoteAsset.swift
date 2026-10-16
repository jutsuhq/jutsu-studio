import Foundation

/// An uploaded file, reachable by the provider at `url`.
public struct RemoteAsset: Codable, Sendable, Hashable {
    public var url: URL
    /// The provider's own ID for the file, when requests name it by ID rather than URL.
    public var id: String?

    public init(url: URL, id: String? = nil) {
        self.url = url
        self.id = id
    }
}
