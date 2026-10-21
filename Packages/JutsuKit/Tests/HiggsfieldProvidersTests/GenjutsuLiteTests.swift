import Foundation
import HiggsfieldAPI
import HiggsfieldMCP
import HiggsfieldTestSupport
import JutsuCore
import Testing

@testable import HiggsfieldProviders

extension Network {
    /// Genjutsu Lite (issue #15): Genjutsu's Motion Transfer and Object Swap on Wan 3.0, as `generate_video` models of
    /// their own. Its REST schema isn't published, so an API key doesn't run it.
    @Suite struct GenjutsuLite {
        static let lite = VideoModel(rawValue: "genjutsuLite") ?? .genjutsu

        static func spec(_ mode: Mode, seconds: TimeInterval = 12, resolution: Resolution = .p720) -> JobSpec {
            JobSpec(
                mode: mode, model: lite,
                source: SourceClip(
                    fileURL: URL(fileURLWithPath: "/tmp/in.mov"), duration: 30,
                    pixelSize: PixelSize(width: 1280, height: 720), range: 0...seconds),
                references: [LocalImage(fileURL: URL(fileURLWithPath: "/tmp/a.jpg"))], prompt: "make it rain",
                resolution: resolution)
        }

        static let medias: JSONValue = [
            ["role": "video_references", "value": "video-1"], ["role": "image_references", "value": "image-1"],
        ]

        /// Each mode sends Genjutsu's request to its own model: the media and the resolution, nothing else.
        @Test(arguments: [
            (Mode.motionTransfer, "hf_mult_motion_control_flash", Resolution.p480),
            (.objectSwap, "hf_mult_replace_object_flash", .p1080),
        ])
        func eachModeSendsGenjutsusRequest(mode: Mode, model: String, resolution: Resolution) async throws {
            let (provider, stub) = Provider.provider(tools: Provider.fullSet) { _, _ in
                ["results": [["id": "job-1"]]]
            }
            _ = try await provider.submit(
                Self.spec(mode, resolution: resolution), inputs: Provider.inputs, idempotencyKey: UUID())

            let params = try #require(Provider.calls(stub).first?["arguments"]?["params"])
            #expect(
                params == [
                    "model": .string(model), "medias": Self.medias, "prompt": "make it rain",
                    "resolution": .string(resolution.rawValue), "use_unlim": false,
                ])
            #expect(try Provider.schemaViolations(stub).isEmpty)
            #expect(try CatalogSnapshot.violations(ofParams: params).isEmpty)
        }

        /// Billed by its source, like Genjutsu: `get_cost` quotes it once the source is uploaded, with the source in
        /// `medias`. Before that there is no fallback rate yet, so the price is unknown and nothing is asked.
        @Test(arguments: [Mode.motionTransfer, .objectSwap])
        func itIsQuotedOnceTheSourceIsUploaded(mode: Mode) async throws {
            let (provider, stub) = Provider.provider(tools: Provider.fullSet) { _, _ in
                ["cost": ["credits": 12, "credits_exact": .number(12.5)]]
            }
            #expect(try await provider.estimate(Self.spec(mode)) == .unknownCredits)
            #expect(Provider.calls(stub).isEmpty)

            let quoted = try await provider.serverEstimate(Self.spec(mode), inputs: Provider.inputs)
            #expect(quoted == .credits(12.5, isEstimate: false))
            let sent = try #require(Provider.calls(stub).first?["arguments"]?["params"])
            #expect(sent["get_cost"] == true)
            #expect(sent["model"]?.stringValue == AccountModel.model(for: Self.spec(mode))?.rawValue)
            #expect(sent["medias"]?.arrayValue?.first?["value"] == "video-1")
            #expect(try Provider.schemaViolations(stub).isEmpty)
        }

        /// The account offers it; an API key doesn't, and refuses a job on it.
        @Test func itRunsOnTheAccountOnly() async throws {
            let (provider, _) = Provider.provider(tools: Provider.fullSet)
            #expect(try await provider.capabilities().models.contains(Self.lite))
            #expect(AccountModel.runs(Self.lite))
            #expect(!Self.lite.runsWithAPIKey)
            #expect(throws: ProviderError.self) {
                try APIModel(Self.spec(.motionTransfer), inputs: Provider.inputs)
            }
        }

        /// Its `models_explore` answers limit its own jobs, not Genjutsu's.
        @Test func theServersLimitsApplyToLiteAlone() {
            let table = AccountModel.constraints(from: [
                VideoRequest.Model(rawValue: "hf_mult_motion_control_flash"): ModelLimits(maxDuration: 10)
            ])
            #expect(
                table.entries == [
                    .init(model: Self.lite, mode: .motionTransfer, constraints: ModelConstraints(maxDuration: 10))
                ])
            #expect(Self.lite.limits(for: .motionTransfer, constraints: table).duration == 4...10)
            #expect(Self.lite.limits(for: .objectSwap, constraints: table).duration == 4...15)
            #expect(VideoModel.genjutsu.limits(for: .motionTransfer, constraints: table).duration == 4...30)
        }

        /// The live catalog's answer states no length, so the catalog's 15 s stands; a longer selection is refused.
        @Test func aSelectionPast15SecondsIsRefused() async throws {
            let motion = try CatalogSnapshot.model("hf_mult_motion_control_flash")
            let swap = try CatalogSnapshot.model("hf_mult_replace_object_flash")
            let (provider, _) = ProviderConstraints.provider(tools: Provider.fullSet + [ProviderConstraints.explore]) {
                _, arguments in
                switch arguments["model_id"]?.stringValue {
                case "hf_mult_motion_control_flash": motion
                case "hf_mult_replace_object_flash": swap
                default: [:]
                }
            }
            let table = try #require(try await provider.modelConstraints())
            #expect(table[Self.lite, .motionTransfer] == ModelConstraints())
            #expect(Self.lite.limits(for: .motionTransfer, constraints: table).duration == 4...15)
            #expect(Validation.check(Self.spec(.motionTransfer, seconds: 15), constraints: table).isEmpty)
            #expect(
                Validation.check(Self.spec(.motionTransfer, seconds: 20), constraints: table) == [.durationTooLong(20)])
            #expect(Validation.check(Self.spec(.objectSwap, seconds: 20), constraints: table) == [.durationTooLong(20)])
        }

        /// A finished Lite job in the account's history comes back as Lite, in its mode.
        @Test func historyNamesTheLiteModel() {
            #expect(HistoryMapping.kind(ofModel: "hf_mult_motion_control_flash")?.1 == Self.lite)
            #expect(HistoryMapping.kind(ofModel: "hf_mult_replace_object_flash")?.0 == .objectSwap)
        }
    }
}
