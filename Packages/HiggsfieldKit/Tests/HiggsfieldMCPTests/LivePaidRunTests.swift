import Foundation
import HiggsfieldCore
import HiggsfieldTestSupport
import Testing

@testable import HiggsfieldMCP

/// The answers of the paid run of issue #114 on 2026-10-15 (`docs/mcp-snapshots/live-2026-10-15/`), trimmed and with
/// example URLs, replayed by a stub.
extension Network {
    @Suite struct LivePaidRun {
        /// A stub answering every call with the live answer `name`.
        static func replay(_ name: String, tools: [JSONValue] = []) throws -> (HiggsfieldAccount, StubServer) {
            let live = try CatalogSnapshot.liveAnswer(name)
            return Account.account(tools: Account.fullSet + tools) { _, _ in live.answer }
        }

        /// A stub answering `tool` with `text` as an `isError` result, and everything else as usual.
        static func refusing(_ tool: String, text: String, answer: JSONValue = [:]) -> (HiggsfieldAccount, StubServer) {
            let answering = mcpServer(tools: Account.fullSet)
            let stub = StubServer { request, _ in
                guard request.json?["params"]?["name"] == .string(tool), let id = request.json?["id"] else {
                    return answering.respond(to: request)
                }
                return .json([
                    "jsonrpc": "2.0", "id": id,
                    "result": [
                        "isError": true, "content": [["type": "text", "text": .string(text)]],
                        "structuredContent": answer,
                    ],
                ])
            }
            let session = stub.session()
            let client = MCPClient(endpoint: Fixture.mcpURL, tokens: tokenProvider(), session: session)
            return (HiggsfieldAccount(client: client, session: session), stub)
        }

        static let running = [
            "e62128d0-f91e-4c5c-aafd-f1be29d8039e", "3e91e2e7-caee-482e-9c9e-c0af66cda89d",
            "8c2f6fdf-d06c-4666-bd7b-f6d8c5eafcfc", "b2315e67-3ee8-4b8b-9e73-b62860d37ec8",
            "b283e31d-0916-483a-bad2-428e77749cfc", "287a7844-446e-4bd3-b484-7b93f2f6a6b7",
            "6051a981-2b0b-4e86-a17b-829fa5a3d4ba", "b46fa887-f1b9-4894-90ba-302e1780bf1c",
            "295989fc-675c-4ab1-930e-10a29cd3d349", "b9673ee0-417a-48c1-be0e-d6ec347b7f0a",
        ]

        @Test func theLiveCallsKeepToTheSnapshotSchemas() throws {
            for name in [
                "generate_video_count_2", "generate_image_count_2", "generate_image_use_unlim_refused",
                "jobs_wait_running", "media_import_url",
            ] {
                let live = try CatalogSnapshot.liveAnswer(name)
                #expect(try CatalogSnapshot.violations(of: live.arguments, sentTo: live.tool).isEmpty, "\(name)")
            }
        }

        /// `count: 2` answered two `results[]`, each its own job, and was charged per variant (two `transactions`
        /// entries of 12 credits against a quote of 12 for one).
        @Test func videoVariantsAreOneJobEach() async throws {
            let (account, _) = try Self.replay("generate_video_count_2")
            var request = VideoRequest(model: .seedance25, media: [], prompt: "a paper boat", resolution: "480p")
            request.count = 2

            let generation = try await account.generate(request)

            #expect(generation.id == "e62128d0-f91e-4c5c-aafd-f1be29d8039e")
            #expect(generation.variantIDs == ["3e91e2e7-caee-482e-9c9e-c0af66cda89d"])
            #expect(generation.credits == nil)
        }

