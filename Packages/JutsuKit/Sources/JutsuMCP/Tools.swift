import Foundation
import HiggsfieldMCP
import JutsuAgent

/// The MCP tools, one per app command, in the order `tools/list` gives them. Arguments are snake_case, as MCP tools
/// usually are; the app's answer keeps its own camelCase JSON.
enum Tool: String, CaseIterable {
    case capabilities, quote
    case createVideo = "create_video"
    case jobs
    case jobAction = "job_action"
    case createImage = "create_image"
    case elements
    case librarySearch = "library_search"
    case libraryGet = "library_get"
    case libraryDownload = "library_download"
    case libraryMark = "library_mark"
    case enhance
    case deliverySet = "delivery_set"
    case export
    case frames
    case show

    /// The command for these arguments, or the tool error that tells the model what to fix. Checked here before
    /// anything reaches the app, and again by the app as it decodes the command. `create_video` names the agent's own
    /// files here; `MCPServer` hands them to the app before it sends the command.
    func command(
        _ arguments: [String: JSONValue], workingDirectory: URL = Inbox().workingDirectory
    )
        -> Result<AgentCommand, AgentError>
    {
        do throws(AgentError) {
            let given = Arguments(tool: rawValue, values: arguments)
            return switch self {
            case .capabilities: .success(try Self.capabilities(given))
            case .quote: .success(try Self.quote(given))
            case .createVideo: .success(try Self.createVideo(given, workingDirectory: workingDirectory))
            case .createImage: .success(try Self.createImage(given, workingDirectory: workingDirectory))
            case .jobs: .success(try Self.jobs(given))
            case .jobAction: .success(try Self.jobAction(given))
            case .librarySearch: .success(try Self.librarySearch(given))
            case .libraryGet: .success(try Self.libraryGet(given))
            case .elements: .success(try Self.elements(given))
            case .libraryDownload: .success(try Self.libraryDownload(given))
            case .libraryMark: .success(try Self.libraryMark(given))
            case .enhance: .success(try Self.enhance(given))
            case .deliverySet: .success(try Self.deliverySet(given))
            case .export: .success(try Self.export(given))
            case .frames: .success(try Self.frames(given, workingDirectory: workingDirectory))
            case .show: .success(try Self.show(given))
            }
        } catch {
            return .failure(error)
        }
    }

    private static func capabilities(_ given: Arguments) throws(AgentError) -> AgentCommand {
        try given.allow(["models", "model", "image_models", "styles", "voices"])
        let model = try given.string("model")
        if let problem = CapabilitiesCommand.problem(model: model) { throw .badRequest("capabilities: \(problem)") }
        let models = try given.bool("models")
        return .capabilities(
            CapabilitiesCommand(
                models: models || model != nil, model: model, imageModels: try given.bool("image_models"),
                styles: try given.bool("styles"), voices: try given.bool("voices")))
    }

    private static func quote(_ given: Arguments) throws(AgentError) -> AgentCommand {
        try given.allow(videoKeys.union(["image_count"]))
        var video = try given.video()
        // A quote reads no file: only how many images there are counts.
        if !video.images.isEmpty, try given.int("image_count") == nil {
            video.imageCount = video.images.count
        }
        video.images = []
        video.source?.path = nil
        video.title = nil
        if let count = try given.int("image_count") { video.imageCount = count }
        if let problem = video.problem { throw .badRequest("quote: \(problem)") }
        return .quote(QuoteCommand(video: video))
    }

    private static func createVideo(_ given: Arguments, workingDirectory: URL) throws(AgentError) -> AgentCommand {
        try given.allow(videoKeys.union(["request_id", "max_cost", "wait_seconds"]))
        let requestID = try given.requestID()
        let maxCost = try given.maxCost()
        let wait = try given.int("wait_seconds") ?? 0
        if let problem = JobsCommand.waitProblem(wait) { throw .badRequest("create_video: \(problem)") }
        var video = try given.video()
        if let problem = video.problem { throw .badRequest("create_video: \(problem)") }
        if video.imageCount != nil { throw .badRequest("create_video takes images, the files, not a count") }
        // The agent's paths as files on this Mac, so the same files always give the same fingerprint.
        let local = { (path: String) in Inbox.resolve(path, from: workingDirectory).path(percentEncoded: false)
        }
        if let path = video.source?.path { video.source?.path = local(path) }
        video.images = video.images.map(local)
        let fingerprint = try Self.fingerprint(video, maxCost: maxCost)
        return .createVideo(
            CreateVideoCommand(
                requestID: requestID, fingerprint: fingerprint, parameters: try Self.parameters(video), video: video,
                maxCost: maxCost, waitSeconds: wait))
    }

