import Foundation
import JutsuAgent
import JutsuCore
import JutsuTestSupport
import Testing

@testable import Presentation

/// subtitles make for agents, with a stand-in speech engine: once per request ID, refused by the sheet's rules,
/// followed and canceled as a job of kind on_device; get and export of what a version has.
@MainActor
@Suite struct AgentSubtitleRunsTests {
    let speech = FakeSpeech()
    let defaults: UserDefaults
    let runs: SubtitleRuns
    let agent: AgentSubtitleRuns
    let gate = AgentRequestGate<AgentCreated, AgentError>(log: AgentRequestLog(folder: nil))
    let refusals = AgentRequestGate<AgentCreated, AgentError>.Refusals(
        conflict: .requestConflict, unreadable: AgentError(.failed, message: "unreadable", retryable: true),
        neverQueued: AgentError(.failed, message: "never queued", retryable: true))
    let source = MaterialReference(materialID: UUID(), versionID: UUID())
    let saved = Box<[Subtitles]>([])

    init() throws {
        let name = "AgentSubtitleRunsTests-\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        speech.available.languages[.parakeetUltra] = ["de", "lv"]
        let saved = saved
        runs = SubtitleRuns(engine: speech, defaults: defaults) { _, subtitles in saved.update { $0.append(subtitles) }
        }
        agent = AgentSubtitleRuns(runs: runs, models: nil) { .credits }
    }

    private func command(
        language: String? = "en-US", engine: AgentSubtitleEngine? = nil, requestID: String = "subs-1",
        fingerprint: String = String(repeating: "a", count: 64)
    ) -> SubtitlesCommand {
        SubtitlesCommand(
            action: .make, item: source.materialID, requestID: requestID, fingerprint: fingerprint,
            language: language, engine: engine)
    }

    private func make(
        _ fields: SubtitlesCommand, recorded: Box<[UUID]> = Box([])
    ) async throws(AgentError)
        -> AgentCreated
    {
        let gate = gate
        let target = AgentSubtitleRuns.Target(source: source, file: URL(filePath: "/tmp/talk.mp4"), subtitles: nil)
        return try await agent.make(
            fields, client: "agent", gate: gate, refusals: refusals,
            record: { ids throws(AgentError) in
                recorded.update { $0 += ids }
                do {
                    try gate.record(
                        fields.requestID ?? "", fingerprint: fields.fingerprint ?? "", ids: ids, at: .now,
                        kind: AgentOnDeviceRuns.kind)
                } catch {
                    throw AgentError(.failed, message: "can't record", retryable: true)
                }
            },
            target: { target })
    }

    private func refusal(_ fields: SubtitlesCommand) async -> AgentError? {
        do {
            _ = try await make(fields)
            return nil
        } catch {
            return error
        }
    }

    @Test func theSameRequestStartsOneRunAndAnswersWithIt() async throws {
        let recorded = Box<[UUID]>([])
        let first = try await make(command(), recorded: recorded)
        let again = try await make(command(), recorded: recorded)

        #expect(!first.known && again.known)
        #expect(first.jobs.map(\.id) == again.jobs.map(\.id) && recorded.value == first.jobs.map(\.id))
        #expect(runs.runs.count == 1)
        let job = try #require(first.jobs.first)
        #expect(job.kind == "on_device" && job.operation == "subtitles" && job.model == "speech_transcriber")
        #expect(job.item == source.materialID && job.requestID == "subs-1" && job.client == "agent")
        #expect(job.price == AgentAmount(0, .credits) && job.isPriceExact)
        let other = command(language: "ru-RU", fingerprint: String(repeating: "b", count: 64))
        #expect(await refusal(other)?.code == .requestConflict)

        speech.release()
        await runs.finish()
        #expect(agent.job(job.id)?.state == "done" && agent.isSettled(job.id))
        #expect(saved.value.first?.transcript.text == "Hello there.")
        #expect(agent.started.map(\.id) == [job.id])
    }

    @Test func anAgentsRunLeavesThePersonsLanguage() async throws {
        defaults.set("ru-RU", forKey: SubtitleRuns.lastLanguageKey)
        _ = try await make(command(language: "en-US"))
        speech.release()
        await runs.finish()
        #expect(speech.heard.map(\.language) == ["en-US"])
        #expect(runs.preferredLanguage == "ru-RU")
    }

