import Foundation
import JutsuAgent
import JutsuCore
import Testing

@testable import Presentation

/// The agent budget's limits are set once (`AgentAmount.maximum`), and what `capabilities` says is left is what the
/// spending guard counts.
@Suite struct AgentBudgetTests {
    /// The numbers agents and the person see: changing them is a decision, not a refactor.
    @Test func theMostABudgetOrAMaxCostCanBeIsPinned() {
        #expect(AgentAmount.maximum(for: .usdCents) == 1_000_000)
        #expect(AgentAmount.maximum(for: .credits) == 10_000_000)
        #expect(
            AgentPreferences.budgetKey(for: .apiKey).limit == AgentAmount.maximum(for: AgentBudgetUnit(for: .apiKey)))
        #expect(
            AgentPreferences.budgetKey(for: .account).limit == AgentAmount.maximum(for: AgentBudgetUnit(for: .account)))
    }

    @Test func theBudgetCountsReservationsAndNeverOverflows() {
        let budget = AgentCapabilities.Budget(
            for: .account, dailyLimit: 100, taken: AgentSpendTotal(spent: 30, reserved: 50), allowsUnlimited: false)
        #expect(budget.unit == .credits && budget.spentToday == 30 && budget.reservedToday == 50)
        #expect(budget.remaining == 20)
        let huge = AgentCapabilities.Budget(
            for: .account, dailyLimit: 100, taken: AgentSpendTotal(spent: .max, reserved: .max), allowsUnlimited: false)
        #expect(huge.remaining == 0)
    }

    @Test func theBudgetNeverGoesBelowZero() {
        let over = AgentCapabilities.Budget(
            for: .account, dailyLimit: 100, taken: AgentSpendTotal(spent: 140), allowsUnlimited: false)
        #expect(over.remaining == 0)
        let negative = AgentCapabilities.Budget(
            for: .apiKey, dailyLimit: -5, taken: AgentSpendTotal(spent: -1), allowsUnlimited: false)
        #expect(negative.unit == .usdCents && negative.dailyLimit == 0 && negative.spentToday == 0)
        #expect(negative.remaining == 0)
    }

    /// Once the allowance didn't pay for an agent's job today, agents aren't told they may use it.
    @Test func unlimitedIsOfferedOnlyWhileNoneWasChargedToday() {
        let allowed = AgentCapabilities.Budget(
            for: .account, dailyLimit: 0, taken: AgentSpendTotal(), allowsUnlimited: true)
        #expect(allowed.unlimitedAllowed)
        let charged = AgentCapabilities.Budget(
            for: .account, dailyLimit: 0, taken: AgentSpendTotal(unlimitedCharged: true), allowsUnlimited: true)
        #expect(!charged.unlimitedAllowed)
    }
}
