import Foundation
import HiggsfieldAPI
import HiggsfieldMCP
import HiggsfieldTestSupport
import JutsuCore
import Testing

@testable import HiggsfieldProviders

extension Network {
    /// Kling 4.0 Flash runs Kling 4.0's code with its own catalog entry: REST's four `v4.0-flash` endpoints from their
    /// model pages (2026-11-11) and `kling_4_0_flash`'s `mode`s against its `models_explore get` in the catalog
    /// snapshot of 2026-11-10. It renders at 720p only, for 3–20 s, from a start frame without an end frame.
    @Suite struct Kling4Flash {
        static func flash() throws -> VideoModel { try #require(VideoModel(rawValue: "kling40Flash")) }

        /// Kling 4.0's job of the same kind (`Network.Kling4`), on Flash at its one resolution.
        static func onFlash(_ spec: JobSpec) throws -> JobSpec {
            var spec = spec
            spec.model = try flash()
            spec.resolution = .p720
            return spec
        }

        static func clip(
            images: Int = 0, seconds: TimeInterval = 12, aspectRatio: AspectRatio? = .portrait
        ) throws
            -> JobSpec
        {
            try onFlash(Kling4.clip(images: images, seconds: seconds, aspectRatio: aspectRatio))
        }

        static func frames(_ count: Int = 1) throws -> JobSpec { try onFlash(Kling4.frames(count)) }

        static func onSource(mode: Mode = .motionTransfer, seconds: TimeInterval = 10) throws -> JobSpec {
            try onFlash(Kling4.onSource(mode: mode, seconds: seconds))
        }

        @Test func itIsTheCheapKlingFourAt720p() throws {
            let model = try Self.flash()
            #expect(model.title == "Kling 4.0 Flash")
            #expect(model.family == VideoModel.klingMotionControl.family)
            #expect(model.modes == [.motionTransfer, .edit])
            #expect(model.resolutions == [.p720])
            #expect(model.fitted(.p1080) == .p720)
            #expect(model.makesClipsWithoutSource && model.declares(.frames) && !model.takesEndFrame)
            #expect(try Kling4.kling().takesEndFrame)
            #expect(model.descriptor.shape == .kling4 && model.descriptor.requiresPrompt)
            #expect(model.runsWithAPIKey && AccountModel.runs(model))
            for mode in model.modes {
                #expect(model.limits(for: mode).duration == 3...20)
                #expect(model.limits(for: mode).referenceImages.upperBound == 10)
            }
        }

        // MARK: REST

        /// Each kind of job goes to Flash's own endpoint with Kling 4.0's body: 720p, the length inside 3–20 s, and
        /// from frames the start alone.
        @Test func eachModeHasItsFlashEndpoint() throws {
            let none = RemoteInputs(video: nil, images: [])
            let text = try Kling4.body(of: Self.clip(), inputs: none)
            #expect(text.0 == .kling4FlashTextToVideo)
            #expect(
                text.1 == #"{"aspect_ratio":"9:16","duration":12,"prompt":"a fox in the snow","resolution":"720p"}"#)
            #expect(try Kling4.body(of: Self.clip(seconds: 1), inputs: none).1.contains(#""duration":3,"#))
            #expect(try Kling4.body(of: Self.clip(seconds: 25), inputs: none).1.contains(#""duration":20,"#))

            let framed = try Kling4.body(of: Self.frames(), inputs: RemoteInputs(video: nil, images: [Kling4.start]))
            #expect(framed.0 == .kling4FlashImageToVideo)
            #expect(framed.1 == #"{"duration":5,"image_url":"https://cdn.example.com/a.jpg","resolution":"720p"}"#)
            // Its schema has no end frame and refuses unknown fields, so a second image is never sent as one.
            let two = try Kling4.body(
                of: Self.frames(2), inputs: RemoteInputs(video: nil, images: [Kling4.start, Kling4.end]))
            #expect(!two.1.contains("end_image_url"))

            let withVideo = RemoteInputs(video: Kling4.video, images: [Kling4.start])
            let reference = try Kling4.body(of: Self.onSource(), inputs: withVideo)
            #expect(reference.0 == .kling4FlashReferenceToVideo)
            #expect(
                reference.1
                    == #"{"aspect_ratio":"adaptive","duration":10,"image_urls":["https://cdn.example.com/a.jpg"],"prompt":"make it rain","resolution":"720p","video_urls":["https://cdn.example.com/in.mp4"]}"#
            )
            let edit = try Kling4.body(of: Self.onSource(mode: .edit, seconds: 30), inputs: withVideo)
            #expect(edit.0 == .kling4FlashVideoEdit)
            #expect(
                edit.1
                    == #"{"aspect_ratio":"adaptive","duration":20,"image_urls":["https://cdn.example.com/a.jpg"],"prompt":"make it rain","resolution":"720p","video_url":"https://cdn.example.com/in.mp4"}"#
            )
        }

