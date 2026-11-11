import Foundation
import HiggsfieldAPI
import HiggsfieldMCP
import HiggsfieldTestSupport
import JutsuCore
import Testing

@testable import HiggsfieldProviders

extension Network {
    /// Higgsfield Intone on the account only: `intone` against its `models_explore get` in the catalog snapshot of
    /// 2026-11-10. One or two characters say one speech recording; the speech sets the length. Higgsfield's REST
    /// catalog has no Intone.
    @Suite struct Intone {
        static func intone() throws -> VideoModel { try #require(VideoModel(rawValue: "intone")) }

        static let speech = LocalAudio(fileURL: URL(fileURLWithPath: "/tmp/lines.mp3"), duration: 9)
        static let audio = RemoteAsset(url: URL(string: "https://cdn.example.com/lines.mp3")!, id: "audio-1")

        static func clip(
            characters: Int = 1, speech: LocalAudio? = Self.speech, resolution: Resolution = .p1080,
            aspectRatio: AspectRatio? = .portrait
        ) throws -> JobSpec {
            JobSpec(
                mode: .motionTransfer, model: try intone(), source: nil,
                references: Array(
                    repeating: LocalImage(fileURL: URL(fileURLWithPath: "/tmp/face.png")), count: characters),
                prompt: "", resolution: resolution, length: 5, aspectRatio: aspectRatio, speech: speech)
        }

        @Test func itIsAnAccountOnlyTalkingHeadModel() throws {
            let model = try Self.intone()
            #expect(model.title == "Higgsfield Intone" && model.family == "Higgsfield")
            #expect(model.modes == [.motionTransfer] && model.resolutions == Resolution.standard)
            #expect(model.declares(.speech) && model.makesClipsWithoutSource && !model.declares(.frames))
            #expect(!model.declares(.generatedAudio) && !model.offersDraft)
            #expect(!model.runsWithAPIKey && AccountModel.runs(model))
            #expect(model.descriptor.speechSeconds == 2...30 && model.descriptor.speechTail == 2.5)
            #expect(throws: ProviderError.self) {
                try APIModel(try Self.clip(), inputs: RemoteInputs(video: nil, images: []))
            }
        }

        /// The clip runs the speech and 2.5 s more, whatever length the form held.
        @Test func theSpeechSetsTheLength() throws {
            #expect(try Self.clip().duration == 11.5)
            #expect(try Self.clip(speech: nil).duration == 5)
        }

        /// The images go as `character_images` and the speech as `audio_references`, with the resolution and the
        /// nearest of the model's frames; no `duration`, `mode`, `generate_audio` or `bitrate_mode`.
        @Test func theAccountSendsTheSpeakersAndTheSpeech() async throws {
            let (provider, stub) = Provider.provider(tools: Provider.fullSet) { _, _ in
                ["results": [["id": "job-1"]]]
            }
            let jobs: [(JobSpec, RemoteInputs)] = [
                (try Self.clip(), RemoteInputs(video: nil, images: [Kling4.start], audio: Self.audio)),
                (
                    try Self.clip(characters: 2, resolution: .p480, aspectRatio: .auto),
                    RemoteInputs(video: nil, images: [Kling4.start, Kling4.end], audio: Self.audio)
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
            #expect(params.allSatisfy { $0["model"] == "intone" })
            #expect(
                params.allSatisfy {
                    $0["duration"] == nil && $0["mode"] == nil && $0["generate_audio"] == nil
                        && $0["bitrate_mode"] == nil
                })
            #expect(params.map { $0["resolution"] } == ["1080p", "480p"])
            #expect(params.map { $0["aspect_ratio"] } == ["9:16", nil])
            #expect(
                params[1]["medias"] == [
                    ["role": "character_images", "value": "image-1"], ["role": "character_images", "value": "image-2"],
                    ["role": "audio_references", "value": "audio-1"],
                ])
        }

        // MARK: Limits

        /// One or two characters, a speech of 2–30 s, and no source video.
        @Test func validationKeepsToTheSchema() throws {
            #expect(Validation.check(try Self.clip()).isEmpty)
            #expect(Validation.check(try Self.clip(characters: 2)).isEmpty)
            #expect(Validation.check(try Self.clip(characters: 0)).contains(.tooFewReferences(minimum: 1)))
            #expect(Validation.check(try Self.clip(characters: 3)) == [.tooManyReferences(maximum: 2)])
            #expect(Validation.check(try Self.clip(speech: nil)) == [.speechRequired])
            let short = LocalAudio(fileURL: Self.speech.fileURL, duration: 1.5)
            let long = LocalAudio(fileURL: Self.speech.fileURL, duration: 31)
            let longest = LocalAudio(fileURL: Self.speech.fileURL, duration: 30)
            #expect(Validation.check(try Self.clip(speech: short)) == [.speechTooShort(1.5)])
            #expect(Validation.check(try Self.clip(speech: long)) == [.speechTooLong(31)])
            #expect(Validation.check(try Self.clip(speech: longest)).isEmpty)
            var withSource = try Self.clip()
            withSource.source = SourceClip(
                fileURL: URL(fileURLWithPath: "/tmp/in.mp4"), duration: 10,
                pixelSize: PixelSize(width: 1280, height: 720), range: 0...10)
            #expect(Validation.check(withSource) == [.sourceNotTaken])
        }

        // MARK: Prices

        /// Until a quote, which comes only once the speech is uploaded: 1, 2 or 4 credits a second of the speech and
        /// its 2.5 s tail.
        @Test func theAccountEstimatesUntilAQuoteAfterUpload() throws {
            #expect(AccountModel.estimatedCredits(for: try Self.clip()) == 48)
            #expect(AccountModel.estimatedCredits(for: try Self.clip(resolution: .p720)) == 24)
            #expect(AccountModel.estimatedCredits(for: try Self.clip(resolution: .p480)) == 12)
            #expect(AccountModel.quotesAfterUpload(try Self.clip()))
            #expect(
                AccountModel.quoteRequest(for: try Self.clip(), model: VideoRequest.Model(rawValue: "intone")) == nil)
        }

        // MARK: History

        /// The speakers come back as the images, and the speech as long as the output without its tail.
        @Test func historyKeepsTheSpeakersAndTheSpeech() throws {
            let generation = PastGeneration(
                id: "g-1", type: "video", status: "completed", model: "intone",
                createdAt: Date(timeIntervalSince1970: 0), outputURL: URL(string: "https://cdn.example/out.mp4"),
                duration: 11.5, prompt: "", resolution: "720p",
                media: [
                    PastMedia(role: .character, id: "image-1", url: URL(string: "https://cdn.example/a.png")),
                    PastMedia(role: .audio, id: "audio-1", url: URL(string: "https://cdn.example/lines.mp3")),
                ])
            let item = try #require(HistoryMapping.item(generation))
            #expect(item.model == (try Self.intone()) && item.mode == .motionTransfer)
            #expect(item.inputs.images.map(\.id) == ["image-1"] && item.inputs.audio?.id == "audio-1")
            let spec = item.spec()
            #expect(spec.speech?.duration == 9 && spec.duration == 11.5)
            #expect(Validation.check(spec).isEmpty)
        }
    }
}
