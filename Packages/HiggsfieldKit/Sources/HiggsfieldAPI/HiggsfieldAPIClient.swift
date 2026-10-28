import Foundation
import HiggsfieldCore

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

#if canImport(os)
    import os

    private let logger = Logger(subsystem: "com.jutsustudio", category: "HiggsfieldAPI")
#endif

/// REST client for `api.higgsfield.ai`. Every failure surfaces as `HiggsfieldError`, or `CancellationError`.
public struct HiggsfieldAPIClient: Sendable {
    // swiftlint:disable:next force_unwrapping
    public static let defaultBaseURL = URL(string: "https://api.higgsfield.ai")!

    public let baseURL: URL
    public let keyID: String
    let session: URLSession
    private let authorization: String

    public init(
        keyID: String, secret: String, baseURL: URL = HiggsfieldAPIClient.defaultBaseURL, session: URLSession = .shared
    ) {
        self.authorization = "Key \(keyID):\(secret)"
        self.keyID = keyID
        self.baseURL = baseURL
        self.session = session
    }

    // MARK: Uploads

    /// Asks for a presigned PUT URL and the public URL the file will have once uploaded.
    public func uploadTarget(contentType: String) async throws -> UploadTarget {
        let body = try encode(UploadURLRequest(contentType: contentType))
        let (data, http) = try await call(request("POST", "files/generate-upload-url", body: body))
        return try decode(UploadTarget.self, data, status: http.statusCode)
    }

    /// Streams the file to a presigned URL. The signature is the authorization, so no key is sent.
    /// `uploadURL` comes from the server and must be https; any other throws `.server(status: 200)`, as an
    /// upload target the client can't act on.
    public func put(
        fileAt fileURL: URL, contentType: String, to uploadURL: URL, headers: [String: String] = [:]
    ) async throws {
        guard uploadURL.isHTTPS else {
            #if canImport(os)
                logger.error("Refused an upload URL that isn't https")
            #endif
            throw HiggsfieldError.server(status: 200)
        }
        var request = URLRequest(url: uploadURL)
        request.httpMethod = "PUT"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (_, http) = try await send(request, fromFile: fileURL)
        // Storage errors (e.g. 403 for an expired signature) mean nothing about the API key or balance.
        guard http.isSuccess else {
            logFailure("PUT", "presigned upload", http)
            throw HiggsfieldError.server(status: http.statusCode)
        }
    }

    // MARK: Jobs

    /// The price in USD of what `submit` would send for the same request. Charges nothing.
    /// `body` is the endpoint's own (`ModelEndpoint`).
    public func estimate(_ endpoint: ModelEndpoint, _ body: some Encodable & Sendable) async throws -> Decimal {
        let (data, http) = try await call(request("POST", "estimate/\(endpoint.rawValue)", body: try encode(body)))
        let response = try decode(EstimateResponse.self, data, status: http.statusCode)
        guard let usd = Decimal(string: response.usd, locale: Locale(identifier: "en_US_POSIX")), usd >= 0 else {
            throw HiggsfieldError.server(status: http.statusCode)
        }
        return usd
    }

    public func submit(
        _ endpoint: ModelEndpoint, _ body: some Encodable & Sendable, idempotencyKey: UUID
    ) async throws -> SubmittedRequest {
        var request = request("POST", endpoint.rawValue, body: try encode(body))
        request.setValue(idempotencyKey.uuidString.lowercased(), forHTTPHeaderField: "Idempotency-Key")
        let (data, http) = try await call(request)
        let response = try decode(SubmitResponse.self, data, status: http.statusCode)
        return SubmittedRequest(
            requestID: response.requestID, correlationID: http.correlationID, statusURL: response.statusURL,
            cancelURL: response.cancelURL, initialStatus: response.initialStatus)
    }

    /// `statusURL` is the one the submit answer returned, used only on the API's own host.
    public func status(requestID: String, statusURL: URL? = nil) async throws -> GenerationStatus {
        let url = trustedURL(statusURL, orPath: "requests/\(requestID)/status")
        let (data, http) = try await call(request("GET", url))
        return try decode(StatusResponse.self, data, status: http.statusCode).generationStatus
    }

