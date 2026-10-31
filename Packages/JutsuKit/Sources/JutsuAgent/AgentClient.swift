// Darwin sockets: the app and the helper only, never the portable wire types.
#if canImport(Darwin)
    import Darwin
    import Foundation

    /// One connection to the app's socket: requests are sent and answered one at a time. Blocking, for the helper and
    /// tests; never for the main thread of an app.
    public final class AgentClient {
        public enum Failure: Error, Equatable {
            /// Nothing listens there: the app isn't running, or is still starting.
            case notListening(errno: Int32)
            /// The app closed the connection.
            case closed
            /// A write or the wait for the answer took longer than the timeout.
            case timedOut
            /// Longer than `AgentSocket.maxPathLength`.
            case pathTooLong
            /// The file to upload ended before the size it was sent with.
            case fileChanged
        }

        private let socket: Int32
        private var buffer = AgentLineBuffer()

        /// - Parameter timeout: how long a write or a wait for the answer may take before the connection counts as
        ///   closed, so a hung app can't hang the agent too.
        public init(socket path: URL, timeout: Duration = .seconds(30)) throws {
            let socket = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            guard socket >= 0 else { throw Failure.notListening(errno: errno) }
            // Every stored property is set from here on, so a throw runs deinit, which closes the socket. Closing it here
            // too would close whatever descriptor another thread opened under the same number in between.
            self.socket = socket
            guard let connected = AgentSocket.withAddress(path, { connect(socket, $0, $1) }) else {
                throw Failure.pathTooLong
            }
            guard connected == 0 else { throw Failure.notListening(errno: errno) }
            // A closed peer is an error from write, not a SIGPIPE that ends the process.
            var on: Int32 = 1
            setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            let seconds = max(1, timeout.components.seconds)
            var limit = timeval(tv_sec: Int(seconds), tv_usec: 0)
            setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(socket, SOL_SOCKET, SO_SNDTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        }

        deinit { close(socket) }

        public func send(_ request: AgentRequest) throws -> AgentResponse {
            try send(line: AgentWire.line(request))
        }

        /// Sends `file`'s bytes, `command.size` of them, after the request's line, and returns the app's answer. The app
        /// may refuse before reading them and close the connection; its answer is read all the same.
        public func upload(
            _ command: UploadCommand, from file: URL, id: String? = nil, client: String? = nil
        ) throws
            -> AgentResponse
        {
            try write(AgentWire.line(AgentRequest(.upload(command), id: id, client: client)))
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            var sent: Int64 = 0
            do {
                while sent < command.size {
                    let chunk = try handle.read(upToCount: Int(min(Self.uploadChunk, command.size - sent))) ?? Data()
                    // The app would wait for the rest; closing the connection tells it the upload failed.
                    guard !chunk.isEmpty else { throw Failure.fileChanged }
                    try write(chunk)
                    sent += Int64(chunk.count)
                }
            } catch Failure.closed {
                // Refused early: the answer says why.
            }
            return try AgentWire.decoder.decode(AgentResponse.self, from: readLine())
        }

        static let uploadChunk: Int64 = 1 << 20

        /// A line as given, newline included: also for tests of what the app does with malformed input.
        public func send(line: Data) throws -> AgentResponse {
            try write(line)
            return try AgentWire.decoder.decode(AgentResponse.self, from: readLine())
        }

        private func write(_ data: Data) throws {
            try data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                var offset = 0
                while offset < raw.count {
                    let written = Darwin.write(socket, base + offset, raw.count - offset)
                    if written < 0 && errno == EINTR { continue }
                    guard written > 0 else { throw written < 0 && Self.isTimeout(errno) ? Failure.timedOut : .closed }
                    offset += written
                }
            }
        }

        private func readLine() throws -> Data {
            var chunk = [UInt8](repeating: 0, count: 4096)
            while true {
                // Answers aren't capped like requests: a list of jobs grows with the queue.
                if let line = buffer.nextLine() { return line }
                let count = read(socket, &chunk, chunk.count)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw count < 0 && Self.isTimeout(errno) ? Failure.timedOut : .closed }
                buffer.push(Data(chunk[..<count]))
            }
        }

        /// What `SO_RCVTIMEO` and `SO_SNDTIMEO` end a read or write with.
        private static func isTimeout(_ code: Int32) -> Bool { code == EAGAIN || code == EWOULDBLOCK }
    }
#endif
