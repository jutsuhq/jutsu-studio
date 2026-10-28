import Foundation
import HiggsfieldAPI
import HiggsfieldMCP
import HiggsfieldTestSupport
import JutsuCore
import Testing

@testable import HiggsfieldProviders

extension Network {
    /// Kling 4.0 on both connections: REST's four endpoints from their documented schemas (open.higgsfield.ai,
    /// 2026-10-28) and `kling4_0`'s `mode`s against its `models_explore get` in the catalog snapshot.
    @Suite struct Kling4 {
        static let model = VideoModel(rawValue: "kling40")

        static func kling() throws -> VideoModel { try #require(model) }

        /// A clip from a prompt alone, or from images when there are some.
        static func clip(
            images: Int = 0, prompt: String = "a fox in the snow", seconds: TimeInterval = 12,
            resolution: Resolution = .p1080, aspectRatio: AspectRatio? = .portrait
        ) throws -> JobSpec {
            JobSpec(
                mode: .motionTransfer, model: try kling(), source: nil,
                references: Array(repeating: LocalImage(fileURL: URL(fileURLWithPath: "/tmp/ref.png")), count: images),
                prompt: prompt, resolution: resolution, length: seconds, aspectRatio: aspectRatio)
        }

        /// A clip from a start frame and, with two images, an end frame.
        static func frames(_ count: Int = 2, prompt: String = "") throws -> JobSpec {
            var spec = try clip(images: count, prompt: prompt, seconds: 5, resolution: .p720)
            spec.referencesAreFrames = true
            return spec
        }

        /// A job on a source: its references (Motion Transfer) or an Edit of it.
        static func onSource(
            mode: Mode = .motionTransfer, seconds: TimeInterval = 10, images: Int = 1, prompt: String = "make it rain"
        ) throws -> JobSpec {
            JobSpec(
                mode: mode, model: try kling(),
                source: SourceClip(
                    fileURL: URL(fileURLWithPath: "/tmp/in.mp4"), duration: 60,
                    pixelSize: PixelSize(width: 1280, height: 720), range: 0...seconds),
                references: Array(repeating: LocalImage(fileURL: URL(fileURLWithPath: "/tmp/ref.png")), count: images),
                prompt: prompt, resolution: .p720)
        }

        static let video = RemoteAsset(url: URL(string: "https://cdn.example.com/in.mp4")!, id: "video-1")
        static let start = RemoteAsset(url: URL(string: "https://cdn.example.com/a.jpg")!, id: "image-1")
        static let end = RemoteAsset(url: URL(string: "https://cdn.example.com/b.jpg")!, id: "image-2")

        static func body(of spec: JobSpec, inputs: RemoteInputs) throws -> (ModelEndpoint, String) {
            let request = try APIModel(spec, inputs: inputs)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return (request.endpoint, String(decoding: try encoder.encode(request.body), as: UTF8.self))
        }

        @Test func itIsAKlingThatMakesClipsWithoutASource() throws {
            let model = try Self.kling()
            #expect(model.title == "Kling 4.0")
            #expect(model.family == VideoModel.klingMotionControl.family)
            #expect(model.modes == [.motionTransfer, .edit])
            #expect(model.resolutions == [.p720, .p1080])
            #expect(model.makesClipsWithoutSource && model.declares(.frames) && model.descriptor.requiresPrompt)
            #expect(model.runsWithAPIKey && AccountModel.runs(model))
            for mode in model.modes {
                #expect(model.limits(for: mode).duration == 3...30)
                #expect(model.limits(for: mode).referenceImages.upperBound == 10)
            }
        }

        // MARK: REST

        /// A prompt alone: `text-to-video`, the frame asked for (it has no `adaptive`, so Auto leaves it out for
        /// the server's 16:9) and the length inside 3–30 s.
        @Test func aPromptAloneIsTextToVideo() throws {
            let none = RemoteInputs(video: nil, images: [])
            let (endpoint, body) = try Self.body(of: Self.clip(), inputs: none)
            #expect(endpoint == .kling4TextToVideo)
            #expect(body == #"{"aspect_ratio":"9:16","duration":12,"prompt":"a fox in the snow","resolution":"1080p"}"#)
            #expect(
                try Self.body(of: Self.clip(aspectRatio: .cinema), inputs: none).1.contains(#""aspect_ratio":"21:9""#))
            #expect(!(try Self.body(of: Self.clip(aspectRatio: .auto), inputs: none).1.contains("aspect_ratio")))
            #expect(try Self.body(of: Self.clip(seconds: 1), inputs: none).1.contains(#""duration":3,"#))
            #expect(try Self.body(of: Self.clip(seconds: 45), inputs: none).1.contains(#""duration":30,"#))
        }

        /// Frames: `image-to-video` with the start and end frame, no prompt needed and no frame (the images set it).
        @Test func framesAreImageToVideo() throws {
            let (endpoint, body) = try Self.body(
                of: Self.frames(), inputs: RemoteInputs(video: nil, images: [Self.start, Self.end]))
            #expect(endpoint == .kling4ImageToVideo)
            #expect(
                body
                    == #"{"duration":5,"end_image_url":"https://cdn.example.com/b.jpg","image_url":"https://cdn.example.com/a.jpg","resolution":"720p"}"#
            )
            let startOnly = try Self.body(of: Self.frames(1), inputs: RemoteInputs(video: nil, images: [Self.start]))
            #expect(!startOnly.1.contains("end_image_url"))
            #expect(throws: ProviderError.self) {
                try APIModel(Self.frames(0), inputs: RemoteInputs(video: nil, images: []))
            }
        }

