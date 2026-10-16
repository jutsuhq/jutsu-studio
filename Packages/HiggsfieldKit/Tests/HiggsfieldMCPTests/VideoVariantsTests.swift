import Foundation
import HiggsfieldCore
import HiggsfieldTestSupport
import Testing

@testable import HiggsfieldMCP

/// `generate_video`'s `count` (catalog snapshot of 2026-10-15): 1–4 variants of the same request, each its own job
/// in `results`, capped to 1 by the server with `use_unlim`.
extension Network {
    @Suite struct VideoVariants {
        static func request(count: Int, usesUnlimited: Bool = false) -> VideoRequest {
            var request = Account.request
            request.count = count
            request.usesUnlimited = usesUnlimited
            return request
        }

        static func sentParams(_ stub: StubServer) -> JSONValue? {
            Account.calls(stub).first?["arguments"]?["params"]
        }

        @Test func countIsSentAboveOne() async throws {
            let (account, stub) = Account.account { _, _ in ["results": [["id": "job-1"], ["id": "job-2"]]] }
            _ = try await account.generate(Self.request(count: 3))
            #expect(Self.sentParams(stub)?["count"] == 3)
        }

        @Test func oneVariantSendsNoCount() async throws {
            let (account, stub) = Account.account { _, _ in ["results": [["id": "job-1"]]] }
            _ = try await account.generate(Self.request(count: 1))
            #expect(Self.sentParams(stub)?["count"] == nil)
        }

        /// The server caps an unlimited request to one generation, so the count isn't asked for at all.
        @Test func unlimitedSendsNoCount() async throws {
            let (account, stub) = Account.account { _, _ in ["results": [["id": "job-1"]]] }
            _ = try await account.generate(Self.request(count: 4, usesUnlimited: true))
            #expect(Self.sentParams(stub)?["count"] == nil)
            #expect(Self.sentParams(stub)?["use_unlim"] == true)
        }

        @Test func everyJobOfTheAnswerIsKept() async throws {
            let (account, _) = Account.account { _, _ in
                [
                    "results": [
                        ["id": "job-1"], ["id": "job-2"], ["status": "queued"], ["id": "job-2"], ["id": "job-3"],
                    ],
                    "request_id": "trace-1",
                ]
            }
            let generation = try await account.generate(Self.request(count: 4))
            #expect(generation.id == "job-1")
            #expect(generation.variantIDs == ["job-2", "job-3"])
            #expect(generation.requestID == "trace-1")
        }

        /// The answer's cost is the whole request's: it stays on the generation once, never per variant.
        @Test func theCostIsTheWholeRequests() async throws {
            let (account, _) = Account.account { _, _ in
                [
                    "results": [["id": "job-1"], ["id": "job-2"]],
                    "cost": ["credits_exact": .number(24), "credits": 24],
                ]
            }
            let generation = try await account.generate(Self.request(count: 2))
            #expect(generation.credits == 24)
            #expect(generation.variantIDs == ["job-2"])
        }
    }
}
