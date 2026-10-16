import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

// The one URLSession transport of the clients and the app's downloader. Each user names the error a transport
// failure becomes, so the clients keep throwing `HiggsfieldError` and the downloader its own error.

extension URLSession {
    /// Like `data(for:)`, with transport failures mapped to `networkError`.
    /// With `file`, streams it as the body instead of loading it into memory.
    /// Cancellation stays cancellation, so callers stop instead of retrying it as a failure.
    public func send(
        _ request: URLRequest, fromFile file: URL? = nil, networkError: any Error = HiggsfieldError.network
    ) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        let data: Data
        let response: URLResponse
        do {
            if let file {
                (data, response) = try await upload(for: request, fromFile: file)
            } else {
                (data, response) = try await self.data(for: request)
            }
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch is URLError {
            throw networkError
        }
        return try (data, HTTPURLResponse.required(response, networkError: networkError))
    }
}

extension HTTPURLResponse {
    public var isSuccess: Bool { (200..<300).contains(statusCode) }

    /// `response` as an HTTP response; anything else means the transport failed, which throws `networkError`.
    public static func required(
        _ response: URLResponse?, networkError: any Error = HiggsfieldError.network
    ) throws -> HTTPURLResponse {
        guard let http = response as? HTTPURLResponse else { throw networkError }
        return http
    }
}

extension URL {
    /// Every URL a server hands out must pass this before it is opened, read or downloaded: a `file:` or other
    /// scheme from the server must never reach the user's files.
    public var isHTTPS: Bool {
        scheme?.lowercased() == "https" && host?.isEmpty == false
    }
}
