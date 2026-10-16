import Foundation
import HiggsfieldMCP
import HiggsfieldTestSupport
import JutsuCore
import Testing

@testable import HiggsfieldProviders

@Suite struct LinkedInputTests {
    let origin = URL(string: "https://media.example.org/clip.mp4")!

    @Test func anAPIKeySendsALinkedFileByItsLinkUpTo200MiB() async throws {
        let server = StubServer()
        let provider = server.makeAPIProvider()

        let linked = try await provider.linkedAsset(origin, kind: .video, byteCount: 5_000_000)
        let tooLarge = try await provider.linkedAsset(origin, kind: .video, byteCount: 201 * 1024 * 1024)
        let insecure = try #require(URL(string: "http://media.example.org/clip.mp4"))
        let notHTTPS = try await provider.linkedAsset(insecure, kind: .video, byteCount: 1)

        #expect(linked == RemoteAsset(url: origin))
        #expect(tooLarge == nil)
        #expect(notHTTPS == nil)
        #expect(server.requests.isEmpty)
    }

    @Test func theSubmitBodyNamesTheLinkInsteadOfAnUpload() async throws {
        let server = StubServer()
        server.on(
            "POST", "/higgsfield/genjutsu/motion-transfer/v1.0",
            StubResponse(body: #"{"status": "queued", "request_id": "req-1"}"#))
        let image = try #require(URL(string: "https://images.example.org/face.png"))
        let source = SourceClip(
            fileURL: URL(fileURLWithPath: "/tmp/clip.mp4"), duration: 8, pixelSize: PixelSize(width: 1280, height: 720),
            range: 0...8, remoteOrigin: origin)
        let spec = JobSpec(mode: .motionTransfer, source: source, resolution: .p720)
        let inputs = RemoteInputs(video: RemoteAsset(url: origin), images: [RemoteAsset(url: image)])

        _ = try await server.makeAPIProvider().submit(spec, inputs: inputs, idempotencyKey: UUID())

        let body = try #require(server.requests.first?.body)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["video_url"] as? String == origin.absoluteString)
        #expect(json["image_urls"] as? [String] == [image.absoluteString])
    }

}

extension Network {
    /// The account imports a linked file with `media_import_url` (the catalog snapshot of 2026-10-15's tool).
    @Suite struct AccountLinkedInputs {
        static let origin = URL(string: "https://media.example.org/clip.mp4")!
        static let mediaID = "5b7d1e90-2a4c-4e8f-9d36-7c1a2b3e4f50"

        static func provider(
            _ reply: @escaping @Sendable (JSONValue) -> JSONValue
        ) throws -> (HiggsfieldMCPProvider, StubServer) {
            Provider.provider(tools: Provider.fullSet + [try CatalogSnapshot.tool("media_import_url")]) {
                name, arguments in name == "media_import_url" ? reply(arguments) : [:]
            }
        }

        @Test func aLinkedFileUpTo50MBIsImportedByItsLink() async throws {
            let (provider, stub) = try Self.provider { _ in ["media_id": .string(Self.mediaID), "type": "video"] }

            let linked = try await provider.linkedAsset(Self.origin, kind: .video, byteCount: 50_000_000)

            #expect(linked == RemoteAsset(url: Self.origin, id: Self.mediaID))
            #expect(
                Provider.calls(stub) == [
                    [
                        "name": "media_import_url",
                        "arguments": ["url": "https://media.example.org/clip.mp4", "type": "video"],
                    ]
                ])
            #expect(try Provider.schemaViolations(stub).isEmpty)
        }

        @Test func aLargeOrInsecureFileIsUploadedWithoutACall() async throws {
            let (provider, stub) = try Self.provider { _ in ["media_id": .string(Self.mediaID)] }
            let insecure = try #require(URL(string: "http://media.example.org/clip.mp4"))

            #expect(try await provider.linkedAsset(Self.origin, kind: .video, byteCount: 50_000_001) == nil)
            #expect(try await provider.linkedAsset(insecure, kind: .image, byteCount: 1000) == nil)
            #expect(Provider.calls(stub).isEmpty)
        }

        @Test func aRefusedImportOrAMissingToolUploads() async throws {
            let (refusing, _) = try Self.provider { _ in ["error": "Remote host refused the download"] }
            #expect(try await refusing.linkedAsset(Self.origin, kind: .image, byteCount: 1000) == nil)

            let (without, stub) = Provider.provider(tools: Provider.fullSet)
            #expect(try await without.linkedAsset(Self.origin, kind: .video, byteCount: 1000) == nil)
            #expect(Provider.calls(stub).isEmpty)
        }
    }
}
