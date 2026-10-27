import Foundation
import JutsuAgent

/// What the menu bar panel shows of agents besides their jobs: the clients that sent requests lately, and the requests
/// that wait for the person to agree to a model download on this Mac. In memory only, so a relaunch forgets both.
public struct AgentActivity: Sendable, Hashable {
    /// A request an agent couldn't run until the person agrees in an item's sheet (`needs_person`).
    public struct Ask: Sendable, Hashable {
        public var item: UUID
        public var sheet: AgentSheet
        /// The item's title, as the Library shows it.
        public var title: String
        public var askedAt: Date

        public init(item: UUID, sheet: AgentSheet, title: String, askedAt: Date) {
            self.item = item
            self.sheet = sheet
            self.title = title
            self.askedAt = askedAt
        }
    }

    /// A client counts as connected for this long after its last request: the helper holds no connection open, it
    /// sends each request on its own.
    public static let connectedFor: TimeInterval = 10 * 60
    /// An ask nobody answered within this is dropped: the agent has moved on.
    public static let askLifetime: TimeInterval = 60 * 60
    /// How often a client's last request is noted: often enough for `connectedFor`, rarely enough not to redraw
    /// the panel for every `jobs` call.
    static let noteInterval: TimeInterval = 60
    static let unnamedClient = "agent"
    static let keptAsks = 10

    /// Each client's last noted request.
    public private(set) var lastRequest: [String: Date] = [:]
    /// Newest first.
    public private(set) var asks: [Ask] = []

    public init() {}

    /// Notes a request from `client`; changes nothing while its last one was noted less than `noteInterval` ago.
    public mutating func noteRequest(from client: String?, at date: Date) {
        let name = client.flatMap { $0.isEmpty ? nil : $0 } ?? Self.unnamedClient
        if let last = lastRequest[name], date.timeIntervalSince(last) < Self.noteInterval { return }
        lastRequest[name] = date
    }

    /// The clients whose last request was less than `connectedFor` ago, by name.
    public func connectedClients(at now: Date) -> [String] {
        lastRequest.filter { now.timeIntervalSince($0.value) < Self.connectedFor }.keys.sorted()
    }

    /// Notes an ask, replacing an older one for the same item and sheet, and drops the asks past `askLifetime`.
    public mutating func noteAsk(_ ask: Ask) {
        asks.removeAll { old in
            (old.item == ask.item && old.sheet == ask.sheet)
                || ask.askedAt.timeIntervalSince(old.askedAt) >= Self.askLifetime
        }
        asks.insert(ask, at: 0)
        if asks.count > Self.keptAsks { asks.removeLast(asks.count - Self.keptAsks) }
    }

    /// The person opened the item's sheet, or the agent's request went through.
    public mutating func clearAsk(for item: UUID, sheet: AgentSheet) {
        asks.removeAll { $0.item == item && $0.sheet == sheet }
    }

    /// The asks still waiting at `now`.
    public func openAsks(at now: Date) -> [Ask] {
        asks.filter { now.timeIntervalSince($0.askedAt) < Self.askLifetime }
    }
}
