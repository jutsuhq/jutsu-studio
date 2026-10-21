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
    /// The app answers every command within this, under the minute MCP clients usually give a tool call: a `jobs` or
    /// export wait is at most 50 s, and any other command whose work runs longer is answered `still_working` while
    /// the work goes on (`AgentServer`). Long work returns a handle instead (`AgentOperations`).
    public static let answerDeadline = Duration.seconds(55)
    /// How long the helper waits on the socket for each write and for the answer: the answer deadline and a margin
    /// for the line to arrive.
    public static let helperTimeout = answerDeadline + .seconds(5)
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
    /// Makes images, idempotent by its request ID.
    case createImage(CreateImageCommand)
    /// Finds results in the Library, a page at a time.
    case librarySearch(LibrarySearchCommand)
    /// The full details of Library items by ID.
    case libraryGet(LibraryGetCommand)
    /// Sets the culling verdict and the star of Library items.
    case libraryMark(LibraryMarkCommand)
    /// Queues an Enhance operation on a video result, idempotent by its request ID.
    case enhance(EnhanceCommand)
    /// Makes, lists or exports delivery sets.
    case deliverySet(DeliverySetCommand)
    /// Exports video results for editing.
    case export(ExportCommand)

    public var name: String {
        switch self {
        case .capabilities: "capabilities"
        case .show: "show"
        case .upload: "upload"
        case .quote: "quote"
        case .createVideo: "create_video"
        case .jobs: "jobs"
        case .jobAction: "job_action"
        case .createImage: "create_image"
        case .librarySearch: "library_search"
        case .libraryGet: "library_get"
        case .libraryMark: "library_mark"
        case .enhance: "enhance"
        case .deliverySet: "delivery_set"
        case .export: "export"
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
        case "create_image": command = .createImage(try .checked(from: decoder))
        case "library_search": command = .librarySearch(try .checked(from: decoder))
        case "library_get": command = .libraryGet(try .checked(from: decoder))
        case "library_mark": command = .libraryMark(try .checked(from: decoder))
        case "enhance": command = .enhance(try .checked(from: decoder))
        case "delivery_set": command = .deliverySet(try .checked(from: decoder))
        case "export": command = .export(try .checked(from: decoder))
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
        case .createImage(let fields): try fields.encode(to: encoder)
        case .librarySearch(let fields): try fields.encode(to: encoder)
        case .libraryGet(let fields): try fields.encode(to: encoder)
        case .libraryMark(let fields): try fields.encode(to: encoder)
        case .enhance(let fields): try fields.encode(to: encoder)
        case .deliverySet(let fields): try fields.encode(to: encoder)
        case .export(let fields): try fields.encode(to: encoder)
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
    /// create_video, create_image and enhance: the jobs the request queued.
    public var created: AgentCreated?
    public var jobs: AgentJobs?
    /// job_action: what was done.
    public var acted: AgentActed?
    /// library_search: a page of results.
    public var library: AgentLibraryPage?
    /// library_get: the items in full.
    public var details: AgentLibraryDetailsPage?
    /// library_mark: the items as they are now.
    public var marked: AgentMarked?
    public var delivery: AgentDelivery?
    public var exported: AgentExported?
    public var error: AgentError?

    public init(
        id: String? = nil, capabilities: AgentCapabilities? = nil, shown: AgentShown? = nil, uploaded: String? = nil,
        quote: AgentQuote? = nil, created: AgentCreated? = nil, jobs: AgentJobs? = nil, acted: AgentActed? = nil,
        library: AgentLibraryPage? = nil, details: AgentLibraryDetailsPage? = nil, marked: AgentMarked? = nil,
        delivery: AgentDelivery? = nil, exported: AgentExported? = nil, error: AgentError? = nil
    ) {
        self.id = id
        self.capabilities = capabilities
        self.shown = shown
        self.uploaded = uploaded
        self.quote = quote
        self.created = created
        self.jobs = jobs
        self.acted = acted
        self.library = library
        self.details = details
        self.marked = marked
        self.delivery = delivery
        self.exported = exported
        self.error = error
    }
}
