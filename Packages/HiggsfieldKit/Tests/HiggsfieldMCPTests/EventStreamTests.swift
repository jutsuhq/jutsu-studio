import Foundation
import Testing

@testable import HiggsfieldMCP

@Suite struct EventStreamTests {
    /// Bytes of `text`, then the stream stays open like a server that keeps the connection.
    private func openStream(_ text: String) -> AsyncStream<UInt8> {
        AsyncStream { continuation in
            for byte in text.utf8 { continuation.yield(byte) }
        }
    }

    @Test func stopsAtTheReplyWhileTheStreamStaysOpen() async throws {
        let stream = openStream(
            "event: message\ndata: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\"}\n\n"
                + "data: {\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{}}\n\n")
        let body = try await readEventStream(stream) { events in events.contains { $0.contains("\"id\":7") } }
        #expect(serverSentEventData(String(decoding: body, as: UTF8.self)).count == 2)
    }

    @Test func handlesCarriageReturnLineEnds() async throws {
        let stream = openStream("data: {\"id\":1}\r\n\r\n")
        let body = try await readEventStream(stream) { $0.contains("{\"id\":1}") }
        #expect(String(decoding: body, as: UTF8.self) == "data: {\"id\":1}\r\n\r\n")
    }

    @Test func readsToTheEndWhenNoEventCompletes() async throws {
        let stream = AsyncStream<UInt8> { continuation in
            for byte in "data: a\n\ndata: b\n\n".utf8 { continuation.yield(byte) }
            continuation.finish()
        }
        let body = try await readEventStream(stream) { _ in false }
        #expect(serverSentEventData(String(decoding: body, as: UTF8.self)) == ["a", "b"])
    }

    @Test func checksCompletionOncePerEventAsItArrives() async throws {
        let stream = openStream("data: a\n\nevent: x\ndata: b\ndata: c\n\n: comment\n\ndata: d\r\n\r\n")
        var seen: [[String]] = []
        _ = try await readEventStream(stream) { events in
            seen.append(events)
            return events.count == 3
        }
        #expect(seen == [["a"], ["a", "b\nc"], ["a", "b\nc", "d"]])
    }

    @Test func replyCheckReadsOnlyTheNewestEvent() {
        let isReply = MCPClient.isReply(to: 7)
        let reply = #"{"jsonrpc":"2.0","id":7,"result":{}}"#
        let notification = #"{"jsonrpc":"2.0","method":"notifications/progress"}"#
        #expect(isReply([notification, reply]))
        #expect(!isReply([reply, notification]))
        #expect(!isReply([#"{"jsonrpc":"2.0","id":8,"result":{}}"#]))
        #expect(!isReply([]))
    }

    @Test func manyEventsBeforeTheReplyAreCheckedOnceEach() async throws {
        let notification = "data: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\"}\n\n"
        let stream = openStream(
            String(repeating: notification, count: 2_000) + "data: {\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{}}\n\n")
        let isReply = MCPClient.isReply(to: 7)
        var checks = 0
        let body = try await readEventStream(stream) { events in
            checks += 1
            return isReply(events)
        }
        #expect(checks == 2_001)
        #expect(serverSentEventData(String(decoding: body, as: UTF8.self)).count == 2_001)
    }

    @Test func parsesEventsSplitAcrossChunks() {
        var parser = ServerSentEventParser()
        var events: [String] = []
        for chunk in ["da", "ta: {\"id\"", ":1}\r", "\n", "\r\nda", "ta: two\n", "\n"] {
            events += chunk.utf8.compactMap { parser.consume($0) }
        }
        #expect(events == ["{\"id\":1}", "two"])
        #expect(parser.finish() == nil)
    }

    @Test func keepsAnEventTheBodyEndsWithoutABlankLine() {
        #expect(serverSentEventData("data: a\n\ndata: b") == ["a", "b"])
    }

    @Test func refusesAnEventStreamOverTheLimit() async throws {
        let stream = openStream("data: " + String(repeating: "x", count: 64) + "\n\n")
        await #expect(throws: ResponseTooLarge.self) {
            _ = try await readEventStream(stream, limit: 32) { _ in false }
        }
    }

    @Test func refusesABodyOverTheLimit() async throws {
        let stream = AsyncStream<UInt8> { continuation in
            for byte in Array(repeating: UInt8(ascii: "x"), count: 33) { continuation.yield(byte) }
            continuation.finish()
        }
        await #expect(throws: ResponseTooLarge.self) { _ = try await readBody(stream, limit: 32) }
    }

    @Test func readsABodyAtTheLimit() async throws {
        let stream = AsyncStream<UInt8> { continuation in
            for byte in Array(repeating: UInt8(ascii: "x"), count: 32) { continuation.yield(byte) }
            continuation.finish()
        }
        #expect(try await readBody(stream, limit: 32).count == 32)
        #expect(maxResponseBytes == 16 * 1024 * 1024)
    }
}
