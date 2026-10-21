import Foundation
import JutsuCore

// The list price the guard falls back on, and the texts a held or failed request shows.
extension AgentImageQueue {
    /// The model's list price for the request, an estimate.
    static func listPrice(of record: AgentImageRecord) -> Cost? {
        switch record.model.listPrice {
        case .usd(let amount, _)?: .usd(amount * Decimal(record.count), isEstimate: true)
        case .credits(let amount, _)?: .credits(amount * Decimal(record.count), isEstimate: true)
        case nil: nil
        }
    }

    static func hold(_ hold: AgentHold) -> AgentImageRecord.Hold {
        switch hold {
        case .unknownPrice: .unknownPrice
        case .overMaxCost: .overMaxCost
        case .overDailyBudget: .overDailyBudget
        case .ledgerUnavailable: .ledgerUnavailable
        case .unlimitedNotAllowed: .unlimitedNotAllowed
        case .aboveApprovedPrice: .aboveApprovedPrice
        }
    }

    /// Why a held request waits, for its row in the Queue.
    public static func text(of hold: AgentImageRecord.Hold) -> String {
        switch hold {
        case .unknownPrice:
            String(localized: "Waiting for you: its price isn't known.", bundle: .module)
        case .overMaxCost:
            String(localized: "Waiting for you: it costs more than the agent was allowed.", bundle: .module)
        case .overDailyBudget:
            String(localized: "Waiting for you: it's over today's agent budget.", bundle: .module)
        case .ledgerUnavailable:
            String(localized: "Waiting for you: agent spending can't be recorded.", bundle: .module)
        case .unlimitedNotAllowed:
            String(
                localized: "Waiting for you: it would use your plan's unlimited generations, which agents may not use.",
                bundle: .module)
        case .aboveApprovedPrice:
            String(localized: "Waiting for you: it costs more now than the price you approved.", bundle: .module)
        case .priceAboveCap:
            String(localized: "Waiting for you: it takes today past your spend cap.", bundle: .module)
        }
    }

    static let notRecorded = String(localized: "Jutsu Studio lost the record of this request.", bundle: .module)
    static let lostAnswer = String(
        localized: "Jutsu Studio quit while sending this request, so it may have been sent. Its price still counts.",
        bundle: .module)
}
