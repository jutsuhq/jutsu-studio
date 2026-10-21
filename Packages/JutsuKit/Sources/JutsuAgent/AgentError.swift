import Foundation

/// A refused or failed command. `code` is stable for clients to branch on, `message` is for the person, `next` says
/// what to do instead, and `retryable` whether sending the same request again later can succeed. Agents read these
/// as tool results, so the text is English and written for them.
public struct AgentError: Error, Codable, Equatable, Sendable {
    /// A string, not an enum, so a client still decodes a code added after it was built.
    public struct Code: RawRepresentable, Codable, Hashable, Sendable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }

        public static let agentsOff = Code(rawValue: "agents_off")
        public static let unsupportedVersion = Code(rawValue: "unsupported_version")
        public static let unknownCommand = Code(rawValue: "unknown_command")
        public static let badRequest = Code(rawValue: "bad_request")
        public static let notFound = Code(rawValue: "not_found")
        /// A file the app can't take, with why.
        public static let fileRefused = Code(rawValue: "file_refused")
        /// The socket's path is longer than a Unix socket address holds (`AgentSocket.maxPathLength`).
        public static let socketPathTooLong = Code(rawValue: "socket_path_too_long")
        /// The same request ID came with other parameters.
        public static let requestConflict = Code(rawValue: "request_conflict")
    }

    public var code: Code
    public var message: String
    public var retryable: Bool
    public var next: String?

    public init(_ code: Code, message: String, retryable: Bool, next: String? = nil) {
        self.code = code
        self.message = message
        self.retryable = retryable
        self.next = next
    }

    /// Retryable: the person can turn it on, and the same request then works.
    public static let agentsOff = AgentError(
        .agentsOff, message: "Agents are turned off in Jutsu Studio.", retryable: true,
        next: "Ask the person to turn on Settings › Agents › Allow agents in Jutsu Studio, then send the request again."
    )

    public static func unsupportedVersion(_ version: Int) -> AgentError {
        AgentError(
            .unsupportedVersion,
            message: "Protocol version \(version) is not supported; this app speaks \(AgentProtocol.version).",
            retryable: false, next: "Use the jutsu helper inside this Jutsu Studio.app.")
    }

    public static func unknownCommand(_ name: String) -> AgentError {
        AgentError(
            .unknownCommand, message: "Unknown command '\(name.prefix(64))'.", retryable: false,
            next: "Send capabilities to see what this app supports.")
    }

    public static func badRequest(_ reason: String) -> AgentError {
        AgentError(
            .badRequest, message: "Malformed request: \(reason).", retryable: false,
            next: "Fix the arguments as the message says and call the tool again.")
    }

    public static func socketPathTooLong(_ socket: URL) -> AgentError {
        let path = socket.path(percentEncoded: false)
        return AgentError(
            .socketPathTooLong,
            message: "The agent socket's path is \(path.utf8.count) bytes, more than the \(AgentSocket.maxPathLength) "
                + "a Unix socket takes: \(path)",
            retryable: false,
            next: "Agents need a home folder with a shorter path. For development, point \(AgentSocket.variable) at a "
                + "shorter path.")
    }
}
