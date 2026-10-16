import Foundation
import HiggsfieldCore
import HiggsfieldTestSupport
import Testing

@testable import HiggsfieldMCP

/// `show_reference_elements` (issue #43), against the tool schema of the catalog snapshot of 2026-10-15. The answers are in the shape of the tools' `outputSchema`s; the snapshot has no live answer.
extension Network {
    @Suite struct ReferenceElements {
        static func tools() throws -> [JSONValue] {
            Account.fullSet + [try CatalogSnapshot.tool("show_reference_elements")]
        }

        static func account(
            tools: [JSONValue]? = nil, _ reply: @escaping @Sendable (String, JSONValue) -> JSONValue = { _, _ in [:] }
        ) throws -> (HiggsfieldAccount, StubServer) {
            Account.account(tools: try tools ?? Self.tools(), call: reply)
        }

        /// An element as the `outputSchema` describes it: in a list, `medias` holds only the first image.
        static func element(
            id: String, name: String, category: String, status: String = "completed", medias: [JSONValue]
        ) -> JSONValue {
            [
                "id": .string(id), "name": .string(name), "category": .string(category), "description": .null,
                "status": .string(status), "medias": .array(medias), "video_medias": [], "created_at": 1_760_000_000,
            ]
        }

        @Test func listSendsTheActionAndReadsElementsWithTheirFirstImage() async throws {
            let (account, stub) = try Self.account { _, _ in
                [
                    "items": [
                        Self.element(
                            id: "el-1", name: "Mara", category: "character_ip_verified",
                            medias: [
                                ["id": "m-1", "url": "https://upload.higgsfield.ai/u/1.jpg", "type": "media_input"]
                            ]
                        ),
                        Self.element(
                            id: "el-2", name: "Rooftop", category: "environment", status: "processing",
                            medias: [["id": "job-9", "url": "https://cdn.higgsfield.ai/2.png", "type": "image_job"]]),
                        Self.element(
                            id: "el-3", name: "Lamp", category: "prop",
                            medias: [["id": "m-3", "url": "http://insecure.example.com/3.jpg", "type": "media_input"]]),
                        ["name": "No ID"],
                    ],
                    "next_cursor": 1_759_999_000,
                ]
            }

            let page = try await account.referenceElements(cursor: 1_760_000_500, size: 300)

            #expect(page.nextCursor == 1_759_999_000)
            #expect(page.items.map(\.id) == ["el-1", "el-2", "el-3"])
            let mara = try #require(page.items.first)
            #expect(mara.name == "Mara")
            #expect(mara.category == .character)
            #expect(mara.status == "completed")
            #expect(mara.thumbnailURL == URL(string: "https://upload.higgsfield.ai/u/1.jpg"))
            #expect(mara.images == [.init(url: URL(string: "https://upload.higgsfield.ai/u/1.jpg")!, mediaID: "m-1")])
            #expect(page.items[1].images.map(\.mediaID) == ["job-9"])
            #expect(page.items[1].status == "processing")
            #expect(page.items[2].images.isEmpty)
            #expect(page.items[2].thumbnailURL == nil)
            #expect(
                Account.calls(stub) == [
                    [
                        "name": "show_reference_elements",
                        "arguments": ["action": "list", "size": 100, "cursor": 1_760_000_500],
                    ]
                ])
            #expect(try Account.schemaViolations(stub).isEmpty)
        }

