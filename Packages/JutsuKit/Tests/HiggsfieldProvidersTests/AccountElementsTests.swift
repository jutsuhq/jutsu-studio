import Foundation
import HiggsfieldCore
import HiggsfieldMCP
import HiggsfieldTestSupport
import JutsuCore
import Testing

@testable import HiggsfieldProviders

extension Network {
    /// The account's elements (issue #43), with the tool definition of the catalog snapshot of 2026-10-15 and answers
    /// in the shape of its `outputSchema`.
    @Suite struct AccountElementsProvider {
        static func tools() throws -> [JSONValue] {
            Provider.fullSet + [try CatalogSnapshot.tool("show_reference_elements")]
        }
        static let media = ServerMedia(id: "m-1", url: URL(string: "https://cdn.example.com/1.jpg")!, owner: "user_1")
        static let elementID = "3f1c8a52-6b0e-4d7a-9a51-2f4b8c9d0e17"

        static func item(_ id: String, _ name: String, status: String, medias: [JSONValue] = []) -> JSONValue {
            [
                "id": .string(id), "name": .string(name), "category": "prop", "description": .null,
                "status": .string(status), "medias": .array(medias), "video_medias": [], "created_at": 1_760_000_000,
            ]
        }

        static func reply(_ name: String, _ arguments: JSONValue) -> JSONValue {
            let first: JSONValue = ["id": "m-1", "url": "https://cdn.example.com/1.jpg", "type": "media_input"]
            switch (name, arguments["action"]) {
            case ("show_reference_elements", "list"):
                return [
                    "items": [
                        item(elementID, "Mara", status: "completed", medias: [first]),
                        item("el-2", "Checking", status: "ip_checking"),
                        item("el-3", "Refused", status: "nsfw"),
                    ],
                    "next_cursor": 1_759_999_000,
                ]
            case ("show_reference_elements", "get"):
                let second: JSONValue = ["id": "job-7", "url": "https://cdn.example.com/2.png", "type": "image_job"]
                return ["items": [item(elementID, "Mara", status: "completed", medias: [first, second])]]
            case ("generate_video", _):
                return ["results": [["id": "job-1"]]]
            default:
                return [:]
            }
        }

        @Test func elementsListUsableOnesAndGetTheirImages() async throws {
            let (provider, stub) = Provider.provider(tools: try Self.tools(), call: Self.reply)

            let elements = try await provider.elements(after: nil)
            let listed = try #require(elements.items.first)
            let full = try await provider.elementImages(listed)

            // Only a completed element can be used: one still being checked, or refused, is left out.
            #expect(elements.items.map(\.id) == [Self.elementID])
            #expect(listed.category == .prop)
            #expect(listed.thumbnailURL == Self.media.url)
            // A list names only the first image, so the element asks `get` for all of them.
            #expect(listed.images.isEmpty)
            #expect(elements.nextCursor != nil)
            #expect(
                full.images == [
                    ElementImage(url: Self.media.url, media: Self.media),
                    ElementImage(
                        url: URL(string: "https://cdn.example.com/2.png")!,
                        media: ServerMedia(
                            id: "job-7", url: URL(string: "https://cdn.example.com/2.png")!, owner: "user_1")),
                ])
            #expect(Provider.calls(stub).map { $0["arguments"]?["action"] } == ["list", "get"])
            #expect(try Provider.schemaViolations(stub).isEmpty)
        }

