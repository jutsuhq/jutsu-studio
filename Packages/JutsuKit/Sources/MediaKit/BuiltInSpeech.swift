import AVFoundation
import Foundation
import JutsuCore
import Speech

/// macOS 26's own speech models through SpeechAnalyzer: SpeechTranscriber for the locales it has, DictationTranscriber
/// for the others. A locale's model comes through AssetInventory, which downloads it from Apple once.
enum BuiltInSpeech {
    /// The revision a built-in transcript is cached under: the models change with macOS.
    static var revision: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "macos-\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    static func availability() async -> SpeechAvailability {
        guard #available(macOS 26, *) else { return .none }
        var availability = SpeechAvailability()
        if SpeechTranscriber.isAvailable {
            availability.languages[.transcriber] = await SpeechTranscriber.supportedLocales.map(identifier)
            availability.installed[.transcriber] = Set(await SpeechTranscriber.installedLocales.map(identifier))
        }
        availability.languages[.dictation] = await DictationTranscriber.supportedLocales.map(identifier)
        availability.installed[.dictation] = Set(await DictationTranscriber.installedLocales.map(identifier))
        return availability
    }

    /// The words of `file`'s sound; downloads the locale's model first when it isn't here and `mayDownload`.
    static func transcribe(
        _ file: URL, language: String, model: SpeechModel, mayDownload: Bool,
        progress: @escaping @Sendable (OnDeviceProgress) -> Void
    ) async throws -> [TimedWord] {
        guard #available(macOS 26, *) else { throw TranscriptionError.unsupportedLanguage }
        let audio = try AVAudioFile(forReading: file)
        let duration = Double(audio.length) / audio.processingFormat.sampleRate
        let session = try await Session(model: model, language: language)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [session.module]) {
            guard mayDownload else { throw TranscriptionError.modelNeeded }
            try await install(request, progress: progress)
        }
        progress(.working(0))
        return try await session.run(audio, duration: duration, progress: progress)
    }

    @available(macOS 26, *)
    private static func install(
        _ request: AssetInstallationRequest, progress: @escaping @Sendable (OnDeviceProgress) -> Void
    ) async throws {
        let fraction = request.progress
        let watcher = Task {
            while !Task.isCancelled {
                progress(.downloadingModel(fraction.fractionCompleted))
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        defer { watcher.cancel() }
        try await request.downloadAndInstall()
    }

    private static func identifier(_ locale: Locale) -> String {
        locale.identifier(.bcp47)
    }
}

/// One analysis: the model for the locale, its results as they come, and the words they hold.
@available(macOS 26, *)
private struct Session {
    let module: any SpeechModule
    private let language: String
    private let results: AsyncThrowingStream<AttributedString, any Error>

    init(model: SpeechModel, language: String) async throws {
        self.language = language
        let requested = Locale(identifier: language)
        switch model {
        case .transcriber:
            guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requested) else {
                throw TranscriptionError.unsupportedLanguage
            }
            let transcriber = SpeechTranscriber(
                locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
            module = transcriber
            results = Self.finals(of: transcriber.results.map { ($0.isFinal, $0.text) })
        case .dictation:
            guard let locale = await DictationTranscriber.supportedLocale(equivalentTo: requested) else {
                throw TranscriptionError.unsupportedLanguage
            }
            let transcriber = DictationTranscriber(
                locale: locale, contentHints: [], transcriptionOptions: [.punctuation], reportingOptions: [],
                attributeOptions: [.audioTimeRange])
            module = transcriber
            results = Self.finals(of: transcriber.results.map { ($0.isFinal, $0.text) })
        case .parakeetUltra:
            throw TranscriptionError.unsupportedLanguage
        }
    }

    private static func finals<S: AsyncSequence & Sendable>(
        of sequence: S
    ) -> AsyncThrowingStream<AttributedString, any Error> where S.Element == (Bool, AttributedString) {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await (isFinal, text) in sequence where isFinal { continuation.yield(text) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func run(
        _ audio: AVAudioFile, duration: TimeInterval, progress: @escaping @Sendable (OnDeviceProgress) -> Void
    ) async throws -> [TimedWord] {
        let analyzer = SpeechAnalyzer(modules: [module])
        let (results, language) = (results, language)
        let collector = Task {
            var words: [TimedWord] = []
            for try await text in results {
                Self.append(text, to: &words, language: language)
                if let end = words.last?.end, duration > 0 { progress(.working(min(end / duration, 1))) }
            }
            return words
        }
        do {
            try await withTaskCancellationHandler {
                if let last = try await analyzer.analyzeSequence(from: audio) {
                    try await analyzer.finalizeAndFinish(through: last)
                } else {
                    await analyzer.cancelAndFinishNow()
                }
            } onCancel: {
                Task { await analyzer.cancelAndFinishNow() }
            }
            try Task.checkCancellation()
            return try await collector.value
        } catch {
            collector.cancel()
            throw error
        }
    }

    /// The timed runs of one result as words, as `WordSpacing` joins them for `language`.
    static func append(_ text: AttributedString, to words: inout [TimedWord], language: String) {
        let runs = text.runs.compactMap { run -> TimedWord? in
            guard let range = run.audioTimeRange else { return nil }
            return TimedWord(
                text: String(text[run.range].characters), start: range.start.seconds, end: range.end.seconds)
        }
        WordSpacing.append(runs, to: &words, language: language)
    }
}