    @Test func aLanguageIsMatchedByItsCodeAndTheEngineByItsName() async throws {
        speech.available.installed[.parakeetUltra] = ["de", "lv"]
        let english = try await make(command(language: "en", engine: .builtIn))
        #expect(english.jobs.first?.model == "speech_transcriber")
        speech.release()
        await runs.finish()
        let german = try await make(command(language: "de-AT", engine: .parakeet, requestID: "subs-2"))
        #expect(german.jobs.first?.model == "parakeet_ultra")
        await runs.finish()
        #expect(speech.heard.map(\.language) == ["en-US", "de"])
    }

    @Test func whatOnlyThePersonCanDoAsksForThem() async {
        // Parakeet takes Latvian but isn't downloaded; Dictation's Russian model needs the person's agreement.
        let latvian = await refusal(command(language: "lv", engine: .auto))
        #expect(latvian?.code == .needsPerson && latvian?.next?.contains("sheet subtitles") == true)
        #expect(latvian?.message.contains("Parakeet") == true)
        let russian = await refusal(command(language: "ru-RU", requestID: "subs-2"))
        #expect(russian?.code == .needsPerson && russian?.message.contains("Apple") == true)
        #expect(await refusal(command(language: "ja-JP", requestID: "subs-3"))?.code == .invalidRequest)
        #expect(await refusal(command(language: "lv", engine: .builtIn, requestID: "subs-4"))?.code == .invalidRequest)
        #expect(runs.runs.isEmpty)
    }

    @Test func aSecondRunOnTheItemIsBusyAndAgentsCancelOnlyTheirOwn() async throws {
        let id = try #require(try await make(command()).jobs.first?.id)
        #expect(await refusal(command(requestID: "subs-2"))?.code == .busy)

        let personal = UUID()
        #expect(
            runs.start(
                SubtitleRuns.Request(
                    source: MaterialReference(materialID: UUID(), versionID: UUID()), file: URL(filePath: "/tmp/b.mp4"),
                    language: "en-US"), id: personal))
        await #expect(throws: AgentError.self) { _ = try await agent.cancel(personal) }

        let canceled = try await agent.cancel(id)
        #expect(canceled?.state == "canceled")
        #expect(try await agent.cancel(UUID()) == nil)
        speech.release()
        await runs.finish()
        #expect(saved.value.count == 1)
    }

    @Test func getAndExportReadTheVersionsCues() throws {
        let transcript = Transcript(
            language: "en-US", model: .transcriber, revision: "1",
            words: [TimedWord(text: "Hello", start: 0.2, end: 0.6), TimedWord(text: "there.", start: 0.7, end: 1.1)])
        // As the person edited them: two lines in one cue.
        let subtitles = Subtitles(
            transcript: transcript, cues: [SubtitleCue(start: 0.2, end: 1.5, text: "Hello\nthere.")])

        let answer = try AgentSubtitleRuns.answer(subtitles, of: source, format: .srt)
        #expect(answer.item == source.materialID && answer.versionID == source.versionID)
        #expect(answer.cues == [AgentCue(start: 0.2, end: 1.5, text: "Hello\nthere.")])
        #expect(answer.text == "1\n00:00:00,200 --> 00:00:01,500\nHello\nthere.\n" && answer.file == nil)
        #expect(try AgentSubtitleRuns.answer(subtitles, of: source).text == nil)
        #expect(throws: AgentError.self) { try AgentSubtitleRuns.answer(nil, of: source) }

        let name = AgentSubtitleRuns.fileName(
            for: URL(filePath: "/tmp/Talk take.mp4"), language: "en-US", format: .vtt, existing: ["talk take.en-us.vtt"]
        )
        #expect(name != "Talk take.en-US.vtt" && name.hasSuffix(".vtt") && name.hasPrefix("Talk take"))
    }

    @Test func capabilitiesListEachEnginesLanguagesAndModel() async {
        await runs.loadAvailability()
        let capabilities = agent.capabilities()
        #expect(capabilities.defaultEngine == "auto")
        #expect(capabilities.engines.map(\.engine) == ["built_in", "parakeet"])
        #expect(
            capabilities.engines[0].languages == ["en-US", "ru-RU"] && capabilities.engines[0].model == "needs_consent")
        #expect(capabilities.engines[0].needsConsent == ["ru-RU"])
        #expect(capabilities.engines[1].languages == ["de", "lv"] && capabilities.engines[1].model == "not_downloaded")
        runs.agreeToModel(for: "ru-RU")
        runs.defaultEngine = .parakeet
        #expect(agent.capabilities().engines[0].model == "agreed" && agent.capabilities().defaultEngine == "parakeet")
        #expect(agent.capabilities().engines[0].needsConsent == [])
        speech.release()
    }
}
