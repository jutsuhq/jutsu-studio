import Foundation
import HiggsfieldAPI
import HiggsfieldMCP
import HiggsfieldTestSupport
import JutsuCore
import Testing

@testable import HiggsfieldProviders

extension Network {
    /// Genjutsu Lite (issue #15): Genjutsu's Motion Transfer and Object Swap on Wan 3.0, as `generate_video` models of
    /// their own. With an API key, Motion Transfer alone on its REST endpoint.
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

        /// Object Swap renders at 720p and 1080p only (`hf_mult_replace_object_flash`, snapshot of 2026-10-28), so it
        /// never sends 480p: a job asking for it is made at 720p, and so is one stored at 480p before, which the
        /// Queue, the Library and the estimate then show at 720p too. Motion Transfer keeps 480p.
        @Test func objectSwapNeverSends480p() async throws {
            let (provider, stub) = Provider.provider(tools: Provider.fullSet) { _, _ in
                ["results": [["id": "job-1"]]]
            }
            // A job stored at 480p: the JSON a store kept before Object Swap had its own resolutions.
            var data = try JSONEncoder().encode(Self.spec(.objectSwap))
            var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            object["resolution"] = "480p"
            data = try JSONSerialization.data(withJSONObject: object)
            let stored = try JSONDecoder().decode(JobSpec.self, from: data)
            #expect(stored.resolution == .p720)
            #expect(try await provider.estimate(stored) == .credits(24, isEstimate: true))

            let specs = [
                Self.spec(.objectSwap, resolution: .p480), stored, Self.spec(.motionTransfer, resolution: .p480),
            ]
            #expect(specs[0].resolution == .p720)
            for spec in specs { _ = try await provider.submit(spec, inputs: Provider.inputs, idempotencyKey: UUID()) }

            let params = Provider.calls(stub).compactMap { $0["arguments"]?["params"] }
            #expect(params.map { $0["resolution"] } == ["720p", "720p", "480p"])
            for sent in params { #expect(try CatalogSnapshot.violations(ofParams: sent).isEmpty, "\(sent)") }
        }

        /// Up to 10 reference images in either mode, at least one.
        @Test(arguments: [Mode.motionTransfer, .objectSwap])
        func itTakesUpTo10Images(mode: Mode) {
            var spec = Self.spec(mode)
            spec.references = Array(repeating: LocalImage(fileURL: URL(fileURLWithPath: "/tmp/a.jpg")), count: 10)
            #expect(Validation.check(spec).isEmpty)
            spec.references.append(LocalImage(fileURL: URL(fileURLWithPath: "/tmp/b.jpg")))
            #expect(Validation.check(spec) == [.tooManyReferences(maximum: 10)])
            spec.references = []
            #expect(Validation.check(spec) == [.tooFewReferences(minimum: 1)])
        }

        /// Billed by its source, like Genjutsu: `get_cost` quotes it once the source is uploaded, with the source in
        /// `medias`. Before that it is the catalog's estimate, 2 credits a second at 720p, and nothing is asked.
        @Test(arguments: [Mode.motionTransfer, .objectSwap])
        func itIsQuotedOnceTheSourceIsUploaded(mode: Mode) async throws {
            let (provider, stub) = Provider.provider(tools: Provider.fullSet) { _, _ in
                ["cost": ["credits": 12, "credits_exact": .number(12.5)]]
            }
            #expect(try await provider.estimate(Self.spec(mode)) == .credits(24, isEstimate: true))
            // Object Swap asked for 480p is made, and estimated, at 720p.
            let low: Decimal = mode == .objectSwap ? 24 : 12
            #expect(try await provider.estimate(Self.spec(mode, resolution: .p480)) == .credits(low, isEstimate: true))
            #expect(Provider.calls(stub).isEmpty)

            let quoted = try await provider.serverEstimate(Self.spec(mode), inputs: Provider.inputs)
            #expect(quoted == .credits(12.5, isEstimate: false))
            let sent = try #require(Provider.calls(stub).first?["arguments"]?["params"])
            #expect(sent["get_cost"] == true)
            #expect(sent["model"]?.stringValue == AccountModel.model(for: Self.spec(mode))?.rawValue)
            #expect(sent["medias"]?.arrayValue?.first?["value"] == "video-1")
            #expect(try Provider.schemaViolations(stub).isEmpty)
        }

        /// The account runs both modes; an API key runs Motion Transfer alone, the one mode REST lists
        /// (`higgsfield/genjutsu-light/motion-transfer/v1.0`), and refuses an Object Swap before anything is sent.
        @Test func anAPIKeyRunsMotionTransferAlone() async throws {
            let (account, _) = Provider.provider(tools: Provider.fullSet)
            let accountCapabilities = try await account.capabilities()
            #expect(AccountModel.runs(Self.lite))
            #expect(accountCapabilities.runs(Self.lite, in: .motionTransfer))
            #expect(accountCapabilities.runs(Self.lite, in: .objectSwap))

            let server = StubServer()
            let capabilities = try await server.makeAPIProvider().capabilities()
            #expect(Self.lite.runsWithAPIKey)
            #expect(capabilities.unservedModes == [Self.lite: [.objectSwap]])
            #expect(capabilities.runs(Self.lite, in: .motionTransfer))
            #expect(!capabilities.runs(Self.lite, in: .objectSwap))
            #expect(throws: ProviderError.self) {
                try APIModel(Self.spec(.objectSwap), inputs: Self.restInputs)
            }
        }

