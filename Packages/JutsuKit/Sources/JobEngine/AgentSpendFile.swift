import Foundation
import JutsuCore

/// What the engine needs to let agents spend: the ledger, and the person's daily agent budget per connection.
public struct AgentSpendPolicy: Sendable {
    public var ledger: any AgentSpendLedger
    /// Settings › Agents › Daily agent budget for the connection, in its `AgentMoney.unit(for:)`; 0 lets agents
    /// spend nothing.
    public var dailyLimit: @Sendable (ProviderKind) -> Int
    /// Settings › Agents › Let agents use unlimited generations: whether an agent's job the plan's unlimited allowance
    /// would pay for may go out without the person. Off holds it.
    public var allowsUnlimited: @Sendable () -> Bool

    public init(
        ledger: any AgentSpendLedger, dailyLimit: @escaping @Sendable (ProviderKind) -> Int,
        allowsUnlimited: @escaping @Sendable () -> Bool = { false }
    ) {
        self.ledger = ledger
        self.dailyLimit = dailyLimit
        self.allowsUnlimited = allowsUnlimited
    }
}

/// The agent spend ledger as one JSON file, apart from the job store, so deleting jobs or results gives nothing
/// back. Read strictly: a file that exists and can't be read throws on every call rather than counting from zero,
/// and the engine then sends nothing an agent asked for. Written atomically on every change; entries older than
/// `keptDays` days are dropped as it writes.
public actor AgentSpendFile: AgentSpendLedger {
    private let file: URL
    private let calendar: Calendar
    private let now: @Sendable () -> Date
    private var entries: [AgentSpend]?

    /// Today and yesterday: what a budget can count, with room for a day that just ended.
    static let keptDays = 2

    public init(file: URL, calendar: Calendar = .current, now: @escaping @Sendable () -> Date = { Date() }) {
        self.file = file
        self.calendar = calendar
        self.now = now
    }

    public func reserve(_ spend: AgentSpend, dailyLimit: Int?) throws -> Bool {
        var entries = try load()
        if let dailyLimit {
            let taken = Self.total(entries, on: spend.at, unit: spend.money.unit, calendar: calendar).taken
            guard AgentMoney.sum(taken, spend.money.amount) <= dailyLimit else { return false }
        }
        entries.append(spend)
        try write(entries)
        return true
    }

    public func release(_ id: UUID) throws {
        var entries = try load()
        guard let index = entries.firstIndex(where: { $0.id == id }), !entries[index].isSettled else { return }
        entries.remove(at: index)
        try write(entries)
    }

    public func settle(_ id: UUID, amount: Int?) throws {
        var entries = try load()
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        if let amount { entries[index].money.amount = max(0, min(amount, AgentMoney.ceiling)) }
        entries[index].isSettled = true
        try write(entries)
    }

    public func unbill(_ id: UUID, part: String, of parts: Int) throws {
        var entries = try load()
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        var entry = entries[index]
        guard entry.unbilled?.contains(part) != true else { return }
        entry.parts = min(max(entry.parts ?? 1, parts, 1), AgentSpend.maxParts)
        entry.unbilled = (entry.unbilled ?? []) + [part]
        entries[index] = entry
        try write(entries)
    }

    public func unsettled() throws -> [AgentSpend] {
        try load().filter { !$0.isSettled }
    }

    public func total(on day: Date, unit: AgentMoney.Unit) throws -> AgentSpendTotal {
        Self.total(try load(), on: day, unit: unit, calendar: calendar)
    }

    static func total(
        _ entries: [AgentSpend], on day: Date, unit: AgentMoney.Unit, calendar: Calendar
    )
        -> AgentSpendTotal
    {
        entries.reduce(into: AgentSpendTotal()) { total, entry in
            guard entry.money.unit == unit, calendar.isDate(entry.at, inSameDayAs: day) else { return }
            if entry.isUnlimitedCharged { total.unlimitedCharged = true }
            if entry.isSettled {
                total.spent = AgentMoney.sum(total.spent, entry.counted)
            } else {
                total.reserved = AgentMoney.sum(total.reserved, entry.counted)
            }
        }
    }

    private func load() throws -> [AgentSpend] {
        if let entries { return entries }
        let loaded: [AgentSpend]
        if FileManager.default.fileExists(atPath: file.path) {
            loaded = try JSONDecoder.agentSpend.decode([AgentSpend].self, from: Data(contentsOf: file))
        } else {
            loaded = []
        }
        entries = loaded
        return loaded
    }

    private func write(_ updated: [AgentSpend]) throws {
        let start = calendar.startOfDay(for: now())
        let cutoff = calendar.date(byAdding: .day, value: 1 - Self.keptDays, to: start) ?? start
        let kept = updated.filter { $0.at >= cutoff }
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder.agentSpend.encode(kept).write(to: file, options: .atomic)
        entries = kept
    }
}

extension JSONEncoder {
    fileprivate static var agentSpend: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

extension JSONDecoder {
    fileprivate static var agentSpend: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