        // MARK: Account

        /// `kling_4_0_flash`'s four `mode`s, each keeping to its `models_explore get`: 720p, 3–20 s, the frame as
        /// `start_image` alone, the source and images as references.
        @Test func theAccountSendsEachMode() async throws {
            let (provider, stub) = Provider.provider(tools: Provider.fullSet) { _, _ in
                ["results": [["id": "job-1"]]]
            }
            let jobs: [(JobSpec, RemoteInputs)] = [
                (try Self.clip(), RemoteInputs(video: nil, images: [])),
                (try Self.frames(), RemoteInputs(video: nil, images: [Kling4.start])),
                (try Self.onSource(), RemoteInputs(video: Kling4.video, images: [Kling4.start])),
                (
                    try Self.onSource(mode: .edit, seconds: 40),
                    RemoteInputs(video: Kling4.video, images: [Kling4.start])
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
            #expect(params.allSatisfy { $0["model"] == "kling_4_0_flash" && $0["resolution"] == "720p" })
            #expect(
                params.map { $0["mode"] } == ["text-to-video", "image-to-video", "reference-to-video", "video-edit"])
            #expect(params[0]["duration"] == 12 && params[0]["aspect_ratio"] == "9:16")
            #expect(params[1]["medias"] == [["role": "start_image", "value": "image-1"]])
            #expect(params[2]["aspect_ratio"] == "auto")
            #expect(params[3]["duration"] == 20)
        }

        // MARK: Validation

        /// One start frame, no end frame; up to 20 s; ten images.
        @Test func validationKeepsToTheSchemas() throws {
            #expect(Validation.check(try Self.clip()).isEmpty)
            #expect(Validation.check(try Self.frames()).isEmpty)
            #expect(Validation.check(try Self.frames(2)).contains(.tooManyReferences(maximum: 1)))
            #expect(Validation.check(try Self.clip(images: 11)).contains(.tooManyReferences(maximum: 10)))
            #expect(Validation.check(try Self.onSource(mode: .edit, seconds: 21)).contains(.durationTooLong(21)))
            #expect(Validation.check(try Self.onSource(seconds: 20)).isEmpty)
        }

        // MARK: Prices

        /// The REST list price: $0.094 a second without an input video; with one, $0.063 on the output's seconds
        /// plus as many of the input's, which are the selection's.
        @Test func restListPrices() throws {
            let pricing = try Pricing.bundled()
            for spec in [try Self.clip(seconds: 10), try Self.clip(images: 1, seconds: 10)] {
                #expect(try pricing.cost(for: spec) == .usd(Decimal(string: "0.94")!, isEstimate: true))
            }
            var frames = try Self.frames()
            frames.length = 10
            #expect(try pricing.cost(for: frames) == .usd(Decimal(string: "0.94")!, isEstimate: true))
            for spec in [try Self.onSource(), try Self.onSource(mode: .edit)] {
                #expect(try pricing.cost(for: spec) == .usd(Decimal(string: "1.26")!, isEstimate: true))
            }
        }

        /// On the account, until a quote: 3 credits a second, 4 with a source video, derived from REST's prices
        /// against Kling 4.0's (no credit price is published). A prompt alone is quoted before upload.
        @Test func theAccountEstimatesUntilAQuote() throws {
            #expect(AccountModel.estimatedCredits(for: try Self.clip(seconds: 10)) == 30)
            #expect(AccountModel.estimatedCredits(for: try Self.frames()) == 15)
            #expect(AccountModel.estimatedCredits(for: try Self.onSource()) == 40)
            #expect(AccountModel.estimatedCredits(for: try Self.onSource(mode: .edit, seconds: 12)) == 48)
            let model = VideoRequest.Model(rawValue: "kling_4_0_flash")
            let quote = try #require(AccountModel.quoteRequest(for: try Self.clip(), model: model))
            #expect(quote.mode == VideoRequest.kling4TextToVideo && quote.resolution == "720p")
            #expect(AccountModel.quoteRequest(for: try Self.onSource(), model: model) == nil)
        }
    }
}
