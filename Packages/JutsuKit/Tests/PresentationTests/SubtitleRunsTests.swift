import Foundation
import JutsuCore
import JutsuTestSupport
import Testing

@testable import Presentation

/// Hears canned words and waits until released; notes which model heard what.
final class FakeSpeech: SpeechTranscribing, @unchecked Sendable {
    struct Heard {
        let language: String
        let model: SpeechModel
        let mayDownload: Bool
    }

    private let lock = NSLock()
    private var released = false
    private var running = 0
    private var _mostAtOnce = 0
    private var _heard: [Heard] = []
    var available = SpeechAvailability(
        languages: [.transcriber: ["en-US"], .dictation: ["en-US", "ru-RU"]],
        installed: [.transcriber: ["en-US"]])
    var failure: (any Error)?

    var heard: [Heard] { lock.withLock { _heard } }
    var mostAtOnce: Int { lock.withLock { _mostAtOnce } }

    func release() { lock.withLock { released = true } }

    func availability() async -> SpeechAvailability { available }

    func transcribe(
        _ file: URL, language: String, model: SpeechModel, mayDownload: Bool,
        progress: @escaping @Sendable (OnDeviceProgress) -> Void
    ) async throws -> Transcript {
        lock.withLock {
            running += 1
            _mostAtOnce = max(_mostAtOnce, running)
            _heard.append(Heard(language: language, model: model, mayDownload: mayDownload))
        }
        defer { lock.withLock { running -= 1 } }
        progress(.working(0.5))
        while !lock.withLock({ released }) { try await Task.sleep(for: .milliseconds(2)) }
        if let failure { throw failure }
        return Transcript(
            language: language, model: model, revision: "1",
            words: [TimedWord(text: "Hello", start: 0.2, end: 0.6), TimedWord(text: "there.", start: 0.7, end: 1.1)])
    }
}

@MainActor
@Suite struct SubtitleRunsTests {
    let speech = FakeSpeech()
    let defaults: UserDefaults

    init() throws {
        let name = "SubtitleRunsTests-\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
    }

    private func request(_ language: String = "en-US") -> SubtitleRuns.Request {
        SubtitleRuns.Request(
            source: MaterialReference(materialID: UUID(), versionID: UUID()), file: URL(filePath: "/tmp/clip.mp4"),
            language: language)
    }

    @Test func runsOneAtATimeAndSavesEachOnItsVersion() async {
        var saved: [MaterialReference: Subtitles] = [:]
        let runs = SubtitleRuns(engine: speech, defaults: defaults) { request, subtitles in
            saved[request.source] = subtitles
        }
        await runs.loadAvailability()
        let first = request()
        let second = request()

        #expect(runs.start(first))
        #expect(runs.start(second))
        await eventually { runs.runs.first?.state == .working(0.5) }
        #expect(runs.runs.map(\.state) == [.working(0.5), .waiting])
        speech.release()
        await runs.finish()

        #expect(speech.mostAtOnce == 1)
        #expect(saved[first.source]?.transcript.text == "Hello there.")
        #expect(saved[second.source]?.language == "en-US")
        #expect(runs.failure == nil)
        #expect(runs.preferredLanguage == "en-US")
    }

    @Test func builtInHearsALanguageTheTranscriberLacksWithDictation() async {
        let runs = SubtitleRuns(engine: speech, defaults: defaults) { _, _ in }
        await runs.loadAvailability()
        speech.release()

        #expect(runs.model(for: "en-US") == .transcriber)
        #expect(runs.model(for: "ru-RU") == .dictation)
        #expect(!runs.start(request("lv-LV")))
        runs.agreeToModel(for: "ru-RU")
        #expect(runs.start(request("ru-RU")))
        await runs.finish()
        #expect(speech.heard.map(\.model) == [.dictation])
        #expect(speech.heard.first?.mayDownload == true)
    }

    @Test func aModelThatIsntHereWaitsForTheAgreementToItsOwnLanguage() async {
        speech.available.languages[.dictation] = ["en-US", "ru-RU", "uk-UA"]
        let runs = SubtitleRuns(engine: speech, defaults: defaults) { _, _ in }
        #expect(!runs.start(request()))
        await runs.loadAvailability()

        #expect(!runs.needsConsent("en-US"))
        #expect(runs.needsConsent("ru-RU"))
        #expect(!runs.start(request("ru-RU")))
        runs.agreeToModel(for: "ru-RU")
        #expect(!runs.needsConsent("ru-RU") && runs.agreedToModel(for: "ru-RU"))
        #expect(defaults.bool(forKey: "onDevice.modelConsent.speech.ru-RU"))
        #expect(runs.needsConsent("uk-UA") && !runs.agreedToModel(for: "uk-UA"))
        #expect(!runs.start(request("uk-UA")))
        #expect(runs.start(request("ru-RU")))
        speech.release()
        await runs.finish()
        #expect(speech.heard.map(\.language) == ["ru-RU"])
    }

