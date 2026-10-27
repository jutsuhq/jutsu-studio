import Foundation
import Testing

@testable import JutsuCore

@Suite struct SpeechSelectionTests {
    let availability = SpeechAvailability(
        languages: [.transcriber: ["en-US", "de-DE"], .dictation: ["en-US", "ru-RU"]],
        installed: [.transcriber: ["en-US"]])

    @Test func builtInPrefersTheTranscriberAndFallsBackToDictation() {
        #expect(SpeechSelection.builtIn(for: "en-US", in: availability) == .transcriber)
        #expect(SpeechSelection.builtIn(for: "ru-RU", in: availability) == .dictation)
        #expect(SpeechSelection.builtIn(for: "lv-LV", in: availability) == nil)
        #expect(SpeechSelection.builtIn(for: "en-US", in: .none) == nil)
    }

    @Test func theSheetOffersEveryLanguageOnce() {
        #expect(SpeechSelection.languages(in: availability) == ["de-DE", "en-US", "ru-RU"])
    }

    @Test func parakeetTakesALanguageByItsCodeAndAddsOnlyTheOnesTheBuiltInModelsLack() {
        var both = availability
        both.languages[.parakeetUltra] = ["de", "lv"]
        both.installed[.parakeetUltra] = ["lv"]

        #expect(SpeechSelection.model(.parakeet, for: "de-AT", in: both) == .parakeetUltra)
        #expect(SpeechSelection.model(.parakeet, for: "ru-RU", in: both) == nil)
        #expect(SpeechSelection.model(.parakeet, for: "de", in: availability) == nil)
        #expect(SpeechSelection.model(.builtIn, for: "lv", in: both) == nil)
        #expect(both.isInstalled(.parakeetUltra, "lv-LV"))
        #expect(!both.isInstalled(.parakeetUltra, "de-DE"))
        #expect(SpeechSelection.languages(in: both) == ["de-DE", "en-US", "lv", "ru-RU"])
    }

    @Test func autoPrefersTheTranscriberThenADownloadedParakeetThenDictation() {
        var all = availability
        all.languages[.parakeetUltra] = ["en", "ru", "lv"]
        #expect(SpeechSelection.model(.auto, for: "en-US", in: all) == .transcriber)
        #expect(SpeechSelection.model(.auto, for: "ru-RU", in: all) == .dictation)
        // Before the download Parakeet comes last, so a language only it takes still names it.
        #expect(SpeechSelection.model(.auto, for: "lv", in: all) == .parakeetUltra)
        #expect(SpeechSelection.model(.auto, for: "ja-JP", in: all) == nil)
        all.installed[.parakeetUltra] = ["en", "ru", "lv"]
        #expect(SpeechSelection.model(.auto, for: "ru-RU", in: all) == .parakeetUltra)
        #expect(SpeechSelection.model(.auto, for: "en-US", in: all) == .transcriber)
    }

    @Test func theLastLanguageComesFirstThenTheSystemsThenTheFirst() {
        let languages = ["de-DE", "en-US", "ru-RU"]
        #expect(SpeechSelection.preferred(languages, last: "ru-RU", system: ["en-US"]) == "ru-RU")
        #expect(SpeechSelection.preferred(languages, last: "fr-FR", system: ["en-US"]) == "en-US")
        #expect(SpeechSelection.preferred(languages, last: nil, system: ["en-GB", "de"]) == "en-US")
        #expect(SpeechSelection.preferred(languages, last: nil, system: ["fr-FR", "de"]) == "de-DE")
        #expect(SpeechSelection.preferred(languages, last: nil, system: ["fr-FR"]) == "de-DE")
        #expect(SpeechSelection.preferred([], last: "en-US", system: ["en-US"]) == nil)
    }

    @Test func theCacheKeyChangesWithEachPartAndIsAFileName() {
        let name = SpeechSelection.cacheKey(contentHash: "hash", language: "en-US", model: .transcriber, revision: "r1")
        #expect(name == "hash_en-US_speech-transcriber_r1")
        let others = [
            SpeechSelection.cacheKey(contentHash: "other", language: "en-US", model: .transcriber, revision: "r1"),
            SpeechSelection.cacheKey(contentHash: "hash", language: "en-GB", model: .transcriber, revision: "r1"),
            SpeechSelection.cacheKey(contentHash: "hash", language: "en-US", model: .dictation, revision: "r1"),
            SpeechSelection.cacheKey(contentHash: "hash", language: "en-US", model: .transcriber, revision: "r2"),
        ]
        #expect(Set(others + [name]).count == 5)
        #expect(
            !SpeechSelection.cacheKey(contentHash: "a/b", language: "x:y", model: .dictation, revision: "1 2")
                .contains { "/: ".contains($0) })
    }

    @Test func aVersionWithoutSubtitlesStillDecodes() throws {
        let version = MaterialVersion(fileURL: URL(filePath: "/tmp/clip.mp4"))
        var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(version)) as? [String: Any])
        json.removeValue(forKey: "subtitles")
        let decoded = try JSONDecoder().decode(MaterialVersion.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.subtitles == nil)
    }
}
