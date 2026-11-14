import Foundation
import HiggsfieldAPI
import HiggsfieldMCP
import HiggsfieldTestSupport
import JutsuCore
import Testing

@testable import HiggsfieldProviders

extension Network {
    /// Gemini Omni Flash 1.2 on the account only: `gemini_omni_flash_1_2`'s five `mode`s against its
    /// `models_explore get` in the catalog snapshot of 2026-11-10. Higgsfield's REST catalog has no Gemini model.
    @Suite struct GeminiOmniFlash {
        static func gemini() throws -> VideoModel { try #require(VideoModel(rawValue: "geminiOmniFlash12")) }

        static func clip(
            images: Int = 0, prompt: String = "a fox in the snow", seconds: TimeInterval = 12,
            resolution: Resolution = .p720, aspectRatio: AspectRatio? = .portrait
        ) throws -> JobSpec {
            JobSpec(
                mode: .motionTransfer, model: try gemini(), source: nil,
                references: Array(repeating: LocalImage(fileURL: URL(fileURLWithPath: "/tmp/ref.png")), count: images),
                prompt: prompt, resolution: resolution, length: seconds, aspectRatio: aspectRatio)
        }

        static func frames(_ count: Int, seconds: TimeInterval = 8) throws -> JobSpec {
            var spec = try clip(images: count, prompt: "", seconds: seconds)
            spec.referencesAreFrames = true
            return spec
        }

        /// References with the source (Motion Transfer), an Edit of it, or an Extend adding `added` seconds.
        static func onSource(
            mode: Mode = .motionTransfer, seconds: TimeInterval = 8, added: TimeInterval? = nil, images: Int = 1
        ) throws -> JobSpec {
            JobSpec(
                mode: mode, model: try gemini(),
                source: SourceClip(
                    fileURL: URL(fileURLWithPath: "/tmp/in.mp4"), duration: 60,
                    pixelSize: PixelSize(width: 1280, height: 720), range: 0...seconds),
                references: Array(repeating: LocalImage(fileURL: URL(fileURLWithPath: "/tmp/ref.png")), count: images),
                prompt: "make it rain", resolution: .p1080, length: added)
        }

        @Test func itIsAnAccountOnlyGeminiUpTo4K() throws {
            let model = try Self.gemini()
            #expect(model.title == "Gemini Omni Flash 1.2" && model.family == "Gemini")
            #expect(model.modes == [.motionTransfer, .edit, .extend])
            #expect(model.resolutions == [.p360, .p720, .p1080, .k4])
            #expect(model.fitted(.p480) == .p360 && model.fitted(.k2) == .p1080)
            #expect(model.makesClipsWithoutSource && model.declares(.frames) && model.takesEndFrame)
            #expect(!model.declares(.generatedAudio) && !model.offersDraft)
            #expect(!model.runsWithAPIKey && AccountModel.runs(model))
            #expect(throws: ProviderError.self) {
                try APIModel(try Self.clip(), inputs: RemoteInputs(video: nil, images: []))
            }
        }

