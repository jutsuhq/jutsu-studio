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
        /// The request ID was already used with these parameters: its files aren't needed again, the job exists.
        public static let requestKnown = Code(rawValue: "request_known")
        /// Nothing is connected to Higgsfield.
        public static let notConnected = Code(rawValue: "not_connected")
        /// The request breaks the model's rules or limits; the message says which.
        public static let invalidRequest = Code(rawValue: "invalid_request")
        /// Over the person's own daily spend cap: only they can raise it or start the job.
        public static let overCap = Code(rawValue: "over_cap")
        /// Only the person can do this, in the app.
        public static let needsPerson = Code(rawValue: "needs_person")
        /// The job is in a state the action doesn't apply to.
        public static let notApplicable = Code(rawValue: "not_applicable")
        /// The app failed to do it; the message says why.
        public static let failed = Code(rawValue: "failed")
        /// Higgsfield prices the operation only after it has run, so no agent can stay within a max_cost for it.
        public static let pricedAfterRun = Code(rawValue: "priced_after_run")
        /// This Mac can't run the engine: its macOS or its hardware lacks it.
        public static let engineUnavailable = Code(rawValue: "engine_unavailable")
        /// The item has a run going already; the message names it.
        public static let busy = Code(rawValue: "busy")
        /// The command's work took longer than the app answers within (`AgentProtocol.answerDeadline`); it goes on.
        public static let stillWorking = Code(rawValue: "still_working")
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

    public static func invalidRequest(_ reason: String) -> AgentError {
        AgentError(
            .invalidRequest, message: reason, retryable: false,
            next: "Change the request as the message says; capabilities with models true lists each model's limits.")
    }

    /// Nothing is stopped: a request with a `request_id` sent again returns what it made, once it has.
    public static func stillWorking(_ command: String) -> AgentError {
        AgentError(
            .stillWorking,
            message: "Jutsu Studio is still working on \(command); it goes on without this answer.", retryable: true,
            next: "Send the same request again in a moment (the same request_id returns what it made), or call jobs.")
    }

    public static let requestConflict = AgentError(
        .requestConflict, message: "This request_id was already used with other parameters.", retryable: false,
        next: "Use a new request_id for a different request, or send exactly the same parameters to get its job.")

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