    private static func jobs(_ given: Arguments) throws(AgentError) -> AgentCommand {
        try given.allow(["ids", "limit", "wait_seconds", "cursor"])
        let ids = try given.strings("ids").map { text throws(AgentError) -> UUID in
            guard let id = UUID(uuidString: text) else { throw .badRequest("jobs: ids are job IDs (UUIDs)") }
            return id
        }
        let limit = try given.int("limit")
        let wait = try given.int("wait_seconds") ?? 0
        let cursor = try given.string("cursor")
        if let problem = JobsCommand.problem(idCount: ids.count, limit: limit, waitSeconds: wait, cursor: cursor) {
            throw .badRequest("jobs: \(problem)")
        }
        return .jobs(JobsCommand(ids: ids, limit: limit, waitSeconds: wait, cursor: cursor))
    }

    private static func jobAction(_ given: Arguments) throws(AgentError) -> AgentCommand {
        try given.allow(["action", "job"])
        guard let name = try given.string("action"), let action = AgentJobAction(rawValue: name) else {
            throw .badRequest("job_action: action is one of \(actionNames)")
        }
        let job = try given.string("job")
        if let problem = JobActionCommand.problem(action: action, hasJob: job != nil) {
            throw .badRequest("job_action: \(problem)")
        }
        let id = try job.map { text throws(AgentError) -> UUID in
            guard let id = UUID(uuidString: text) else { throw .badRequest("job_action: job is a job ID") }
            return id
        }
        return .jobAction(JobActionCommand(action: action, job: id))
    }

    private static func show(_ given: Arguments) throws(AgentError) -> AgentCommand {
        try given.allow(["page", "job", "item", "sheet"])
        let (page, job) = (try given.string("page"), try given.string("job"))
        let (item, sheet) = (try given.string("item"), try given.string("sheet"))
        if let problem = ShowCommand.problem(
            hasPage: page != nil, hasJob: job != nil, hasItem: item != nil, hasSheet: sheet != nil)
        {
            throw .badRequest(problem)
        }
        if let page {
            guard let page = AgentPage(rawValue: page) else { throw .badRequest("show: page is one of \(pageNames)") }
            return .show(.page(page))
        }
        if let item, let sheet {
            guard let id = UUID(uuidString: item) else { throw .badRequest("show: item is a Library item ID") }
            guard let sheet = AgentSheet(rawValue: sheet) else {
                let names = AgentSheet.allCases.map(\.rawValue).joined(separator: ", ")
                throw .badRequest("show: sheet is one of \(names)")
            }
            return .show(.sheet(sheet, item: id))
        }
        guard let id = job.flatMap(UUID.init(uuidString:)) else { throw .badRequest("show: job is a job ID (a UUID)") }
        return .show(.job(id))
    }

    static let pageNames = AgentPage.allCases.map(\.rawValue).joined(separator: ", ")
    static let actionNames = AgentJobAction.allCases.map(\.rawValue).joined(separator: ", ")

    /// What `quote` and `create_video` both take.
    static let videoKeys: Set<String> = [
        "mode", "model", "prompt", "source", "images", "style", "resolution", "draft", "length", "aspect_ratio",
        "audio", "variants", "elements", "title",
    ]

    /// What makes two `create_video` requests the same: the parameters, the files by path and size, and the most the
    /// agent agreed to pay. A file that changed size since makes it another request.
    static func fingerprint(_ video: AgentVideoRequest, maxCost: AgentAmount) throws(AgentError) -> String {
        struct Fingerprinted: Encodable {
            var video: AgentVideoRequest
            var sizes: [Int?]
            var maxCost: AgentAmount
        }
        let sizes = Self.sizes([video.source?.path].compactMap(\.self) + video.images)
        do {
            return try AgentFingerprint.of(Fingerprinted(video: video, sizes: sizes, maxCost: maxCost))
        } catch {
            throw .badRequest("create_video: the parameters can't be read")
        }
    }

