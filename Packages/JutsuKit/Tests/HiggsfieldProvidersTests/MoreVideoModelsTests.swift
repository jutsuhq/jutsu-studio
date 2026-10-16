import Foundation
import HiggsfieldAPI
import HiggsfieldMCP
import HiggsfieldTestSupport
import JutsuCore
import Testing

@testable import HiggsfieldProviders

extension Network {
    /// The reference-video models of issue #101: their REST bodies from the documented schemas, and their
    /// `generate_video` arguments against the account's own schemas in the catalog snapshot of 2026-10-15.
    @Suite struct MoreVideoModels {
        static func model(_ id: String) throws -> VideoModel { try #require(VideoModel(rawValue: id)) }

        static func spec(
            _ id: String, mode: Mode = .motionTransfer, seconds: TimeInterval = 10, resolution: Resolution = .p720,
            size: PixelSize = PixelSize(width: 1280, height: 720), audio: AudioOption = .original
        ) throws -> JobSpec {
            JobSpec(
                mode: mode, model: try model(id),
                source: SourceClip(
                    fileURL: URL(fileURLWithPath: "/tmp/in.mp4"), duration: 40, pixelSize: size, range: 0...seconds),
                references: [LocalImage(fileURL: URL(fileURLWithPath: "/tmp/ref.png"))], prompt: "make it rain",
                resolution: resolution, audio: audio)
        }

        static let inputs = RemoteInputs(
            video: RemoteAsset(url: URL(string: "https://cdn.example.com/in.mp4")!, id: "video-1"),
            images: [RemoteAsset(url: URL(string: "https://cdn.example.com/a.jpg")!, id: "image-1")])

        static func body(of request: APIModel) throws -> String {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return String(decoding: try encoder.encode(request.body), as: UTF8.self)
        }

        // MARK: REST

        /// Kling O3 Edit: the source, the images and the quality; no length, the output follows the source.
        @Test func klingO3EditSendsTheClipTheImagesAndTheQuality() throws {
            let standard = try APIModel(Self.spec("klingO3VideoEdit", mode: .edit), inputs: Self.inputs)
            #expect(standard.endpoint == .klingO3VideoEdit)
            #expect(
                try Self.body(of: standard)
                    == #"{"image_urls":["https://cdn.example.com/a.jpg"],"mode":"std","prompt":"make it rain","video_urls":["https://cdn.example.com/in.mp4"]}"#
            )
            let pro = try APIModel(Self.spec("klingO3VideoEdit", mode: .edit, resolution: .p1080), inputs: Self.inputs)
            #expect(try Self.body(of: pro).contains(#""mode":"pro""#))
        }

        /// Kling 2.6 Motion Control: 3.0's body, its quality the endpoint.
        @Test func kling26IsTheMotionControlBodyOnItsOwnEndpoints() throws {
            let standard = try APIModel(Self.spec("klingMotionControl26"), inputs: Self.inputs)
            #expect(standard.endpoint == .kling26MotionControlStandard)
            #expect(standard.body is KlingMotionRequest)
            let pro = try APIModel(Self.spec("klingMotionControl26", resolution: .p1080), inputs: Self.inputs)
            #expect(pro.endpoint == .kling26MotionControlPro)
        }

        /// Wan 3.0 and 3.0 Prime: the selection's seconds, the resolution, the soundtrack switch; no frame, so the
        /// server's `adaptive` follows the references.
        @Test(arguments: [
            ("wan30Reference", ModelEndpoint.wan30ReferenceToVideo),
            ("wan30PrimeReference", .wan30PrimeReferenceToVideo),
        ])
        func wan30SendsTheLengthResolutionAndSound(id: String, endpoint: ModelEndpoint) throws {
            let request = try APIModel(Self.spec(id, seconds: 12.5), inputs: Self.inputs)
            #expect(request.endpoint == endpoint)
            #expect(
                try Self.body(of: request)
                    == #"{"duration":13,"generate_audio":false,"image_urls":["https://cdn.example.com/a.jpg"],"prompt":"make it rain","resolution":"720p","video_urls":["https://cdn.example.com/in.mp4"]}"#
            )
            let generated = try APIModel(Self.spec(id, audio: .generated), inputs: Self.inputs)
            #expect(try Self.body(of: generated).contains(#""generate_audio":true"#))
        }

