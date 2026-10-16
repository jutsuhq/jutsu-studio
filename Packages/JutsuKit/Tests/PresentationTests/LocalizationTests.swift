import Foundation
import JutsuCore
import Testing

@testable import Presentation

extension Locale {
    /// Tests that check dollar amounts pin `CostText.locale` to this, so they don't depend on the Mac's region.
    static let enUS = Locale(identifier: "en_US")
}

@Suite struct LocalizationTests {
    @Test func pluralsComeFromTheStringCatalog() {
        #expect(SpendLine.jobsText(1) == "1 job")
        #expect(SpendLine.jobsText(0) == "0 jobs")
        #expect(SpendLine.jobsText(3) == "3 jobs")
        #expect(BatchGrouping.variantText(count: 1, mode: .restyle) == "1 style")
        #expect(BatchGrouping.variantText(count: 4, mode: .restyle) == "4 styles")
        #expect(BatchGrouping.variantText(count: 3, mode: .motionTransfer) == "3 characters")
        #expect(MenuBarSummary.headline(active: 1, paused: 0) == "1 job in the queue")
        #expect(MenuBarSummary.headline(active: 2, paused: 1) == "2 jobs in the queue · 1 paused")
        #expect(AppSettings.formatBytes(1) == "1 byte")
        #expect(AppSettings.formatBytes(512) == "512 bytes")
        #expect(CostText.amount(1, unit: .credits) == "1 credit")
        #expect(CostText.amount(1200, unit: .credits) == "1200 credits")
        #expect(AppSettings.formatCredits(1, locale: .enUS) == "1 credit")
    }

    /// A plural inside a sentence follows its own number, not the first one.
    @Test func pluralsInsideASentence() throws {
        let one = ConnectionState.account(AccountInfo(plan: "Pro", credits: 1))
        let plate = try #require(AccountPlate(connection: one, lowCreditThreshold: 0, locale: .enUS))
        #expect(plate.accessibilityLabel == "Pro plan, 1 credit left")
        let unknownPlan = ConnectionState.account(AccountInfo(credits: 1_500))
        let account = try #require(AccountPlate(connection: unknownPlan, lowCreditThreshold: 0, locale: .enUS))
        #expect(account.accessibilityLabel == "Higgsfield account, 1,500 credits left")
    }

    /// Times, percentages and sizes are written with the locale's separators.
    @Test func numbersFollowTheLocale() {
        CostText.$locale.withValue(Locale(identifier: "de_DE")) {
            #expect(CostText.timecode(66.54) == "01:06,5")
            #expect(CostText.seconds(12.5) == "12,5 s")
            #expect(AppSettings.formatBytes(1_430_000_000) == "1,43 GB")
            // German puts a no-break space before the sign.
            #expect(CostText.percent(fraction: 0.42) == "42\u{A0}%")
        }
        CostText.$locale.withValue(.enUS) {
            #expect(CostText.timecode(66.54) == "01:06.5")
            #expect(CostText.limit(4.5) == "4.5 s")
            #expect(CostText.limit(30) == "30 s")
            #expect(CostText.percent(fraction: 0.42) == "42%")
        }
    }

    @Test func dollarsAreNeverGroupedAndRoundHalfUp() {
        CostText.$locale.withValue(.enUS) {
            #expect(CostText.dollars(Decimal(string: "1234.5")!) == "$1234.50")
            #expect(CostText.dollars(Decimal(string: "0.005")!) == "$0.01")
            #expect(AppSettings.formatUSD(19.99) == "$19.99")
        }
    }

    /// Always USD, in the way the locale writes an amount.
    @Test func dollarsFollowTheLocale() {
        CostText.$locale.withValue(Locale(identifier: "de_DE")) {
            let text = CostText.dollars(Decimal(string: "1234.5")!)
            #expect(text.contains("1234,50"))
            #expect(text.contains("$"))
        }
        #expect(AppSettings.formatUSD(75.0, locale: .enUS) == "$75.00")
    }

    /// A plural variant that doesn't name its number fails the app's build, and the variant is picked by the first
    /// argument, so that argument has to be the number.
    @Test(arguments: [
        "Packages/JutsuKit/Sources/Presentation/Resources", "Packages/JutsuKit/Sources/HiggsfieldProviders/Resources",
        "Packages/JutsuKit/Sources/JobEngine/Resources", "JutsuStudio/Resources",
    ])
    func everyPluralVariantNamesItsNumber(folder: String) throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appending(path: "../../../../")
        let data = try Data(contentsOf: root.appending(path: folder).appending(path: "Localizable.xcstrings"))
        let catalog = try JSONDecoder().decode(Catalog.self, from: data)
        for (key, entry) in catalog.strings {
            for (language, localization) in entry.localizations ?? [:] {
                if let plural = localization.variations?.plural {
                    #expect(key.firstSpecifier == "%lld", "\(key): the first argument isn't the number")
                    for (category, variant) in plural {
                        let value = variant.stringUnit.value
                        #expect(
                            value.range(of: #"%(\d+\$)?lld"#, options: .regularExpression) != nil,
                            "\(key) [\(language) \(category)]: \(value)")
                    }
                }
                // A sentence with more than one number names the one its plural follows in a substitution.
                for (name, substitution) in localization.substitutions ?? [:] {
                    for (category, variant) in substitution.variations.plural ?? [:] {
                        let value = variant.stringUnit.value
                        #expect(value.contains("%arg"), "\(key) [\(language) \(name) \(category)]: \(value)")
                    }
                }
            }
        }
    }
}

private struct Catalog: Decodable {
    struct Unit: Decodable { var value: String }
    struct Variant: Decodable { var stringUnit: Unit }
    struct Variations: Decodable { var plural: [String: Variant]? }
    struct Substitution: Decodable { var variations: Variations }
    struct Localization: Decodable {
        var variations: Variations?
        var substitutions: [String: Substitution]?
    }
    struct Entry: Decodable { var localizations: [String: Localization]? }

    var strings: [String: Entry]
}

extension String {
    /// The first format specifier, "%lld", "%@" or a positional "%2$lld"; `nil` when there is none.
    fileprivate var firstSpecifier: String? {
        guard let range = range(of: #"%(\d+\$)?(lld|@)"#, options: .regularExpression) else { return nil }
        return String(self[range])
    }
}
