import Foundation
import Testing

@testable import JobEngine
@testable import JutsuCore

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

@Suite(.timeLimit(.minutes(1)))
struct ServerImageReaderTests {
    @Test(arguments: [true, false])
    func anOversizedStreamIsStoppedBeforeItsWholeBodyArrives(declaresLength: Bool) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ImageStreamStub.self]
        let url = try #require(URL(string: "https://example.org/\(UUID())?length=\(declaresLength)"))
        let reader = ServerImageReader(session: URLSession(configuration: configuration), maxBytes: 16)
        await #expect(throws: MediaLinkError.tooLarge(maxBytes: 16)) { try await reader.data(from: url) }
        // Linux Foundation doesn't stop a protocol whose task is cancelled from its response handler, so there the
        // stub sends the rest anyway; the app runs on macOS, where the stream stops.
        #if !canImport(FoundationNetworking)
            #expect(ImageStreamStub.sent.count(for: url) < 8192)
        #endif
    }

    func reader(maxBytes: Int64 = 1 << 20) -> ServerImageReader {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MediaLinkStub.self]
        return ServerImageReader(session: URLSession(configuration: configuration), maxBytes: maxBytes)
    }

    func link(_ query: String, scheme: String = "https") throws -> URL {
        try #require(URL(string: "\(scheme)://cdn.example.org/thumbs/a?\(query)"))
    }

    @Test func anImageIsRead() async throws {
        #expect(try await reader().data(from: try link("type=image/webp")).count == 12)
        #expect(try await reader().data(from: try link("type=image/avif")).count == 12)
    }

    @Test func aGenericTypeIsLeftToTheDecoder() async throws {
        #expect(try await reader().data(from: try link("type=application/octet-stream")).count == 12)
    }

    @Test(arguments: ["http", "file", "ftp"])
    func onlyHTTPSIsRequested(scheme: String) async throws {
        await #expect(throws: MediaLinkError.notHTTPS) {
            try await reader().data(from: try link("type=image/png", scheme: scheme))
        }
    }

    @Test func aPageIsRefused() async throws {
        await #expect(throws: MediaLinkError.notMedia(contentType: "text/html")) {
            try await reader().data(from: try link("type=text/html;%20charset=utf-8"))
        }
    }

    @Test func aPictureOverTheLimitIsRefused() async throws {
        await #expect(throws: MediaLinkError.tooLarge(maxBytes: 8)) {
            try await reader(maxBytes: 8).data(from: try link("type=image/png&size=20"))
        }
    }

    @Test func aMissingPictureSaysTheStatus() async throws {
        await #expect(throws: MediaLinkError.unavailable(status: 404)) {
            try await reader().data(from: try link("type=image/png&status=404"))
        }
    }
}

private final class ImageStreamStub: URLProtocol {
    static let sent = SentBytes()
    private let lock = NSLock()
    private var stopped = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        var headers = ["Content-Type": "image/png"]
        if url.query == "length=true" { headers["Content-Length"] = "8192" }
        guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)
        else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let stream = Stream(loader: self, url: url)
        DispatchQueue.global().async { stream.send() }
    }

    override func stopLoading() { lock.withLock { stopped = true } }

    private struct Stream: @unchecked Sendable {
        // One worker delivers URLProtocol client callbacks; stopLoading touches only the locked cancellation flag.
        let loader: ImageStreamStub
        let url: URL

        func send() {
            for _ in 0..<8 {
                Thread.sleep(forTimeInterval: 0.01)
                guard !loader.lock.withLock({ loader.stopped }) else { return }
                ImageStreamStub.sent.add(1024, for: url)
                loader.client?.urlProtocol(loader, didLoad: Data(repeating: 7, count: 1024))
            }
            loader.client?.urlProtocolDidFinishLoading(loader)
        }
    }

    final class SentBytes: @unchecked Sendable {
        // Safe: counts are accessed only under lock.
        private let lock = NSLock()
        private var counts: [URL: Int] = [:]
        func add(_ count: Int, for url: URL) { lock.withLock { counts[url, default: 0] += count } }
        func count(for url: URL) -> Int { lock.withLock { counts[url, default: 0] } }
    }
}
