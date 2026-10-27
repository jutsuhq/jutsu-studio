import Foundation
import Testing

@testable import JutsuAgent

/// subtitles on the wire: make, get and export, the sheet show opens, and what capabilities says of the models.
@Suite struct SubtitlesWireTests {
    private let fingerprint = String(repeating: "a", count: 64)
    private let item = UUID()

    private func roundTrip(_ command: AgentCommand) throws -> AgentCommand {
        let line = try AgentWire.line(AgentRequest(command, id: "1"))
        return try AgentWire.request(from: line.dropLast()).request.get().command
    }

    @Test func eachActionRoundTrips() throws {
        let commands: [AgentCommand] = [
            .subtitles(
                SubtitlesCommand(
                    action: .make, item: item, requestID: "subs-1", fingerprint: fingerprint, language: "de-DE",
                    engine: .parakeet)),
            .subtitles(SubtitlesCommand(action: .make, item: item, requestID: "subs-2", fingerprint: fingerprint)),
            .subtitles(SubtitlesCommand(action: .get, item: item)),
            .subtitles(SubtitlesCommand(action: .get, item: item, format: .vtt)),
            .subtitles(SubtitlesCommand(action: .export, item: item, format: .srt)),
            .show(.sheet(.subtitles, item: item)),
        ]
        for command in commands { #expect(try roundTrip(command) == command) }
        let line = try AgentWire.line(AgentRequest(commands[0]))
        let text = String(decoding: line, as: UTF8.self)
        #expect(text.contains(#""command":"subtitles""#) && text.contains(#""requestId":"subs-1""#))
        #expect(text.contains(#""engine":"parakeet""#) && text.contains(#""action":"make""#))
    }

    @Test func eachActionTakesOnlyItsOwnFields() {
        let refused = [
            SubtitlesCommand(action: .make, item: item, fingerprint: fingerprint),
            SubtitlesCommand(action: .make, item: item, requestID: "subs-1"),
            SubtitlesCommand(action: .make, item: item, requestID: "subs-1", fingerprint: fingerprint, format: .srt),
            SubtitlesCommand(
                action: .make, item: item, requestID: "subs-1", fingerprint: fingerprint, language: "en US"),
            SubtitlesCommand(action: .get, item: item, requestID: "subs-1"),
            SubtitlesCommand(action: .get, item: item, language: "en-US"),
            SubtitlesCommand(action: .export, item: item, engine: .auto, format: .srt),
            SubtitlesCommand(action: .export, item: item),
        ]
        for command in refused { #expect(command.problem != nil, "\(command)") }
        #expect(SubtitlesCommand(action: .export, item: item, format: .vtt).problem == nil)
        #expect(SubtitlesCommand(action: .get, item: item).problem == nil)
        #expect(SubtitlesCommand.isLanguage("zh-Hant-TW") && SubtitlesCommand.isLanguage("de"))
        #expect(!SubtitlesCommand.isLanguage("1de") && !SubtitlesCommand.isLanguage("d"))
    }

    @Test func aRefusedCommandNeverReachesTheApp() throws {
        let line = Data(#"{"version":1,"command":"subtitles","action":"export","item":"\#(item.uuidString)"}"#.utf8)
        let decoded = try AgentWire.request(from: line).request
        guard case .failure(let error) = decoded else { throw AgentError.badRequest("decoded") }
        #expect(error.code == .badRequest && error.message.contains("format"))
    }

    @Test func theAnswerAndCapabilitiesKeepTheirShape() throws {
        let answer = AgentSubtitles(
            item: item, versionID: UUID(), language: "en-US", model: "speech_transcriber",
            cues: [AgentCue(start: 0.2, end: 1.1, text: "Hello\nthere.")], text: "WEBVTT\n")
        let response = AgentResponse(id: "1", subtitles: answer)
        let decoded = try JSONDecoder().decode(AgentResponse.self, from: AgentWire.line(response).dropLast())
        #expect(decoded == response)
        #expect(String(decoding: try AgentWire.line(answer), as: UTF8.self).contains(#""versionId""#))

        var onDevice = AgentCapabilities.OnDevice(
            smoothMotion: .init(available: true, model: "none"), upscaleVideo: .init(available: true, model: "agreed"),
            upscaleImage: .init(available: true, model: "agreed"))
        onDevice.subtitles = AgentSubtitleCapabilities(
            defaultEngine: "auto",
            engines: [.init(engine: "parakeet", available: true, languages: ["de", "en"], model: "not_downloaded")])
        let back = try JSONDecoder().decode(AgentCapabilities.OnDevice.self, from: AgentWire.line(onDevice).dropLast())
        #expect(back == onDevice)
        #expect(AgentCapabilities.ToolGroup.all.flatMap(\.tools).contains("subtitles"))
    }
}
