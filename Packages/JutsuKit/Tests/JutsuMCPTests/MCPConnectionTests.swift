import Foundation
import HiggsfieldMCP
import JutsuAgent
import JutsuTestSupport
import Testing

@testable import JutsuMCP

/// What the connection wrote, and what the fake app saw, from any thread.
private final class Record: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [Data] = []
    private var cancelled: [String] = []
    private var clients: [String?] = []

    func write(_ line: Data) { lock.withLock { lines.append(line) } }
    func sawCancel(_ name: String) { lock.withLock { cancelled.append(name) } }
    func sawClient(_ client: String?) { lock.withLock { clients.append(client) } }

    /// The ID of each reply, in the order they were written; every reply is one whole line.
    var ids: [JSONValue] {
        lock.withLock {
            lines.compactMap { line in
                guard line.last == UInt8(ascii: "\n"), !line.dropLast().contains(UInt8(ascii: "\n")) else { return nil }
                return (try? JSONDecoder().decode(JSONValue.self, from: line))?["id"]
            }
        }
    }

    var cancels: [String] { lock.withLock { cancelled } }
    var seenClients: [String?] { lock.withLock { clients } }
}

/// Requests served at once over one client's lines (`MCPConnection`).
@Suite(.timeLimit(.minutes(1)))
struct MCPConnectionTests {
    private static let capabilities = AgentCapabilities(
        appVersion: "0.2.0", connection: .init(kind: .none), budget: nil)

    private let record = Record()

    /// A connection whose fake app answers `jobs` only after 30 s, or once its task is cancelled.
    private func connection() -> MCPConnection {
        let record = record
        let server = MCPServer(version: "0.2.0") { command, client in
            record.sawClient(client)
            if case .jobs = command {
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch {
                    record.sawCancel("jobs")
                }
            }
            return AgentResponse(capabilities: Self.capabilities)
        }
        return MCPConnection(server: server) { record.write($0) }
    }

    private func line(_ method: String, _ params: JSONValue? = nil, id: JSONValue? = nil) throws -> Data {
        var message: [String: JSONValue] = ["jsonrpc": "2.0", "method": .string(method)]
        message["id"] = id
        message["params"] = params
        return try JSONEncoder().encode(JSONValue.object(message))
    }

    @Test func aWaitingCallHoldsUpNothingAndACancelledOneIsNeverAnswered() async throws {
        let connection = connection()
        await connection.receive(
            try line("initialize", ["protocolVersion": "2025-06-18", "clientInfo": ["name": "agent"]], id: 0))
        await connection.receive(
            try line("tools/call", ["name": "jobs", "arguments": ["wait_seconds": 50]], id: 1))
        await connection.receive(try line("tools/call", ["name": "capabilities"], id: 2))
        await eventually { record.ids == [0, 2] }

        await connection.receive(try line("notifications/cancelled", ["requestId": 1, "reason": "user"]))
        await eventually { record.cancels == ["jobs"] }
        await connection.drain()

        #expect(record.ids == [0, 2])
        // Both requests ran in the session the handshake set up.
        #expect(record.seenClients == ["agent", "agent"])
    }

    @Test func statelessRequestsAndNotificationsWorkAsBefore() async throws {
        let connection = connection()
        let meta: JSONValue = [
            "io.modelcontextprotocol/protocolVersion": "2026-07-28",
            "io.modelcontextprotocol/clientCapabilities": [:],
        ]
        await connection.receive(try line("notifications/initialized"))
        await connection.receive(try line("tools/call", ["_meta": meta, "name": "capabilities"], id: "a"))
        await connection.receive(try line("notifications/cancelled", ["requestId": "unknown"]))
        await connection.receive(Data("not json".utf8))
        await connection.drain()

        // The parse error is answered in turn, the request in a task of its own: either may come first.
        #expect(Set(record.ids) == ["a", .null])
        #expect(record.ids.count == 2)
    }
}
