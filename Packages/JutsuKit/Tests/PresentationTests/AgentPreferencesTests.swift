import Foundation
import JutsuCore
import Testing

@testable import Presentation

extension UserDefaultsBackedTests {
    @Suite struct AgentPreferencesTests {
        /// A defaults suite of its own, and the domain the preferences read, as the app's bundle ID would be.
        private func preferences() throws -> (UserDefaults, AgentPreferences) {
            let name = "AgentPreferencesTests-\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: name))
            defaults.removePersistentDomain(forName: name)
            return (defaults, AgentPreferences(defaults: defaults, domain: name))
        }

        @Test func agentsAreOffWithNoBudgetUntilThePersonSaysOtherwise() throws {
            let (_, preferences) = try preferences()
            #expect(!preferences.isAllowed)
            #expect(preferences.dailyBudget(for: .apiKey) == 0)
            #expect(preferences.dailyBudget(for: .account) == 0)
        }

        @Test func whatSettingsSavedIsRead() throws {
            let (defaults, preferences) = try preferences()
            defaults.set(true, forKey: AgentPreferences.allowKey)
            defaults.set(1250, forKey: AgentPreferences.budgetCentsKey)
            defaults.set(300, forKey: AgentPreferences.budgetCreditsKey)
            #expect(preferences.isAllowed)
            #expect(preferences.dailyBudget(for: .apiKey) == 1250)
            #expect(preferences.dailyBudget(for: .account) == 300)
        }

        @Test func settingsWritesWhatItReads() throws {
            let (_, preferences) = try preferences()
            preferences.setAllowed(true)
            preferences.setDailyBudget(Int.max, for: .apiKey)
            preferences.setDailyBudget(-5, for: .account)
            #expect(preferences.isAllowed)
            #expect(preferences.dailyBudget(for: .apiKey) == AgentPreferences.maxBudgetCents)
            #expect(preferences.dailyBudget(for: .account) == 0)
        }

        @Test func unlimitedGenerationsAreOffForAgentsUntilThePersonTurnsThemOn() throws {
            let (defaults, preferences) = try preferences()
            #expect(!preferences.allowsUnlimited)
            defaults.register(defaults: [AgentPreferences.unlimitedKey: true])
            #expect(!preferences.allowsUnlimited)
            preferences.setAllowsUnlimited(true)
            #expect(preferences.allowsUnlimited)
        }

        @Test func aLaunchArgumentCantTurnAgentsOn() throws {
            let (defaults, preferences) = try preferences()
            // What `-agents.allow YES` puts in the argument domain, read by `bool(forKey:)` but not saved.
            defaults.register(defaults: [AgentPreferences.allowKey: true, AgentPreferences.budgetCentsKey: 500])
            #expect(defaults.bool(forKey: AgentPreferences.allowKey))
            #expect(!preferences.isAllowed)
            #expect(preferences.dailyBudget(for: .apiKey) == 0)
        }

        @Test func aStoredBudgetOutOfRangeIsReadWithinIt() throws {
            let (defaults, preferences) = try preferences()
            defaults.set(1e300, forKey: AgentPreferences.budgetCentsKey)
            defaults.set(-40, forKey: AgentPreferences.budgetCreditsKey)
            #expect(preferences.dailyBudget(for: .apiKey) == AgentPreferences.maxBudgetCents)
            #expect(preferences.dailyBudget(for: .account) == 0)
            defaults.set(Double.nan, forKey: AgentPreferences.budgetCentsKey)
            #expect(preferences.dailyBudget(for: .apiKey) == 0)
            defaults.set("lots", forKey: AgentPreferences.budgetCreditsKey)
            #expect(preferences.dailyBudget(for: .account) == 0)
        }

        @Test func dollarsAreReadToTheCent() {
            let cases: [(String, Int?)] = [
                ("0", 0), ("12", 1200), ("12.5", 1250), ("12.05", 1205), ("$1,000.00", 100_000), (" 7. ", 700),
                ("10000", 1_000_000), ("10000.01", nil), ("12.345", nil), ("-1", nil), ("1e3", nil), ("", nil),
                ("$", nil), (".5", nil), ("1.2.3", nil), ("99999999999999999999999", nil), ("١٢", nil),
            ]
            for (text, cents) in cases {
                #expect(AgentPreferences.parseBudget(text, for: .apiKey) == cents, "\(text)")
            }
        }

        @Test func creditsAreWholeNumbers() {
            let cases: [(String, Int?)] = [
                ("0", 0), ("1000", 1000), ("1,000 credits", 1000), ("1 credit", 1), ("250cr", 250),
                ("10000000", 10_000_000), ("10000001", nil), ("12.5", nil), ("-3", nil), ("", nil),
                ("999999999999999999999", nil),
            ]
            for (text, credits) in cases {
                #expect(AgentPreferences.parseBudget(text, for: .account) == credits, "\(text)")
            }
        }

        @Test func theFieldsTextReadsBack() {
            for cents in [0, 5, 1250, 1_000_000] {
                let text = AgentPreferences.budgetText(cents, for: .apiKey)
                #expect(AgentPreferences.parseBudget(text, for: .apiKey) == cents)
            }
            #expect(AgentPreferences.budgetText(1205, for: .apiKey) == "12.05")
            #expect(
                AgentPreferences.parseBudget(AgentPreferences.budgetText(4200, for: .account), for: .account) == 4200)
        }
    }
}
