import Foundation
import HiggsfieldCore
import HiggsfieldTestSupport
import Testing

@testable import HiggsfieldMCP

/// `media_import_url` (issue #90), against the tool's schema in the catalog snapshot of 2026-10-15.
extension Network {
    @Suite struct MediaImport {
        static func tools() throws -> [JSONValue] {
            Account.fullSet + [try CatalogSnapshot.tool("media_import_url")]
        }

        static let link = URL(string: "https://videos.example.com/clip.mp4")!

        @Test func importSendsTheLinkAndTypeAndReadsTheMediaID() async throws {
            let (account, stub) = Account.account(tools: try Self.tools()) { _, _ in
                [
                    "media_id": "5b7d1e90-2a4c-4e8f-9d36-7c1a2b3e4f50", "type": "video", "content_type": "video/mp4",
                    "source_url": "https://videos.example.com/clip.mp4",
                ]
            }

            #expect(
                try await account.importMedia(from: Self.link, type: "video") == "5b7d1e90-2a4c-4e8f-9d36-7c1a2b3e4f50")
            #expect(
                Account.calls(stub) == [
                    [
                        "name": "media_import_url",
                        "arguments": ["url": "https://videos.example.com/clip.mp4", "type": "video"],
                    ]
                ])
            #expect(try Account.schemaViolations(stub).isEmpty)
        }

        @Test func anAnswerWithoutAMediaIDIsARefusal() async throws {
            let (account, _) = Account.account(tools: try Self.tools()) { _, _ in ["error": "File is over 50 MB"] }
            await #expect(throws: HiggsfieldError.validation(field: nil, message: "File is over 50 MB")) {
                try await account.importMedia(from: Self.link, type: "video")
            }
        }

        @Test func aMissingToolIsReported() async throws {
            let (account, stub) = Account.account()
            await #expect(throws: HiggsfieldError.toolUnavailable("media_import_url")) {
                try await account.importMedia(from: Self.link, type: "image")
            }
            #expect(Account.calls(stub).isEmpty)
        }
    }
}
