import Foundation
import Testing

@testable import JutsuCore

@Suite struct ExportPresetTests {
    @Test(arguments: [ExportPreset.premiere, .davinciResolve, .finalCutPro])
    func nlePresetsAreProResInQuickTimeWithPCM(preset: ExportPreset) {
        #expect(preset.videoCodec == .proRes422)
        #expect(preset.audioCodec == .linearPCM)
        #expect(preset.fileExtension == "mov")
    }

    @Test func editingH264IsMP4WithAAC() {
        #expect(ExportPreset.editingH264.videoCodec == .h264)
        #expect(ExportPreset.editingH264.audioCodec == .aac)
        #expect(ExportPreset.editingH264.fileExtension == "mp4")
    }

    @Test(arguments: [
        (23.976, FrameDuration(value: 1001, timescale: 24000)),
        (23.98, FrameDuration(value: 1001, timescale: 24000)),
        (29.97, FrameDuration(value: 1001, timescale: 30000)),
        (59.94, FrameDuration(value: 1001, timescale: 60000)),
        (24.0, FrameDuration(value: 1, timescale: 24)),
        (25.0, FrameDuration(value: 1, timescale: 25)),
        (30.02, FrameDuration(value: 1, timescale: 30)),
        (60.0, FrameDuration(value: 1, timescale: 60)),
    ])
    func frameDurationMatchesTheNominalRate(rate: Double, expected: FrameDuration) {
        #expect(FrameDuration.constant(forNominalRate: rate) == expected)
    }

    @Test(arguments: [0.0, -5, .nan, .infinity, 1000])
    func unusableRateFallsBackTo30(rate: Double) {
        #expect(FrameDuration.constant(forNominalRate: rate) == FrameDuration(value: 1, timescale: 30))
    }
}

@Suite struct ExportNamingTests {
    func spec(
        mode: Mode = .motionTransfer, source: String = "/clips/rooftop.mov", range: ClosedRange<TimeInterval> = 4...10,
        references: [String] = ["/refs/hero.png"], presetID: UUID? = nil
    ) -> JobSpec {
        let clip = SourceClip(
            fileURL: URL(fileURLWithPath: source), duration: 600, pixelSize: PixelSize(width: 1920, height: 1080),
            range: range)
        return JobSpec(
            mode: mode, source: clip, references: references.map { LocalImage(fileURL: URL(fileURLWithPath: $0)) },
            presetID: presetID, resolution: .p720)
    }

    @Test func motionTransferNamesTheReference() {
        let names = ExportNaming.names(for: spec(), presetName: nil, preset: .premiere) { _ in false }
        #expect(names.video == "rooftop_00m04.0s-00m10.0s_motion_hero_v1.mov")
        #expect(names.sidecar == "rooftop_00m04.0s-00m10.0s_motion_hero_v1.json")
    }

    @Test func extraReferencesAreCounted() {
        let spec = spec(mode: .objectSwap, references: ["/r/hero.png", "/r/b.jpg", "/r/c.jpg"])
        #expect(ExportNaming.baseName(for: spec, presetName: nil) == "rooftop_00m04.0s-00m10.0s_swap_hero+2")
    }

