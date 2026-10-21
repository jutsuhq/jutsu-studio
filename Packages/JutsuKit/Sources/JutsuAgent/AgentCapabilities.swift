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
        public var remaining: Int
        /// Settings › Agents › Let agents use unlimited generations. Off, a job the plan's unlimited allowance would pay
        /// for waits for the person (hold unlimited_not_allowed); on, it runs without counting against the budget.
        /// `false` for the rest of the day once the allowance didn't pay for an agent's job sent for it: such jobs then
        /// keep every limit, as any other.
        public var unlimitedAllowed: Bool

        public init(
            unit: AgentBudgetUnit, dailyLimit: Int, spentToday: Int, reservedToday: Int = 0,
            unlimitedAllowed: Bool = false
        ) {
            self.unit = unit
            self.unlimitedAllowed = unlimitedAllowed
            self.dailyLimit = max(0, dailyLimit)
            self.spentToday = max(0, spentToday)
            self.reservedToday = max(0, reservedToday)
            let (taken, overflow) = self.spentToday.addingReportingOverflow(self.reservedToday)
            remaining = overflow ? 0 : max(0, self.dailyLimit - taken)
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

        public init(
            mode: String, minSeconds: Double, maxSeconds: Double, minImages: Int, maxImages: Int, needsStyle: Bool,
            needsSource: Bool
        ) {
            self.mode = mode
            self.minSeconds = minSeconds
            self.maxSeconds = maxSeconds
            self.minImages = minImages
            self.maxImages = maxImages
            self.needsStyle = needsStyle
            self.needsSource = needsSource
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

        public init(
            id: String, title: String, counts: [Int], aspectRatios: [String], input: String, maxInputs: Int = 0
        ) {
            self.id = id
            self.title = title
            self.counts = counts
            self.aspectRatios = aspectRatios
            self.input = input
            self.maxInputs = maxInputs
        }
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
}

/// What an agent budget counts in: cents with an API key, credits on an account.
public enum AgentBudgetUnit: String, Codable, Sendable {
    case usdCents = "usd_cents"
    case credits
}
