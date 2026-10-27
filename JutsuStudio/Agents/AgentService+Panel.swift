import Foundation
import JutsuAgent
import Presentation

// What the menu bar panel shows of agents: today's budget, the clients that sent requests lately, and the requests
// that wait for the person to agree to a model download (`AgentActivity`).
extension AgentService {
    /// Today's agent budget, as `capabilities` reports it; `nil` while nothing is connected.
    func budgetToday() async throws(AgentError) -> AgentCapabilities.Budget? {
        guard let kind = environment.connection.state.kind else { return nil }
        let taken = try await agentSpendToday(for: kind)
        let cap = environment.spendCap(for: kind)
        var capTaken: Int?
        if let cap, let committed = try? await environment.committedToday(in: cap.unit) {
            capTaken = AgentCap.money(committed, cap.unit)?.amount
        }
        return AgentCapabilities.Budget(
            for: kind, dailyLimit: preferences.dailyBudget(for: kind), taken: taken,
            allowsUnlimited: preferences.allowsUnlimited,
            dailyCap: cap.flatMap { AgentCap.money($0.amount, $0.unit)?.amount }, capTakenToday: capTaken)
    }

    /// Assigned only when it changes, so the panel isn't redrawn for every `jobs` call.
    func noteRequest(from client: String?) {
        var updated = activity
        updated.noteRequest(from: client, at: .now)
        if updated != activity { activity = updated }
    }

    /// A request that went through settles the item's ask.
    func noteAnswered(_ command: AgentCommand) {
        guard let item = Self.askedItem(command),
            activity.asks.contains(where: { $0.item == item.id && $0.sheet == item.sheet })
        else { return }
        activity.clearAsk(for: item.id, sheet: item.sheet)
    }

    /// An `enhance` on this Mac or a subtitles `make` refused with `needs_person` waits for the person's agreement in
    /// the item's sheet: the panel lists it under Needs you.
    func noteRefused(_ command: AgentCommand, _ error: AgentError) async {
        guard error.code == .needsPerson, let item = Self.askedItem(command) else { return }
        let title = (try? await itemTitle(item.id)) ?? String(localized: "Library item")
        activity.noteAsk(AgentActivity.Ask(item: item.id, sheet: item.sheet, title: title, askedAt: .now))
    }

    /// The panel's Needs you row: opens the sheet the agent asked for, as `show` does, and settles the ask.
    func openAsk(_ ask: AgentActivity.Ask) async {
        activity.clearAsk(for: ask.item, sheet: ask.sheet)
        _ = try? await show(.sheet(ask.sheet, item: ask.item))
    }

    private static func askedItem(_ command: AgentCommand) -> (id: UUID, sheet: AgentSheet)? {
        switch command {
        case .enhance(let fields): (fields.item, .upscaleOnMac)
        case .subtitles(let fields) where fields.action == .make: (fields.item, .subtitles)
        default: nil
        }
    }

    private func itemTitle(_ id: UUID) async throws(AgentError) -> String {
        switch try await onDeviceItem(id) {
        case .video(_, let item, _): item.title
        case .image(_, let image): image.title ?? image.prompt
        }
    }
}