    @Test func restyleNamesThePreset() {
        let spec = spec(mode: .restyle, references: ["/r/ignored.png"], presetID: UUID())
        #expect(
            ExportNaming.baseName(for: spec, presetName: "Film Noir") == "rooftop_00m04.0s-00m10.0s_restyle_Film Noir")
        #expect(ExportNaming.baseName(for: spec, presetName: nil) == "rooftop_00m04.0s-00m10.0s_restyle_preset")
    }

    @Test func missingStyleLeavesNoEmptyField() {
        let spec = spec(references: [])
        #expect(ExportNaming.baseName(for: spec, presetName: nil) == "rooftop_00m04.0s-00m10.0s_motion")
    }

    @Test(arguments: [
        (0.0...4.04, "00m00.0s-00m04.0s"),
        (59.96...61.25, "01m00.0s-01m01.3s"),
        (754.5...780, "12m34.5s-13m00.0s"),
    ])
    func rangeIsZeroPaddedTenths(range: ClosedRange<TimeInterval>, expected: String) {
        #expect(ExportNaming.rangeText(range) == expected)
    }

    @Test func unsafeCharactersAreReplaced() {
        let spec = spec(source: "/clips/.a:b*c?.mov", references: ["/r/x<y>|z\".png"])
        #expect(ExportNaming.baseName(for: spec, presetName: nil) == "a-b-c-_00m04.0s-00m10.0s_motion_x-y--z-")
    }

    @Test func emptySourceNameBecomesClip() {
        let spec = spec(source: "/clips/ .mov", references: [])
        #expect(ExportNaming.baseName(for: spec, presetName: nil).hasPrefix("clip_00m04.0s"))
    }

    @Test func longFieldsAreCutByBytes() {
        let spec = spec(
            mode: .restyle, source: "/c/" + String(repeating: "é", count: 200) + ".mov", presetID: UUID())
        let name = ExportNaming.names(
            for: spec, presetName: String(repeating: "x", count: 100), preset: .finalCutPro
        ) { _ in false }.video
        #expect(name.utf8.count <= 255)
        #expect(name.hasSuffix("_restyle_" + String(repeating: "x", count: 40) + "_v1.mov"))
    }

    @Test func versionBumpsPastAnyTakenTake() {
        let base = "rooftop_00m04.0s-00m10.0s_motion_hero"
        let taken: Set = ["\(base)_v1.mov", "\(base)_v2.mp4", "\(base)_v3.json"]
        let names = ExportNaming.names(for: spec(), presetName: nil, preset: .editingH264) { taken.contains($0) }
        #expect(names.video == "\(base)_v4.mp4")
        #expect(names.sidecar == "\(base)_v4.json")
    }
}

@Suite struct ExportSidecarTests {
    func job() throws -> Job {
        let id = try #require(UUID(uuidString: "1A2B3C4D-0000-0000-0000-000000000000"))
        let createdAt = try #require(ISO8601DateFormatter().date(from: "2026-03-07T23:30:05Z"))
        var spec = makeSpec(mode: .restyle, references: 2, presetID: UUID(), prompt: "rainy night")
        spec.source?.bookmark = Data("secret-bookmark".utf8)
        var job = Job(
            id: id, spec: spec, providerKind: .apiKey, cost: .usd(1.91, isEstimate: true), createdAt: createdAt)
        job.serverPrice = .usd(Decimal(string: "1.908") ?? 0, isEstimate: false)
        job.remote = RemoteJob(
            requestID: "req-42", correlationID: "corr", statusURL: URL(string: "https://api.example/s?sig=abc"),
            cancelURL: URL(string: "https://api.example/c?sig=abc"))
        job.finishedAt = createdAt.addingTimeInterval(90)
        return job
    }

    @Test func carriesTheJobInputs() throws {
        let job = try job()
        let sidecar = ExportSidecar(job: job, presetName: "Film Noir", exportPreset: .davinciResolve, exportedAt: .now)
        #expect(sidecar.source == .init(fileName: "source.mov", rangeStart: 0, rangeEnd: 10))
        #expect(sidecar.references == ["ref0.jpg", "ref1.jpg"])
        #expect(sidecar.style?.name == "Film Noir")
        #expect(sidecar.prompt == "rainy night")
        #expect(sidecar.requestID == "req-42")
        #expect(sidecar.cost == .init(amount: "1.908", unit: "usd", isEstimate: false))
        #expect(sidecar.exportPreset == .davinciResolve)
    }

    @Test func roundTripsAndLeaksNoPathsOrURLs() throws {
        let job = try job()
        let sidecar = ExportSidecar(job: job, presetName: nil, exportPreset: .premiere, exportedAt: job.createdAt)
        let data = try sidecar.encoded()
        #expect(try ExportSidecar.decode(data) == sidecar)
        let text = String(decoding: data, as: UTF8.self)
        for leak in ["/tmp", "bookmark", "sig=", "https", "corr", "idempotency", "apiKey"] {
            #expect(!text.contains(leak), "sidecar contains \(leak)")
        }
        #expect(text.contains("\"exportedAt\" : \"2026-03-07T23:30:05Z\""))
    }
}