        @Test func anElementImageIsSentByItsMediaIDOnlyForItsAccount() async throws {
            let (provider, stub) = Provider.provider(tools: try Self.tools(), call: Self.reply)
            let other = ServerMedia(id: "m-9", url: Self.media.url, owner: "user_2")

            let asset = try #require(try await provider.serverAsset(Self.media))
            #expect(try await provider.serverAsset(other) == nil)
            let inputs = RemoteInputs(video: Provider.inputs.video, images: [asset])
            _ = try await provider.submit(Provider.spec(.motionTransfer), inputs: inputs, idempotencyKey: UUID())

            let generate = Provider.calls(stub).first { $0["name"] == "generate_video" }
            // The image's own media ID, as a plain reference: never the element's ID, which `medias` doesn't take.
            #expect(
                generate?["arguments"]?["params"]?["medias"]
                    == [
                        ["role": "video_references", "value": "video-1"], ["role": "image_references", "value": "m-1"],
                    ])
            #expect(generate?["arguments"]?["params"]?["prompt"]?.stringValue?.contains("<<<") != true)
        }

        /// The snapshot's `media_upload`, `media_confirm` and `show_reference_elements`; `create` answers with the
        /// element in the shape of its `outputSchema`, still being checked.
        static func publishingServer() throws -> StubServer {
            let tools = [
                try CatalogSnapshot.tool("media_upload"), try CatalogSnapshot.tool("media_confirm"),
                try CatalogSnapshot.tool("show_reference_elements"),
            ]
            let mcp = mcpServer(tools: Provider.fullSet + tools) { name, arguments in
                switch name {
                case "media_upload":
                    return [
                        "uploads": [
                            [
                                "media_id": "m-1", "upload_url": "https://upload.example/put/1?X-Signature=abc",
                                "url": "https://upload.higgsfield.ai/user_1/m-1.png",
                            ]
                        ]
                    ]
                case "media_confirm":
                    return ["results": [["media_id": "m-1", "status": "uploaded"]]]
                case "show_reference_elements":
                    var element = Self.item(Self.elementID, "Mara", status: "processing", medias: [])
                    element = .object(
                        (element.objectValue ?? [:]).merging([
                            "category": "character", "medias": arguments["medias"] ?? [],
                        ]) { $1 })
                    return ["element": element]
                default:
                    return [:]
                }
            }
            return StubServer { request, _ in request.method == "PUT" ? StubResponse() : mcp.respond(to: request) }
        }

        @Test func aSetIsUploadedThenCreatedAsACharacterElement() async throws {
            let stub = try Self.publishingServer()
            let provider = makeProvider(stub.session())
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).png")
            try Data("png".utf8).write(to: file)
            defer { try? FileManager.default.removeItem(at: file) }

            let asset = try await provider.upload(
                PreparedFile(fileURL: file, contentType: "image/png", byteCount: 3, contentHash: "h"))
            let element = try await provider.createElement(name: "Mara", category: .character, images: [asset])

            #expect(element.id == Self.elementID)
            #expect(element.category == .character)
            #expect(element.status == "processing")
            let url = URL(string: "https://upload.higgsfield.ai/user_1/m-1.png")!
            #expect(
                element.images == [ElementImage(url: url, media: ServerMedia(id: "m-1", url: url, owner: "user_1"))])
            let calls = Provider.calls(stub)
            #expect(calls.map { $0["name"] } == ["media_upload", "media_confirm", "show_reference_elements"])
            #expect(
                calls.last?["arguments"]
                    == [
                        "action": "create", "category": "character", "name": "Mara",
                        "medias": [["id": "m-1", "url": .string(url.absoluteString), "type": "media_input"]],
                    ])
            #expect(stub.requests.contains { $0.method == "PUT" })
            #expect(try Provider.schemaViolations(stub).isEmpty)
        }

        @Test func anUploadWithoutAMediaIDIsRefusedBeforeAnythingIsSent() async throws {
            let (provider, stub) = Provider.provider(tools: try Self.tools(), call: Self.reply)
            let local = RemoteAsset(url: URL(string: "https://cdn.example.com/1.jpg")!)

            await #expect(throws: ProviderError.self) {
                try await provider.createElement(name: "Mara", category: .character, images: [local])
            }
            await #expect(throws: ProviderError.self) {
                try await provider.createElement(name: "Mara", category: .character, images: [])
            }
            #expect(Provider.calls(stub).isEmpty)
        }
    }
}