    /// The files' sizes, `nil` for one that can't be read: a file that changed size makes another request.
    static func sizes(_ files: [String]) -> [Int?] {
        files.map { path in (try? URL(filePath: path).resourceValues(forKeys: [.fileSizeKey]))?.fileSize }
    }

    /// The same as `fingerprint` without `max_cost`: what a `create_video` sent again with a higher `max_cost` shares
    /// with the request it raises.
    static func parameters(_ video: AgentVideoRequest) throws(AgentError) -> String {
        struct Parameters: Encodable {
            var video: AgentVideoRequest
            var sizes: [Int?]
        }
        let sizes = Self.sizes([video.source?.path].compactMap(\.self) + video.images)
        do {
            return try AgentFingerprint.of(Parameters(video: video, sizes: sizes))
        } catch {
            throw .badRequest("create_video: the parameters can't be read")
        }
    }

    /// The fingerprint of another paid tool's request: the tool, its parameters, its files by size and `max_cost`.
    /// The tool is part of it, so one request ID never means two tools' requests.
    /// `maxCost` is `nil` for a free run, and is then left out.
    static func fingerprint(
        _ tool: String, _ fields: some Encodable, files: [String], _ maxCost: AgentAmount?
    ) throws(AgentError) -> String {
        let sizes = Self.sizes(files)
        do {
            return try AgentFingerprint.of(ToolFingerprint(tool: tool, fields: fields, sizes: sizes, maxCost: maxCost))
        } catch {
            throw .badRequest("\(tool): the parameters can't be read")
        }
    }
}

/// What a paid tool's fingerprint is made of (`Tool.fingerprint`).
private struct ToolFingerprint<Fields: Encodable>: Encodable {
    var tool: String
    var fields: Fields
    var sizes: [Int?]
    var maxCost: AgentAmount?
}

/// A tool's arguments, read strictly: a key the tool doesn't take or a value of the wrong type is an error that
/// names it, never a crash or a silent default.
struct Arguments {
    let tool: String
    let values: [String: JSONValue]

    func allow(_ keys: Set<String>) throws(AgentError) {
        if let unknown = values.keys.sorted().first(where: { !keys.contains($0) }) {
            let known = keys.sorted().joined(separator: ", ")
            throw .badRequest("\(tool) takes \(known.isEmpty ? "no arguments" : known), not '\(unknown.prefix(64))'")
        }
    }

    /// nil when left out or null.
    func string(_ key: String) throws(AgentError) -> String? {
        switch values[key] {
        case nil, .null?: return nil
        case .string(let value)?: return value
        default: throw .badRequest("\(tool): \(key) is a string")
        }
    }

    /// `false` when left out or null.
    func bool(_ key: String) throws(AgentError) -> Bool {
        switch values[key] {
        case nil, .null?: return false
        case .bool(let value)?: return value
        default: throw .badRequest("\(tool): \(key) is true or false")
        }
    }

    /// A finite number; nil when left out or null.
    func number(_ key: String) throws(AgentError) -> Double? {
        switch values[key] {
        case nil, .null?: return nil
        case let value?:
            guard let number = value.numberValue, number.isFinite else {
                throw .badRequest("\(tool): \(key) is a number")
            }
            return number
        }
    }

    /// A whole number that fits; nil when left out or null.
    func int(_ key: String) throws(AgentError) -> Int? {
        guard let number = try number(key) else { return nil }
        guard number.rounded() == number, abs(number) < 1e15 else {
            throw .badRequest("\(tool): \(key) is a whole number")
        }
        return Int(number)
    }

    /// nil when left out or null, unlike `bool`.
    // swiftlint:disable:next discouraged_optional_boolean
    func optionalBool(_ key: String) throws(AgentError) -> Bool? {
        switch values[key] {
        case nil, .null?: return nil
        case .bool(let value)?: return value
        default: throw .badRequest("\(tool): \(key) is true or false")
        }
    }

