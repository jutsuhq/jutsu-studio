import Foundation
import Testing

@testable import JutsuCore

@Suite struct OutputNamePatternTests {
    let utc = TimeZone(identifier: "UTC") ?? .current

    func job(mode: Mode = .objectSwap, preset: Bool = false, isDraft: Bool = false) throws -> Job {
        let id = try #require(UUID(uuidString: "1A2B3C4D-0000-0000-0000-000000000000"))
        let createdAt = try #require(ISO8601DateFormatter().date(from: "2026-03-07T23:30:05Z"))
        var spec = makeSpec(mode: mode, presetID: preset ? UUID() : nil, resolution: .p720)
        spec.isDraft = isDraft
        return Job(id: id, spec: spec, providerKind: .apiKey, cost: .usd(1, isEstimate: false), createdAt: createdAt)
    }

    @Test func defaultIsLocalDateModeAndShortID() throws {
        let job = try job()
        let tokyo = try #require(TimeZone(identifier: "Asia/Tokyo"))
        #expect(
            OutputNamePattern.standard.fileName(for: job, presetName: nil, timeZone: utc)
                == "2026-03-07_objectSwap_1a2b3c4d.mp4")
        #expect(
            OutputNamePattern.standard.fileName(for: job, presetName: nil, timeZone: tokyo)
                == "2026-03-08_objectSwap_1a2b3c4d.mp4")
    }

    @Test func everyTokenExpands() throws {
        let pattern = OutputNamePattern("{date} {time} {mode} {preset} {res} {draft} {id}")
        let name = pattern.fileName(
            for: try job(mode: .restyle, preset: true, isDraft: true), presetName: "Film Noir", timeZone: utc)
        #expect(name == "2026-03-07 23-30-05 restyle Film Noir 720p draft 1a2b3c4d.mp4")
    }

    @Test func missingPresetAndNonDraftAreEmpty() throws {
        let pattern = OutputNamePattern("{mode}{preset}{draft}_{id}")
        #expect(pattern.fileName(for: try job(), presetName: "Ignored", timeZone: utc) == "objectSwap_1a2b3c4d.mp4")
    }

    @Test(arguments: [
        ("{date}_{draft}_{mode}", "2026-03-07_objectSwap"),
        ("{draft} {preset} {mode}", "objectSwap"),
        ("{mode}-{draft}-{preset}-{id}", "objectSwap-1a2b3c4d"),
        ("{draft}_{mode}_{preset}", "objectSwap"),
        ("{mode}_{draft}-{id}", "objectSwap_-1a2b3c4d"),
        ("{mode}__{id}", "objectSwap__1a2b3c4d"),
    ])
    func emptyTokensLeaveNoStraySeparators(pattern: String, expected: String) throws {
        let name = OutputNamePattern(pattern).fileName(for: try job(), presetName: nil, timeZone: utc)
        #expect(name == "\(expected).mp4")
    }

    @Test func unknownPresetNameIsAPlaceholder() throws {
        let pattern = OutputNamePattern("{preset}_{id}")
        #expect(pattern.fileName(for: try job(preset: true), presetName: nil, timeZone: utc) == "preset_1a2b3c4d.mp4")
    }

    @Test(arguments: ["", "   ", "{nope}_{id}", "{date", "{Date}", "{{date}}"])
    func invalidPatternFallsBackToTheDefault(pattern: String) {
        #expect(!OutputNamePattern.isValid(pattern))
        #expect(OutputNamePattern(pattern).pattern == OutputNamePattern.defaultPattern)
    }

    @Test(arguments: ["{date}", "clip", "a}b_{id}", OutputNamePattern.defaultPattern])
    func validPatternIsKept(pattern: String) {
        #expect(OutputNamePattern(pattern).pattern == pattern)
    }

    @Test func nameThatSanitizesToNothingUsesTheDefault() throws {
        let name = OutputNamePattern("..{draft}").fileName(for: try job(), presetName: nil, timeZone: utc)
        #expect(name == "2026-03-07_objectSwap_1a2b3c4d.mp4")
    }

    @Test(arguments: [
        ("a/b:c", "a-b-c"), ("..hidden", "hidden"), ("  . x  ", "x"), ("line\nbreak\u{7}", "linebreak"),
        ("tab\there", "tabhere"), ("👩‍🎨 art", "👩‍🎨 art"),
    ])
    func sanitizes(input: String, expected: String) {
        #expect(OutputNamePattern.sanitize(input) == expected)
    }

    @Test func longNamesAreCutOnCharacterBoundaries() {
        let cut = OutputNamePattern.sanitize(String(repeating: "é", count: 300))
        #expect(cut.utf8.count <= OutputNamePattern.maxBaseBytes)
        #expect(cut == String(repeating: "é", count: OutputNamePattern.maxBaseBytes / 2))
    }

    @Test func presetNameIsSanitized() throws {
        let name = OutputNamePattern("{preset}").fileName(
            for: try job(preset: true), presetName: "Anime/Manga: v2", timeZone: utc)
        #expect(name == "Anime-Manga- v2.mp4")
    }

    @Test func freeNameIsKept() {
        #expect(OutputNamePattern.available("clip.mp4") { _ in false } == "clip.mp4")
    }

    @Test func takenNameGetsTheFirstFreeCounter() {
        let taken: Set = ["clip.mp4", "clip-2.mp4", "clip-3.mp4"]
        #expect(OutputNamePattern.available("clip.mp4") { taken.contains($0) } == "clip-4.mp4")
    }

    @Test func counterGoesBeforeTheExtensionOnly() {
        let taken: Set = ["v1.0 final.mp4", "noext"]
        #expect(OutputNamePattern.available("v1.0 final.mp4") { taken.contains($0) } == "v1.0 final-2.mp4")
        #expect(OutputNamePattern.available("noext") { taken.contains($0) } == "noext-2")
    }
}
