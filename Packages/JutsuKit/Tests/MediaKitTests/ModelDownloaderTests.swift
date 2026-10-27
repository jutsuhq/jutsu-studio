import Foundation
import JutsuCore
import Testing

@testable import MediaKit

/// Serves "hello" for every file but one named "bad", which has other content of the same size, and answers a
/// `Range` request with just that part, as Hugging Face does.
final class ModelFileStub: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let body = Data((url.lastPathComponent == "bad" ? "jello" : "hello").utf8)
        var part = body
        var status = 200
        if let range = request.value(forHTTPHeaderField: "Range")?.dropFirst("bytes=".count).split(separator: "-"),
            let first = range.first.flatMap({ Int($0) }), let last = range.last.flatMap({ Int($0) })
        {
            part = body.subdata(in: first..<min(last + 1, body.count))
            status = 206
        }
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)
        else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: part)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite(.timeLimit(.minutes(1)))
struct ModelDownloaderTests {
    let folder = FileManager.default.temporaryDirectory.appending(path: "ModelDownloader-\(UUID())")
    /// "hello", by SHA-256 and by Git's blob hash.
    let sha256 = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
    let gitBlob = "b6fc4c620b67d95f953a5c1c1230aaab5db5a1b0"

    var downloader: ModelDownloader {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModelFileStub.self]
        return ModelDownloader(session: URLSession(configuration: configuration))
    }

    func manifest(_ files: [ModelManifest.File]) -> ModelManifest {
        ModelManifest(repository: "owner/model", revision: "0123abcd", files: files)
    }

    private func write(_ text: String, to path: String) throws -> URL {
        let url = folder.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    @Test func aFileMatchesByEitherHashAndAtItsSizeOnly() throws {
        let good = try write("hello", to: "good")
        let other = try write("jello", to: "other")

        #expect(try ModelDownloader.matches(good, .init(path: "good", size: 5, sha256: sha256)))
        #expect(try ModelDownloader.matches(good, .init(path: "good", size: 5, gitBlob: gitBlob)))
        #expect(try !ModelDownloader.matches(other, .init(path: "other", size: 5, sha256: sha256)))
        #expect(try !ModelDownloader.matches(other, .init(path: "other", size: 5, gitBlob: gitBlob)))
        #expect(try !ModelDownloader.matches(good, .init(path: "good", size: 6, sha256: sha256)))
        #expect(try !ModelDownloader.matches(good, .init(path: "good", size: 5)))
    }

    @Test func downloadsCheckedFilesAndResumesAPartialOne() async throws {
        let files: [ModelManifest.File] = [
            .init(path: "Model.mlmodelc/weights/weight.bin", size: 5, sha256: sha256),
            .init(path: "vocab.json", size: 5, gitBlob: gitBlob),
        ]
        _ = try write("he", to: "vocab.json.part")
        #expect(!downloader.isComplete(manifest(files), in: folder))

        let fractions = FractionLog()
        try await downloader.download(manifest(files), into: folder) { fractions.append($0) }

        #expect(downloader.isComplete(manifest(files), in: folder))
        #expect(try String(contentsOf: folder.appending(path: "vocab.json"), encoding: .utf8) == "hello")
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "vocab.json.part").path))
        #expect(fractions.values.last == 1)
        #expect(downloader.size(of: folder) > 0)
        try downloader.remove(folder)
        #expect(downloader.size(of: folder) == 0)
        try downloader.remove(folder)
    }

    @Test func aFileWithOtherContentIsDeletedAndFails() async throws {
        let files: [ModelManifest.File] = [.init(path: "bad", size: 5, sha256: sha256)]

        await #expect(throws: ModelDownloadError.checksumMismatch("bad")) {
            try await downloader.download(manifest(files), into: folder) { _ in }
        }
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "bad").path))
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "bad.part").path))
        try? FileManager.default.removeItem(at: folder)
    }

    @Test func eachFileComesFromThePinnedRevision() throws {
        let file = ModelManifest.File(path: "Encoder v3.mlmodelc/model.mil", size: 1)
        let url = try #require(manifest([file]).url(of: file))
        #expect(
            url.absoluteString == "https://huggingface.co/owner/model/resolve/0123abcd/Encoder%20v3.mlmodelc/model.mil")
        #expect(ParakeetUltra.manifest.files.count == 18)
        #expect(ParakeetUltra.manifest.size == 632_162_964)
        #expect(ParakeetUltra.manifest.files.allSatisfy { ($0.sha256 == nil) != ($0.gitBlob == nil) })
        #expect(ParakeetUltra.manifest.revision.count == 40)
    }
}

/// The fractions a download reported, in order.
final class FractionLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [Double] = []
    var values: [Double] { lock.withLock { _values } }
    func append(_ value: Double) { lock.withLock { _values.append(value) } }
}
