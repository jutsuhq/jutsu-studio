import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

public struct StubResponse: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: String
    /// Sends the body but never ends the response, like a stream the server keeps alive without answering.
    public var keepsOpen: Bool

    public init(status: Int = 200, headers: [String: String] = [:], body: String = "", keepsOpen: Bool = false) {
        self.status = status
        self.headers = headers
        self.body = body
        self.keepsOpen = keepsOpen
    }

    public static func json(_ text: String, status: Int = 200, headers: [String: String] = [:]) -> StubResponse {
        StubResponse(
            status: status, headers: headers.merging(["Content-Type": "application/json"]) { own, _ in own },
            body: text)
    }

    public static func eventStream(_ text: String) -> StubResponse {
        StubResponse(headers: ["Content-Type": "text/event-stream"], body: text)
    }

    public static let notFound = StubResponse(status: 404)
}

public struct RecordedRequest: Sendable {
    public var method: String
    public var url: URL
    public var headers: [String: String]
    /// `nil` when the request has no body.
    public var body: Data?

    public var path: String { url.path }
    public var bodyText: String? { body.map { String(decoding: $0, as: UTF8.self) } }

    public func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

/// A fake HTTP host, reached through a session from `StubServer.makeSession()` or `session()`.
///
/// Each session routes requests to its own server, including requests to the real API host names.
// @unchecked: all mutable state is behind `lock`.
public final class StubServer: @unchecked Sendable {
    /// Gets the request and how many earlier requests went to the same URL.
    public typealias Handler = @Sendable (RecordedRequest, Int) -> StubResponse

    public let host = "\(UUID().uuidString.lowercased()).test"
    public var baseURL: URL { URL(string: "https://\(host)")! }

    private let lock = NSLock()
    private let handler: Handler?
    private var routes: [String: Result<StubResponse, URLError>] = [:]
    private var log: [RecordedRequest] = []

    /// Answers the routes set with `on`, and 404 to anything else.
    /// Registered for the rest of the test run; the few leaked servers don't matter.
    public init() {
        handler = nil
        StubServer.register(self)
    }

    /// Answers every request with `handler`.
    public init(_ handler: @escaping Handler) {
        self.handler = handler
        StubServer.register(self)
    }

    public func on(_ method: String, _ path: String, _ response: StubResponse) {
        lock.withLock { routes["\(method) \(path)"] = .success(response) }
    }

    public func on(_ method: String, _ path: String, fail error: URLError) {
        lock.withLock { routes["\(method) \(path)"] = .failure(error) }
    }

    public var requests: [RecordedRequest] { lock.withLock { log } }

    public func requests(to url: String) -> [RecordedRequest] { requests.filter { $0.url.absoluteString == url } }

    /// A session whose requests to hosts other than a stub server's all come to this server.
    public func session() -> URLSession {
        let configuration = Self.configuration()
        #if canImport(FoundationNetworking)
            // Swift 6.4's Linux Foundation leaves the session's additional headers off the request a protocol
            // sees, so there the session gets a protocol class of its own, which names the server instead.
            configuration.protocolClasses = [protocolClass]
        #else
            configuration.httpAdditionalHeaders = [Self.serverHeader: host]
        #endif
        return URLSession(configuration: configuration)
    }

    /// A session that reaches stub servers at their `baseURL`.
    public static func makeSession() -> URLSession {
        URLSession(configuration: configuration())
    }

    private static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return configuration
    }

    /// Records `request` and answers it; a route set to `fail` answers 502 here. Lets a handler pass
    /// requests on to another server.
    public func respond(to request: RecordedRequest) -> StubResponse {
        (try? answer(request).get()) ?? StubResponse(status: 502)
    }

    fileprivate func answer(_ request: RecordedRequest) -> Result<StubResponse, URLError> {
        let earlier = lock.withLock {
            log.append(request)
            return log.dropLast().filter { $0.url == request.url }.count
        }
        if let handler { return .success(handler(request, earlier)) }
        return lock.withLock { routes["\(request.method) \(request.path)"] ?? .success(.notFound) }
    }

    // MARK: Registry

    private static let registryLock = NSLock()
    // Safe: only read or written under `registryLock`.
    nonisolated(unsafe) private static var servers: [String: StubServer] = [:]
    private static let serverHeader = "X-Higgsfield-Test-Server"

    private static func register(_ server: StubServer) {
        registryLock.withLock { servers[server.host] = server }
    }

    fileprivate static func server(for request: URLRequest, protocolClass: AnyClass) -> StubServer? {
        let host = request.url?.host ?? ""
        let fallback = request.value(forHTTPHeaderField: serverHeader) ?? ""
        return registryLock.withLock {
            servers[host] ?? servers[fallback] ?? protocolServers[ObjectIdentifier(protocolClass)]
        }
    }

    #if canImport(FoundationNetworking)
        // Safe: only read or written under `registryLock`.
        nonisolated(unsafe) private static var protocolServers: [ObjectIdentifier: StubServer] = [:]
        nonisolated(unsafe) private static var protocolCount = 0

        /// A `StubProtocol` subclass that only this server's sessions use.
        private var protocolClass: AnyClass {
            Self.registryLock.withLock {
                if let known = Self.protocolServers.first(where: { $0.value === self }) {
                    return Self.protocolClasses[known.key]!
                }
                Self.protocolCount += 1
                let type = Self.taggedProtocol(Self.protocolCount, Never.self)
                Self.protocolServers[ObjectIdentifier(type)] = self
                Self.protocolClasses[ObjectIdentifier(type)] = type
                return type
            }
        }

        nonisolated(unsafe) private static var protocolClasses: [ObjectIdentifier: AnyClass] = [:]

        /// A distinct class for each `number`: its binary digits, as nested generic tags.
        private static func taggedProtocol<Tag>(_ number: Int, _: Tag.Type) -> AnyClass {
            guard number > 0 else { return TaggedStubProtocol<Tag>.self }
            return number & 1 == 0
                ? taggedProtocol(number >> 1, Digit0<Tag>.self) : taggedProtocol(number >> 1, Digit1<Tag>.self)
        }
    #else
        private static let protocolServers: [ObjectIdentifier: StubServer] = [:]
    #endif
}

class StubProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url, let server = StubServer.server(for: request, protocolClass: type(of: self)) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        let recorded = RecordedRequest(
            method: request.httpMethod ?? "GET", url: url, headers: request.allHTTPHeaderFields ?? [:],
            body: Self.body(of: request))
        switch server.answer(recorded) {
        case .success(let stub):
            if let response = HTTPURLResponse(
                url: url, statusCode: stub.status, httpVersion: "HTTP/1.1", headerFields: stub.headers)
            {
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            }
            client?.urlProtocol(self, didLoad: Data(stub.body.utf8))
            if !stub.keepsOpen { client?.urlProtocolDidFinishLoading(self) }
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    /// URLSession hands protocols the body as a stream, not `httpBody`.
    private static func body(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

#if canImport(FoundationNetworking)
    private enum Digit0<Tag> {}
    private enum Digit1<Tag> {}
    private final class TaggedStubProtocol<Tag>: StubProtocol {}
#endif
