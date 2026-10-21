import Foundation

/// The commands an agent can send the app, shared by the app and the `jutsu` helper. One JSON object per line each
/// way over a Unix socket: a request, then its response, in order.
///
/// ```
/// → {"version":1,"id":"1","client":"claude-code","command":"show","page":"queue"}
/// ← {"id":"1","shown":{"page":"queue"}}
/// ```
///
/// A new command is a case here, a payload type with its own fields, and a result field in `AgentResponse`; nothing
/// that exists changes shape.
public enum AgentProtocol {
    /// Raised only for a change an older peer would misread; new commands and new optional fields don't need it.
    public static let version = 1
    /// A request line longer than this is refused rather than buffered: no command needs more. An upload's bytes
    /// follow its line and don't count (`AgentInbox.maxFileSize`).
    public static let maxLineLength = 64 * 1024
}

public enum AgentCommand: Equatable, Sendable {
    /// What the app can do now: the connection, credits, the agent budget and the tool groups.
    case capabilities(CapabilitiesCommand)
    /// Opens a page or a job in the app window and brings the window forward.
    case show(ShowCommand)
    /// A file for the inbox, its bytes after the line. Only the helper sends it, for a tool that takes a file.
    case upload(UploadCommand)
    /// What a video would cost, without queueing it.
    case quote(QuoteCommand)
    /// Queues a video, idempotent by its request ID.
    case createVideo(CreateVideoCommand)
    /// The state of jobs, optionally once they settle.
    case jobs(JobsCommand)
    /// Cancel, retry or run a job next, or pause or resume the queue.
    case jobAction(JobActionCommand)

    public var name: String {
        switch self {
        case .capabilities: "capabilities"
        case .show: "show"
        case .upload: "upload"
        case .quote: "quote"
        case .createVideo: "create_video"
        case .jobs: "jobs"
        case .jobAction: "job_action"
        }
    }
}

public struct AgentRequest: Codable, Equatable, Sendable {
    public var version: Int
    /// Echoed in the response, so a client can match them up.
    public var id: String?
    /// The agent's name as its MCP client reports it (`clientInfo`), for the person to see where a job came from.
    public var client: String?
    public var command: AgentCommand

    public init(_ command: AgentCommand, id: String? = nil, client: String? = nil, version: Int = AgentProtocol.version)
    {
        self.version = version
        self.id = id
        self.client = client
        self.command = command
    }

    /// Flat, with `command` naming the rest of the keys: what a person types into `nc -U` too.
    private enum CodingKeys: String, CodingKey {
        case version, id, client, command
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        id = try container.decodeIfPresent(String.self, forKey: .id)
        client = try container.decodeIfPresent(String.self, forKey: .client)
        let name = try container.decode(String.self, forKey: .command)
        // The commands' own fields sit next to version, id and command.
        switch name {
        case "capabilities": command = .capabilities(try CapabilitiesCommand(from: decoder))
        case "show": command = .show(try ShowCommand(from: decoder))
        case "upload": command = .upload(try UploadCommand(from: decoder))
        case "quote": command = .quote(try QuoteCommand(from: decoder))
        case "create_video": command = .createVideo(try CreateVideoCommand(from: decoder))
        case "jobs": command = .jobs(try JobsCommand(from: decoder))
        case "job_action": command = .jobAction(try JobActionCommand(from: decoder))
        default: throw AgentError.unknownCommand(name)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encodeIfPresent(id, forKey: .id)
        try container.encodeIfPresent(client, forKey: .client)
        try container.encode(command.name, forKey: .command)
        switch command {
        case .capabilities(let fields): try fields.encode(to: encoder)
        case .show(let fields): try fields.encode(to: encoder)
        case .upload(let fields): try fields.encode(to: encoder)
        case .quote(let fields): try fields.encode(to: encoder)
        case .createVideo(let fields): try fields.encode(to: encoder)
        case .jobs(let fields): try fields.encode(to: encoder)
        case .jobAction(let fields): try fields.encode(to: encoder)
        }
    }
}

/// Exactly one of the result fields or `error` is set.
public struct AgentResponse: Codable, Equatable, Sendable {
    public var id: String?
    public var capabilities: AgentCapabilities?
    /// show: what the window now shows.
    public var shown: AgentShown?
    /// upload: where the app put the file, a path inside its inbox.
    public var uploaded: String?
    public var quote: AgentQuote?
    /// create_video: the jobs the request queued.
    public var created: AgentCreated?
    public var jobs: AgentJobs?
    /// job_action: what was done.
    public var acted: AgentActed?
    public var error: AgentError?

    public init(
        id: String? = nil, capabilities: AgentCapabilities? = nil, shown: AgentShown? = nil, uploaded: String? = nil,
        quote: AgentQuote? = nil, created: AgentCreated? = nil, jobs: AgentJobs? = nil, acted: AgentActed? = nil,
        error: AgentError? = nil
    ) {
        self.id = id
        self.capabilities = capabilities
        self.shown = shown
        self.uploaded = uploaded
        self.quote = quote
        self.created = created
        self.jobs = jobs
        self.acted = acted
        self.error = error
    }
}
