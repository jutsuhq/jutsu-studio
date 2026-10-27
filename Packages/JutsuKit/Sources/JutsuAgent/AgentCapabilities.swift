import Foundation

/// The answer to `capabilities`. Never carries a credential or the account's e-mail: whether a connection exists and
/// what it pays with is all an agent needs.
public struct AgentCapabilities: Codable, Equatable, Sendable {
    public enum ConnectionKind: String, Codable, Sendable {
        case none, apiKey, account
    }

    public struct Connection: Codable, Equatable, Sendable {
        public var kind: ConnectionKind
        /// The account's plan, when Higgsfield named it.
        public var plan: String?
        /// The account's credits as last read; nil with an API key, whose balance can't be read, or before it is.
        public var credits: Int?

        public init(kind: ConnectionKind, plan: String? = nil, credits: Int? = nil) {
            self.kind = kind
            self.plan = plan
            self.credits = credits
        }
    }

    /// What agents may spend today, in whole units of what the connection pays with: cents with an API key,
    /// credits on an account.
    public struct Budget: Codable, Equatable, Sendable {
        public var unit: AgentBudgetUnit
        /// Settings › Agents › Daily agent budget; 0 until the person sets one.
        public var dailyLimit: Int
        /// Charged today for agents' jobs.
        public var spentToday: Int
        /// Held today for agents' submits sent and not answered yet; counts against the budget like a charge.
        public var reservedToday: Int
        /// What is left of `dailyLimit` once spent and reserved are taken, never below 0, as the app's spending guard
        /// counts it.
        public var remaining: Int
        /// Settings › Agents › Let agents use unlimited generations. Off, a job the plan's unlimited allowance would pay
        /// for waits for the person (hold unlimited_not_allowed); on, it runs without counting against the budget.
        /// `false` for the rest of the day once the allowance didn't pay for an agent's job sent for it: such jobs then
        /// keep every limit, as any other.
        public var unlimitedAllowed: Bool
        /// The person's own daily cap (Settings › Spending), in the same unit; `nil` when they set none. It counts
        /// every job, theirs and agents', apart from this budget, and a job over it is refused with over_cap.
        public var dailyCap: Int?
        /// What the cap counts today, charged or still queued; `nil` without a cap or when it can't be read.
        public var capTakenToday: Int?

        /// The fields as given, unchecked. The app builds its budget with `Budget(for:dailyLimit:taken:...)` in
        /// Presentation, which takes `remaining` from `AgentSpendTotal.remaining`, the spending guard's own count;
        /// any other caller must pass that number too, never one worked out here. Public for Presentation, which
        /// JutsuAgent can't see.
        public init(
            unit: AgentBudgetUnit, dailyLimit: Int, spentToday: Int, reservedToday: Int = 0, remaining: Int,
            unlimitedAllowed: Bool = false, dailyCap: Int? = nil, capTakenToday: Int? = nil
        ) {
            self.unit = unit
            self.dailyLimit = dailyLimit
            self.spentToday = spentToday
            self.reservedToday = reservedToday
            self.remaining = remaining
            self.unlimitedAllowed = unlimitedAllowed
            self.dailyCap = dailyCap
            self.capTakenToday = capTakenToday
        }
    }

    /// Tools that belong together, so an agent can tell what this version of the app offers.
    public struct ToolGroup: Codable, Equatable, Sendable {
        public var name: String
        public var tools: [String]

        public init(name: String, tools: [String]) {
            self.name = name
            self.tools = tools
        }

        /// Every tool this version offers, in the order `tools/list` gives them.
        public static let all = [
            ToolGroup(name: "app", tools: ["capabilities"]),
            ToolGroup(name: "video", tools: ["quote", "create_video", "jobs", "job_action"]),
            ToolGroup(name: "image", tools: ["create_image"]),
            ToolGroup(name: "elements", tools: ["elements"]),
            ToolGroup(
                name: "library",
                tools: [
                    "library_search", "library_get", "library_download", "library_mark", "enhance", "delivery_set",
                    "export", "frames",
                ]),
            ToolGroup(name: "window", tools: ["show"]),
        ]
    }

    /// A video model, compact: what an agent needs to pick one.
    public struct Model: Codable, Equatable, Sendable {
        public var id: String
        public var title: String
        public var modes: [String]
        public var resolutions: [String]
        /// Whether the connection runs it now.
        public var available: Bool
        /// Only for the one model asked for: what a job on it takes.
        public var details: ModelDetails?

