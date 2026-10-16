import Foundation
import HiggsfieldCore
import HiggsfieldMCP
import HiggsfieldTestSupport
import JutsuCore
import Testing

@testable import HiggsfieldProviders

extension Network {
    /// The price before upload (issue #113): a model sent a length is quoted with `get_cost` and no media, once per
    /// what the price depends on; a model billed by its source gets the catalog's estimate until it is uploaded.
    @Suite struct ProviderQuotes {
        static let quote: @Sendable (String, JSONValue) -> JSONValue = { _, _ in
            ["cost": ["credits": 35, "credits_exact": .number(35.5)]]
        }

        /// A model `models.json` lists; its absence fails the catalog tests.
        static func model(_ id: String) -> VideoModel { VideoModel(rawValue: id) ?? .genjutsu }
        static let klingO3Edit = model("klingO3VideoEdit")

        static func spec(
            _ model: VideoModel, mode: Mode = .motionTransfer, seconds: TimeInterval = 5,
            resolution: Resolution = .p720
        ) -> JobSpec {
            JobSpec(
                mode: mode, model: model,
                source: SourceClip(
                    fileURL: URL(fileURLWithPath: "/tmp/in.mov"), duration: 30,
                    pixelSize: PixelSize(width: 1280, height: 720), range: 0...seconds),
                references: [LocalImage(fileURL: URL(fileURLWithPath: "/tmp/a.jpg"))], prompt: "make it rain",
                resolution: resolution)
        }

        static func quotes(_ stub: StubServer) -> [JSONValue] {
            Provider.calls(stub).filter { $0["name"] == "generate_video" }.compactMap { $0["arguments"]?["params"] }
        }

        /// Seedance from a prompt alone (`t2v`), Seedance's Extend, Kling 3.0 (which needs `duration`), Wan 3.0, Wan
        /// 3.0 Prime and Cinema Studio 4.0.
        static let perSecond: [JobSpec] = {
            var prompt = spec(.seedance25)
            prompt.source = nil
            prompt.references = []
            prompt.length = 8
            prompt.aspectRatio = .portrait
            let models: [VideoModel] =
                [.klingMotionControl] + ["wan30Reference", "wan30PrimeReference", "cinemaStudio4"].map(model)
            return [prompt, spec(.seedance25, mode: .extend)] + models.map { spec($0) }
        }()

        @Test(arguments: perSecond)
        func aModelSentALengthIsQuotedBeforeUpload(spec: JobSpec) async throws {
            let (provider, stub) = Provider.provider(tools: Provider.fullSet, call: Self.quote)
            #expect(try await provider.estimate(spec) == .credits(35.5, isEstimate: false))

            let sent = try #require(Self.quotes(stub).first)
            #expect(Self.quotes(stub).count == 1)
            #expect(sent["get_cost"] == true)
            #expect(sent["use_unlim"] == false)
            #expect(sent["duration"]?.numberValue != nil)
            // Nothing is uploaded yet, and the price doesn't depend on the prompt or the variants.
            #expect(sent["medias"] == nil && sent["prompt"] == nil && sent["count"] == nil)
            #expect(try Provider.schemaViolations(stub).isEmpty)
            let known = "kling3_0_motion_control: duration isn't a parameter"
            #expect(try CatalogSnapshot.violations(ofParams: sent).filter { $0 != known }.isEmpty)
        }

        /// Genjutsu, Seedance's Edit and Kling O3 Edit follow the source, which `get_cost` needs in `medias`: before
        /// upload they show the estimate, and the quote with the uploaded source is exact.
        @Test(arguments: [
            spec(.genjutsu, seconds: 12), spec(.genjutsu, mode: .objectSwap, seconds: 12),
            spec(.seedance25, mode: .edit, seconds: 12), spec(Self.klingO3Edit, mode: .edit, seconds: 12),
        ])
        func aModelBilledByItsSourceIsQuotedAfterUpload(spec: JobSpec) async throws {
            let (provider, stub) = Provider.provider(tools: Provider.fullSet, call: Self.quote)
            let estimate = try await provider.estimate(spec)
            #expect(estimate.isEstimate && !estimate.isUnknownPrice)
            #expect(Provider.calls(stub).isEmpty)

            #expect(
                try await provider.serverEstimate(spec, inputs: Provider.inputs) == .credits(35.5, isEstimate: false))
            let sent = try #require(Self.quotes(stub).first)
            #expect(sent["get_cost"] == true)
            #expect(sent["medias"]?.arrayValue?.first?["value"] == "video-1")
            #expect(try Provider.schemaViolations(stub).isEmpty)
        }

