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

        public init(unit: AgentBudgetUnit, dailyLimit: Int, spentToday: Int, reservedToday: Int = 0) {
            self.unit = unit
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
