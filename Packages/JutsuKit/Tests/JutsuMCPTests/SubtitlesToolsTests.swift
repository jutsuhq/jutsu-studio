import Foundation
import HiggsfieldMCP
import JutsuAgent
import Testing

@testable import JutsuMCP

/// subtitles as the helper turns its arguments into commands: make idempotent by its fingerprint, get and export
/// without one, and arguments refused before anything reaches the app.
@Suite struct SubtitlesToolsTests {
    private let item = JSONValue.string(UUID().uuidString)

    private func subtitles(_ arguments: [String: JSONValue]) -> Result<AgentCommand, AgentError> {
        var all: [String: JSONValue] = ["item": item]
        for (key, value) in arguments { all[key] = value }
        return Tool.subtitles.command(all)
    }

    private func command(_ arguments: [String: JSONValue]) throws -> SubtitlesCommand {
        guard case .success(.subtitles(let command)) = subtitles(arguments) else {
            throw AgentError.badRequest("no subtitles for \(arguments)")
        }
        return command
    }

    @Test func makeIsFingerprintedByItsParameters() throws {
        let first = try command(["action": "make", "request_id": "subs-1", "language": "en-US"])
        #expect(first.engine == nil && first.language == "en-US")
        let fingerprint = try #require(first.fingerprint)
        #expect(AgentNames.isValidFingerprint(fingerprint))
        let same = try command(["action": "make", "request_id": "subs-1", "language": "en-US"])
        #expect(same.fingerprint == fingerprint)
        let other = try command(["action": "make", "request_id": "subs-1", "language": "en-US", "engine": "parakeet"])
        #expect(other.fingerprint != fingerprint && other.engine == .parakeet)
        #expect(try command(["action": "make", "request_id": "subs-1"]).fingerprint != fingerprint)
    }

    @Test func getAndExportTakeNoRequest() throws {
        let get = try command(["action": "get", "format": "vtt"])
        #expect(get.fingerprint == nil && get.requestID == nil && get.format == .vtt)
        #expect(try command(["action": "export", "format": "srt"]).format == .srt)
    }

    @Test func badArgumentsAreRefusedBeforeTheApp() {
        let cases: [[String: JSONValue]] = [
            [:], ["action": "transcribe"], ["action": "make"], ["action": "make", "request_id": "subs 1"],
            ["action": "make", "request_id": "subs-1", "engine": "whisper"],
            ["action": "make", "request_id": "subs-1", "format": "srt"],
            ["action": "get", "request_id": "subs-1"], ["action": "export"], ["action": "export", "format": "ass"],
            ["action": "get", "item": "not-an-id"], ["action": "get", "max_cost": ["amount": 1, "unit": "usd"]],
        ]
        for arguments in cases {
            guard case .failure(let error) = subtitles(arguments) else {
                Issue.record("\(arguments) was taken")
                continue
            }
            #expect(error.code == .badRequest, "\(arguments)")
        }
    }

    @Test func theToolIsListedWithItsSchemaAndTheSheet() throws {
        let definition = try #require(Tool.subtitles.definition(structured: true).objectValue)
        #expect(definition["name"] == "subtitles")
        let input = try #require(definition["inputSchema"]?.objectValue)
        #expect(input["required"] == ["action", "item"])
        let output = try #require(definition["outputSchema"]?.objectValue?["properties"]?.objectValue)
        #expect(output["cues"] != nil && output["jobs"] != nil && output["file"] != nil)
        #expect(Tool.subtitles.about.contains("needs_person"))
        guard case .success(.show(let show)) = Tool.show.command(["item": item, "sheet": "subtitles"]) else {
            throw AgentError.badRequest("no show")
        }
        #expect(show.sheet == .subtitles)
    }
}
