import Foundation

// The fields of each command and the answers they get. Each type checks its own fields as it decodes, so the app
// refuses a malformed command with `bad_request` before any of it runs, whatever sent it.

/// The pages `show` can open, by the names the sidebar uses.
public enum AgentPage: String, Codable, Sendable, CaseIterable {
    case create, queue, library, settings
}

public struct CapabilitiesCommand: Codable, Equatable, Sendable {
    /// Lists the video models; left out, the answer stays short.
    public var models: Bool
    /// Only this model, by its ID; implies `models`.
    public var model: String?
    /// Lists the connection's image models, which `create_image` takes.
    public var imageModels: Bool
    /// Lists Restyle's styles from the catalog Create last read.
    public var styles: Bool
    /// Lists the voices Change Voice offers on an account.
    public var voices: Bool

    public init(
        models: Bool = false, model: String? = nil, imageModels: Bool = false, styles: Bool = false,
        voices: Bool = false
    ) {
        self.models = models
        self.model = model
        self.imageModels = imageModels
        self.styles = styles
        self.voices = voices
    }

    private enum CodingKeys: String, CodingKey {
        case models, model, imageModels, styles, voices
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        models = try container.decodeIfPresent(Bool.self, forKey: .models) ?? false
        model = try container.decodeIfPresent(String.self, forKey: .model)
        imageModels = try container.decodeIfPresent(Bool.self, forKey: .imageModels) ?? false
        styles = try container.decodeIfPresent(Bool.self, forKey: .styles) ?? false
        voices = try container.decodeIfPresent(Bool.self, forKey: .voices) ?? false
        if let problem = Self.problem(model: model) { throw AgentError.badRequest(problem) }
    }

    /// Why `model` can't name a model; nil when it can. Shared by the helper and the app.
    public static func problem(model: String?) -> String? {
        guard let model, !AgentNames.isValidModelID(model) else { return nil }
        return "model is a model ID, such as seedance25"
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if models { try container.encode(models, forKey: .models) }
        try container.encodeIfPresent(model, forKey: .model)
        if imageModels { try container.encode(imageModels, forKey: .imageModels) }
        if styles { try container.encode(styles, forKey: .styles) }
        if voices { try container.encode(voices, forKey: .voices) }
    }
}

/// The sheets `show` can open for a Library item.
public enum AgentSheet: String, Codable, Sendable, CaseIterable {
    /// Upscale on This Mac, where the person agrees to macOS downloading its model.
    case upscaleOnMac = "upscale_on_mac"
}

/// Exactly one of `page`, `job` or `item`; `item` comes with `sheet`.
public struct ShowCommand: Codable, Equatable, Sendable {
    public var page: AgentPage?
    /// A job's ID: a finished one opens its result in Library, any other its row in the Queue.
    public var job: UUID?
    /// A Library item, which `sheet` is opened for.
    public var item: UUID?
    public var sheet: AgentSheet?

    public static func page(_ page: AgentPage) -> ShowCommand { ShowCommand(page: page) }
    public static func job(_ id: UUID) -> ShowCommand { ShowCommand(job: id) }
    public static func sheet(_ sheet: AgentSheet, item: UUID) -> ShowCommand { ShowCommand(item: item, sheet: sheet) }

    private init(page: AgentPage? = nil, job: UUID? = nil, item: UUID? = nil, sheet: AgentSheet? = nil) {
        self.page = page
        self.job = job
        self.item = item
        self.sheet = sheet
    }

    private enum CodingKeys: String, CodingKey {
        case page, job, item, sheet
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        page = try container.decodeIfPresent(AgentPage.self, forKey: .page)
        job = try container.decodeIfPresent(UUID.self, forKey: .job)
        item = try container.decodeIfPresent(UUID.self, forKey: .item)
        sheet = try container.decodeIfPresent(AgentSheet.self, forKey: .sheet)
        if let problem = Self.problem(
            hasPage: page != nil, hasJob: job != nil, hasItem: item != nil, hasSheet: sheet != nil)
        {
            throw AgentError.badRequest(problem)
        }
    }

    /// Why `show` can't open these; nil when it can. It names the tool itself, so the helper sends it as it is.
    public static func problem(hasPage: Bool, hasJob: Bool, hasItem: Bool = false, hasSheet: Bool = false) -> String? {
        if [hasPage, hasJob, hasItem].filter(\.self).count != 1 {
            let pages = AgentPage.allCases.map(\.rawValue).joined(separator: ", ")
            return "show takes exactly one of page (\(pages)), job (a job ID) or item (a Library item ID, with sheet)"
        }
        guard hasItem == hasSheet else {
            let sheets = AgentSheet.allCases.map(\.rawValue).joined(separator: ", ")
            return "show opens a sheet for an item: send item with sheet (\(sheets))"
        }
        return nil
    }
}