        @Test func getReadsTheOneItemWithAllItsImages() async throws {
            let (account, stub) = try Self.account { _, _ in
                [
                    "items": [
                        Self.element(
                            id: "3f1c8a52-6b0e-4d7a-9a51-2f4b8c9d0e17", name: "Mara", category: "character",
                            medias: [
                                ["id": "m-1", "url": "https://upload.higgsfield.ai/u/1.jpg", "type": "media_input"],
                                ["id": "m-2", "url": "https://upload.higgsfield.ai/u/2.jpg", "type": "media_input"],
                            ])
                    ]
                ]
            }

            let element = try await account.referenceElement(id: "3f1c8a52-6b0e-4d7a-9a51-2f4b8c9d0e17")

            #expect(element.images.map(\.mediaID) == ["m-1", "m-2"])
            #expect(element.thumbnailURL == URL(string: "https://upload.higgsfield.ai/u/1.jpg"))
            #expect(
                Account.calls(stub).first?["arguments"]
                    == ["action": "get", "element_id": "3f1c8a52-6b0e-4d7a-9a51-2f4b8c9d0e17"])
            #expect(try Account.schemaViolations(stub).isEmpty)
        }

        @Test func aGetWithoutTheElementGivesTheServersReason() async throws {
            let (account, _) = try Self.account { _, _ in ["error": "Element not found"] }
            await #expect(throws: HiggsfieldError.validation(field: nil, message: "Element not found")) {
                try await account.referenceElement(id: "3f1c8a52-6b0e-4d7a-9a51-2f4b8c9d0e17")
            }
        }

        @Test func anAnswerWithoutItemsIsUnexpected() async throws {
            let (account, _) = try Self.account { _, _ in ["elements": []] }
            await #expect(
                throws: HiggsfieldError.validation(
                    field: nil, message: "Unexpected result from the show_reference_elements tool")
            ) {
                try await account.referenceElements()
            }
        }

        static let uploads = [
            UploadedMedia(id: "m-1", url: URL(string: "https://upload.higgsfield.ai/user_1/1.png")!),
            UploadedMedia(id: "m-2", url: URL(string: "https://upload.higgsfield.ai/user_1/2.png")!),
        ]

        @Test func createSendsTheUploadsAndReadsTheNewElement() async throws {
            let (account, stub) = try Self.account { _, arguments in
                [
                    "element": Self.element(
                        id: "3f1c8a52-6b0e-4d7a-9a51-2f4b8c9d0e17", name: "Mara-in-red", category: "character",
                        status: "processing", medias: arguments["medias"]?.arrayValue ?? [])
                ]
            }

            let element = try await account.createReferenceElement(
                name: "  Mara in red, the main character of the series  ", category: .character, images: Self.uploads)

            #expect(element.id == "3f1c8a52-6b0e-4d7a-9a51-2f4b8c9d0e17")
            #expect(element.category == .character)
            #expect(element.images.map(\.mediaID) == ["m-1", "m-2"])
            #expect(
                Account.calls(stub) == [
                    [
                        "name": "show_reference_elements",
                        "arguments": [
                            "action": "create", "category": "character",
                            // Cut to the schema's 32 characters.
                            "name": "Mara in red, the main character",
                            "medias": [
                                [
                                    "id": "m-1", "url": "https://upload.higgsfield.ai/user_1/1.png",
                                    "type": "media_input",
                                ],
                                [
                                    "id": "m-2", "url": "https://upload.higgsfield.ai/user_1/2.png",
                                    "type": "media_input",
                                ],
                            ],
                        ],
                    ]
                ])
            #expect(try Account.schemaViolations(stub).isEmpty)
        }

        @Test func createWithoutANameLetsTheServerNameAndClassifyIt() async throws {
            let (account, stub) = try Self.account { _, _ in
                ["element": Self.element(id: "el-1", name: "auto-name", category: "prop", medias: [])]
            }

            _ = try await account.createReferenceElement(name: " ", category: nil, images: [Self.uploads[0]])

            let arguments = Account.calls(stub).first?["arguments"]
            #expect(arguments?["name"] == nil)
            #expect(arguments?["category"] == "auto")
            #expect(try Account.schemaViolations(stub).isEmpty)
        }

        @Test func aRefusedCreateGivesTheServersReason() async throws {
            let (account, _) = try Self.account { _, _ in ["error": "Image failed moderation"] }
            await #expect(throws: HiggsfieldError.validation(field: nil, message: "Image failed moderation")) {
                try await account.createReferenceElement(name: "Mara", category: .character, images: Self.uploads)
            }
        }

        @Test func aToolThatCantCreateIsReportedWithoutACall() async throws {
            let listOnly = tool("show_reference_elements", "Elements", ["action", "element_id", "cursor", "size"])
            let (account, stub) = try Self.account(tools: Account.fullSet + [listOnly])
            await #expect(throws: HiggsfieldError.toolUnavailable("show_reference_elements")) {
                try await account.createReferenceElement(name: "Mara", category: .character, images: Self.uploads)
            }
            #expect(Account.calls(stub).isEmpty)
        }

        @Test func aMissingToolIsReportedWithoutACall() async throws {
            let (account, stub) = try Self.account(tools: Account.fullSet)
            await #expect(throws: HiggsfieldError.toolUnavailable("show_reference_elements")) {
                try await account.referenceElements()
            }
            #expect(Account.calls(stub).isEmpty)
        }
    }
}