        /// References: `reference-to-video` with the images (`@image_1`…) and the source as the one reference video
        /// (`@video_1`); Auto with a source is `adaptive`, without one the frame asked for.
        @Test func referencesAreReferenceToVideo() throws {
            let (endpoint, body) = try Self.body(
                of: Self.onSource(), inputs: RemoteInputs(video: Self.video, images: [Self.start]))
            #expect(endpoint == .kling4ReferenceToVideo)
            #expect(
                body
                    == #"{"aspect_ratio":"adaptive","duration":10,"image_urls":["https://cdn.example.com/a.jpg"],"prompt":"make it rain","resolution":"720p","video_urls":["https://cdn.example.com/in.mp4"]}"#
            )
            let images = try Self.body(
                of: Self.clip(images: 2, aspectRatio: .landscape),
                inputs: RemoteInputs(video: nil, images: [Self.start, Self.end]))
            #expect(images.0 == .kling4ReferenceToVideo)
            #expect(
                images.1
                    == #"{"aspect_ratio":"16:9","duration":12,"image_urls":["https://cdn.example.com/a.jpg","https://cdn.example.com/b.jpg"],"prompt":"a fox in the snow","resolution":"1080p"}"#
            )
            let auto = try Self.body(
                of: Self.clip(images: 1, aspectRatio: .auto), inputs: RemoteInputs(video: nil, images: [Self.start]))
            #expect(auto.1.contains(#""aspect_ratio":"adaptive""#))
        }

        /// Edit: `video-edit` with the source as `video_url` and the images as references; its `duration` is the
        /// output's, the selection's inside 3–30 s.
        @Test func anEditIsVideoEdit() throws {
            let inputs = RemoteInputs(video: Self.video, images: [Self.start])
            let (endpoint, body) = try Self.body(of: Self.onSource(mode: .edit, seconds: 12), inputs: inputs)
            #expect(endpoint == .kling4VideoEdit)
            #expect(
                body
                    == #"{"aspect_ratio":"adaptive","duration":12,"image_urls":["https://cdn.example.com/a.jpg"],"prompt":"make it rain","resolution":"720p","video_url":"https://cdn.example.com/in.mp4"}"#
            )
            #expect(
                try Self.body(of: Self.onSource(mode: .edit, seconds: 2), inputs: inputs).1.contains(#""duration":3,"#))
            #expect(
                try Self.body(of: Self.onSource(mode: .edit, seconds: 40), inputs: inputs).1.contains(
                    #""duration":30,"#))
            #expect(throws: ProviderError.self) {
                try APIModel(Self.onSource(mode: .edit), inputs: RemoteInputs(video: nil, images: [Self.start]))
            }
        }

        /// The app's tags become the schemas': `@ImageN` the N-th image sent, `@Video1` the source; the whole number
        /// is read, and a tag past what is sent, or already `@image_N`, stays as written.
        @Test func theTagsAreTheSchemas() throws {
            #expect(
                APIModel.kling4Prompt("@Image1 and @image10 by @Video1, @Image11", images: 10, videos: 1)
                    == "@image_1 and @image_10 by @video_1, @Image11")
            #expect(
                APIModel.kling4Prompt("@Image1 meets @Image12", images: 12, videos: 0) == "@image_1 meets @image_12")
            #expect(APIModel.kling4Prompt("@Video1 @Image1", images: 0, videos: 0) == "@Video1 @Image1")
            #expect(
                APIModel.kling4Prompt("@image_2 @ @Image mail@Image2x", images: 2, videos: 0)
                    == "@image_2 @ @Image mail@image_2x")
            #expect(APIModel.kling4Prompt("no tags", images: 3, videos: 1) == "no tags")

            var spec = try Self.onSource()
            spec.prompt = "@Image1 dances in @Video1"
            let reference = try Self.body(of: spec, inputs: RemoteInputs(video: Self.video, images: [Self.start]))
            #expect(reference.1.contains(#""prompt":"@image_1 dances in @video_1""#))
            spec.mode = .edit
            let edit = try Self.body(of: spec, inputs: RemoteInputs(video: Self.video, images: [Self.start]))
            #expect(edit.1.contains(#""prompt":"@image_1 dances in @video_1""#))
            // The account gets the prompt as written, as for every account model.
            let account = AccountModel.request(
                for: spec, model: VideoRequest.Model(rawValue: "kling4_0"),
                media: [VideoRequest.Media(role: .video, id: "video-1")])
            #expect(account.prompt == "@Image1 dances in @Video1")
        }

        /// A blank prompt is left out, as Validation reads it: only `image-to-video` takes none.
        @Test func aBlankPromptIsLeftOut() throws {
            let (_, body) = try Self.body(
                of: Self.frames(prompt: "  \n"), inputs: RemoteInputs(video: nil, images: [Self.start]))
            #expect(!body.contains("prompt"))
        }

        // MARK: Account

        /// `kling4_0`'s four `mode`s, each keeping to its `models_explore get`: frames as `start_image` and
        /// `end_image`, the source and images as `video_references` and `image_references`, Auto as `auto`.
        @Test func theAccountSendsEachMode() async throws {
            let (provider, stub) = Provider.provider(tools: Provider.fullSet) { _, _ in
                ["results": [["id": "job-1"]]]
            }
            let jobs: [(JobSpec, RemoteInputs)] = [
                (try Self.clip(), RemoteInputs(video: nil, images: [])),
                (try Self.frames(), RemoteInputs(video: nil, images: [Self.start, Self.end])),
                (try Self.onSource(), RemoteInputs(video: Self.video, images: [Self.start])),
                (try Self.onSource(mode: .edit, seconds: 40), RemoteInputs(video: Self.video, images: [Self.start])),
                (
                    try Self.clip(images: 1, seconds: 1, aspectRatio: .auto),
                    RemoteInputs(video: nil, images: [Self.start])
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
            #expect(
                params.map { $0["mode"] } == [
                    "text-to-video", "image-to-video", "reference-to-video", "video-edit", "reference-to-video",
                ])
            #expect(params.allSatisfy { $0["model"] == "kling4_0" })

            #expect(params[0]["aspect_ratio"] == "9:16" && params[0]["resolution"] == "1080p")
            #expect(params[0]["duration"] == 12 && params[0]["prompt"] == "a fox in the snow")
            #expect((params[0]["medias"]?.arrayValue ?? []).isEmpty)
            #expect(
                params[1]["medias"] == [
                    ["role": "start_image", "value": "image-1"], ["role": "end_image", "value": "image-2"],
                ])
            #expect(params[1]["aspect_ratio"] == "9:16" && params[1]["duration"] == 5)
            #expect(
                params[2] == [
                    "model": "kling4_0", "mode": "reference-to-video",
                    "medias": [
                        ["role": "video_references", "value": "video-1"],
                        ["role": "image_references", "value": "image-1"],
                    ],
                    "prompt": "make it rain", "resolution": "720p", "duration": 10, "aspect_ratio": "auto",
                    "use_unlim": false,
                ])
            #expect(params[3]["duration"] == 30 && params[3]["aspect_ratio"] == "auto")
            #expect(params[3]["medias"]?.arrayValue?.first?["role"] == "video_references")
            #expect(params[4]["duration"] == 3 && params[4]["aspect_ratio"] == "auto")
        }

        // MARK: Validation

        /// Up to 10 images, more are refused; a prompt is needed except from frames; Edit needs its clip.
        @Test func validationKeepsToTheSchemas() throws {
            #expect(Validation.check(try Self.clip()).isEmpty)
            #expect(Validation.check(try Self.clip(images: 10)).isEmpty)
            #expect(Validation.check(try Self.clip(images: 11)).contains(.tooManyReferences(maximum: 10)))
            #expect(Validation.check(try Self.onSource(images: 10)).isEmpty)
            #expect(Validation.check(try Self.onSource(images: 11)).contains(.tooManyReferences(maximum: 10)))
            // `reference-to-video` needs a prompt and an image or the video; without them it is text-to-video,
            // which needs the prompt alone.
            #expect(Validation.check(try Self.clip(images: 2, prompt: "")) == [.promptRequired])
            #expect(Validation.check(try Self.clip(prompt: " ")) == [.promptRequired])
            #expect(Validation.check(try Self.onSource(prompt: "")) == [.promptRequired])
            // `image-to-video` takes no prompt, but needs its start frame.
            #expect(Validation.check(try Self.frames()).isEmpty)
            #expect(Validation.check(try Self.frames(0)).contains(.tooFewReferences(minimum: 1)))
            #expect(Validation.check(try Self.frames(3)).contains(.tooManyReferences(maximum: 2)))
            // `video-edit` needs the clip and a prompt.
            var edit = try Self.onSource(mode: .edit)
            #expect(Validation.check(edit).isEmpty)
            edit.source = nil
            #expect(Validation.check(edit).contains(.sourceRequired))
            #expect(Validation.check(try Self.onSource(mode: .edit, prompt: "")).contains(.promptRequired))
            #expect(Validation.check(try Self.onSource(mode: .edit, seconds: 31)).contains(.durationTooLong(31)))
            #expect(Validation.check(try Self.onSource(seconds: 2)).contains(.durationTooShort(2)))
        }

        // MARK: Prices

        /// The REST list prices: $0.157 and $0.235 a second without an input video; with one, $0.094 and $0.141 on
        /// the output's seconds plus as many of the input's, which are the selection's.
        @Test(arguments: [
            (Resolution.p720, false, "1.57"), (.p1080, false, "2.35"), (.p720, true, "1.88"), (.p1080, true, "2.82"),
        ])
        func restListPrices(resolution: Resolution, withVideo: Bool, usd: String) throws {
            let pricing = try Pricing.bundled()
            var spec = withVideo ? try Self.onSource() : try Self.clip(images: 1, seconds: 10)
            spec.resolution = resolution
            #expect(try pricing.cost(for: spec) == .usd(Decimal(string: usd)!, isEstimate: true))
            if !withVideo {
                spec.references = []
                #expect(try pricing.cost(for: spec) == .usd(Decimal(string: usd)!, isEstimate: true))
                var frames = try Self.frames()
                frames.resolution = resolution
                frames.length = 10
                #expect(try pricing.cost(for: frames) == .usd(Decimal(string: usd)!, isEstimate: true))
            } else {
                var edit = try Self.onSource(mode: .edit)
                edit.resolution = resolution
                #expect(try pricing.cost(for: edit) == .usd(Decimal(string: usd)!, isEstimate: true))
            }
        }

        /// On the account: 5 credits a second at 720p and 7.5 at 1080p, Higgsfield's announced price, until a quote;
        /// with a source video (references or Edit) 1.2 times that, as REST bills the input video too.
        @Test func theAccountEstimatesFromTheAnnouncedPrice() throws {
            var spec = try Self.clip(seconds: 10)
            #expect(AccountModel.estimatedCredits(for: spec) == 75)
            spec.length = 45
            #expect(AccountModel.estimatedCredits(for: spec) == 225)
            var images = try Self.clip(images: 2, seconds: 10)
            images.resolution = .p720
            #expect(AccountModel.estimatedCredits(for: images) == 50)
            #expect(AccountModel.estimatedCredits(for: try Self.frames()) == 25)

            // Never below the announced rate times REST's ratio with an input video to without (10 s here).
            var reference = try Self.onSource()
            let at720 = try #require(AccountModel.estimatedCredits(for: reference))
            #expect(at720 == 60 && Double(at720) >= 5 * 10 * 0.188 / 0.157)
            reference.resolution = .p1080
            let at1080 = try #require(AccountModel.estimatedCredits(for: reference))
            #expect(at1080 == 90 && Double(at1080) >= (7.5 * 10 * 0.282 / 0.235).rounded())
            var edit = try Self.onSource(mode: .edit, seconds: 12)
            #expect(AccountModel.estimatedCredits(for: edit) == 72)
            edit.resolution = .p1080
            #expect(AccountModel.estimatedCredits(for: edit) == 108)
        }

        /// A prompt alone is quoted before anything is uploaded, with its `mode`; a job with a source, frames or
        /// images only once they are, since the media name the `mode` and may change the price.
        @Test func onlyAPromptAloneIsQuotedBeforeUpload() async throws {
            let model = VideoRequest.Model(rawValue: "kling4_0")
            let quote = try #require(AccountModel.quoteRequest(for: try Self.clip(), model: model))
            #expect(quote.mode == VideoRequest.kling4TextToVideo)
            #expect(quote.resolution == "1080p" && quote.duration == 12)
            for spec in [
                try Self.frames(), try Self.clip(images: 1), try Self.onSource(), try Self.onSource(mode: .edit),
            ] {
                #expect(AccountModel.quoteRequest(for: spec, model: model) == nil)
            }
            let (provider, stub) = Provider.provider(tools: Provider.fullSet)
            #expect(try await provider.estimate(try Self.onSource()) == .credits(60, isEstimate: true))
            #expect(Provider.calls(stub).isEmpty)
        }
    }
}