        /// Wan 2.7: at most 10 s, 720p or 1080p, 16:9 or 9:16 by the source's frame, and no soundtrack switch.
        @Test func wan27KeepsToItsSchema() throws {
            let portrait = try Self.spec(
                "wan27Reference", seconds: 14, resolution: .p480, size: PixelSize(width: 720, height: 1280))
            let request = try APIModel(portrait, inputs: Self.inputs)
            #expect(request.endpoint == .wan27ReferenceToVideo)
            #expect(
                try Self.body(of: request)
                    == #"{"aspect_ratio":"9:16","duration":10,"image_urls":["https://cdn.example.com/a.jpg"],"prompt":"make it rain","resolution":"720p","video_urls":["https://cdn.example.com/in.mp4"]}"#
            )
        }

        /// Cinema Studio 4.0: at least 4 s, 480p or 720p, the frame nearest the source's (it takes no "auto").
        @Test func cinemaStudioKeepsToItsSchema() throws {
            let spec = try Self.spec("cinemaStudio4", seconds: 2, resolution: .p1080, audio: .generated)
            let request = try APIModel(spec, inputs: Self.inputs)
            #expect(request.endpoint == .cinemaStudio4)
            #expect(
                try Self.body(of: request)
                    == #"{"aspect_ratio":"16:9","duration":4,"generate_audio":true,"image_urls":["https://cdn.example.com/a.jpg"],"prompt":"make it rain","resolution":"720p","video_urls":["https://cdn.example.com/in.mp4"]}"#
            )
        }

        /// Cinema Studio's creative controls go in the body by their fields, only the ones the job sets.
        @Test func cinemaStudioSendsTheControlsItSets() throws {
            var spec = try Self.spec("cinemaStudio4", seconds: 6)
            spec.cinemaControls = CinemaControls([
                .cameraModel: "35mm-film", .cameraLens: "anamorphic", .cameraAperture: "f4-moderate",
                .cameraMovement: "dolly-in", .genre: "noir", .era: "1960s", .light: "contre-jour", .pacing: "calm",
                .colorPalette: "neon-rain-at-midnight",
            ])
            #expect(
                try Self.body(of: APIModel(spec, inputs: Self.inputs))
                    == #"{"aspect_ratio":"16:9","camera_aperture":"f4-moderate","camera_lens":"anamorphic","camera_model":"35mm-film","camera_movement":"dolly-in","color_palette":"neon-rain-at-midnight","duration":6,"era":"1960s","generate_audio":false,"genre":"noir","image_urls":["https://cdn.example.com/a.jpg"],"light":"contre-jour","pacing":"calm","prompt":"make it rain","resolution":"720p","video_urls":["https://cdn.example.com/in.mp4"]}"#
            )
            // Another model with the same body sends none, even from a spec that has them.
            var wan = try Self.spec("wan30Reference")
            wan.cinemaControls = spec.cinemaControls
            #expect(!(try Self.body(of: APIModel(wan, inputs: Self.inputs)).contains("genre")))
        }

        /// MiniMax H3: 2K whatever the form's resolution, 5–15 s, no frame (the server's `auto`) and no soundtrack
        /// switch. H3 Max isn't in the REST docs, so an API key can't run it.
        @Test func miniMaxH3KeepsToItsSchema() throws {
            let short = try APIModel(Self.spec("minimaxH3Reference", seconds: 3), inputs: Self.inputs)
            #expect(short.endpoint == .minimaxH3ReferenceToVideo)
            #expect(
                try Self.body(of: short)
                    == #"{"duration":5,"image_urls":["https://cdn.example.com/a.jpg"],"prompt":"make it rain","resolution":"2K","video_urls":["https://cdn.example.com/in.mp4"]}"#
            )
            let long = try APIModel(Self.spec("minimaxH3Reference", seconds: 20), inputs: Self.inputs)
            #expect(try Self.body(of: long).contains(#""duration":15"#))
            #expect(throws: ProviderError.self) {
                try APIModel(Self.spec("minimaxH3MaxReference", resolution: .p768), inputs: Self.inputs)
            }
        }

        /// Wan 2.7, Kling 2.6 and the Kling O3 video reference run with an API key only.
        @Test func theAccountRunsOnlyTheConfirmedOnes() throws {
            for id in ["wan27Reference", "klingMotionControl26", "klingO3VideoReference"] {
                #expect(!AccountModel.runs(try Self.model(id)), "\(id)")
            }
            for id in [
                "klingO3VideoEdit", "wan30Reference", "wan30PrimeReference", "cinemaStudio4", "minimaxH3Reference",
                "minimaxH3MaxReference",
            ] {
                #expect(AccountModel.runs(try Self.model(id)), "\(id)")
            }
        }

        // MARK: Account

        /// Each catalog model the account runs sends only what `models_explore get` of its model lists: the roles,
        /// the parameter names and their options and ranges, at each of its resolutions, at both ends of its length
        /// and with each sound choice. The arguments also keep to `generate_video`'s `inputSchema`.
        @Test func everyAccountModelKeepsToItsSnapshotSchema() async throws {
            let (provider, stub) = Provider.provider(tools: Provider.fullSet) { _, _ in
                ["results": [["id": "job-1"]]]
            }
            var sent = 0
            var withVariants = 0
            for model in VideoModel.allCases where AccountModel.runs(model) {
                for mode in model.modes where model.accountModelID(for: mode) != nil {
                    let limits = model.limits(for: mode)
                    for resolution in model.resolutions {
                        for seconds in [limits.duration.lowerBound, limits.duration.upperBound] {
                            for audio in [AudioOption.original, .generated] {
                                var spec = try Self.spec(
                                    model.rawValue, mode: mode, seconds: seconds, resolution: resolution, audio: audio)
                                // Variants (`count`) are a `generate_video` setting every account model takes.
                                spec.variants = audio == .generated ? JobSpec.maximumVariants : 1
                                if spec.variants > 1 { withVariants += 1 }
                                _ = try await provider.submit(spec, inputs: Self.inputs, idempotencyKey: UUID())
                                sent += 1
                            }
                        }
                    }
                }
            }
            let calls = Provider.calls(stub).filter { $0["name"] == "generate_video" }
            #expect(calls.count == sent)
            #expect(calls.filter { $0["arguments"]?["params"]?["count"] == 4 }.count == withVariants)
            // Kling 3.0's `duration` predates the snapshot: its `get` lists no length, and `generate_video` clamps or
            // ignores what a model doesn't take (`docs/higgsfield-api.md` 4.5).
            let known = "kling3_0_motion_control: duration isn't a parameter"
            for call in calls {
                let arguments = call["arguments"] ?? [:]
                #expect(try CatalogSnapshot.violations(of: arguments, sentTo: "generate_video").isEmpty)
                let found = try CatalogSnapshot.violations(ofParams: arguments["params"] ?? .null).filter {
                    $0 != known
                }
                #expect(found.isEmpty, "\(found)")
            }
        }

        /// The new account models' arguments as sent.
        @Test func theNewAccountModelsSendTheirParams() async throws {
            let (provider, stub) = Provider.provider(tools: Provider.fullSet) { _, _ in
                ["results": [["id": "job-2"]]]
            }
            let specs = [
                try Self.spec("klingO3VideoEdit", mode: .edit, resolution: .p1080), try Self.spec("wan30Reference"),
                try Self.spec("wan30PrimeReference", audio: .generated), try Self.spec("cinemaStudio4", seconds: 12),
            ]
            for spec in specs { _ = try await provider.submit(spec, inputs: Self.inputs, idempotencyKey: UUID()) }

            let params = Provider.calls(stub).compactMap { $0["arguments"]?["params"]?.objectValue }
            let medias: JSONValue = [
                ["role": "video_references", "value": "video-1"], ["role": "image_references", "value": "image-1"],
            ]
            #expect(
                params[0] == [
                    "model": "kling_video_edit", "medias": medias, "prompt": "make it rain", "mode": "pro",
                    "use_unlim": false,
                ])
            #expect(
                params[1] == [
                    "model": "wan3_0", "medias": medias, "prompt": "make it rain", "resolution": "720p", "duration": 10,
                    "generate_audio": false, "use_unlim": false,
                ])
            #expect(params[2]["model"] == "wan3_0_prime")
            #expect(params[2]["generate_audio"] == true)
            #expect(
                params[3] == [
                    "model": "cinematic_studio_video_4_0", "medias": medias, "prompt": "make it rain",
                    "mode": "omni_reference", "resolution": "720p", "duration": 12, "generate_audio": false,
                    "use_unlim": false,
                ])
        }

        /// MiniMax H3 and H3 Max on the account: their own resolutions and the length, no `mode` or soundtrack, as
        /// their `models_explore get` lists. Cinema Studio leaves its creative controls out there: the account
        /// names them by IDs its catalog doesn't list.
        @Test func miniMaxAndCinemaControlsOnTheAccount() async throws {
            let (provider, stub) = Provider.provider(tools: Provider.fullSet) { _, _ in
                ["results": [["id": "job-3"]]]
            }
            var cinema = try Self.spec("cinemaStudio4", seconds: 12)
            cinema.cinemaControls = CinemaControls([.genre: "noir", .cameraModel: "8mm-film"])
            let specs = [
                try Self.spec("minimaxH3Reference", seconds: 8),
                try Self.spec("minimaxH3MaxReference", seconds: 20, resolution: .p1080), cinema,
            ]
            for spec in specs { _ = try await provider.submit(spec, inputs: Self.inputs, idempotencyKey: UUID()) }

            let params = Provider.calls(stub).compactMap { $0["arguments"]?["params"]?.objectValue }
            let medias: JSONValue = [
                ["role": "video_references", "value": "video-1"], ["role": "image_references", "value": "image-1"],
            ]
            #expect(
                params[0] == [
                    "model": "minimax_h3", "medias": medias, "prompt": "make it rain", "resolution": "2K",
                    "duration": 8, "use_unlim": false,
                ])
            #expect(
                params[1] == [
                    "model": "minimax_h3_max", "medias": medias, "prompt": "make it rain", "resolution": "768p",
                    "duration": 15, "use_unlim": false,
                ])
            #expect(
                params[2] == [
                    "model": "cinematic_studio_video_4_0", "medias": medias, "prompt": "make it rain",
                    "mode": "omni_reference", "resolution": "720p", "duration": 12, "generate_audio": false,
                    "use_unlim": false,
                ])
            #expect(!AccountModel.parameters.contains(.cinemaControls))
        }

        /// A reframe takes 480p, 720p or 1080p: a MiniMax result's 2K or 768p is sent as the nearest of those.
        @Test(arguments: [(Resolution.k2, "1080p"), (.p768, "720p"), (.p480, "480p")])
        func aReframeOfAMiniMaxResultTakesAStandardResolution(resolution: Resolution, sent: String) throws {
            var spec = try Self.spec("minimaxH3MaxReference", resolution: resolution)
            spec.resolution = resolution
            spec.operation = PostOperation(action: .reframe(.portrait), sourceJobID: "job-1")
            guard case .reframe(_, _, let sentResolution) = AccountModel.editOperation(for: spec) else {
                Issue.record("expected a reframe")
                return
            }
            #expect(sentResolution == sent)
        }

        /// The fallback estimates of the new models, from the free quotes of 2026-10-15 (issue #113), for when
        /// Higgsfield can't quote: 10 s.
        @Test(arguments: [
            ("wan30Reference", Resolution.p480, 10), ("wan30Reference", .p1080, 35),
            ("wan30PrimeReference", .p720, 30), ("wan30PrimeReference", .p1080, 60),
            ("cinemaStudio4", .p480, 30), ("cinemaStudio4", .p720, 70),
        ])
        func theNewModelsHaveAFallbackEstimate(id: String, resolution: Resolution, credits: Int) throws {
            #expect(AccountModel.estimatedCredits(for: try Self.spec(id, resolution: resolution)) == credits)
        }

        /// Kling O3 Edit follows its source, so before upload it has only the estimate (12 s: std 18, pro 24).
        @Test func klingO3EditIsEstimatedByItsSource() async throws {
            let (provider, stub) = Provider.provider(tools: Provider.fullSet)
            let standard = try Self.spec("klingO3VideoEdit", mode: .edit, seconds: 12)
            let pro = try Self.spec("klingO3VideoEdit", mode: .edit, seconds: 12, resolution: .p1080)
            #expect(try await provider.estimate(standard) == .credits(18, isEstimate: true))
            #expect(try await provider.estimate(pro) == .credits(24, isEstimate: true))
            #expect(Provider.calls(stub).isEmpty)
        }
    }
}