        /// A prompt alone, frames, references, an Edit and an Extend, each keeping to the `models_explore get`:
        /// the nearest of 16:9 and 9:16 without a source, none with one; no length for Edit; the frames as
        /// `start_image` and `end_image`; no `generate_audio`, as the model makes its sound on its own.
        @Test func theAccountSendsEachMode() async throws {
            let (provider, stub) = Provider.provider(tools: Provider.fullSet) { _, _ in
                ["results": [["id": "job-1"]]]
            }
            var wide = try Self.clip(images: 1, seconds: 30, resolution: .k4, aspectRatio: .cinema)
            wide.prompt = "a cat"
            let jobs: [(JobSpec, RemoteInputs)] = [
                (try Self.clip(seconds: 15, resolution: .p360), RemoteInputs(video: nil, images: [])),
                (try Self.frames(1), RemoteInputs(video: nil, images: [Kling4.start])),
                (try Self.frames(2), RemoteInputs(video: nil, images: [Kling4.start, Kling4.end])),
                (try Self.onSource(seconds: 14), RemoteInputs(video: Kling4.video, images: [Kling4.start])),
                (wide, RemoteInputs(video: nil, images: [Kling4.start])),
                (
                    try Self.onSource(mode: .edit, seconds: 12),
                    RemoteInputs(video: Kling4.video, images: [Kling4.start])
                ),
                (
                    try Self.onSource(mode: .extend, seconds: 6, added: 20, images: 0),
                    RemoteInputs(video: Kling4.video, images: [])
                ),
            ]
            for (spec, inputs) in jobs {
                _ = try await provider.submit(spec, inputs: inputs, idempotencyKey: UUID())
            }
            let calls = Provider.calls(stub).filter { $0["name"] == "generate_video" }
            let params = calls.compactMap { $0["arguments"]?["params"]?.objectValue }
            #expect(params.count == jobs.count)
            for call in calls {
                let found = try CatalogSnapshot.violations(ofParams: call["arguments"]?["params"] ?? .null)
                #expect(found.isEmpty, "\(found)")
            }
            #expect(params.allSatisfy { $0["model"] == "gemini_omni_flash_1_2" && $0["generate_audio"] == nil })
            #expect(
                params.map { $0["mode"] } == [
                    "text-to-video", "image-to-video", "image-to-video", "reference-to-video", "reference-to-video",
                    "edit", "extend",
                ])
            #expect(params.map { $0["duration"] } == [15, 8, 8, 10, 10, nil, 10])
            #expect(params.map { $0["aspect_ratio"] } == ["9:16", "9:16", "9:16", nil, "16:9", nil, nil])
            #expect(params.map { $0["resolution"] } == ["360p", "720p", "720p", "1080p", "4k", "1080p", "1080p"])
            #expect(params[1]["medias"] == [["role": "start_image", "value": "image-1"]])
            #expect(
                params[2]["medias"] == [
                    ["role": "start_image", "value": "image-1"], ["role": "end_image", "value": "image-2"],
                ])
            #expect(
                params[5]["medias"] == [
                    ["role": "video_references", "value": "video-1"], ["role": "image_references", "value": "image-1"],
                ])
            #expect(params[6]["medias"] == [["role": "video_references", "value": "video-1"]])
        }

        // MARK: Limits

        /// 3–15 s from a prompt or a start frame alone; 3–10 s with references, a source or an end frame, and for
        /// what Extend adds (and its clip); an Edit's clip 3–15 s. Up to six images.
        @Test func validationKeepsToTheSchema() throws {
            #expect(Validation.check(try Self.clip(seconds: 15)).isEmpty)
            #expect(Validation.check(try Self.clip(seconds: 16)).contains(.durationTooLong(16)))
            #expect(Validation.check(try Self.frames(1, seconds: 15)).isEmpty)
            #expect(Validation.check(try Self.frames(2, seconds: 12)).contains(.durationTooLong(12)))
            #expect(Validation.check(try Self.clip(images: 6, seconds: 10)).isEmpty)
            #expect(Validation.check(try Self.clip(images: 1, seconds: 11)).contains(.durationTooLong(11)))
            #expect(Validation.check(try Self.clip(images: 7, seconds: 10)).contains(.tooManyReferences(maximum: 6)))
            #expect(Validation.check(try Self.onSource(seconds: 11)).contains(.durationTooLong(11)))
            #expect(Validation.check(try Self.onSource(mode: .edit, seconds: 15)).isEmpty)
            #expect(Validation.check(try Self.onSource(mode: .edit, seconds: 16)).contains(.durationTooLong(16)))
            let extend = { (added: TimeInterval) in try Self.onSource(mode: .extend, seconds: 6, added: added) }
            #expect(Validation.check(try extend(10)).isEmpty)
            #expect(Validation.check(try extend(11)).contains(.durationTooLong(11)))
            #expect(Validation.check(try extend(2)).contains(.durationTooShort(2)))
            #expect(Validation.check(try Self.clip(prompt: "")) == [.promptRequired])
            #expect(Validation.check(try Self.frames(1)).isEmpty)
        }

        // MARK: Prices

        /// Until a quote: 2 credits a second at 720p, from Higgsfield's published dollar price, and Google's ratios
        /// for the other tiers. A prompt alone is quoted before upload; media, Edit and Extend after.
        @Test func theAccountEstimatesUntilAQuote() async throws {
            #expect(AccountModel.estimatedCredits(for: try Self.clip(seconds: 10)) == 20)
            #expect(AccountModel.estimatedCredits(for: try Self.clip(seconds: 10, resolution: .p360)) == 7)
            #expect(AccountModel.estimatedCredits(for: try Self.clip(seconds: 10, resolution: .p1080)) == 30)
            #expect(AccountModel.estimatedCredits(for: try Self.clip(seconds: 10, resolution: .k4)) == 60)
            #expect(AccountModel.estimatedCredits(for: try Self.onSource(mode: .edit, seconds: 12)) == 36)
            #expect(AccountModel.estimatedCredits(for: try Self.onSource(mode: .extend, added: 5, images: 0)) == 15)

            let model = VideoRequest.Model(rawValue: "gemini_omni_flash_1_2")
            let quote = try #require(AccountModel.quoteRequest(for: try Self.clip(), model: model))
            #expect(quote.mode == VideoRequest.kling4TextToVideo && quote.duration == 12 && quote.resolution == "720p")
            for spec in [
                try Self.frames(1), try Self.clip(images: 1), try Self.onSource(), try Self.onSource(mode: .edit),
                try Self.onSource(mode: .extend, added: 5, images: 0),
            ] {
                #expect(AccountModel.quoteRequest(for: spec, model: model) == nil)
            }
        }

        // MARK: History

        /// `edit` and `extend` come back as Edit and Extend, its other modes as Motion Transfer; neither without
        /// its clip.
        @Test func historyNamesItsModes() throws {
            let video = PastMedia(role: .video, id: "video-1", url: URL(string: "https://cdn.example/in.mp4"))
            func generation(_ mode: String, _ media: [PastMedia]) -> PastGeneration {
                var generation = PastGeneration(
                    id: "g-1", type: "video", status: "completed", model: "gemini_omni_flash_1_2",
                    createdAt: Date(timeIntervalSince1970: 0), outputURL: URL(string: "https://cdn.example/out.mp4"),
                    duration: 8, prompt: "rain", resolution: "4k", media: media)
                generation.mode = mode
                return generation
            }
            let edit = try #require(HistoryMapping.item(generation("edit", [video])))
            #expect(edit.mode == .edit && edit.spec().resolution == .k4)
            #expect(try #require(HistoryMapping.item(generation("extend", [video]))).mode == .extend)
            #expect(try #require(HistoryMapping.item(generation("text-to-video", []))).mode == .motionTransfer)
            #expect(HistoryMapping.item(generation("extend", [])) == nil)
            #expect(HistoryMapping.item(generation("edit", [])) == nil)
        }
    }
}
