import Darwin
import Foundation

/// The app's end of the agent socket. It listens from launch, and reads Allow agents again for every command and
/// every upload, so turning the setting off refuses the next command at once, on a connection opened before too,
/// with `agents_off` the agent can show the person. Turning it off stops nothing an agent started.
@MainActor
public final class AgentServer {
    /// Runs one command the app has accepted; the server fills in the response's `id`.
    public typealias Handler = @MainActor (AgentRequest) async throws(AgentError) -> AgentResponse
    /// Runs before an upload's bytes are read, after Allow agents and the upload's own fields were checked: a
    /// refusal leaves the bytes unread and nothing in the inbox. A command whose request ID is already taken by
    /// other parameters is refused here.
    public typealias UploadGate = @MainActor (UploadCommand, _ client: String?) throws(AgentError) -> Void

    public let socket: URL
    public let inbox: AgentInbox
    private let isAllowed: @MainActor () -> Bool
    private let gate: UploadGate
    private let handle: Handler
    private let answerDeadline: Duration
    private let freeSpace: @Sendable (URL) -> Int64?
    private var listener: AgentListener?
    private var connections: [ObjectIdentifier: AgentSocketConnection] = [:]

    /// - Parameters:
    ///   - answerDeadline: what a command's answer waits for its work at most (`AgentProtocol.answerDeadline`).
    ///   - freeSpace: the bytes free on the volume of the given file, `nil` when unknown; an upload must leave
    ///     `AgentInbox.minFreeSpace` (`AgentInbox.roomProblem`).
    public init(
        socket: URL, isAllowed: @escaping @MainActor () -> Bool, gate: @escaping UploadGate = { _, _ in },
        answerDeadline: Duration = AgentProtocol.answerDeadline,
        freeSpace: @escaping @Sendable (URL) -> Int64? = { _ in nil }, handle: @escaping Handler
    ) {
        self.socket = socket
        inbox = AgentInbox(socket: socket)
        self.isAllowed = isAllowed
        self.gate = gate
        self.answerDeadline = answerDeadline
        self.freeSpace = freeSpace
        self.handle = handle
    }

    public var isListening: Bool { listener != nil }

    /// Binds the socket, creating its folder. Throws `AgentError.socketPathTooLong` or the POSIX error.
    public func start() throws {
        guard listener == nil else { return }
        guard AgentSocket.fits(socket) else { throw AgentError.socketPathTooLong(socket) }
        try FileManager.default.createDirectory(
            at: socket.deletingLastPathComponent(), withIntermediateDirectories: true)
        listener = try AgentListener(path: socket) { [weak self] connection in
            guard let self else { return connection.cancel() }
            self.accept(connection)
        }
    }

    /// Stops listening, closes open connections and removes the socket file.
    public func stop() {
        guard let listener else { return }
        listener.cancel()
        self.listener = nil
        for connection in connections.values { connection.cancel() }
        connections = [:]
        unlink(socket.path(percentEncoded: false))
    }

    /// The answer to one request line, for any command but `upload`, whose bytes follow its line on the socket.
    public func response(to line: Data) async -> AgentResponse {
        let (id, request) = AgentWire.request(from: line)
        do throws(AgentError) {
            guard isAllowed() else { throw .agentsOff }
            let parsed = try request.get()
            if case .upload = parsed.command { throw .badRequest("upload is read with the bytes that follow it") }
            var response = try await answer(parsed)
            response.id = id
            return response
        } catch {
            return AgentResponse(id: id, error: error)
        }
    }

    /// The handler's answer, or `still_working` once `answerDeadline` passes first. The work runs in a task of its
    /// own and goes on either way: nothing a command started is stopped because its answer came too late.
    private func answer(_ request: AgentRequest) async throws(AgentError) -> AgentResponse {
        let handle = handle
        let work = Task { () -> Result<AgentResponse, AgentError> in
            do throws(AgentError) {
                return .success(try await handle(request))
            } catch {
                return .failure(error)
            }
        }
        let first = await withCheckedContinuation {
            (continuation: CheckedContinuation<Result<AgentResponse, AgentError>?, Never>) in
            let race = AnswerRace(continuation)
            let timer = Task { [answerDeadline] in
                try? await Task.sleep(for: answerDeadline)
                race.finish(nil)
            }
            Task {
                let result = await work.value
                timer.cancel()
                race.finish(result)
            }
        }
        guard let first else { throw .stillWorking(request.command.name) }
        return try first.get()
    }

    private func accept(_ connection: AgentSocketConnection) {
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        Task {
            await serve(connection)
            connections[id] = nil
        }
    }