        /// `soul_2` with `count: 2` answered two jobs, each charged 0.12.
        @Test func imageVariantsAreOneJobEach() async throws {
            let (account, _) = try Self.replay("generate_image_count_2")
            let request = AccountImageRequest(model: "soul_2", prompt: "a paper boat", aspectRatio: "1:1", count: 2)

            let jobs = try await account.generateImages(request)

            #expect(
                jobs.map(\.id) == ["8c2f6fdf-d06c-4666-bd7b-f6d8c5eafcfc", "b2315e67-3ee8-4b8b-9e73-b62860d37ec8"])
        }

        /// While running, a Seedance job is `in_progress` with `type: "image"`; the status alone is read, so it is in
        /// progress, and the finished ones are read with their `result_url`.
        @Test func jobsWaitWhileRunning() async throws {
            let (account, _) = try Self.replay("jobs_wait_running", tools: [try CatalogSnapshot.tool("jobs_wait")])

            let wait = try #require(try await account.waitForJobs(Self.running))

            #expect(wait.pollAfterSeconds == 10)
            let finished = ["8c2f6fdf", "b2315e67", "b46fa887", "295989fc"]
            for id in Self.running {
                let status = try #require(wait.statuses[id], "\(id)")
                if finished.contains(where: id.hasPrefix) {
                    guard case .completed(let url) = status else {
                        Issue.record("\(id) is \(status)")
                        continue
                    }
                    #expect(url.host() == "example.com" && url.lastPathComponent.contains(id))
                } else {
                    #expect(status == .inProgress, "\(id)")
                }
            }
        }

        @Test func jobsWaitOnceEveryJobIsDone() async throws {
            let (account, _) = try Self.replay("jobs_wait_completed", tools: [try CatalogSnapshot.tool("jobs_wait")])

            let wait = try #require(try await account.waitForJobs(Self.running))

            #expect(wait.statuses.count == 10)
            #expect(wait.pollAfterSeconds == nil)
            #expect(
                wait.statuses["6051a981-2b0b-4e86-a17b-829fa5a3d4ba"]
                    == .completed(
                        videoURL: try #require(
                            URL(
                                string:
                                    "https://example.com/hf_20261015_132300_6051a981-2b0b-4e86-a17b-829fa5a3d4ba.mp4")
                        )))
        }

        @Test func mediaImportReadsTheMediaID() async throws {
            let (account, stub) = try Self.replay(
                "media_import_url", tools: [try CatalogSnapshot.tool("media_import_url")])
            let link = try #require(URL(string: "https://example.com/clip.mp4"))

            #expect(try await account.importMedia(from: link, type: "video") == "86198d56-f1e1-4176-b6bf-68a90d545a01")
            #expect(
                Account.calls(stub).first?["arguments"]
                    == (try CatalogSnapshot.liveAnswer("media_import_url").arguments))
        }

        /// A refused unlimited opt-in started nothing (balance and credit history unchanged), so it is a refusal with
        /// its reason, not an unknown outcome.
        @Test func aRefusedUnlimitedOptInIsARefusal() async throws {
            let live = try CatalogSnapshot.liveAnswer("generate_image_use_unlim_refused")
            let text = try #require(live.text)
            #expect(live.isError)
            let request = AccountImageRequest(model: "soul_2", prompt: "a paper boat", aspectRatio: "1:1", count: 1)

            let (images, _) = Self.refusing("generate_image", text: text, answer: live.answer)
            await #expect(throws: HiggsfieldError.validation(field: nil, message: text)) {
                try await images.generateImages(request)
            }

            let (videos, _) = Self.refusing("generate_video", text: text)
            await #expect(throws: HiggsfieldError.validation(field: nil, message: text)) {
                try await videos.generate(Account.request)
            }
        }

        /// Any other execution error of a submit may have started a job.
        @Test func anotherSubmitErrorIsAnUnknownOutcome() async throws {
            let (account, _) = Self.refusing("generate_video", text: "Error starting generation: upstream timeout")
            await #expect(throws: HiggsfieldError.server(status: 200)) {
                try await account.generate(Account.request)
            }
        }
    }
}
