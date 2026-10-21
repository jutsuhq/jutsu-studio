import Foundation
import HiggsfieldMCP

/// `MCPServer` over one client's stream of lines, each request answered in a task of its own, so a call that waits on
/// the app (`jobs` with `wait_seconds`) doesn't hold up the calls sent after it.
///
/// `initialize` and everything that isn't a request are answered in turn, before the next line is taken, so the
/// requests after the handshake see its session. `notifications/cancelled` cancels its request's task, and a
/// cancelled request is answered with nothing, as MCP asks; `initialize` is never cancelled. Each reply is written
/// whole by `write`, one at a time, on this actor.
public actor MCPConnection {
    private var server: MCPServer
    private let write: @Sendable (Data) -> Void
    /// The requests being answered, by their JSON-RPC ID; `token` tells a request from a later one sent with its ID.
    private var running: [JSONValue: (token: UUID, task: Task<Void, Never>)] = [:]

    /// - Parameter write: writes one reply line, called on this actor and never twice at once.
    public init(server: MCPServer, write: @escaping @Sendable (Data) -> Void) {
        self.server = server
        self.write = write
    }

    /// Takes one line from the client.
    public func receive(_ line: Data) async {
        let message = try? JSONDecoder().decode(JSONValue.self, from: line)
        let method = message?["method"]?.stringValue
        if method == "notifications/cancelled", message?["id"] == nil {
            if let id = message?["params"]?["requestId"] { cancel(id) }
            return
        }
        guard let id = message?["id"], let method, method != "initialize" else {
            // Answered at once, without waiting on the app; `initialize` keeps the session it sets up.
            var current = server
            let reply = await current.reply(to: line)
            server = current
            if let reply { write(reply) }
            return
        }
        let token = UUID()
        let snapshot = server
        running[id] = (
            token,
            Task {
                var server = snapshot
                let reply = await server.reply(to: line)
                await self.finish(id, token: token, reply: reply)
            }
        )
    }

    /// Waits for the requests still being answered, as when the client has closed its end.
    public func drain() async {
        while let next = running.values.first {
            await next.task.value
        }
    }

    private func cancel(_ id: JSONValue) {
        running.removeValue(forKey: id)?.task.cancel()
    }

    /// Writes the reply unless the request was cancelled meanwhile.
    private func finish(_ id: JSONValue, token: UUID, reply: Data?) {
        guard running[id]?.token == token else { return }
        running[id] = nil
        if let reply { write(reply) }
    }
}
