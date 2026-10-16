import Foundation
import Testing

@testable import JutsuCore

@Test(arguments: [
    (10, 3, [4, 3, 3]),
    (12, 4, [3, 3, 3, 3]),
    (5, 1, [5]),
    (1, 2, [1, 0]),
])
func creditsSplitIntoWholeSharesThatAddUp(total: Int, parts: Int, shares: [Int]) {
    let split = Cost.credits(Decimal(total), isEstimate: false).split(into: parts)
    #expect(split == shares.map { .credits(Decimal($0), isEstimate: false) })
}

@Test func fractionalCreditsSplitEvenly() {
    #expect(
        Cost.credits(1.5, isEstimate: false).split(into: 3)
            == Array(repeating: .credits(0.5, isEstimate: false), count: 3))
}

@Test func dollarsSplitEvenly() {
    let split = Cost.usd(3.9, isEstimate: true).split(into: 3)
    #expect(split.count == 3)
    #expect(split.allSatisfy { $0.isEstimate })
    #expect(split.map(\.amount).reduce(0, +) == 3.9)
    #expect(Cost.usd(1, isEstimate: false).split(into: 0).isEmpty)
}

@Test func aPriceTimesTheVariants() {
    #expect(Cost.credits(14, isEstimate: true).times(3) == .credits(42, isEstimate: true))
    #expect(Cost.usd(1.5, isEstimate: false).times(2) == .usd(3, isEstimate: false))
}

@Test func aSpecStoredBeforeVariantsMakesOne() throws {
    var spec = makeSpec()
    spec.variants = 3
    var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(spec)) as? [String: Any])
    #expect(object.removeValue(forKey: "variants") as? Int == 3)

    let decoded = try JSONDecoder().decode(JobSpec.self, from: JSONSerialization.data(withJSONObject: object))

    #expect(decoded.variants == 1)
    #expect(try JSONDecoder().decode(JobSpec.self, from: JSONEncoder().encode(spec)).variants == 3)
}
