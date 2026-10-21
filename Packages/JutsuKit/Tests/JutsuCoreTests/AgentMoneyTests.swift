import Foundation
import Testing

@testable import JutsuCore

@Suite struct AgentMoneyTests {
    @Test func pricesRoundUpToWholeUnits() {
        #expect(AgentMoney(.usd(1.301, isEstimate: false)) == AgentMoney(131, .usdCents))
        #expect(AgentMoney(.usd(2, isEstimate: false)) == AgentMoney(200, .usdCents))
        #expect(AgentMoney(.credits(0.25, isEstimate: false)) == AgentMoney(1, .credits))
        #expect(AgentMoney(.credits(40, isEstimate: true)) == AgentMoney(40, .credits))
    }

    /// Never a trap: a huge, negative or unknown amount is clamped or refused.
    @Test func hugeNegativeAndUnknownAmountsDontTrap() throws {
        let huge = try #require(Decimal(string: "1e30"))
        #expect(AgentMoney(.usd(huge, isEstimate: false))?.amount == AgentMoney.ceiling)
        #expect(AgentMoney(.credits(-3, isEstimate: false)) == nil)
        #expect(AgentMoney(.credits(.nan, isEstimate: false)) == nil)
        #expect(AgentMoney(Cost.unknownUSD) == nil)
        #expect(AgentMoney(-5, .credits).amount == 0)
        #expect(AgentMoney.sum(Int.max, Int.max) == AgentMoney.ceiling)
        #expect(AgentSpendTotal(spent: Int.max, reserved: Int.max).remaining(of: 10) == 0)
    }

    func origin(max: Int, approved: Bool = false) -> AgentOrigin {
        AgentOrigin(
            client: nil, requestID: "a", maxCost: AgentMoney(max, .usdCents), approvedByPerson: approved)
    }

    @Test func theGuardHoldsWhatIsOverALimitOrUnknown() {
        let price = Cost.usd(1.3, isEstimate: false)
        #expect(
            AgentSpendDecision.decide(price: price, isKnown: true, origin: origin(max: 130), dailyLimit: 130)
                == .send(AgentMoney(130, .usdCents), limit: 130))
        #expect(
            AgentSpendDecision.decide(price: price, isKnown: true, origin: origin(max: 129), dailyLimit: 500)
                == .hold(.overMaxCost))
        #expect(
            AgentSpendDecision.decide(price: price, isKnown: true, origin: origin(max: 500), dailyLimit: 129)
                == .hold(.overDailyBudget))
        #expect(
            AgentSpendDecision.decide(price: price, isKnown: false, origin: origin(max: 500), dailyLimit: 500)
                == .hold(.unknownPrice))
        // Credits against a cents limit never pass.
        #expect(
            AgentSpendDecision.decide(
                price: .credits(1, isEstimate: false), isKnown: true, origin: origin(max: 500), dailyLimit: 500)
                == .hold(.overMaxCost))
        #expect(
            AgentSpendDecision.decide(
                price: price, isKnown: false, origin: origin(max: 1, approved: true), dailyLimit: 0)
                == .send(AgentMoney(130, .usdCents), limit: nil))
    }

    /// The plan's unlimited allowance pays it: nothing counts against the budget, but it goes out without the person
    /// only when they let agents use it.
    @Test func anUnlimitedRequestIsHeldUnlessAgentsMayUseUnlimited() {
        let price = Cost.usd(1.3, isEstimate: false)
        #expect(
            AgentSpendDecision.decide(
                price: price, isKnown: true, origin: origin(max: 500), dailyLimit: 500, paysUnlimited: true)
                == .hold(.unlimitedNotAllowed))
        #expect(
            AgentSpendDecision.decide(
                price: price, isKnown: false, origin: origin(max: 0), dailyLimit: 0, paysUnlimited: true,
                allowsUnlimited: true)
                == .send(AgentMoney(0, .usdCents), limit: nil))
        #expect(
            AgentSpendDecision.decide(
                price: price, isKnown: true, origin: origin(max: 0, approved: true), dailyLimit: 0,
                paysUnlimited: true)
                == .send(AgentMoney(0, .usdCents), limit: nil))
    }

    @Test func onlyAQuoteOrAnExactPriceIsKnown() {
        var job = Job(
            spec: JobSpec(mode: .motionTransfer, source: nil, resolution: .p720), providerKind: .apiKey,
            cost: .usd(1, isEstimate: true))
        #expect(!job.agentPriceIsKnown)
        job.serverPrice = .usd(1.2, isEstimate: false)
        #expect(job.agentPriceIsKnown)
        job = Job(spec: job.spec, providerKind: .apiKey, cost: .usd(1, isEstimate: false))
        #expect(job.agentPriceIsKnown)
        job = Job(spec: job.spec, providerKind: .apiKey, cost: .unknownUSD)
        #expect(!job.agentPriceIsKnown)
    }

    /// Jobs stored before agents existed decode without one.
    @Test func jobsWithoutAnAgentStillDecode() throws {
        let job = Job(
            spec: JobSpec(mode: .motionTransfer, source: nil, resolution: .p720), providerKind: .apiKey,
            cost: .usd(1, isEstimate: false))
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(job)) as? [String: Any])
        object["agent"] = nil
        let decoded = try JSONDecoder().decode(Job.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.agent == nil)
        var agentJob = job
        agentJob.agent = origin(max: 5)
        #expect(try JSONDecoder().decode(Job.self, from: JSONEncoder().encode(agentJob)).agent == origin(max: 5))
    }
}
