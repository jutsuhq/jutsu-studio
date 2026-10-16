import Foundation
import HiggsfieldMCP
import HiggsfieldTestSupport
import JutsuCore
import Testing

@testable import HiggsfieldProviders

extension Network {
    /// Variants are `generate_video`'s `count` (catalog snapshot of 2026-10-15).
    @Suite struct ProviderVariants {
        static func spec(_ mode: Mode = .motionTransfer, variants: Int, usesUnlimited: Bool = false) -> JobSpec {
            var spec = Provider.spec(mode)
            spec.variants = variants
            spec.usesUnlimited = usesUnlimited
            return spec
        }

        static func generateParams(_ stub: StubServer) -> [JSONValue] {
            Provider.calls(stub).filter { $0["name"] == "generate_video" }.compactMap { $0["arguments"]?["params"] }
        }

        @Test func capabilitiesOfferFourVariantsWhereTheAccountGenerates() async throws {
            let (provider, _) = Provider.provider(tools: Provider.fullSet)
            #expect(try await provider.capabilities().maxVariants == 4)
            let (withoutGenerate, _) = Provider.provider(tools: [])
            #expect(try await withoutGenerate.capabilities().maxVariants == 1)
        }

        @Test func everyJobOfTheAnswerComesBack() async throws {
            let (provider, stub) = Provider.provider(tools: Provider.fullSet) { _, _ in
                ["results": [["id": "job-1"], ["id": "job-2"], ["id": "job-3"]], "request_id": "trace-1"]
            }
            let job = try await provider.submit(
                Self.spec(variants: 3), inputs: Provider.inputs, idempotencyKey: UUID())

            #expect(job.requestID == "job-1")
            #expect(job.variants.map(\.requestID) == ["job-2", "job-3"])
            #expect(job.variants.allSatisfy { $0.correlationID == "trace-1" })
            #expect(Self.generateParams(stub).first?["count"] == 3)
            #expect(try Provider.schemaViolations(stub).isEmpty)
        }

        /// The server caps an unlimited request to one generation: no count is sent with `use_unlim`.
        @Test func anUnlimitedJobSendsNoCount() async throws {
            let stub = mcpServer(tools: ProviderUnlimited.tools) { name, _ in
                switch name {
                case "models_explore": ProviderUnlimited.page(available: true)
                case "generate_video": ["results": [["id": "job-1"]]]
                default: [:]
                }
            }
            let provider = makeProvider(stub.session(), unlimitedOptIn: true)
            _ = try await provider.capabilities()

            _ = try await provider.submit(
                Self.spec(variants: 3, usesUnlimited: true), inputs: Provider.inputs, idempotencyKey: UUID())

            let params = try #require(Self.generateParams(stub).first)
            #expect(params["use_unlim"] == true)
            #expect(params["count"] == nil)
            #expect(try Provider.schemaViolations(stub).isEmpty)
        }

        @Test func theEstimateIsOneVariantsTimesTheCount() async throws {
            let (provider, _) = Provider.provider(tools: Provider.fullSet)
            let one = try await provider.estimate(Self.spec(variants: 1))
            let three = try await provider.estimate(Self.spec(variants: 3))
            #expect(three.amount == one.amount * 3)
        }

        /// Whether `get_cost` prices `count` isn't documented: one variant is quoted and priced that many times.
        @Test func theQuoteIsForOneVariantTimesTheCount() async throws {
            let (provider, stub) = Provider.provider(tools: Provider.fullSet) { _, _ in
                ["cost": ["credits": 28, "credits_exact": .number(27.5)]]
            }
            let cost = try await provider.serverEstimate(Self.spec(variants: 3), inputs: Provider.inputs)

            #expect(cost == .credits(82.5, isEstimate: false))
            let params = try #require(Self.generateParams(stub).first)
            #expect(params["get_cost"] == true)
            #expect(params["count"] == nil)
            #expect(try Provider.schemaViolations(stub).isEmpty)
        }

        /// A Genjutsu Style runs through `execute_preset`, which has no count: refused before anything is sent.
        @Test func aStyleOfSeveralVariantsIsRefusedBeforeSending() async throws {
            let (provider, stub) = Provider.provider(tools: Provider.fullSet)
            var spec = Self.spec(.restyle, variants: 2)
            spec.presetID = UUID()
            await #expect(throws: ProviderError.self) {
                try await provider.submit(spec, inputs: Provider.inputs, idempotencyKey: UUID())
            }
            #expect(Provider.calls(stub).isEmpty)
        }

        @Test func theAPIKeyRefusesVariantsBeforeSending() async throws {
            let (_, stub) = Provider.provider(tools: [])
            let provider = stub.makeAPIProvider()
            await #expect(throws: ProviderError.self) { try await provider.estimate(Self.spec(variants: 2)) }
            await #expect(throws: ProviderError.self) {
                try await provider.submit(Self.spec(variants: 2), inputs: Provider.inputs, idempotencyKey: UUID())
            }
            #expect(stub.requests.isEmpty)
        }
    }
}
