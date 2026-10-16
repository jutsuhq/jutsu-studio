import Foundation
import HiggsfieldCore
import HiggsfieldMCP
import HiggsfieldTestSupport
import JutsuCore
import Testing

@testable import HiggsfieldProviders

/// A Topaz upscale's charge, matched in the account's credit history (issue #113). Every transaction here is
/// synthetic: no Topaz charge has been read from the live server, so the matching relies on nothing but "Topaz" in
/// the name, the action and the time.
@Suite struct AccountChargesTests {
    static let submitted = Date(timeIntervalSince1970: 1_791_980_000)
    static let finished = submitted.addingTimeInterval(300)
    static let window = AccountCharges.window(submittedAt: submitted, finishedAt: finished)

    static func spend(_ title: String, _ credits: Double, at offset: TimeInterval) -> CreditTransaction {
        CreditTransaction(date: submitted.addingTimeInterval(offset), credits: credits, action: "spend", title: title)
    }

    @Test func theWindowRunsFromBeforeTheSubmitToAfterTheEnd() {
        #expect(Self.window.lowerBound == Self.submitted.addingTimeInterval(-120))
        #expect(Self.window.upperBound == Self.finished.addingTimeInterval(120))
        let unfinished = AccountCharges.window(submittedAt: Self.submitted, finishedAt: nil)
        #expect(unfinished.upperBound == Self.submitted.addingTimeInterval(120))
    }

    @Test(arguments: ["Topaz Video Upscale", "Video upscale - TOPAZ", "topaz_video", "Upscale (Topaz)"])
    func aTopazSpendInTheWindowIsTheCharge(_ title: String) {
        let history = [
            Self.spend("Higgsfield Genjutsu - Object Swap", -39, at: 10),
            Self.spend(title, -42.5, at: 3),
            Self.spend("Seedance 2.5", -35, at: -30),
        ]
        #expect(AccountCharges.credits(of: history, in: Self.window) == 42.5)
    }

    @Test func aChargeBookedWhenTheJobFinishesStillMatches() {
        let history = [Self.spend("Topaz Video Upscale", -20, at: 310)]
        #expect(AccountCharges.credits(of: history, in: Self.window) == 20)
    }

    @Test func nothingNamedForTopazLeavesThePriceUnknown() {
        let history = [
            Self.spend("Video Upscale", -2, at: 3),
            Self.spend("ByteDance Upscale", -4, at: 5),
            Self.spend("Topaz Image Upscale", -8, at: 6),
        ]
        #expect(AccountCharges.credits(of: history, in: Self.window) == nil)
    }

    @Test func aTopazSpendOutsideTheWindowIsSomeoneElses() {
        let history = [
            Self.spend("Topaz Video Upscale", -20, at: -121),
            Self.spend("Topaz Video Upscale", -20, at: 300 + 121),
        ]
        #expect(AccountCharges.credits(of: history, in: Self.window) == nil)
    }

    /// Two upscales sent together can't be told apart, and a refund means the spend isn't the final price.
    @Test func moreThanOneTopazEntryInTheWindowIsAmbiguous() {
        let two = [Self.spend("Topaz Video Upscale", -20, at: 2), Self.spend("Topaz Video Upscale", -30, at: 8)]
        #expect(AccountCharges.credits(of: two, in: Self.window) == nil)
        let refunded = [
            Self.spend("Topaz Video Upscale", -20, at: 2),
            CreditTransaction(
                date: Self.submitted.addingTimeInterval(60), credits: 20, action: "refund",
                title: "Topaz Video Upscale"),
        ]
        #expect(AccountCharges.credits(of: refunded, in: Self.window) == nil)
    }

    @Test func aRefundOrAZeroAloneIsNoCharge() {
        let refund = CreditTransaction(
            date: Self.submitted, credits: 20, action: "refund", title: "Topaz Video Upscale")
        #expect(AccountCharges.credits(of: [refund], in: Self.window) == nil)
        #expect(AccountCharges.credits(of: [Self.spend("Topaz", 0, at: 1)], in: Self.window) == nil)
        #expect(AccountCharges.credits(of: [Self.spend("Topaz", .nan, at: 1)], in: Self.window) == nil)
    }

    @Test func theSameEntryOnTwoPagesCountsOnce() {
        let entry = Self.spend("Topaz Video Upscale", -12, at: 4)
        #expect(AccountCharges.credits(of: [entry, entry], in: Self.window) == 12)
    }
}

extension Network {
    /// `charge(of:)` against a stub `transactions` tool.
    @Suite struct AccountChargeReading {
        static let tools =
            Provider.fullSet + [tool("transactions", "List the user's credit transactions", ["cursor", "size"])]
        static let submitted = AccountChargesTests.submitted

        static func iso(_ offset: TimeInterval) -> JSONValue {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return .string(formatter.string(from: submitted.addingTimeInterval(offset)))
        }

        static func topazJob(submitted: Date? = Self.submitted) -> Job {
            var spec = Provider.spec(.motionTransfer)
            spec.operation = PostOperation(
                action: .upscale(UpscaleOptions(target: .k4, engine: .topaz)), sourceJobID: "job-1")
            var job = Job(spec: spec, providerKind: .account, owner: "user_1", cost: .unknownCredits)
            job.submittedAt = submitted
            job.chargedAt = submitted?.addingTimeInterval(200)
            return job
        }

        static func names(_ stub: StubServer) -> [JSONValue?] {
            Provider.calls(stub).map { $0["name"] }
        }

        /// Newest first: the second page reaches back past the window, so no third is asked for.
        @Test func readsPagesUntilTheWindowAndRecordsTheExactCharge() async throws {
            let (provider, stub) = Provider.provider(tools: Self.tools) { _, arguments in
                if arguments["cursor"] == nil {
                    return [
                        "next_cursor": 50,
                        "items": [
                            [
                                "created_at": Self.iso(900), "credits": -7, "action": "spend",
                                "display_name": "Seedance 2.5",
                            ]
                        ],
                    ]
                }
                return [
                    "next_cursor": 100,
                    "items": [
                        [
                            "created_at": Self.iso(5), "credits": .number(-40.5), "action": "spend",
                            "display_name": "Topaz Video Upscale",
                        ],
                        ["created_at": Self.iso(-600), "credits": -3, "action": "spend", "display_name": "Soul V2"],
                    ],
                ]
            }

            #expect(try await provider.charge(of: Self.topazJob()) == .credits(40.5, isEstimate: false))
            #expect(Self.names(stub) == ["transactions", "transactions"])
            #expect(try Provider.schemaViolations(stub).isEmpty)
        }

        @Test func noMatchLeavesTheChargeUnknown() async throws {
            let (provider, _) = Provider.provider(tools: Self.tools) { _, _ in
                [
                    "next_cursor": .null,
                    "items": [
                        ["created_at": Self.iso(5), "credits": -2, "action": "spend", "display_name": "Upscale"]
                    ],
                ]
            }
            #expect(try await provider.charge(of: Self.topazJob()) == nil)
        }

        /// Only a Topaz upscale with a submit time is looked up; nothing is asked for any other job.
        @Test func otherJobsAreNeverLookedUp() async throws {
            let (provider, stub) = Provider.provider(tools: Self.tools)
            var standard = Self.topazJob()
            standard.spec.operation = PostOperation(action: .upscale(UpscaleOptions(target: .k4)), sourceJobID: "job-1")

            #expect(try await provider.charge(of: standard) == nil)
            #expect(try await provider.charge(of: Self.topazJob(submitted: nil)) == nil)
            #expect(Self.names(stub).isEmpty)
        }
    }
}
