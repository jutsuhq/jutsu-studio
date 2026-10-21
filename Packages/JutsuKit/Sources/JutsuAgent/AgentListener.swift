import Darwin
import Dispatch
import Foundation

/// The agent socket, in plain POSIX. Network.framework's `NWListener` copies the path into a fixed `sockaddr_un`, and
/// with a path past its 103 bytes (a group container's under a long user name) it reports ready while listening
/// nowhere. Here the address is sized to the path (`AgentSocket.withAddress`), which Darwin takes up to
/// `AgentSocket.maxPathLength`, with no chdir. New connections arrive on the main queue.
final class AgentListener {
    private let source: DispatchSourceRead

    /// Binds and listens at `path`, replacing a socket file left there by an earlier run, readable and writable by
    /// this user only.
    init(path: URL, accept: @escaping @MainActor (AgentSocketConnection) -> Void) throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError.current }
        let file = path.path(percentEncoded: false)
        unlink(file)
        let bound = AgentSocket.withAddress(path) { bind(fd, $0, $1) }
        // Before listen, so no connection is accepted while the mode is wider. Not umask, which would change it for
        // every thread of the process. The group container itself is the user's alone.
        guard bound == 0, chmod(file, 0o600) == 0, listen(fd, 16) == 0 else {
            let error = bound == nil ? POSIXError(.ENAMETOOLONG) : POSIXError.current
            close(fd)
            throw error
        }
        // A wakeup with nothing left to accept must not block the main thread.
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler {
            while case let client = Darwin.accept(fd, nil, nil), client >= 0 {
                let connection = AgentSocketConnection(client)
                MainActor.assumeIsolated { accept(connection) }
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
    }

    /// Stops accepting; connections already open stay.
    func cancel() { source.cancel() }
}

/// One client of the agent socket. Bytes are read only when asked for, so an upload comes in no faster than the app
/// writes it to disk; answers go out in order, from a queue of the connection's own.
///
/// `@unchecked Sendable`: every mutable property is read and written only on `queue`, and the descriptor is closed
/// only by the source's cancel handler, which runs on that queue too.
final class AgentSocketConnection: @unchecked Sendable {
    private let fd: Int32
    private let queue = DispatchQueue(label: "com.jutsustudio.agent-connection")
    private let source: DispatchSourceRead
    // Only on `queue`:
    private var waiting: CheckedContinuation<Data?, Never>?
    /// A new source is inactive, which counts as suspended; `resume` activates it.
    private var isSuspended = true
    private var isClosed = false
    private var buffer = [UInt8](repeating: 0, count: 1 << 16)

    init(_ fd: Int32) {
        self.fd = fd
        // accept() hands on the listener's O_NONBLOCK; writes here wait instead, for 30 s at most.
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 30, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.readable() }
        source.setCancelHandler { close(fd) }
    }

    /// The next bytes, up to 64 KiB; nil once the client has closed or the connection was.
    func receive() async -> Data? {
        await withCheckedContinuation { continuation in
            queue.async {
                guard !self.isClosed else { return continuation.resume(returning: nil) }
                self.waiting = continuation
                self.setSuspended(false)
            }
        }
    }

    /// Sends `data` after everything sent before it, then closes the connection if asked.
    func send(_ data: Data, thenClose: Bool = false) {
        queue.async {
            guard !self.isClosed else { return }
            data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                var offset = 0
                while offset < raw.count {
                    let written = write(self.fd, base + offset, raw.count - offset)
                    if written < 0 && errno == EINTR { continue }
                    guard written > 0 else { return }
                    offset += written
                }
            }
            if thenClose { self.shutDown() }
        }
    }

    func cancel() { queue.async { self.shutDown() } }

    private func readable() {
        let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        // Interrupted: the source fires again.
        if count < 0 && (errno == EINTR || errno == EAGAIN) { return }
        setSuspended(true)
        let continuation = waiting
        waiting = nil
        continuation?.resume(returning: count > 0 ? Data(buffer[..<count]) : nil)
    }

    private func shutDown() {
        guard !isClosed else { return }
        isClosed = true
        source.cancel()
        // A suspended source never runs its cancel handler, which closes the descriptor.
        setSuspended(false)
        waiting?.resume(returning: nil)
        waiting = nil
    }

    private func setSuspended(_ suspended: Bool) {
        guard suspended != isSuspended else { return }
        isSuspended = suspended
        if suspended { source.suspend() } else { source.resume() }
    }
}

extension POSIXError {
    /// The error `errno` names now.
    static var current: POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}