    /// `status(requestID:statusURL:)` of an image model's request, which finishes with `images[].url`.
    public func imageStatus(requestID: String, statusURL: URL? = nil) async throws -> ImageStatus {
        let url = trustedURL(statusURL, orPath: "requests/\(requestID)/status")
        let (data, http) = try await call(request("GET", url))
        return try decode(StatusResponse.self, data, status: http.statusCode).imageStatus
    }

    /// Succeeds only while the job is queued; afterwards the API answers 400 (`HiggsfieldError.validation`).
    public func cancel(requestID: String, cancelURL: URL? = nil) async throws {
        _ = try await call(request("POST", trustedURL(cancelURL, orPath: "requests/\(requestID)/cancel")))
    }

    /// `returned` when it is HTTPS on the API's own host and port, so the key never goes anywhere else;
    /// otherwise the documented path under `baseURL`.
    func trustedURL(_ returned: URL?, orPath path: String) -> URL {
        let fallback = baseURL.appendingPathComponent(path)
        guard let returned else { return fallback }
        guard returned.scheme?.lowercased() == "https", let host = returned.host?.lowercased(),
            host == baseURL.host?.lowercased(), returned.port == baseURL.port
        else {
            #if canImport(os)
                logger.error(
                    "Ignored a returned URL outside \(baseURL.host ?? "", privacy: .public); using \(path, privacy: .public)"
                )
            #endif
            return fallback
        }
        return returned
    }

    public func presets() async throws -> [Preset] {
        let (data, http) = try await call(request("GET", "models/\(ModelEndpoint.restyle.rawValue)/presets"))
        return try decode(PresetCatalog.self, data, status: http.statusCode).presets
    }

    /// Onboarding check with a free authenticated call. `false` means the key was refused;
    /// other failures (network, outages) throw because they say nothing about the key.
    public func validateKey() async throws -> Bool {
        do {
            // Only the status counts: a catalog item of a new shape says nothing about the key.
            _ = try await call(request("GET", "models/\(ModelEndpoint.restyle.rawValue)/presets"))
            return true
        } catch HiggsfieldError.unauthorized {
            return false
        }
    }

    // MARK: Transport

    private func request(_ method: String, _ path: String, body: Data? = nil) -> URLRequest {
        request(method, baseURL.appendingPathComponent(path), body: body)
    }

    /// Carries the key: `url` must be `baseURL` or come from `trustedURL`.
    private func request(_ method: String, _ url: URL, body: Data? = nil) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    /// Sends an API request and throws the mapped error for any non-2xx answer.
    private func call(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, http) = try await send(request)
        let retryAfter = http.value(forHTTPHeaderField: "Retry-After")
        if let error = HiggsfieldAPIErrors.error(status: http.statusCode, body: data, retryAfter: retryAfter) {
            logFailure(request.httpMethod ?? "GET", request.url?.path ?? "", http)
            throw error
        }
        return (data, http)
    }

    /// `URLSession.send`, except that a transport failure of a cancelled task is a `CancellationError`.
    private func send(_ request: URLRequest, fromFile file: URL? = nil) async throws -> (Data, HTTPURLResponse) {
        do {
            return try await session.send(request, fromFile: file)
        } catch HiggsfieldError.network where Task.isCancelled {
            throw CancellationError()
        }
    }

    private func encode(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    /// A 2xx body we can't read means the API changed shape; nothing the user can fix.
    private func decode<T: Decodable>(_ type: T.Type, _ data: Data, status: Int) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw HiggsfieldError.server(status: status)
        }
    }

    private func logFailure(_ method: String, _ path: String, _ http: HTTPURLResponse) {
        #if canImport(os)
            logger.error(
                """
                \(method, privacy: .public) \(path, privacy: .public) → \(http.statusCode, privacy: .public), \
                correlation \(http.correlationID ?? "none", privacy: .public)
                """)
        #endif
    }
}

extension HTTPURLResponse {
    var correlationID: String? { value(forHTTPHeaderField: "X-Correlation-ID") }
}

/// Prints without the secret, which the `Authorization` value carries.
extension HiggsfieldAPIClient: CustomStringConvertible, CustomReflectable {
    public var description: String { "HiggsfieldAPIClient(keyID: \(keyID), baseURL: \(baseURL))" }
    public var customMirror: Mirror { Mirror(self, children: ["keyID": keyID, "baseURL": baseURL]) }
}
