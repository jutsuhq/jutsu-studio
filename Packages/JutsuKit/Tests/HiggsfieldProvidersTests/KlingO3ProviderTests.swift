import Foundation
import HiggsfieldAPI
import JutsuCore
import Testing

@testable import HiggsfieldProviders

/// Kling O3's video reference: a catalog entry and the `klingVideoReference` request shape, API key only.
@Suite struct KlingO3ProviderTests {
    static let model = VideoModel(rawValue: "klingO3VideoReference")

    static func spec(seconds: TimeInterval, resolution: Resolution, references: Int = 1) throws -> JobSpec {
        JobSpec(
            mode: .motionTransfer, model: try #require(model),
            source: SourceClip(
                fileURL: URL(fileURLWithPath: "/tmp/in.mp4"), duration: 30,
                pixelSize: PixelSize(width: 1280, height: 720), range: 2...(2 + seconds)),
            references: (0..<references).map { LocalImage(fileURL: URL(fileURLWithPath: "/tmp/ref\($0).png")) },
            prompt: "she spins", resolution: resolution)
    }

    static func body(of request: APIModel) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(request.body), as: UTF8.self)
    }

    /// The source is the reference video, the selection's seconds the clip's (inside 3–10 s), the quality the mode.
    @Test func theRequestCarriesTheVideoTheImagesAndTheQuality() throws {
        let inputs = RemoteInputs(
            video: RemoteAsset(url: try #require(URL(string: "https://cdn.example.com/in.mp4"))),
            images: [RemoteAsset(url: try #require(URL(string: "https://cdn.example.com/a.jpg")))])

        let standard = try APIModel(Self.spec(seconds: 5.5, resolution: .p720), inputs: inputs)
        #expect(standard.endpoint == .klingO3VideoReference)
        #expect(
            try Self.body(of: standard)
                == #"{"duration":6,"image_urls":["https://cdn.example.com/a.jpg"],"mode":"std","prompt":"she spins","video_urls":["https://cdn.example.com/in.mp4"]}"#
        )
        let pro = try APIModel(Self.spec(seconds: 14, resolution: .p1080), inputs: inputs)
        #expect(try Self.body(of: pro).contains(#""duration":10,"#))
        #expect(try Self.body(of: pro).contains(#""mode":"pro""#))
    }

    /// The account's model ID for it isn't known yet (issue #37): the account neither offers nor sends it.
    @Test func theAccountDoesntRunIt() throws {
        let model = try #require(Self.model)
        #expect(!AccountModel.runs(model))
        #expect(AccountModel.model(for: try Self.spec(seconds: 5, resolution: .p720)) == nil)
    }
}