/// What `show` opened.
public struct AgentShown: Codable, Equatable, Sendable {
    public var page: AgentPage
    public var job: UUID?
    public var item: UUID?
    public var sheet: AgentSheet?

    public init(page: AgentPage, job: UUID? = nil, item: UUID? = nil, sheet: AgentSheet? = nil) {
        self.page = page
        self.job = job
        self.item = item
        self.sheet = sheet
    }
}

/// A file an agent named, sent by the helper as `size` raw bytes right after this line. The app stores it in a
/// folder of its own in the inbox (`AgentInbox`) and answers with the copy's path, which the command that needs the
/// file then names.
public struct UploadCommand: Codable, Equatable, Sendable {
    /// The file's own name, kept so its extension says what it is.
    public var name: String
    public var size: Int64
    /// The request the file belongs to. The app checks it before reading a single byte, so a request ID that is
    /// already taken by other parameters is refused while the files it would bring stay unread.
    public var request: UploadRequest?

    public init(name: String, size: Int64, request: UploadRequest? = nil) {
        self.name = name
        self.size = size
        self.request = request
    }

    private enum CodingKeys: String, CodingKey {
        case name, size, request
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        size = try container.decode(Int64.self, forKey: .size)
        request = try container.decodeIfPresent(UploadRequest.self, forKey: .request)
        if let problem = Self.problem(name: name, size: size) { throw AgentError.badRequest(problem) }
    }

    /// Why an upload of `name` with `size` bytes can't be taken, checked by the helper before it reads the file and
    /// by the app before it reads the bytes; nil when it can.
    public static func problem(name: String, size: Int64) -> String? {
        guard AgentNames.isValidFileName(name) else { return "name is one file name, not hidden" }
        guard (0...AgentInbox.maxFileSize).contains(size) else {
            return "size is 0 to \(AgentInbox.maxFileSize >> 30) GiB"
        }
        return nil
    }
}

/// Names the request an upload is for: the command, the agent's `request_id` and a digest of the parameters, so the
/// app can tell a retry of the same request from a reused ID.
public struct UploadRequest: Codable, Equatable, Hashable, Sendable {
    public var command: String
    public var requestID: String
    /// Lowercase hex SHA-256 of the request's parameters as the helper normalized them.
    public var fingerprint: String
    /// `create_video`'s digest without `max_cost` (`CreateVideoCommand.parameters`): the request sent again with
    /// another `max_cost` needs no file again either.
    public var parameters: String?

    public init(command: String, requestID: String, fingerprint: String, parameters: String? = nil) {
        self.command = command
        self.requestID = requestID
        self.fingerprint = fingerprint
        self.parameters = parameters
    }

    private enum CodingKeys: String, CodingKey {
        case command
        case requestID = "requestId"
        case fingerprint, parameters
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        command = try container.decode(String.self, forKey: .command)
        requestID = try container.decode(String.self, forKey: .requestID)
        fingerprint = try container.decode(String.self, forKey: .fingerprint)
        parameters = try container.decodeIfPresent(String.self, forKey: .parameters)
        guard AgentNames.isValidRequestID(requestID) else { throw AgentError.badRequest(AgentNames.requestIDRule) }
        guard AgentNames.isValidFingerprint(fingerprint), parameters.map(AgentNames.isValidFingerprint) ?? true else {
            throw AgentError.badRequest("fingerprint is 64 lowercase hex digits")
        }
    }
}

/// The rules for the names and IDs agents send, shared by the helper and the app.
public enum AgentNames {
    /// `number` as the messages write it, with a space between thousands: 10 000.
    public static func spaced(_ number: Int) -> String {
        var digits = Array(String(number))
        var index = digits.count - 3
        while index > 0 {
            digits.insert(" ", at: index)
            index -= 3
        }
        return String(digits)
    }

    public static let requestIDRule = "request_id takes 1–64 letters, digits, '.', '_' or '-', not starting with '.'"

    /// A request ID: no path separators and no leading dot, so it is also safe as a file or folder name.
    public static func isValidRequestID(_ id: String) -> Bool {
        (1...64).contains(id.utf8.count) && !id.hasPrefix(".") && id.utf8.allSatisfy(isNameByte)
    }

    /// A model ID as `models.json` spells them.
    public static func isValidModelID(_ id: String) -> Bool { isValidRequestID(id) }

    /// One path component up to 255 bytes that isn't hidden.
    public static func isValidFileName(_ name: String) -> Bool {
        (1...255).contains(name.utf8.count) && !name.hasPrefix(".") && !name.contains("/") && !name.contains("\0")
    }

    public static func isValidFingerprint(_ text: String) -> Bool {
        text.utf8.count == 64 && text.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }

    static func isNameByte(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "-"): true
        default: false
        }
    }
}
