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
            case .jobs: .success(try Self.jobs(given))
            case .jobAction: .success(try Self.jobAction(given))
            case .show: .success(try Self.show(given))
            }
        } catch {
            return .failure(error)
        }
    }

    private static func capabilities(_ given: Arguments) throws(AgentError) -> AgentCommand {
        try given.allow(["models", "model"])
        let model = try given.string("model")
        if let model, !AgentNames.isValidModelID(model) {
            throw .badRequest("capabilities: model is a model ID, such as seedance25")
        }
        let models = try given.bool("models")
        return .capabilities(CapabilitiesCommand(models: models || model != nil, model: model))
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
        if let count = try given.int("image_count") { video.imageCount = count }
        if let problem = video.problem { throw .badRequest("quote: \(problem)") }
        return .quote(QuoteCommand(video: video))
    }

    private static func createVideo(_ given: Arguments, workingDirectory: URL) throws(AgentError) -> AgentCommand {
        try given.allow(videoKeys.union(["request_id", "max_cost"]))
        guard let requestID = try given.string("request_id") else {
            throw .badRequest("create_video needs request_id, a new ID of your own for each new request")
        }
        guard AgentNames.isValidRequestID(requestID) else { throw .badRequest(AgentNames.requestIDRule) }
        let maxCost = try given.maxCost()
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
            CreateVideoCommand(requestID: requestID, fingerprint: fingerprint, video: video, maxCost: maxCost))
    }

    private static func jobs(_ given: Arguments) throws(AgentError) -> AgentCommand {
        try given.allow(["ids", "limit", "wait_seconds"])
        let ids = try given.strings("ids").map { text throws(AgentError) -> UUID in
            guard let id = UUID(uuidString: text) else { throw .badRequest("jobs: ids are job IDs (UUIDs)") }
            return id
        }
        guard ids.count <= JobsCommand.maxIDs else {
            throw .badRequest("jobs: ids takes at most \(JobsCommand.maxIDs) job IDs")
        }
        let limit = try given.int("limit")
        if let limit, !(1...JobsCommand.maxLimit).contains(limit) {
            throw .badRequest("jobs: limit is 1 to \(JobsCommand.maxLimit)")
        }
        let wait = try given.int("wait_seconds") ?? 0
        guard (0...JobsCommand.maxWaitSeconds).contains(wait) else {
            throw .badRequest("jobs: wait_seconds is 0 to \(JobsCommand.maxWaitSeconds)")
        }
        return .jobs(JobsCommand(ids: ids, limit: limit, waitSeconds: wait))
    }

    private static func jobAction(_ given: Arguments) throws(AgentError) -> AgentCommand {
        try given.allow(["action", "job"])
        guard let name = try given.string("action"), let action = AgentJobAction(rawValue: name) else {
            throw .badRequest("job_action: action is one of \(actionNames)")
        }
        let job = try given.string("job")
        guard action.needsJob == (job != nil) else {
            throw .badRequest(
                action.needsJob
                    ? "job_action: \(action.rawValue) needs job, a job ID"
                    : "job_action: \(action.rawValue) acts on the whole queue and takes no job")
        }
        let id = try job.map { text throws(AgentError) -> UUID in
            guard let id = UUID(uuidString: text) else { throw .badRequest("job_action: job is a job ID") }
            return id
        }
        return .jobAction(JobActionCommand(action: action, job: id))
    }

    private static func show(_ given: Arguments) throws(AgentError) -> AgentCommand {
        try given.allow(["page", "job"])
        switch (try given.string("page"), try given.string("job")) {
        case (let page?, nil):
            guard let page = AgentPage(rawValue: page) else {
                throw .badRequest("show: page is one of \(pageNames)")
            }
            return .show(.page(page))
        case (nil, let job?):
            guard let id = UUID(uuidString: job) else { throw .badRequest("show: job is a job ID (a UUID)") }
            return .show(.job(id))
        default:
            throw .badRequest("show takes exactly one of page (\(pageNames)) or job (a job ID)")
        }
    }

    static let pageNames = AgentPage.allCases.map(\.rawValue).joined(separator: ", ")
    static let actionNames = AgentJobAction.allCases.map(\.rawValue).joined(separator: ", ")

    /// What `quote` and `create_video` both take.
    static let videoKeys: Set<String> = [
        "mode", "model", "prompt", "source", "images", "style", "resolution", "draft", "length", "aspect_ratio",
        "audio", "variants",
    ]

    /// What makes two `create_video` requests the same: the parameters, the files by path and size, and the most the
    /// agent agreed to pay. A file that changed size since makes it another request.
    static func fingerprint(_ video: AgentVideoRequest, maxCost: AgentAmount) throws(AgentError) -> String {
        struct Fingerprinted: Encodable {
            var video: AgentVideoRequest
            var sizes: [Int?]
            var maxCost: AgentAmount
        }
        let files = [video.source?.path].compactMap(\.self) + video.images
        let sizes = files.map { path in
            (try? URL(filePath: path).resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        }
        do {
            return try AgentFingerprint.of(Fingerprinted(video: video, sizes: sizes, maxCost: maxCost))
        } catch {
            throw .badRequest("create_video: the parameters can't be read")
        }
    }
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
            audio: try string("audio"), variants: try int("variants"))
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