        public init(
            id: String, title: String, modes: [String], resolutions: [String], available: Bool,
            details: ModelDetails? = nil
        ) {
            self.id = id
            self.title = title
            self.modes = modes
            self.resolutions = resolutions
            self.available = available
            self.details = details
        }
    }

    /// A model's limits in one mode.
    public struct ModeDetails: Codable, Equatable, Sendable {
        public var mode: String
        /// Seconds of source one job takes, or a clip without a source runs; for Extend also what it adds.
        public var minSeconds: Double
        public var maxSeconds: Double
        public var minImages: Int
        public var maxImages: Int
        public var needsStyle: Bool
        public var needsSource: Bool
        /// The most `variants` takes here on this connection; 1 with `variantsUnavailable` saying why.
        public var maxVariants: Int
        /// Why one job makes one video here whatever `variants` asks, in English; nil when more are offered.
        public var variantsUnavailable: String?

        public init(
            mode: String, minSeconds: Double, maxSeconds: Double, minImages: Int, maxImages: Int, needsStyle: Bool,
            needsSource: Bool, maxVariants: Int = 1, variantsUnavailable: String? = nil
        ) {
            self.mode = mode
            self.minSeconds = minSeconds
            self.maxSeconds = maxSeconds
            self.minImages = minImages
            self.maxImages = maxImages
            self.needsStyle = needsStyle
            self.needsSource = needsSource
            self.maxVariants = maxVariants
            self.variantsUnavailable = variantsUnavailable
        }
    }

    public struct ModelDetails: Codable, Equatable, Sendable {
        public var modes: [ModeDetails]
        public var hasDraft: Bool
        public var makesClipsWithoutSource: Bool
        public var needsPrompt: Bool

        public init(modes: [ModeDetails], hasDraft: Bool, makesClipsWithoutSource: Bool, needsPrompt: Bool) {
            self.modes = modes
            self.hasDraft = hasDraft
            self.makesClipsWithoutSource = makesClipsWithoutSource
            self.needsPrompt = needsPrompt
        }
    }

    /// An image model of the connection, as `create_image` takes it.
    public struct ImageModel: Codable, Equatable, Sendable {
        public var id: String
        public var title: String
        /// How many images one request can make.
        public var counts: [Int]
        public var aspectRatios: [String]
        /// "none", "optional" or "required": whether it edits input images.
        public var input: String
        /// The most images `create_image` takes as `inputs`; 0 when it edits none.
        public var maxInputs: Int
        /// Set when `maxInputs` is the protocol's bound rather than the model's own: its catalog states no limit.
        public var maxInputsNote: String?

        public init(
            id: String, title: String, counts: [Int], aspectRatios: [String], input: String, maxInputs: Int = 0,
            maxInputsNote: String? = nil
        ) {
            self.id = id
            self.title = title
            self.counts = counts
            self.aspectRatios = aspectRatios
            self.input = input
            self.maxInputs = maxInputs
            self.maxInputsNote = maxInputsNote
        }

        /// `maxInputsNote` for a model whose catalog states no limit.
        public static let boundNote =
            "Higgsfield's catalog states no limit for this model, so up to \(AgentImageRequest.maxInputs) are taken; "
            + "Higgsfield's own quote, made before anything is sent, refuses more than the model takes, and that costs "
            + "nothing."
    }

    /// A Restyle style, by the ID `create_video` takes as `style`.
    public struct Style: Codable, Equatable, Sendable {
        public var id: UUID
        public var name: String

        public init(id: UUID, name: String) {
            self.id = id
            self.name = name
        }
    }

    /// A voice of Change Voice, by the ID `enhance` takes as `voice`.
    public struct Voice: Codable, Equatable, Sendable {
        public var id: String
        public var name: String

        public init(id: String, name: String) {
            self.id = id
            self.name = name
        }
    }

    /// Enhance on this Mac (`enhance` smooth_motion, and upscale with engine mac): free, no account, no upload.
    public struct OnDevice: Codable, Equatable, Sendable {
        /// Smooth Motion, on videos: `modes`.
        public var smoothMotion: AgentOnDeviceEngine
        /// The modes `enhance` smooth_motion takes.
        public var modes: [String]
        /// Upscale with engine mac, on a video, 4×.
        public var upscaleVideo: AgentOnDeviceEngine
        /// Upscale with engine mac, on an image, 4×.
        public var upscaleImage: AgentOnDeviceEngine