    /// An ISO 8601 date and time, such as 2026-10-21T09:00:00Z; nil when left out or null.
    func date(_ key: String) throws(AgentError) -> Date? {
        guard let text = try string(key) else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = ISO8601DateFormatter().date(from: text) ?? withFraction.date(from: text) else {
            throw .badRequest("\(tool): \(key) is an ISO 8601 date and time, such as 2026-10-21T09:00:00Z")
        }
        return date
    }

    /// Library item IDs; empty when left out or null.
    func ids(_ key: String) throws(AgentError) -> [UUID] {
        try strings(key).map { text throws(AgentError) -> UUID in
            guard let id = UUID(uuidString: text) else { throw .badRequest("\(tool): \(key) are Library item IDs") }
            return id
        }
    }

    /// `request_id`, which every paid tool needs.
    func requestID() throws(AgentError) -> String {
        guard let requestID = try string("request_id") else {
            throw .badRequest("\(tool) needs request_id, a new ID of your own for each new request")
        }
        guard AgentNames.isValidRequestID(requestID) else { throw .badRequest(AgentNames.requestIDRule) }
        return requestID
    }

    /// Empty when left out or null.
    func strings(_ key: String) throws(AgentError) -> [String] {
        switch values[key] {
        case nil, .null?: return []
        case .array(let items)?:
            return try items.map { item throws(AgentError) -> String in
                guard case .string(let text) = item else { throw .badRequest("\(tool): \(key) is a list of strings") }
                return text
            }
        default: throw .badRequest("\(tool): \(key) is a list of strings")
        }
    }

    /// nil when left out or null.
    func object(_ key: String) throws(AgentError) -> Arguments? {
        switch values[key] {
        case nil, .null?: return nil
        case .object(let fields)?: return Arguments(tool: "\(tool): \(key)", values: fields)
        default: throw .badRequest("\(tool): \(key) is an object")
        }
    }

    /// The video fields `quote` and `create_video` share.
    func video() throws(AgentError) -> AgentVideoRequest {
        guard let mode = try string("mode") else {
            throw .badRequest("\(tool) needs mode, one of \(AgentVideoRequest.modes.joined(separator: ", "))")
        }
        var source: AgentSource?
        if let fields = try object("source") {
            try fields.allow(["path", "start", "end"])
            let start = try fields.number("start")
            let end = try fields.number("end")
            if let problem = AgentSource.problem(start: start, end: end) { throw .badRequest(problem) }
            source = AgentSource(path: try fields.string("path"), start: start, end: end)
        }
        let style = try string("style").map { text throws(AgentError) -> UUID in
            guard let id = UUID(uuidString: text) else { throw .badRequest("\(tool): style is a style ID (a UUID)") }
            return id
        }
        return AgentVideoRequest(
            mode: mode, model: try string("model"), prompt: try string("prompt"), source: source,
            images: try strings("images"), style: style, resolution: try string("resolution"),
            draft: try bool("draft"), length: try number("length"), aspectRatio: try string("aspect_ratio"),
            audio: try string("audio"), variants: try int("variants"), elements: try strings("elements"),
            title: try string("title"))
    }

    /// `max_cost` as whole units: dollars become cents, rounded down so the job never costs more than was said.
    func maxCost() throws(AgentError) -> AgentAmount {
        guard let fields = try object("max_cost") else {
            throw .badRequest(
                "\(tool) needs max_cost, {amount, unit}: the most you agree to pay, in usd or credits as capabilities "
                    + "says")
        }
        try fields.allow(["amount", "unit"])
        guard let amount = try fields.number("amount"), amount >= 0 else {
            throw .badRequest("\(tool): max_cost.amount is a number, 0 or more")
        }
        switch try fields.string("unit") {
        case "usd"?:
            let most = Double(AgentAmount.maximum(for: .usdCents))
            let cents = (amount * 100).rounded(.down)
            guard cents <= most else { throw .badRequest("\(tool): max_cost is at most $\(Int(most / 100))") }
            return AgentAmount(Int(cents), .usdCents)
        case "credits"?:
            let most = Double(AgentAmount.maximum(for: .credits))
            guard amount <= most else { throw .badRequest("\(tool): max_cost is at most \(Int(most)) credits") }
            return AgentAmount(Int(amount.rounded(.down)), .credits)
        default:
            throw .badRequest("\(tool): max_cost.unit is usd or credits")
        }
    }
}
