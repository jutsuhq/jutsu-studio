import Foundation
import JutsuCore

/// The person's own daily cap as agents read amounts: whole usd_cents or credits, like their budget. It counts every
/// job, the person's own too, apart from the agent budget.
public enum AgentCap {
    /// `amount` of `unit` in whole units, rounded up as every agent amount is; `nil` for one that isn't a number.
    public static func money(_ amount: Decimal, _ unit: Capabilities.CostUnit) -> AgentMoney? {
        AgentMoney(unit == .usd ? .usd(amount, isEstimate: false) : .credits(amount, isEstimate: false))
    }

    /// What `over_cap` says: the cap, what it counts today besides the job, and what the job was counted at.
    public static func overCapMessage(cap: SpendCap, committedToday: Decimal, price: Cost) -> String {
        let text = { (amount: Decimal) in money(amount, cap.unit).map(Self.text) ?? "an unknown amount" }
        let counted = price.isUnknownPrice ? "an unknown price, which the cap never lets pass" : text(price.amount)
        return "The job would take today's spending over the person's daily cap of \(text(cap.amount)): "
            + "\(text(committedToday)) are spent or queued today, the person's jobs and agents' together, and the job "
            + "counts at \(counted). The cap is apart from the agent budget."
    }

    /// `120 usd_cents`, `24 credits`.
    public static func text(_ money: AgentMoney) -> String {
        "\(money.amount) \(money.unit.rawValue)"
    }
}
