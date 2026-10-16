import Foundation
import HiggsfieldMCP
import HiggsfieldTestSupport
import JutsuCore
import Testing

@testable import HiggsfieldProviders

extension Network {
    /// Seedance 2.5's native draft on the account (issue #115): Draft at 480p sends `draft: true`, and a finalize
    /// sends only `model`, `draft_job_id`, `resolution` and `use_unlim`, as quoted live on 2026-10-15.
    @Suite struct NativeDraft {
        /// The paid run's draft: 15 s from reference images, 9:16.
        static func draft(resolution: Resolution = .p480) -> JobSpec {
            JobSpec(
                mode: .motionTransfer, model: .seedance25, source: nil,
                references: [Provider.image, Provider.image], prompt: "a fox in the snow", resolution: resolution,
                isDraft: true, length: 15, aspectRatio: .portrait)
        }

        static var finalize: JobSpec {
            var spec = draft()
            spec.isDraft = false
            spec.resolution = .p1080
            spec.draftJobID = "draft-job"
            return spec
        }

        static let images = RemoteInputs(
            video: nil,
            images: [
                RemoteAsset(url: URL(fileURLWithPath: "/a.jpg"), id: "image-1"),
                RemoteAsset(url: URL(fileURLWithPath: "/b.jpg"), id: "image-2"),
            ])

        static func params(_ stub: StubServer) -> [JSONValue] {
            Provider.calls(stub).filter { $0["name"] == "generate_video" }.compactMap { $0["arguments"]?["params"] }
        }

        @Test func aDraftAt480pAsksForTheNativeDraft() async throws {
            let (provider, stub) = Provider.provider(tools: Provider.fullSet) { _, _ in
                ["results": [["id": "job-1"], ["id": "job-2"]]]
            }
            var spec = Self.draft()
            spec.variants = 2
            let job = try await provider.submit(spec, inputs: Self.images, idempotencyKey: UUID())

            let sent = try #require(Self.params(stub).first)
            #expect(sent["draft"] == true)
            #expect(sent["resolution"] == "480p")
            #expect(sent["mode"] == "omni_reference")
            #expect(sent["duration"] == 15)
            #expect(sent["draft_job_id"] == nil)
            #expect(try CatalogSnapshot.violations(ofParams: sent).isEmpty)
            #expect(try Provider.schemaViolations(stub).isEmpty)
            #expect(job.isNativeDraft)
            #expect(job.variants.map(\.isNativeDraft) == [true])
        }

        /// A final, a draft at another resolution and a draft of an Edit stay plain renders.
        @Test(arguments: [
            {
                var spec = draft(); spec.isDraft = false; return spec
            }(), draft(resolution: .p720),
            {
                var spec = draft(); spec.mode = .extend; return spec
            }(),
        ])
        func otherJobsSendNoDraft(spec: JobSpec) async throws {
            let (provider, stub) = Provider.provider(tools: Provider.fullSet) { _, _ in ["results": [["id": "job-1"]]] }
            let job = try await provider.submit(spec, inputs: Self.images, idempotencyKey: UUID())
            #expect(Self.params(stub).first?["draft"] == nil)
            #expect(!job.isNativeDraft)
        }

        /// The draft's quote before upload asks with `draft: true`, and declines a suggested preset as a submit
        /// does: the paid run's first quote answered only a `preset_recommendation` notice.
        @Test func theDraftQuoteDeclinesASuggestedPreset() async throws {
            let notice: JSONValue = [
                "notice": [
                    "type": "preset_recommendation", "message": "This prompt looks like a preset.",
                    "data": ["retry_literal_with": ["declined_preset_id": "preset-1"]],
                ]
            ]
            let (provider, stub) = Provider.provider(tools: Provider.fullSet) { _, arguments in
                arguments["params"]?["declined_preset_id"] == nil ? notice : ["cost": ["credits": 45]]
            }
            #expect(try await provider.estimate(Self.draft()) == .credits(45, isEstimate: false))
            let quotes = Self.params(stub)
            #expect(quotes.map { $0["declined_preset_id"] } == [nil, "preset-1"])
            #expect(quotes.allSatisfy { $0["draft"] == true && $0["get_cost"] == true })
        }

        @Test func aFinalizeSendsOnlyItsFourKeys() async throws {
            let (provider, stub) = Provider.provider(tools: Provider.fullSet) { _, arguments in
                arguments["params"]?["get_cost"] == true ? ["cost": ["credits": 80]] : ["results": [["id": "final-1"]]]
            }
            var spec = Self.finalize
            spec.usesUnlimited = true
            #expect(try await provider.serverEstimate(spec, inputs: Self.images) == .credits(80, isEstimate: false))
            let job = try await provider.submit(spec, inputs: Self.images, idempotencyKey: UUID())
            #expect(job.requestID == "final-1")
            #expect(!job.isNativeDraft)

            let sent = Self.params(stub)
            #expect(sent.count == 2)
            let expected: JSONValue = [
                "model": "seedance_2_5", "draft_job_id": "draft-job", "resolution": "1080p", "use_unlim": false,
            ]
            var quote = sent[0].objectValue ?? [:]
            #expect(quote.removeValue(forKey: "get_cost") == true)
            #expect(JSONValue.object(quote) == expected)
            #expect(sent[1] == expected)
            #expect(try CatalogSnapshot.violations(ofParams: expected).isEmpty)
            #expect(try Provider.schemaViolations(stub).isEmpty)
        }

        /// Finalize is quoted live before anything runs; a failed quote shows a third of the 1080p rate, as an
        /// estimate (2026-10-15: 80 credits for a 15 s draft, against 240 for a fresh 1080p render).
        @Test func aFinalizeIsQuotedAndFallsBackToAThirdOfTheFreshRate() async throws {
            let (quoted, stub) = Provider.provider(tools: Provider.fullSet) { _, _ in ["cost": ["credits": 80]] }
            #expect(try await quoted.estimate(Self.finalize) == .credits(80, isEstimate: false))
            var quote = Self.params(stub).first?.objectValue ?? [:]
            quote.removeValue(forKey: "get_cost")
            #expect(Set(quote.keys) == ["model", "draft_job_id", "resolution", "use_unlim"])

            let (failing, _) = Provider.provider(tools: Provider.fullSet) { _, _ in [:] }
            #expect(try await failing.estimate(Self.finalize) == .credits(80, isEstimate: true))
            var fresh = Self.finalize
            fresh.draftJobID = nil
            #expect(AccountModel.estimatedCredits(for: fresh) == 240)
        }

        /// Two drafts of the same length don't share a finalize quote.
        @Test func eachDraftsFinalizeIsQuotedOnItsOwn() async throws {
            let (provider, stub) = Provider.provider(tools: Provider.fullSet) { _, _ in ["cost": ["credits": 80]] }
            var other = Self.finalize
            other.draftJobID = "other-draft"
            _ = try await provider.estimate(Self.finalize)
            _ = try await provider.estimate(other)
            #expect(Self.params(stub).map { $0["draft_job_id"] } == ["draft-job", "other-draft"])
        }
    }
}
