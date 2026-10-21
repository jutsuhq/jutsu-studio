import Foundation
import Testing

@testable import JutsuAgent

@Suite struct WireTests {
    private func request(_ json: String) -> (id: String?, request: Result<AgentRequest, AgentError>) {
        AgentWire.request(from: Data(json.utf8))
    }

    private func error(_ json: String) -> AgentError? {
        if case .failure(let error) = request(json).request { error } else { nil }
    }

    @Test func aRequestIsOneFlatLineAndReadsBack() throws {
        let sent = AgentRequest(.show(.page(.queue)), id: "7", client: "Claude Code")
        let line = try AgentWire.line(sent)
        #expect(line.last == UInt8(ascii: "\n"))
        #expect(line.dropLast().contains(UInt8(ascii: "\n")) == false)
        let text = String(decoding: line, as: UTF8.self)
        #expect(text == #"{"client":"Claude Code","command":"show","id":"7","page":"queue","version":1}"# + "\n")
        #expect(try request(text).request.get() == sent)
    }

    @Test func everyCommandRoundTrips() throws {
        let job = UUID()
        let commands: [AgentCommand] = [
            .capabilities(CapabilitiesCommand()), .capabilities(CapabilitiesCommand(models: true, model: "seedance25")),
            .show(.page(.settings)), .show(.job(job)),
            .upload(
                UploadCommand(
                    name: "clip.mov", size: 12,
                    request: UploadRequest(
                        command: "create_video", requestID: "r-1", fingerprint: String(repeating: "a", count: 64)))),
        ]
        for command in commands {
            let line = try AgentWire.line(AgentRequest(command, id: "1"))
            #expect(try AgentWire.request(from: line.dropLast()).request.get().command == command)
        }
    }

    @Test func theVersionIsCheckedBeforeTheCommand() {
        #expect(error(#"{"version":2,"id":"a","command":"later"}"#)?.code == .unsupportedVersion)
        #expect(request(#"{"version":2,"id":"a","command":"later"}"#).id == "a")
        #expect(error(#"{"id":"a","command":"show"}"#)?.code == .badRequest)
    }

    @Test func malformedLinesAreBadRequestsNotCrashes() {
        let lines = [
            "", "not json", "[]", #"{"version":"1"}"#, #"{"version":1}"#, #"{"version":1,"command":7}"#,
            #"{"version":1,"id":3,"command":"show","page":"queue"}"#,
            #"{"version":1,"command":"show"}"#, #"{"version":1,"command":"show","page":"queue","job":"x"}"#,
            #"{"version":1,"command":"show","page":"jobs"}"#, #"{"version":1,"command":"show","job":"not-a-uuid"}"#,
            #"{"version":1,"command":"capabilities","models":"yes"}"#,
            #"{"version":1,"command":"capabilities","model":"../etc"}"#,
            #"{"version":1,"command":"upload","name":".hidden","size":1}"#,
            #"{"version":1,"command":"upload","name":"a/b","size":1}"#,
            #"{"version":1,"command":"upload","name":"a","size":-1}"#,
            #"{"version":1,"command":"upload","name":"a","size":1e30}"#,
            #"{"version":1,"command":"upload","name":"a","size":99999999999999}"#,
            #"{"version":1,"command":"upload","name":"a","size":1,"request":{"command":"x","requestId":".r","fingerprint":""}}"#,
        ]
        for line in lines {
            #expect(error(line)?.code == .badRequest, "\(line)")
        }
        #expect(error(#"{"version":1,"command":"delete_everything"}"#)?.code == .unknownCommand)
    }

    @Test func theLineBufferSplitsLinesAndHandsOutTheBytesAfterThem() {
        var buffer = AgentLineBuffer()
        buffer.push(Data("one\ntw".utf8))
        #expect(buffer.nextLine() == Data("one".utf8))
        #expect(buffer.nextLine() == nil)
        buffer.push(Data("o\nRAW".utf8))
        #expect(buffer.nextLine() == Data("two".utf8))
        #expect(buffer.take(upTo: 2) == Data("RA".utf8))
        #expect(buffer.take(upTo: 10) == Data("W".utf8))
        #expect(buffer.take(upTo: 10).isEmpty)
    }

    @Test func aLineLongerThanAnyRequestIsOverlong() {
        var buffer = AgentLineBuffer()
        buffer.push(Data(repeating: UInt8(ascii: "x"), count: AgentProtocol.maxLineLength))
        #expect(!buffer.isOverlong)
        buffer.push(Data("x".utf8))
        #expect(buffer.isOverlong)
    }

    @Test func requestIDsAndFileNamesCantNamePaths() {
        #expect(AgentNames.isValidRequestID("job-1.retry_2"))
        #expect(AgentNames.isValidRequestID(String(repeating: "a", count: 64)))
        for bad in ["", ".hidden", "a/b", "a b", "ä", String(repeating: "a", count: 65), "..", "a\0b"] {
            #expect(!AgentNames.isValidRequestID(bad), "\(bad)")
        }
        #expect(AgentNames.isValidFileName("My clip (final).mov"))
        for bad in ["", ".partial", "a/b", "x\0", String(repeating: "a", count: 256)] {
            #expect(!AgentNames.isValidFileName(bad))
        }
        #expect(AgentNames.isValidFingerprint(String(repeating: "0f", count: 32)))
        #expect(!AgentNames.isValidFingerprint(String(repeating: "0F", count: 32)))
    }

    @Test func theBudgetNeverGoesBelowZero() {
        let budget = AgentCapabilities.Budget(unit: .credits, dailyLimit: 100, spentToday: 140)
        #expect(budget.remaining == 0)
        #expect(AgentCapabilities.Budget(unit: .usdCents, dailyLimit: -5, spentToday: -1).remaining == 0)
    }
}
