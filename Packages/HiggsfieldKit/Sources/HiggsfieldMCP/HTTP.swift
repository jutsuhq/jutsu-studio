import Foundation
import HiggsfieldCore

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

extension URLSession {
    /// Like `send(_:)`, but an event-stream body is read only until `isComplete` accepts its events, and the
    /// whole exchange fails as `HiggsfieldError.network` after `timeout` seconds. The request's own timeout
    /// counts only idle time, so a stream the server keeps alive without ever answering never trips it.
    /// Swift's Linux Foundation has no `bytes(for:)`; there the whole body is read, as in tests.
    func send(
        _ request: URLRequest, within timeout: TimeInterval, until isComplete: @escaping @Sendable ([String]) -> Bool
    ) async throws -> (
        Data, HTTPURLResponse
    ) {
        try await withThrowingTaskGroup(of: (Data, HTTPURLResponse).self) { group in
            group.addTask { try await self.send(request, until: isComplete) }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw HiggsfieldError.network
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw CancellationError() }
            return first
        }
    }

    private func send(
        _ request: URLRequest, until isComplete: @escaping ([String]) -> Bool
    ) async throws -> (
        Data, HTTPURLResponse
    ) {
        #if canImport(FoundationNetworking)
            let (data, http) = try await send(request)
            guard data.count <= maxResponseBytes else { throw HiggsfieldError.server(status: http.statusCode) }
            return (data, http)
        #else
            let bytes: URLSession.AsyncBytes
            let response: URLResponse
            do {
                (bytes, response) = try await self.bytes(for: request)
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch is URLError {
                throw HiggsfieldError.network
            }
            defer { bytes.task.cancel() }
            let http = try HTTPURLResponse.required(response)
            do {
                if http.value(forHTTPHeaderField: "Content-Type")?.contains("text/event-stream") == true {
                    return (try await readEventStream(bytes, until: isComplete), http)
                }
                return (try await readBody(bytes), http)
            } catch is ResponseTooLarge {
                throw HiggsfieldError.server(status: http.statusCode)
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch is URLError {
                throw HiggsfieldError.network
            }
        #endif
    }

    /// Posts an `application/x-www-form-urlencoded` body; OAuth token and device endpoints take this.
    func postForm(_ url: URL, _ parameters: [String: String]) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(formEncoded(parameters).utf8)
        return try await send(request)
    }
}

/// The most a single MCP response may carry; anything larger is refused rather than buffered.
let maxResponseBytes = 16 * 1024 * 1024

struct ResponseTooLarge: Error {}

/// Collects `bytes`, throwing `ResponseTooLarge` once they exceed `limit`.
func readBody<Bytes: AsyncSequence>(_ bytes: Bytes, limit: Int = maxResponseBytes) async throws -> Data
where Bytes.Element == UInt8 {
    var data = Data()
    for try await byte in bytes {
        guard data.count < limit else { throw ResponseTooLarge() }
        data.append(byte)
    }
    return data
}

func formEncoded(_ parameters: [String: String]) -> String {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    let escape = { (text: String) in text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text }
    return parameters.sorted { $0.key < $1.key }.map { "\(escape($0.key))=\(escape($0.value))" }
        .joined(separator: "&")
}

/// Decodes a JSON body whose keys are snake_case, as all OAuth documents are.
func decodeSnakeCase<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return try decoder.decode(type, from: data)
}

/// Maps an OAuth error body (`{"error": ..., "error_description": ...}`) or a bare status to an error.
func oauthError(_ data: Data, _ response: HTTPURLResponse) -> any Error {
    struct Body: Decodable {
        let error: String
        let errorDescription: String?

        enum CodingKeys: String, CodingKey {
            case error
            case errorDescription = "error_description"
        }
    }
    guard let body = try? JSONDecoder().decode(Body.self, from: data) else {
        return HiggsfieldError.server(status: response.statusCode)
    }
    return body.error == "access_denied"
        ? OAuthError.accessDenied : OAuthError.server(code: body.error, description: body.errorDescription)
}
