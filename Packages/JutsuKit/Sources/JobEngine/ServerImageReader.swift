import Foundation
import HiggsfieldCore
import JutsuCore

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Reads a picture a server links to into memory, for a thumbnail or a preview. Only an https URL is requested, and
/// only a successful answer that may be an image (`MediaLink.checkImage`) of at most `maxBytes` is returned.
/// Failures throw `MediaLinkError`; cancelling throws `CancellationError`.
public struct ServerImageReader: Sendable {
    /// Far above any thumbnail or character sheet, and low enough that a wrong link can't fill the memory.
    public static let maxBytes: Int64 = 64 << 20

    private let session: URLSession
    private let maxBytes: Int64

    public init(session: URLSession = .shared, maxBytes: Int64 = Self.maxBytes) {
        self.session = session
        self.maxBytes = maxBytes
    }

    /// Stream to a bounded scratch file before loading the accepted bytes into memory.
    public func data(from url: URL) async throws -> Data {
        guard url.isHTTPS else { throw MediaLinkError.notHTTPS }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("preview-\(UUID())")
        defer { try? FileManager.default.removeItem(at: file) }
        do {
            try await URLSessionDownloader(session: session, maxBytes: maxBytes).download(
                url, to: file,
                accept: { [maxBytes] response in
                    try MediaLink.checkImage(contentType: response.value(forHTTPHeaderField: "Content-Type"))
                    guard response.expectedContentLength <= maxBytes else {
                        throw MediaLinkError.tooLarge(maxBytes: maxBytes)
                    }
                }, progress: { _, _ in })
            try Task.checkCancellation()
            return try Data(contentsOf: file)
        } catch {
            throw MediaLinkDownloader.linkError(error)
        }
    }
}
