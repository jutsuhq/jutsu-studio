import Foundation
import Presentation
import Testing

@Suite struct AccountPlateTests {
    static let locale = Locale(identifier: "en_US")

    @Test(arguments: [
        ("Free", PlanTier.free), ("Basic", .starter), ("Starter", .starter), ("Pro", .pro), ("Plus", .pro),
        ("Ultimate", .premium), ("Creator", .premium), ("Creator Plus", .elite), ("Ultra", .elite),
        ("Business", .elite), ("Team Pro", .elite), ("Something New", .pro),
    ])
    func tierFollowsThePlanName(plan: String, tier: PlanTier) {
        #expect(PlanTier(planTitle: plan) == tier)
    }

    @Test func accountShowsPlanAndGroupedCredits() throws {
        let state = ConnectionState.account(AccountInfo(plan: "Creator Plus", credits: 2596))
        let plate = try #require(AccountPlate(connection: state, lowCreditThreshold: 50, locale: Self.locale))

        #expect(plate.badge == "Creator Plus")
        #expect(plate.tier == .elite)
        #expect(plate.amount == "2,596")
        #expect(plate.unit == "credits")
        #expect(plate.warning == nil)
        #expect(plate.accessibilityLabel == "Creator Plus plan, 2,596 credits left")
    }

    @Test func lowCreditsWarn() throws {
        let state = ConnectionState.account(AccountInfo(plan: "Pro", credits: 12))
        let plate = try #require(AccountPlate(connection: state, lowCreditThreshold: 50, locale: Self.locale))
        #expect(plate.warning == "Low credits: 12 left")
    }

    @Test func unknownPlanAndCreditsAreNeutral() throws {
        let plate = try #require(AccountPlate(connection: .account(AccountInfo()), lowCreditThreshold: 50))
        #expect(plate.badge == "Account")
        #expect(plate.tier == nil)
        #expect(plate.amount == "—")
        #expect(plate.accessibilityLabel == "Higgsfield account")
    }

    @Test func apiKeyHasNoCreditsAndNoConnectionHasNoPlate() throws {
        let plate = try #require(AccountPlate(connection: .apiKey(keyID: "kid"), lowCreditThreshold: 50))
        #expect(plate.badge == "API key")
        #expect(plate.isAPIKey)
        #expect(plate.tier == nil)
        #expect(plate.warning == nil)
        #expect(AccountPlate(connection: .none, lowCreditThreshold: 50) == nil)
    }
}