        /// The estimates of the models billed by their source match the live quotes for a 12 s clip (2026-10-15).
        @Test(arguments: [
            (spec(.genjutsu, seconds: 12, resolution: .p480), 36),
            (spec(.genjutsu, seconds: 12, resolution: .p1080), 240),
            (spec(.genjutsu, mode: .objectSwap, seconds: 12, resolution: .p480), 39),
            (spec(.genjutsu, mode: .objectSwap, seconds: 12), 91),
            (spec(.genjutsu, mode: .objectSwap, seconds: 12, resolution: .p1080), 260),
            (spec(.seedance25, mode: .edit, seconds: 12, resolution: .p480), 43),
            (spec(.seedance25, mode: .edit, seconds: 12), 91),
            (spec(.seedance25, mode: .edit, seconds: 12, resolution: .p1080), 241),
        ])
        func theEstimateOfASourceBilledModelIsTheLiveRate(spec: JobSpec, credits: Int) {
            #expect(AccountModel.estimatedCredits(for: spec) == credits)
        }

        /// A quote is asked once per model, mode, resolution, length and soundtrack, even while one is out: another
        /// prompt, frame or bitrate reads the same answer, another length asks again.
        @Test func quotesAreKeptByWhatThePriceDependsOn() async throws {
            let (provider, stub) = Provider.provider(tools: Provider.fullSet, call: Self.quote)
            var base = Self.spec(.seedance25)
            base.source = nil
            base.references = []
            base.length = 6
            var otherPrompt = base
            otherPrompt.prompt = "a fox in the snow"
            var otherFrame = base
            otherFrame.aspectRatio = .portrait
            var otherBitrate = base
            otherBitrate.bitrate = .high

            let costs = try await withThrowingTaskGroup(of: Cost.self) { group in
                for spec in [base, otherPrompt, otherFrame, otherBitrate] {
                    group.addTask { try await provider.estimate(spec) }
                }
                return try await group.reduce(into: []) { $0.append($1) }
            }
            #expect(costs.count == 4)
            #expect(costs.allSatisfy { $0 == .credits(35.5, isEstimate: false) })
            #expect(Self.quotes(stub).count == 1)

            var longer = base
            longer.length = 7
            var louder = base
            louder.audio = .mute
            _ = try await provider.estimate(longer)
            _ = try await provider.estimate(louder)
            _ = try await provider.estimate(base)
            #expect(Self.quotes(stub).map { $0["duration"] } == [6, 7, 6])
            #expect(Self.quotes(stub).map { $0["generate_audio"] } == [true, true, false])
        }

        /// A failed quote shows the estimate and isn't kept: the next estimate asks again.
        @Test func aFailedQuoteFallsBackToTheEstimateAndIsAskedAgain() async throws {
            let answers = Answers([[:], ["cost": ["credits": 21]]])
            let (provider, stub) = Provider.provider(tools: Provider.fullSet) { _, _ in answers.next() }
            let spec = Self.spec(.klingMotionControl, seconds: 12)
            #expect(try await provider.estimate(spec) == .credits(21, isEstimate: true))
            #expect(try await provider.estimate(spec) == .credits(21, isEstimate: false))
            #expect(Self.quotes(stub).count == 2)
        }

        /// `count` isn't in the quote (live: 2 quoted the same as 1), so the price is one variant's times the count.
        @Test func variantsMultiplyTheQuote() async throws {
            let (provider, stub) = Provider.provider(tools: Provider.fullSet, call: Self.quote)
            var spec = Self.spec(Self.model("wan30Reference"))
            spec.variants = 3
            #expect(try await provider.estimate(spec) == .credits(106.5, isEstimate: false))
            #expect(Self.quotes(stub).first?["count"] == nil)
        }

        /// The quote before upload is the price the job is queued with and that a cap checks: the engine reads it
        /// with `estimate`, and quotes the uploaded files again right before submit.
        @Test func theQuoteBeforeUploadIsTheJobsPriceUntilTheUploadIsQuoted() async throws {
            let (provider, stub) = Provider.provider(tools: Provider.fullSet) { _, arguments in
                arguments["params"]?["medias"] == nil
                    ? ["cost": ["credits": 35]] : ["cost": ["credits": 35, "credits_exact": .number(35.25)]]
            }
            let spec = Self.spec(.seedance25)
            #expect(try await provider.estimate(spec) == .credits(35, isEstimate: false))
            #expect(
                try await provider.serverEstimate(spec, inputs: Provider.inputs) == .credits(35.25, isEstimate: false))
            #expect(Self.quotes(stub).map { $0["medias"] == nil } == [true, false])
            #expect(Self.quotes(stub).allSatisfy { $0["get_cost"] == true })
        }
    }
}

/// Stub answers in order, the last one repeated.
final class Answers: @unchecked Sendable {
    // @unchecked: `values` is only touched under `lock`.
    private let lock = NSLock()
    private var values: [JSONValue]

    init(_ values: [JSONValue]) {
        self.values = values
    }

    func next() -> JSONValue {
        lock.withLock { values.count > 1 ? values.removeFirst() : values.first ?? [:] }
    }
}