        static let queued = """
            {"status": "queued", "request_id": "req-1",
             "status_url": "https://api.higgsfield.ai/requests/req-1/status"}
            """

        static let restInputs = RemoteInputs(
            video: RemoteAsset(url: URL(string: "https://cdn.example.com/in.mp4")!),
            images: [RemoteAsset(url: URL(string: "https://cdn.example.com/a.jpg")!)])

        /// The body of its console.higgsfield.ai schema, Genjutsu's: `video_url`, `image_urls`, `prompt` and
        /// `resolution`, sent to its own endpoint.
        @Test(arguments: [Resolution.p480, .p720, .p1080])
        func anAPIKeySendsGenjutsusBodyToLitesEndpoint(resolution: Resolution) async throws {
            let server = StubServer()
            server.on("POST", "/higgsfield/genjutsu-light/motion-transfer/v1.0", StubResponse(body: Self.queued))
            _ = try await server.makeAPIProvider().submit(
                Self.spec(.motionTransfer, resolution: resolution), inputs: Self.restInputs, idempotencyKey: UUID())

            let body = try #require(server.requests.first?.bodyText)
            #expect(
                try JSONDecoder().decode(JSONValue.self, from: Data(body.utf8))
                    == [
                        "video_url": "https://cdn.example.com/in.mp4", "image_urls": ["https://cdn.example.com/a.jpg"],
                        "prompt": "make it rain", "resolution": .string(resolution.rawValue),
                    ])
        }

        /// The list price bills the output's seconds alone, the selection's: 12 s at 720p is 12 × $0.1471. The source
        /// is uploaded, so nothing is quoted before.
        @Test(arguments: [(Resolution.p480, "0.8868"), (.p720, "1.7652"), (.p1080, "3.5232")])
        func anAPIKeyEstimatesTheListPrice(resolution: Resolution, usd: String) async throws {
            let server = StubServer()
            let cost = try await server.makeAPIProvider().estimate(Self.spec(.motionTransfer, resolution: resolution))
            #expect(cost == .usd(Decimal(string: usd)!, isEstimate: false))
            #expect(server.requests.isEmpty)
        }

        /// REST's schema takes 1-8 images, the account up to 10: an API key reports 8 as Lite's limit.
        @Test func anAPIKeyTakesUpTo8Images() async throws {
            let table = try #require(try await StubServer().makeAPIProvider().modelConstraints())
            #expect(Self.lite.limits(for: .motionTransfer, constraints: table).referenceImages == 1...8)
            #expect(VideoModel.genjutsu.limits(for: .motionTransfer, constraints: table).referenceImages == 1...8)
            var spec = Self.spec(.motionTransfer)
            spec.references = Array(repeating: LocalImage(fileURL: URL(fileURLWithPath: "/tmp/a.jpg")), count: 9)
            #expect(Validation.check(spec, constraints: table) == [.tooManyReferences(maximum: 8)])
            #expect(Validation.check(spec).isEmpty)
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
