import Foundation

/// Splits a `text/event-stream` body into the `data` payload of each event as its bytes arrive.
/// Multi-line data is joined with `\n`; other fields (`event`, `id`, `retry`) and comments are ignored.
struct ServerSentEventParser {
    private var line: [UInt8] = []
    private var data: [String] = []

    /// Feeds the next byte; returns the event's data when that byte ends an event.
    mutating func consume(_ byte: UInt8) -> String? {
        guard byte == UInt8(ascii: "\n") else {
            line.append(byte)
            return nil
        }
        if line.last == UInt8(ascii: "\r") { line.removeLast() }
        defer { line.removeAll(keepingCapacity: true) }
        if line.isEmpty {
            guard !data.isEmpty else { return nil }
            defer { data = [] }
            return data.joined(separator: "\n")
        }
        if line.starts(with: "data:".utf8) {
            var value = line.dropFirst(5)
            if value.first == UInt8(ascii: " ") { value = value.dropFirst() }
            data.append(String(decoding: value, as: UTF8.self))
        }
        return nil
    }

    /// The data of an event the body ended without a blank line after, if any.
    mutating func finish() -> String? {
        if !line.isEmpty { _ = consume(UInt8(ascii: "\n")) }
        return consume(UInt8(ascii: "\n"))
    }
}

/// The `data` payload of each event in a `text/event-stream` body.
func serverSentEventData(_ body: String) -> [String] {
    var parser = ServerSentEventParser()
    var events = body.utf8.compactMap { parser.consume($0) }
    if let last = parser.finish() { events.append(last) }
    return events
}

/// Reads an event stream until `isComplete` accepts the events received so far, then stops. A Streamable
/// HTTP server may keep the stream open after it sent the reply, so waiting for the end of the body hangs.
/// Throws `ResponseTooLarge` once the body exceeds `limit` bytes.
func readEventStream<Bytes: AsyncSequence>(
    _ bytes: Bytes, limit: Int = maxResponseBytes, until isComplete: ([String]) -> Bool
) async throws -> Data where Bytes.Element == UInt8 {
    var body = Data()
    var parser = ServerSentEventParser()
    var events: [String] = []
    for try await byte in bytes {
        guard body.count < limit else { throw ResponseTooLarge() }
        body.append(byte)
        guard let event = parser.consume(byte) else { continue }
        events.append(event)
        if isComplete(events) { break }
    }
    return body
}