        public init(
            smoothMotion: AgentOnDeviceEngine, upscaleVideo: AgentOnDeviceEngine, upscaleImage: AgentOnDeviceEngine
        ) {
            self.smoothMotion = smoothMotion
            modes = AgentSmoothMotion.allCases.map(\.rawValue)
            self.upscaleVideo = upscaleVideo
            self.upscaleImage = upscaleImage
        }
    }

    public var protocolVersion: Int
    public var appVersion: String
    /// Settings › Agents › Allow agents. Always true in an answer: while it is off, every command is refused with
    /// `agents_off` instead.
    public var agentsAllowed: Bool
    public var connection: Connection
    /// nil while nothing is connected.
    public var budget: Budget?
    public var toolGroups: [ToolGroup]
    /// Only when asked for (`CapabilitiesCommand.models`).
    public var models: [Model]?
    /// Only when asked for (`CapabilitiesCommand.imageModels`); empty when the connection makes no images.
    public var imageModels: [ImageModel]?
    /// Only when asked for (`CapabilitiesCommand.styles`); empty until Create has read the catalog once.
    public var styles: [Style]?
    /// Only when asked for (`CapabilitiesCommand.voices`); empty without an account.
    public var voices: [Voice]?
    /// What runs on this Mac; set by the app on every answer.
    public var onDevice: OnDevice?
    /// The `jutsu` helper's own version, added by the helper (`noteHelper`); the app leaves it out.
    public var helperVersion: String?
    /// Added by a helper older than the app: what the agent should do about it.
    public var helperNote: String?

    public init(
        appVersion: String, agentsAllowed: Bool = true, connection: Connection, budget: Budget?,
        toolGroups: [ToolGroup] = ToolGroup.all, models: [Model]? = nil, protocolVersion: Int = AgentProtocol.version
    ) {
        self.protocolVersion = protocolVersion
        self.appVersion = appVersion
        self.agentsAllowed = agentsAllowed
        self.connection = connection
        self.budget = budget
        self.toolGroups = toolGroups
        self.models = models
    }

    /// The helper `version` that relays this answer: an MCP client keeps the helper process it started, so after the
    /// app is updated it can run an older helper, with that version's tools, until it reconnects. Only a helper that
    /// has this can say so; one from before it relays the answer without either field.
    public mutating func noteHelper(_ version: String) {
        helperVersion = version
        helperNote =
            Self.isOlder(version, than: appVersion)
            ? "This jutsu helper is \(version), older than Jutsu Studio \(appVersion): the MCP client still runs the "
                + "helper it started before the app was updated, with that version's tools. Reconnect the jutsu MCP "
                + "server (/mcp in Claude Code, or restart the client) to get this version's tools."
            : nil
    }

    /// Whether release `helper` is older than release `app`, compared as numbers (0.2.10 after 0.2.9); a development
    /// build or a version that isn't a number is never called older.
    static func isOlder(_ helper: String, than app: String) -> Bool {
        let isRelease = { (version: String) in version.first?.isNumber == true }
        guard isRelease(helper), isRelease(app) else { return false }
        return helper.compare(app, options: .numeric) == .orderedAscending
    }
}

/// What an agent budget counts in: cents with an API key, credits on an account.
public enum AgentBudgetUnit: String, Codable, Sendable {
    case usdCents = "usd_cents"
    case credits
}

/// One engine of this Mac, as `capabilities` reports it (`AgentCapabilities.OnDevice`).
public struct AgentOnDeviceEngine: Codable, Equatable, Sendable {
    /// Whether this Mac's macOS and hardware have it.
    public var available: Bool
    /// The largest source it takes, either way round; `nil` for any size.
    public var maxLongSide: Int?
    public var maxShortSide: Int?
    /// Its model: none (it needs none), needs_consent (only the person can agree to macOS downloading it:
    /// `show` with sheet upscale_on_mac), downloading, ready (a run found it since the app started), or agreed (macOS
    /// downloads it at the first run if it isn't here yet).
    public var model: String

    public init(available: Bool, maxLongSide: Int? = nil, maxShortSide: Int? = nil, model: String) {
        self.available = available
        self.maxLongSide = maxLongSide
        self.maxShortSide = maxShortSide
        self.model = model
    }
}
