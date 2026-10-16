import Foundation

/// A local file ready to upload: trimmed and transcoded video, or a converted image.
public struct PreparedFile: Codable, Sendable, Hashable {
    public var fileURL: URL
    /// MIME type, e.g. `video/mp4`.
    public var contentType: String
    public var byteCount: Int64
    /// Hex SHA-256 of the contents; key of the upload cache.
    public var contentHash: String

    public init(fileURL: URL, contentType: String, byteCount: Int64, contentHash: String) {
        self.fileURL = fileURL
        self.contentType = contentType
        self.byteCount = byteCount
        self.contentHash = contentHash
    }
}
