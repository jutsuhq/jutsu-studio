import Foundation

// subtitles: the Subtitles sheet and editor of a video's current version, free on this Mac.

public enum AgentSubtitlesAction: String, Codable, Sendable, CaseIterable {
    /// Hears the item's speech and saves the cues on its current version: a run, followed with `jobs`.
    case make
    /// The current version's cues, and with `format` their file's text.
    case get
    /// Writes the cues as a file into the output folder's Exports folder.
    case export
}

/// The speech models `make` takes, by the names agents use.
public enum AgentSubtitleEngine: String, Codable, Sendable, CaseIterable {
    case auto
    case builtIn = "built_in"
    case parakeet

    public static let names = allCases.map(\.rawValue).joined(separator: ", ")
}

public enum AgentSubtitleFormat: String, Codable, Sendable, CaseIterable {
    case srt, vtt
}

/// `subtitles` on one video of the Library. `make` is idempotent by its request ID, like `enhance` on this Mac, and
/// free; `get` and `export` read what the current version has.
public struct SubtitlesCommand: Codable, Equatable, Sendable, AgentFields {
    /// The longest language identifier taken, "zh-Hant-TW" and longer with room to spare.
    public static let maxLanguageLength = 35

    public var action: AgentSubtitlesAction
    /// A video's Library ID.
    public var item: UUID
    /// make: your own new ID for the request.
    public var requestID: String?
    /// make: `AgentFingerprint` of its parameters.
    public var fingerprint: String?
    /// make: BCP 47, such as en-US, or a language code, such as de; the person's last or system language when left
    /// out.
    public var language: String?
    /// make: one of `AgentSubtitleEngine`; the person's default from Settings when left out.
    public var engine: AgentSubtitleEngine?
    /// get: adds the cues' file text; export: the file's format, needed.
    public var format: AgentSubtitleFormat?

    public init(
        action: AgentSubtitlesAction, item: UUID, requestID: String? = nil, fingerprint: String? = nil,
        language: String? = nil, engine: AgentSubtitleEngine? = nil, format: AgentSubtitleFormat? = nil
    ) {
        self.action = action
        self.item = item
        self.requestID = requestID
        self.fingerprint = fingerprint
        self.language = language
        self.engine = engine
        self.format = format
    }

    private enum CodingKeys: String, CodingKey {
        case requestID = "requestId"
        case action, item, fingerprint, language, engine, format
    }

    public var problem: String? {
        switch action {
        case .make:
            guard let requestID, AgentNames.isValidRequestID(requestID) else { return AgentNames.requestIDRule }
            guard let fingerprint, AgentNames.isValidFingerprint(fingerprint) else {
                return "fingerprint is 64 lowercase hex digits"
            }
            if format != nil { return "make takes no format; get and export do" }
            if let language, !Self.isLanguage(language) {
                return "language is a BCP 47 identifier such as en-US, or a language code such as de"
            }
        case .get, .export:
            let extra = [("request_id", requestID != nil), ("language", language != nil), ("engine", engine != nil)]
            if let name = extra.first(where: \.1)?.0 { return "\(action.rawValue) takes no \(name); make does" }
            if fingerprint != nil { return "\(action.rawValue) takes no fingerprint" }
            if action == .export, format == nil { return "export needs format: srt or vtt" }
        }
        return nil
    }

    /// Letters, digits, `-` and `_`, starting with a letter.
    static func isLanguage(_ text: String) -> Bool {
        (2...maxLanguageLength).contains(text.utf8.count) && text.first?.isLetter == true
            && text.allSatisfy { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "-" || $0 == "_" }
    }
}

/// One cue, in seconds from the start of the video.
public struct AgentCue: Codable, Equatable, Sendable {
    public var start: Double
    public var end: Double
    /// Its lines, joined by a newline.
    public var text: String

    public init(start: Double, end: Double, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

/// `get` and `export`: the subtitles of the item's current version.
public struct AgentSubtitles: Codable, Equatable, Sendable {
    public var item: UUID
    public var versionID: UUID
    /// BCP 47.
    public var language: String
    /// The model that heard them: speech_transcriber, dictation or parakeet_ultra.
    public var model: String
    public var cues: [AgentCue]
    /// get with format: the cues as that file would hold them.
    public var text: String?
    /// export: the file written.
    public var file: String?

    public init(
        item: UUID, versionID: UUID, language: String, model: String, cues: [AgentCue], text: String? = nil,
        file: String? = nil
    ) {
        self.item = item
        self.versionID = versionID
        self.language = language
        self.model = model
        self.cues = cues
        self.text = text
        self.file = file
    }

    private enum CodingKeys: String, CodingKey {
        case versionID = "versionId"
        case item, language, model, cues, text, file
    }
}

/// What `capabilities` says of subtitles on this Mac (`AgentCapabilities.OnDevice.subtitles`).
public struct AgentSubtitleCapabilities: Codable, Equatable, Sendable {
    /// One speech model.
    public struct Engine: Codable, Equatable, Sendable {
        /// built_in or parakeet.
        public var engine: String
        public var available: Bool
        /// What `make` takes with it: BCP 47 identifiers for built_in, language codes for parakeet.
        public var languages: [String]
        /// built_in: needs_consent while a language in `needsConsent` waits for the person, else agreed.
        /// parakeet: not_downloaded (only the person downloads it, in Settings › Subtitles), downloading or ready.
        public var model: String
        /// built_in: the languages whose model isn't here and that the person hasn't agreed to macOS downloading;
        /// they agree per language, and only they can.
        public var needsConsent: [String]?

        public init(
            engine: String, available: Bool, languages: [String], model: String, needsConsent: [String]? = nil
        ) {
            self.engine = engine
            self.available = available
            self.languages = languages
            self.model = model
            self.needsConsent = needsConsent
        }
    }

    /// The engine `make` uses when it names none: auto, built_in or parakeet.
    public var defaultEngine: String
    public var engines: [Engine]

    public init(defaultEngine: String, engines: [Engine]) {
        self.defaultEngine = defaultEngine
        self.engines = engines
    }
}
