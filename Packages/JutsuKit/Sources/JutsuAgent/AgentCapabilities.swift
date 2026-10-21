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
        /// Taken today by agents' jobs, those in flight included.
        public var spentToday: Int
        public var remaining: Int

        public init(unit: AgentBudgetUnit, dailyLimit: Int, spentToday: Int) {
            self.unit = unit
            self.dailyLimit = max(0, dailyLimit)
            self.spentToday = max(0, spentToday)
            remaining = max(0, self.dailyLimit - self.spentToday)
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
        public static let all = [ToolGroup(name: "app", tools: ["capabilities", "show"])]
    }

    /// A video model, compact: what an agent needs to pick one.
    public struct Model: Codable, Equatable, Sendable {
        public var id: String
        public var title: String
        public var modes: [String]
        public var resolutions: [String]
        /// Whether the connection runs it now.
        public var available: Bool

        public init(id: String, title: String, modes: [String], resolutions: [String], available: Bool) {
            self.id = id
            self.title = title
            self.modes = modes
            self.resolutions = resolutions
            self.available = available
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
