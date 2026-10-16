import Foundation
import HiggsfieldMCP
import HiggsfieldTestSupport
import JutsuCore
import Testing

@testable import HiggsfieldProviders

extension Network {
    /// `models_explore` `list` answers in the shape of the catalog snapshot of 2026-10-15.
    @Suite struct ProviderUnlimited {
        static let explore = tool("models_explore", "Explore models", ["action", "type", "model_id", "after", "limit"])
        static let tools = Provider.fullSet + [explore]

        /// Motion Transfer's model supports `use_unlim`, Object Swap's doesn't; `available` is the `unlim` block's,
        /// whose `remaining` is `null` for an unmetered allowance.
        static func page(available: Bool) -> JSONValue {
            [
                "items": [
                    ["id": "hf_mult_motion_control", "supports_unlim": true],
                    ["id": "hf_mult_replace_object"],
                    ["id": "seedance_2_5"], ["id": "kling3_0_motion_control"],
                ],
                "has_more": false,
                "unlim": ["available": .bool(available), "expires_at": .null, "remaining": .null],
            ]
        }

        static func provider(
            optedIn: Bool = true, available: Bool = true, tools: [JSONValue] = tools,
            generate: JSONValue = ["results": [["id": "job-1"]]]
        ) -> (HiggsfieldMCPProvider, StubServer) {
            let stub = mcpServer(tools: tools) { name, _ in
                switch name {
                case "models_explore": Self.page(available: available)
                case "generate_video": generate
                case "balance": ["credits": 100]
                default: [:]
                }
            }
            return (makeProvider(stub.session(), unlimitedOptIn: optedIn), stub)
        }

        static func spec(_ mode: Mode, usesUnlimited: Bool = false) -> JobSpec {
            var spec = Provider.spec(mode)
            spec.usesUnlimited = usesUnlimited
            return spec
        }

        static func useUnlim(_ stub: StubServer) -> [JSONValue?] {
            Provider.calls(stub).filter { $0["name"] == "generate_video" }
                .map { $0["arguments"]?["params"]?["use_unlim"] }
        }

        @Test func capabilitiesListWhatTheAllowanceCovers() async throws {
            let (provider, _) = Self.provider()
            #expect(try await provider.capabilities().unlimited == [.genjutsu: [.motionTransfer]])
        }

        @Test func capabilitiesWithoutModelsExploreOrAnAllowanceListNothing() async throws {
            let (withoutTool, _) = Self.provider(tools: Provider.fullSet)
            #expect(try await withoutTool.capabilities().unlimited.isEmpty)
            let (withoutAllowance, _) = Self.provider(available: false)
            #expect(try await withoutAllowance.capabilities().unlimited.isEmpty)
        }

        @Test(arguments: [
            (true, true, Mode.motionTransfer, true),  // all yes
            (false, true, .motionTransfer, false),  // setting off
            (true, true, .objectSwap, false),  // model doesn't support it
            (true, false, .motionTransfer, false),  // no allowance now
            (true, true, .restyle, false),  // a Genjutsu Style has no use_unlim
        ])
        func decision(optedIn: Bool, available: Bool, mode: Mode, pays: Bool) async throws {
            let (provider, _) = Self.provider(optedIn: optedIn, available: available)
            _ = try await provider.capabilities()
            #expect(await provider.paysUnlimited(Self.spec(mode)) == pays)
        }

        @Test func nothingIsPaidUnlimitedBeforeTheAllowanceWasRead() async throws {
            let (provider, stub) = Self.provider()
            #expect(await !provider.paysUnlimited(Self.spec(.motionTransfer)))
            #expect(Provider.calls(stub).isEmpty)
        }

        @Test func useUnlimIsSentOnlyForAJobQueuedForItThatStillQualifies() async throws {
            let (provider, stub) = Self.provider()
            _ = try await provider.capabilities()

            _ = try await provider.submit(
                Self.spec(.motionTransfer, usesUnlimited: true), inputs: Provider.inputs, idempotencyKey: UUID())
            _ = try await provider.submit(Self.spec(.motionTransfer), inputs: Provider.inputs, idempotencyKey: UUID())
            _ = try await provider.submit(
                Self.spec(.objectSwap, usesUnlimited: true), inputs: Provider.inputs, idempotencyKey: UUID())

            #expect(Self.useUnlim(stub) == [true, false, false])
        }

        @Test func turningTheSettingOffAfterQueueingSendsCredits() async throws {
            let (provider, stub) = Self.provider(optedIn: false)
            _ = try await provider.capabilities()

            _ = try await provider.submit(
                Self.spec(.motionTransfer, usesUnlimited: true), inputs: Provider.inputs, idempotencyKey: UUID())

            #expect(Self.useUnlim(stub) == [false])
        }

        @Test func anAnswerWithoutAPriceIsPaidFromTheAllowance() async throws {
            let (provider, _) = Self.provider()
            _ = try await provider.capabilities()
            let job = try await provider.submit(
                Self.spec(.motionTransfer, usesUnlimited: true), inputs: Provider.inputs, idempotencyKey: UUID())
            #expect(job.paidWithUnlimited)
            #expect(job.charged == nil)
        }

        @Test func anAnswerWithCreditsRecordsTheRealPrice() async throws {
            let (provider, _) = Self.provider(generate: [
                "results": [["id": "job-1"]], "cost": ["credits_exact": .number(39.2)],
            ])
            _ = try await provider.capabilities()
            let job = try await provider.submit(
                Self.spec(.motionTransfer, usesUnlimited: true), inputs: Provider.inputs, idempotencyKey: UUID())
            #expect(!job.paidWithUnlimited)
            #expect(job.charged == Cost.credits(Decimal(string: "39.2")!, isEstimate: false))
        }

        @Test func aCreditJobIgnoresThePriceInTheAnswer() async throws {
            let (provider, _) = Self.provider(generate: ["results": [["id": "job-1"]], "cost": ["credits": 40]])
            _ = try await provider.capabilities()
            let job = try await provider.submit(
                Self.spec(.motionTransfer), inputs: Provider.inputs, idempotencyKey: UUID())
            #expect(!job.paidWithUnlimited)
            #expect(job.charged == nil)
        }

        @Test func theBalanceAfterAJobReadsTheAllowanceAgainWhileThereIsOne() async throws {
            let (provider, stub) = Self.provider()
            _ = try await provider.capabilities()
            _ = try await provider.balance()
            let explored = Provider.calls(stub).filter { $0["name"] == "models_explore" }
            #expect(explored.count == 2)

            let (without, withoutStub) = Self.provider(available: false)
            _ = try await without.capabilities()
            _ = try await without.balance()
            #expect(Provider.calls(withoutStub).filter { $0["name"] == "models_explore" }.count == 1)
        }
    }
}
