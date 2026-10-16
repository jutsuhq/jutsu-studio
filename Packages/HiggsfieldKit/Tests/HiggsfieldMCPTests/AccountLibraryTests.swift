import Foundation
import HiggsfieldCore
import HiggsfieldTestSupport
import Testing

@testable import HiggsfieldMCP

extension Network {
    /// Likes, credit history and uploads, with answers shaped as the live server gave them on 2026-10-14.
    @Suite struct AccountLibrary {
        static let tools =
            Account.fullSet + [
                tool("set_generation_like", "Like or unlike a generation", ["job_id", "liked", "folder_id"]),
                tool("transactions", "List the user's credit transactions", ["cursor", "size"]),
                tool(
                    "assets_picker_list", "List existing uploaded assets",
                    ["source", "kind", "cursor", "size", "sort", "project_id"]),
            ]

        static func account(
            _ reply: @escaping @Sendable (String, JSONValue) -> JSONValue
        ) -> (
            HiggsfieldAccount, StubServer
        ) {
            Account.account(tools: tools, call: reply)
        }

        @Test func likeSendsTheJobAndTheState() async throws {
            let (account, stub) = Self.account { _, _ in ["liked": true] }

            try await account.setLiked("job-1", liked: true)
            try await account.setLiked("job-1", liked: false)

            #expect(
                Account.calls(stub) == [
                    ["name": "set_generation_like", "arguments": ["job_id": "job-1", "liked": true]],
                    ["name": "set_generation_like", "arguments": ["job_id": "job-1", "liked": false]],
                ])
        }

        @Test func transactionsReadAmountsAndMicrosecondTimes() async throws {
            let (account, stub) = Self.account { _, _ in
                [
                    "next_cursor": 30,
                    "items": [
                        [
                            "created_at": "2026-10-14T12:25:13.091154Z", "credits": 39, "action": "refund",
                            "display_name": "Higgsfield Genjutsu - Object Swap",
                        ],
                        ["created_at": "2026-10-08T08:55:17Z", "credits": .number(-54.41), "action": "spend"],
                        ["credits": -1, "action": "spend"],
                    ],
                ]
            }

            let page = try await account.transactions(cursor: 0, size: 500)

            #expect(page.nextCursor == 30)
            #expect(page.items.count == 2)
            let refund = try #require(page.items.first)
            #expect(refund.credits == 39 && refund.action == "refund")
            #expect(refund.title == "Higgsfield Genjutsu - Object Swap")
            #expect(abs(refund.date.timeIntervalSince1970 - 1_791_980_713.091154) < 0.000_01)
            #expect(page.items[1].credits == -54.41 && page.items[1].title.isEmpty)
            #expect(
                Account.calls(stub).first
                    == ["name": "transactions", "arguments": ["size": 100, "cursor": 0]])
        }

        @Test func uploadsReadVideosWithTheirThumbnails() async throws {
            let (account, stub) = Self.account { _, _ in
                [
                    "next_cursor": .null,
                    "items": [
                        [
                            "id": "video-1", "kind": "video", "url": "https://cdn.example/video-1.mp4",
                            "thumbnailUrl": "https://cdn.example/video-1_thumb.webp", "width": 1080, "height": 1920,
                            "duration": 8, "createdAt": .number(1_791_030_465.453116),
                        ],
                        ["id": "broken", "kind": "video"],
                        ["id": "audio-1", "kind": "audio", "url": "https://cdn.example/a.mp3"],
                    ],
                ]
            }

            let page = try await account.uploads(.video)

            #expect(page.nextCursor == nil)
            #expect(
                page.items == [
                    AccountAsset(
                        id: "video-1", kind: .video, url: URL(string: "https://cdn.example/video-1.mp4")!,
                        thumbnailURL: URL(string: "https://cdn.example/video-1_thumb.webp"), width: 1080,
                        height: 1920, duration: 8, createdAt: Date(timeIntervalSince1970: 1_791_030_465.453116))
                ])
            #expect(
                Account.calls(stub).first
                    == [
                        "name": "assets_picker_list",
                        "arguments": ["source": "uploads", "kind": "video", "size": 30],
                    ])
        }

        @Test func anAnswerWithoutItemsIsUnexpected() async throws {
            let (account, _) = Self.account { _, _ in ["error": "nope"] }
            await #expect(throws: HiggsfieldError.self) { try await account.transactions() }
            await #expect(throws: HiggsfieldError.self) { try await account.uploads(.image) }
        }

        @Test func klingBackgroundGoesIntoTheParams() {
            var request = Account.request
            request.backgroundSource = VideoRequest.backgroundFromVideo
            #expect(request.arguments()["params"]?["background_source"] == "input_video")
            #expect(Account.request.arguments()["params"]?["background_source"] == nil)
        }

        /// Left out unless set, under the keys `models_explore get` of `seedance_2_5` names.
        @Test func seedanceParametersGoIntoTheParamsOnlyWhenSet() {
            var request = Account.request
            request.bitrateMode = "high"
            request.mode = VideoRequest.seedanceExtend
            request.extensionMode = VideoRequest.extendForward
            let params = request.arguments()["params"]
            #expect(params?["bitrate_mode"] == "high")
            #expect(params?["mode"] == "video_extension")
            #expect(params?["extension_mode"] == "forward")
            let unset = Account.request.arguments()["params"]
            #expect(unset?["bitrate_mode"] == nil && unset?["extension_mode"] == nil)
        }
    }
}
