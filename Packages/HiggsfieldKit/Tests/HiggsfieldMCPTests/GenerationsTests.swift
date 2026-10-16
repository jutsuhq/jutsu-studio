import Foundation
import HiggsfieldCore
import HiggsfieldTestSupport
import Testing

@testable import HiggsfieldMCP

extension Network {
    @Suite struct History {
        static let tools =
            Account.fullSet + [
                tool("show_generations", "Show the user's generations", ["type", "only_completed", "size", "cursor"])
            ]

        static func account(_ reply: @escaping @Sendable (JSONValue) -> JSONValue) -> (HiggsfieldAccount, StubServer) {
            Account.account(tools: tools) { name, arguments in name == "show_generations" ? reply(arguments) : [:] }
        }

        @Test func recordedPageDecodes() async throws {
            let recorded = try RecordedGenerations.value()
            let (account, stub) = Self.account { _ in recorded }

            let page = try await account.generations()

            let item = try #require(page.items.first)
            #expect(page.items.count == 1)
            #expect(page.nextCursor == "<cursor; value not recorded>")
            #expect(item.id == "<job id>")
            #expect(item.type == "video")
            #expect(item.status == "completed")
            #expect(item.model == VideoRequest.Model.replaceObject.rawValue)
            #expect(item.createdAt == Date(timeIntervalSince1970: 1_791_032_606.742653))
            #expect(!item.isLiked)
            #expect(item.outputURL?.host == "d8j0ntlcm91z4.cloudfront.net")
            #expect(item.outputURL?.pathExtension == "mp4")
            #expect(item.media.allSatisfy { $0.url?.host == "d2ol7oe51mr4n9.cloudfront.net" })
            #expect(item.width == 1080 && item.height == 1920)
            #expect(item.duration == 8)
            #expect(item.prompt == "<1712 characters>")
            #expect(item.resolution == "720p")
            #expect(item.media.map(\.role) == [.video, .image, .image, .image])
            #expect(item.media.allSatisfy { $0.id == "<media id>" })
            #expect(
                Self.calls(stub).first?["arguments"] == ["size": 24, "only_completed": true, "type": "video"])
        }

        @Test func cursorGoesBackUnchanged() async throws {
            let cursor: JSONValue = ["after": "abc", "offset": 24]
            let (account, stub) = Self.account { _ in ["items": [], "next_cursor": .null] }

            let page = try await account.generations(type: nil, onlyCompleted: false, cursor: cursor, size: 500)

            #expect(page.items.isEmpty)
            #expect(page.nextCursor == nil)
            #expect(
                Self.calls(stub).first?["arguments"] == ["size": 100, "only_completed": false, "cursor": cursor])
        }

        @Test(arguments: ["9007199254740993", "9223372036854775807", "18446744073709551615", "-9007199254740993"])
        func largeNumericCursorGoesBackExactly(_ text: String) async throws {
            let cursor = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
            let (account, stub) = Self.account { _ in ["items": [], "next_cursor": cursor] }
            let page = try await account.generations()
            _ = try await account.generations(cursor: page.nextCursor)
            let request = try #require(stub.requests.last?.bodyText)
            #expect(request.contains("\"cursor\":" + text))
        }

        @Test(arguments: [1e30, -1.0, 12.5])
        func invalidDimensionsAreOmitted(_ width: Double) async throws {
            let (account, _) = Self.account { _ in
                ["items": [["id": "job", "params": ["width": .number(width), "height": 720]]]]
            }
            let item = try #require(try await account.generations().items.first)
            #expect(item.width == nil)
            #expect(item.height == 720)
        }

        @Test func itemsWithoutAnIDAreLeftOut() async throws {
            let (account, _) = Self.account { _ in ["items": [["type": "video"], ["id": "job-2"]]] }
            #expect(try await account.generations().items.map(\.id) == ["job-2"])
        }

        @Test func pageWithoutItemsIsUnexpected() async throws {
            let (account, _) = Self.account { _ in ["error": "nope"] }
            await #expect(
                throws: HiggsfieldError.validation(
                    field: nil, message: "Unexpected result from the show_generations tool")
            ) {
                try await account.generations()
            }
        }

        @Test func missingToolIsReportedByName() async throws {
            let (account, _) = Account.account()
            await #expect(throws: HiggsfieldError.toolUnavailable("show_generations")) {
                try await account.generations()
            }
        }

        static func calls(_ stub: StubServer) -> [JSONValue] {
            Account.calls(stub).filter { $0["name"] == "show_generations" }
        }
    }
}

@Test func historyRolesMapToRequestRoles() {
    #expect(MediaRole(historyRole: "video") == .video)
    #expect(MediaRole(historyRole: "image") == .image)
    #expect(MediaRole(historyRole: "video_references") == .video)
    #expect(MediaRole(historyRole: "image_references") == .image)
    #expect(MediaRole(historyRole: "audio") == nil)
}

@Test(arguments: [
    ("https://cdn.example/a b.mp4", true), ("HTTPS://cdn.example/a.mp4", true), ("http://cdn.example/a.mp4", false),
    ("file:///Users/me/Movies/x.mov", false), ("ftp://cdn.example/a.mp4", false), ("/tmp/a.mp4", false),
    ("https:///a.mp4", false),
])
func serverMediaURLsMustBeHTTPS(string: String, isAccepted: Bool) {
    #expect((URL(serverMedia: string) != nil) == isAccepted)
}
