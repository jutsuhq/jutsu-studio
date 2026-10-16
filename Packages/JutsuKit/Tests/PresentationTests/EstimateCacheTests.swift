import Foundation
import JutsuCore
import JutsuTestSupport
import Testing

@testable import Presentation

/// Credit estimates on the Create screen while the form changes.
@Suite(.timeLimit(.minutes(1)))
struct EstimateCacheTests {
    private static let account = CreateContext(connection: .account(AccountInfo(credits: 5_000)))

    private static func context(_ cache: EstimateCache, cap: SpendCap? = nil) -> CreateContext {
        var context = account
        context.estimates = cache.costs
        context.lastTotals = cache.lastTotals
        context.cap = cap
        return context
    }

    private static func record(_ form: CreateForm, generate: Int, draft: Int, in cache: inout EstimateCache) {
        let specs = form.makeSpecs(isDraft: false)
        let drafts = form.makeSpecs(isDraft: true)
        var fresh: [JobSpec: Cost] = [:]
        for spec in specs { fresh[spec] = .credits(Decimal(generate), isEstimate: true) }
        for spec in drafts { fresh[spec] = .credits(Decimal(draft), isEstimate: true) }
        cache.record(fresh, generate: specs, draft: drafts)
    }

    @Test func typingAPromptKeepsThePriceWithoutAskingAgain() {
        var form = CreateFixture.ready()
        var cache = EstimateCache()
        Self.record(form, generate: 120, draft: 40, in: &cache)

        form.prompt = "a fox in the snow"

        let specs = form.makeSpecs(isDraft: false) + form.makeSpecs(isDraft: true)
        #expect(specs.allSatisfy { $0.prompt == "a fox in the snow" })
        #expect(cache.missing(specs).isEmpty)
        let context = Self.context(cache)
        #expect(form.cost(isDraft: false, in: context) == .credits(120, isEstimate: true))
        #expect(form.priceText(isDraft: true, in: context) == "40 cr")
    }

    @Test func missingAsksForEachPriceOnce() {
        var form = CreateFixture.ready()
        form.prompt = "first"
        let spec = form.makeSpecs(isDraft: false)[0]
        var other = spec
        other.prompt = "second"
        var longer = spec
        longer.resolution = .p1080

        #expect(EstimateCache().missing([spec, other, longer]) == [spec.priceKey, longer.priceKey])
    }

    @Test func aChangedFormShowsTheLastPriceButNeverDecidesOnIt() {
        var form = CreateFixture.ready()
        var cache = EstimateCache()
        Self.record(form, generate: 120, draft: 40, in: &cache)

        form.resolution = .p1080
        let context = Self.context(cache, cap: .credits(1_000))

        #expect(!cache.missing(form.makeSpecs(isDraft: false)).isEmpty)
        #expect(form.priceText(isDraft: false, in: context) == "120 cr")
        #expect(form.priceText(isDraft: true, in: context) == "40 cr")
        #expect(form.costLine(in: context)?.text == "15 s = 120 credits")
        #expect(
            form.costLine(in: context)?.detail
                == "Updating the price · 5000 cr left on your plan · failed runs are free")
        #expect(form.cost(isDraft: false, in: context) == nil)
        guard case .confirm(_, let confirmation) = form.submitDecision(isDraft: false, in: context) else {
            Issue.record("expected a confirmation while the price is unknown")
            return
        }
        #expect(confirmation.title == "Price not known yet")
    }

    @Test func anIncompleteLoadKeepsTheLastTotal() {
        let form = CreateFixture.ready()
        var cache = EstimateCache()
        Self.record(form, generate: 120, draft: 40, in: &cache)

        var changed = form
        changed.resolution = .p1080
        cache.record([:], generate: changed.makeSpecs(isDraft: false), draft: changed.makeSpecs(isDraft: true))

        #expect(cache.lastTotals == [false: .credits(120, isEstimate: true), true: .credits(40, isEstimate: true)])
    }

    @Test func estimatesRunAtOnce() async throws {
        var form = CreateFixture.ready()
        form.setEnd(4)
        form.addRange()
        let keys = EstimateCache().missing(form.makeSpecs(isDraft: false) + form.makeSpecs(isDraft: true))
        try #require(keys.count == 4)
        let arrivals = Arrivals(expected: keys.count)

        // Each estimate waits until all have started: asked one after another, the first would never return.
        let costs = await EstimateCache.estimate(keys) { key in
            await arrivals.arrive()
            return key.isDraft ? nil : .credits(10, isEstimate: true)
        }

        #expect(Set(costs.keys) == Set(keys.filter { !$0.isDraft }))
    }

    /// A form changed during the pause cancels the load, and nothing is asked: dragging a trim handle quotes only
    /// where it stops.
    @Test func aChangeDuringTheDebounceAsksNothing() async throws {
        let keys = EstimateCache().missing(CreateFixture.ready().makeSpecs(isDraft: false))
        let asked = Asked()
        let pause = Gate<Void>()
        let load = Task {
            await EstimateCache.estimate(keys, after: .seconds(1), sleep: { _ in try await pause.wait() }) { key in
                await asked.add(key)
                return .credits(10, isEstimate: false)
            }
        }
        load.cancel()
        await pause.open(.success(()))
        #expect(await load.value == nil)
        #expect(await asked.keys.isEmpty)

        let costs = await EstimateCache.estimate(keys, after: .seconds(1), sleep: { _ in }) { key in
            await asked.add(key)
            return .credits(10, isEstimate: false)
        }
        #expect(costs.map(\.keys).map(Set.init) == Set(keys))
        #expect(await asked.keys == keys)
    }

    /// Nothing to price asks nothing and doesn't wait.
    @Test func noMissingKeysSkipTheDebounce() async {
        let costs = await EstimateCache.estimate([], after: .seconds(60), sleep: { _ in Issue.record("waited") }) { _ in
            Issue.record("asked")
            return nil
        }
        #expect(costs == [:])
    }
}

private actor Asked {
    private(set) var keys: [JobSpec] = []

    func add(_ key: JobSpec) { keys.append(key) }
}

@Suite struct UnknownPriceDecisionTests {
    @Test func underACapAnUnknownPriceAsks() {
        let spec = CreateFixture.ready().makeSpecs(isDraft: false)[0]
        #expect(SubmitDecision.budgeted([spec], cost: nil, committedToday: 0, cap: nil) == .start([spec]))
        guard
            case .confirm(let specs, let confirmation) = SubmitDecision.budgeted(
                [spec, spec], cost: nil, committedToday: 300, cap: .credits(1_000))
        else {
            Issue.record("expected a confirmation")
            return
        }
        #expect(specs == [spec, spec])
        #expect(
            confirmation.message
                == "These 2 jobs' price isn't known, so it may take today past your 1000 credits cap. "
                + "Today is at 300 credits so far.")
        #expect(confirmation.confirmTitle == "Start anyway")
    }
}

/// Holds every caller until `expected` of them have arrived.
private actor Arrivals {
    let expected: Int
    private var count = 0
    private let gate = Gate<Void>()

    init(expected: Int) { self.expected = expected }

    func arrive() async {
        count += 1
        if count == expected { await gate.open(.success(())) }
        _ = try? await gate.wait()
    }
}
