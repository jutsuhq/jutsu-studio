import Foundation
import Testing

@testable import JobEngine
@testable import JutsuCore

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Answers every request with the whole body, ignoring `Range`. Query options: `type=<Content-Type>` (none when
/// left out), `status=<code>`, `size=<bytes>` of body (default 12).
final class MediaLinkStub: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func option(_ name: String) -> String? { query.first { $0.name == name }?.value }
        let status = option("status").flatMap(Int.init) ?? 200
        let body = Data(repeating: 7, count: option("size").flatMap(Int.init) ?? 12)
        var headers = ["Content-Length": "\(body.count)"]
        if let type = option("type") { headers["Content-Type"] = type }
        guard
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)
        else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: status < 300 ? body : Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite(.timeLimit(.minutes(1)))
struct MediaLinkDownloaderTests {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MediaLinks-\(UUID().uuidString)")

    func downloader(maxBytes: Int64 = 1 << 20, freeSpace: Int64? = nil) -> MediaLinkDownloader {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MediaLinkStub.self]
        return MediaLinkDownloader(
            session: URLSession(configuration: configuration), maxBytes: maxBytes, freeSpace: { _ in freeSpace })
    }

    func link(_ path: String, _ query: String) throws -> URL {
        try #require(URL(string: "https://cdn.example.org/\(path)?\(query)"))
    }

    /// What is left in `folder` after a download: nothing after a failure.
    var leftovers: [String] {
        (try? FileManager.default.subpathsOfDirectory(atPath: folder.path)) ?? []
    }

    @Test func aDirectVideoLinkBecomesAFileNamedAfterIt() async throws {
        let fractions = FractionLog()
        let link = try link("clips/Dance%20Take.mp4", "type=video/mp4")

        let media = try await downloader().download(link, into: folder) { fractions.append($0) }

        #expect(media.kind == .video)
        #expect(media.origin == link)
        #expect(media.fileURL.lastPathComponent == "Dance Take.mp4")
        // Paths, not URLs: Linux Foundation keeps a directory URL's trailing slash where Darwin's drops it.
        #expect(
            media.fileURL.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL.path
                == folder.standardizedFileURL.path)
        #expect(try Data(contentsOf: media.fileURL).count == 12)
        #expect(fractions.all.last == 1)
    }

    @Test func aGenericTypeIsNamedByTheLinksExtension() async throws {
        let media = try await downloader().download(
            try link("photo.PNG", "type=application/octet-stream"), into: folder)

        #expect(media.kind == .image)
        #expect(media.fileURL.pathExtension == "png")
    }

    @Test func aWebPageIsRefusedAndNothingIsKept() async throws {
        let watchPage = try link("watch", "type=text/html;%20charset=utf-8")

        await #expect(throws: MediaLinkError.notMedia(contentType: "text/html")) {
            try await downloader().download(watchPage, into: folder)
        }
        #expect(leftovers.isEmpty)
    }

    @Test func aVideoWhereAnImageWasAskedForIsRefused() async throws {
        await #expect(throws: MediaLinkError.wrongKind(expected: .image)) {
            try await downloader().download(try link("a.mp4", "type=video/mp4"), into: folder, expected: .image)
        }
        #expect(leftovers.isEmpty)
    }

    @Test func aFileOverTheLimitIsRefused() async throws {
        await #expect(throws: MediaLinkError.tooLarge(maxBytes: 8)) {
            try await downloader(maxBytes: 8).download(try link("big.mp4", "type=video/mp4&size=20"), into: folder)
        }
        #expect(leftovers.isEmpty)
    }

    @Test func aFullDiskIsSaid() async throws {
        await #expect(throws: MediaLinkError.notEnoughSpace) {
            try await downloader(freeSpace: 4).download(try link("a.mp4", "type=video/mp4"), into: folder)
        }
    }

    @Test func aMissingFileSaysTheStatus() async throws {
        await #expect(throws: MediaLinkError.unavailable(status: 404)) {
            try await downloader().download(try link("gone.mp4", "status=404"), into: folder)
        }
        #expect(leftovers.isEmpty)
    }

    @Test func plainHTTPIsNeverRequested() async throws {
        let insecure = try #require(URL(string: "http://cdn.example.org/a.mp4?type=video/mp4"))
        await #expect(throws: MediaLinkError.notHTTPS) {
            try await downloader().download(insecure, into: folder)
        }
    }

    @Test func anEmptyAnswerIsNotMedia() async throws {
        await #expect(throws: MediaLinkError.notMedia(contentType: nil)) {
            try await downloader().download(try link("a.mp4", "type=video/mp4&size=0"), into: folder)
        }
    }

    @Test func aFileAlreadySavedIsNotDownloadedAgain() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("clip.mp4")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("kept".utf8).write(to: file)

        // Requested, the link would fail.
        try await downloader().download(try link("clip.mp4", "status=404"), to: file, expected: .video)

        #expect(try Data(contentsOf: file) == Data("kept".utf8))
    }

    /// Another download of the same file finishing while this one runs: the file is replaced whole, not refused.
    @Test func aFileSavedDuringTheDownloadIsReplacedWhole() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("account-media").appendingPathComponent("photo.png")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MediaLinkStub.self]
        let racing = MediaLinkDownloader(session: URLSession(configuration: configuration)) { _ in
            try? Data("other".utf8).write(to: file)
            return nil
        }

        try await racing.download(try link("photo.png", "type=image/png"), to: file, expected: .image)

        #expect(try Data(contentsOf: file) == Data(repeating: 7, count: 12))
        #expect(Set(leftovers) == ["account-media", "account-media/photo.png"])
    }

    @Test func aFileOfTheWrongKindIsNotSaved() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("photo.png")

        await #expect(throws: MediaLinkError.wrongKind(expected: .image)) {
            try await downloader().download(try link("photo.mp4", "type=video/mp4"), to: file, expected: .image)
        }
        #expect(leftovers.isEmpty)
    }
}

/// Progress reported from the session's queue.
final class FractionLog: @unchecked Sendable {
    // Safe: `entries` is only touched under `lock`.
    private let lock = NSLock()
    private var entries: [Double?] = []

    func append(_ fraction: Double?) {
        lock.lock()
        defer { lock.unlock() }
        entries.append(fraction)
    }

    var all: [Double?] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }
}