    @Test func aModelFoundMissingAsksForTheAgreementThoughMacOSListedIt() async {
        speech.failure = TranscriptionError.modelNeeded
        speech.release()
        let runs = SubtitleRuns(engine: speech, defaults: defaults) { _, _ in }
        await runs.loadAvailability()
        #expect(!runs.needsConsent("en-US"))

        runs.start(request())
        await runs.finish()
        #expect(runs.needsConsent("en-US"))
        #expect(!runs.start(request()))

        runs.agreeToModel(for: "en-US")
        speech.failure = nil
        #expect(runs.start(request()))
        await runs.finish()
        #expect(speech.heard.map(\.mayDownload) == [false, true])
    }

    @Test func theFileIsOpenedThroughItsBookmark() async {
        speech.release()
        let opened = Box<[Data?]>([])
        let runs = SubtitleRuns(
            engine: speech, defaults: defaults,
            access: { file, bookmark, hear in
                opened.update { $0.append(bookmark) }
                return try await hear(file)
            }
        ) { _, _ in }
        await runs.loadAvailability()
        var clip = request()
        clip.bookmark = Data("bookmark".utf8)

        #expect(runs.start(clip))
        await runs.finish()
        #expect(opened.value == [Data("bookmark".utf8)])
        #expect(runs.finished.map(\.outcome).count == 1 && runs.failure == nil)
    }

    @Test func parakeetWaitsForItsDownloadNotForTheAgreement() async {
        speech.available.languages[.parakeetUltra] = ["de", "en"]
        let runs = SubtitleRuns(engine: speech, defaults: defaults) { _, _ in }
        await runs.loadAvailability()
        var german = request("de-DE")
        german.engine = .parakeet

        #expect(runs.model(for: "de-DE", engine: .parakeet) == .parakeetUltra)
        #expect(runs.model(for: "de-DE") == nil)
        #expect(!runs.needsConsent("de-DE", engine: .parakeet))
        #expect(runs.needsDownload("de-DE", engine: .parakeet))
        #expect(!runs.needsDownload("en-US", engine: .builtIn))
        #expect(!runs.start(german))

        speech.available.installed[.parakeetUltra] = ["de", "en"]
        await runs.loadAvailability()
        speech.release()
        #expect(runs.start(german))
        await runs.finish()
        #expect(speech.heard.map(\.model) == [.parakeetUltra])
    }

    @Test func aSecondRunOnTheSameItemIsRefused() async {
        let runs = SubtitleRuns(engine: speech, defaults: defaults) { _, _ in }
        await runs.loadAvailability()
        let first = request()
        var second = request()
        second.source = first.source

        #expect(runs.start(first))
        #expect(!runs.start(second))
        speech.release()
        await runs.finish()
        #expect(runs.start(second))
        await runs.finish()
    }

    @Test func cancelingSavesNothing() async {
        var saved = 0
        let runs = SubtitleRuns(engine: speech, defaults: defaults) { _, _ in saved += 1 }
        await runs.loadAvailability()
        let first = request()
        let waiting = request()
        runs.start(first)
        runs.start(waiting)
        await eventually { runs.runs.first?.state == .working(0.5) }

        runs.cancel(runs.runs[1].id)
        runs.cancel(runs.runs[0].id)
        await runs.finish()

        #expect(saved == 0)
        #expect(runs.runs.isEmpty)
        #expect(runs.finished.map(\.outcome) == [.canceled, .canceled])
        #expect(runs.failure == nil)
    }

    @Test func noSpeechFailsWithItsOwnWords() async {
        speech.failure = TranscriptionError.noSpeech
        speech.release()
        let runs = SubtitleRuns(engine: speech, defaults: defaults) { _, _ in }
        await runs.loadAvailability()

        runs.start(request())
        await runs.finish()

        #expect(runs.failure?.message == SubtitleText.noSpeech)
        #expect(runs.finished.map(\.outcome) == [.failed(SubtitleText.noSpeech)])
    }
}