    /// Answers each line in order, and reads on only once it is answered. A refused upload closes the connection:
    /// the bytes that may follow can't be told from the next request.
    private func serve(_ connection: AgentSocketConnection) async {
        var buffer = AgentLineBuffer()
        while true {
            guard let line = buffer.nextLine() else {
                guard !buffer.isOverlong, let data = await connection.receive() else { return connection.cancel() }
                buffer.push(data)
                continue
            }
            let (id, request) = AgentWire.request(from: line)
            guard case .success(let parsed) = request, case .upload(let upload) = parsed.command else {
                send(await response(to: line), on: connection)
                continue
            }
            switch await receive(upload, client: parsed.client, buffer: &buffer, from: connection) {
            case .stored(let path): send(AgentResponse(id: id, uploaded: path), on: connection)
            case .refused(let error): return send(AgentResponse(id: id, error: error), on: connection, thenClose: true)
            case .dropped: return connection.cancel()
            }
        }
    }

    private func send(_ response: AgentResponse, on connection: AgentSocketConnection, thenClose: Bool = false) {
        guard let data = try? AgentWire.line(response) else { return }
        connection.send(data, thenClose: thenClose)
    }

    enum UploadOutcome: Equatable {
        /// The file's path in the inbox.
        case stored(String)
        case refused(AgentError)
        /// The client went away before all the bytes came.
        case dropped
    }

    /// `upload.size` bytes from `buffer` and then the connection, through a hidden partial file in a new folder of
    /// the inbox, moved to its name only once complete, so nothing half-written is ever named.
    /// note: written on the main actor a chunk at a time (up to 64 KiB per read); move it off the main actor if
    /// large uploads ever stall the UI.
    private func receive(
        _ upload: UploadCommand, client: String?, buffer: inout AgentLineBuffer, from connection: AgentSocketConnection
    ) async -> UploadOutcome {
        do throws(AgentError) {
            guard isAllowed() else { throw .agentsOff }
            if let problem = UploadCommand.problem(name: upload.name, size: upload.size) { throw .badRequest(problem) }
            try gate(upload, client)
            if let problem = AgentInbox.roomProblem(
                size: upload.size, freeSpace: freeSpace(inbox.folder), stored: inbox.storedSize())
            {
                throw .noRoom(upload.name, problem)
            }
        } catch {
            return .refused(error)
        }
        let folder: URL
        let handle: FileHandle
        let partial: URL
        do {
            folder = try inbox.makeUploadFolder()
            partial = folder.appending(path: ".partial")
            guard FileManager.default.createFile(atPath: partial.path(percentEncoded: false), contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
            handle = try FileHandle(forWritingTo: partial)
        } catch {
            return .refused(.couldNotStore(upload.name, error))
        }
        let destination = folder.appending(path: upload.name)
        let written = await Self.copy(upload.size, from: &buffer, connection, to: handle)
        do {
            try handle.close()
            guard let written else {
                try? FileManager.default.removeItem(at: folder)
                return .dropped
            }
            try written.get()
            try AgentInbox.place(partial, at: destination)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            return .refused(.couldNotStore(upload.name, error))
        }
        return .stored(destination.path(percentEncoded: false))
    }

    /// Writes the next `size` bytes to `handle`: nil when the client went away first. After a failed write the rest
    /// is still read, so the answer comes once the client has sent everything.
    private static func copy(
        _ size: Int64, from buffer: inout AgentLineBuffer, _ connection: AgentSocketConnection, to handle: FileHandle
    ) async -> Result<Void, any Error>? {
        var remaining = size
        var result = Result<Void, any Error>.success(())
        while remaining > 0 {
            var chunk = buffer.take(upTo: Int(min(remaining, 1 << 20)))
            if chunk.isEmpty {
                guard let data = await connection.receive() else { return nil }
                buffer.push(data)
                chunk = buffer.take(upTo: Int(min(remaining, 1 << 20)))
            }
            remaining -= Int64(chunk.count)
            if case .success = result { result = Result { try handle.write(contentsOf: chunk) } }
        }
        return result
    }
}

/// Resumes its continuation once, with whichever result comes first.
@MainActor
private final class AnswerRace {
    private var continuation: CheckedContinuation<Result<AgentResponse, AgentError>?, Never>?

    init(_ continuation: CheckedContinuation<Result<AgentResponse, AgentError>?, Never>) {
        self.continuation = continuation
    }

    func finish(_ result: Result<AgentResponse, AgentError>?) {
        continuation?.resume(returning: result)
        continuation = nil
    }
}

extension AgentError {
    /// Not retried as it is: the room comes back only once files are removed or the waiting jobs take theirs.
    static func noRoom(_ name: String, _ problem: String) -> AgentError {
        AgentError(
            .fileRefused, message: "Jutsu Studio didn't take \(name): \(problem)", retryable: false,
            next: "Ask the person to free space on the Mac or let queued jobs start, or send a smaller file.")
    }

    static func couldNotStore(_ name: String, _ error: any Error) -> AgentError {
        AgentError(
            .fileRefused, message: "Jutsu Studio couldn't store \(name): \(error.localizedDescription)",
            retryable: true,
            next: "Check that the Mac has room for it, then send the request again.")
    }
}
