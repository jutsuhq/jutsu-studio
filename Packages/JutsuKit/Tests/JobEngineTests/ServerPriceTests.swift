import Foundation
import Testing

@testable import JobEngine
@testable import JutsuCore

@Suite(.timeLimit(.minutes(1)))
struct ServerPriceTests {
    @Test func spendingThatBecomesUnreadableAfterEnqueuePreventsSubmission() async throws {
        let harness = Harness()
        let log = harness.log
        let engine = try await harness.makeEngine { _ in
            log.append("readSpend")
            if log.count("readSpend") > 1 { throw BudgetError.spendingUnavailable }
            return SpendStatus(committedToday: 0, cap: .usd(10))
        }
        let job = try await engine.enqueue(makeSpec())
        #expect(
            await harness.repository.wait(
                for: job.id, .failed(reason: .message(BudgetError.spendingUnavailable.localizedDescription))) != nil)
        #expect(await harness.provider.submitKeys.isEmpty)
    }

    @Test func quoteIsKeptNextToThePreliminaryPriceAndCountsForTheCap() async throws {
        let harness = Harness(spendStatus: SpendStatus(committedToday: 0, cap: .usd(10)))
        await harness.provider.setQuote(.success(.usd(1.25, isEstimate: false)))
        let engine = try await harness.makeEngine()

        let job = try await engine.enqueue(makeSpec())
        let done = try #require(await harness.repository.wait(for: job.id, .done))

        #expect(done.cost == .usd(1.3, isEstimate: false))
        #expect(done.serverPrice == .usd(1.25, isEstimate: false))
        #expect(done.price == .usd(1.25, isEstimate: false))
        let log = harness.log.all
        let quoted = try #require(log.firstIndex(of: "serverEstimate"))
        #expect(try quoted > #require(log.lastIndex(of: "upload")))
        #expect(try quoted < #require(log.firstIndex(of: "submit")))
    }

    @Test func quoteOverTheCapPausesUntilTheUserAgrees() async throws {
        let harness = Harness(spendStatus: SpendStatus(committedToday: 1, cap: .usd(3)))
        await harness.provider.setQuote(.success(.usd(2.5, isEstimate: false)))
        let engine = try await harness.makeEngine()

        let job = try await engine.enqueue(makeSpec())
        let paused = try #require(await harness.repository.wait(for: job.id, .paused(.priceAboveCap)))

        #expect(paused.serverPrice == .usd(2.5, isEstimate: false))
        #expect(paused.approvedPrice == nil)
        #expect(await harness.provider.submitKeys.isEmpty)

        try await engine.resume(job.id)
        let done = try #require(await harness.repository.wait(for: job.id, .done))
        #expect(done.approvedPrice == .usd(2.5, isEstimate: false))
        #expect(await harness.provider.submitKeys == [job.idempotencyKey])
        #expect(harness.log.count("serverEstimate") == 1)
    }

    @Test func aQuoteWithinThePriceAgreedOverTheCapIsNotAskedAgain() async throws {
        let harness = Harness(spendStatus: SpendStatus(committedToday: 2, cap: .usd(3)))
        await harness.provider.setQuote(.success(.usd(1.25, isEstimate: false)))
        let engine = try await harness.makeEngine()

        let job = try await engine.enqueue(makeSpec(), overCapApproved: true)

        #expect(job.approvedPrice == .usd(1.3, isEstimate: false))
        #expect(await harness.repository.wait(for: job.id, .done) != nil)
        let states = await harness.repository.states(of: job.id)
        #expect(!states.contains(.paused(.priceAboveCap)))
    }

    /// Agreeing to go over the cap by the estimate isn't agreeing to any price the server quotes later.
    @Test func aQuoteAboveThePriceAgreedOverTheCapIsAskedAgain() async throws {
        let harness = Harness(spendStatus: SpendStatus(committedToday: 2, cap: .usd(3)))
        await harness.provider.setQuote(.success(.usd(2.5, isEstimate: false)))
        let engine = try await harness.makeEngine()

        let job = try await engine.enqueue(makeSpec(), overCapApproved: true)

        #expect(await harness.repository.wait(for: job.id, .paused(.priceAboveCap)) != nil)
        #expect(await harness.provider.submitKeys.isEmpty)
    }

    @Test func failedQuoteFallsBackToThePreliminaryPrice() async throws {
        let harness = Harness(spendStatus: SpendStatus(committedToday: 0, cap: .usd(1)))
        await harness.provider.setQuote(.failure(.server(status: 503)))
        let engine = try await harness.makeEngine()

        let job = try await engine.enqueue(makeSpec(), overCapApproved: true)
        let done = try #require(await harness.repository.wait(for: job.id, .done))

        #expect(done.serverPrice == nil)
        #expect(done.price == .usd(1.3, isEstimate: false))
        #expect(await harness.provider.submitKeys == [job.idempotencyKey])
    }

    @Test func submitAnsweredCompletedDownloadsWithoutPolling() async throws {
        let harness = Harness()
        await harness.provider.answerSubmits(with: .completed(videoURL: URL(string: "https://cdn.example/now.mp4")!))
        let engine = try await harness.makeEngine()

        let job = try await engine.enqueue(makeSpec())
        let done = try #require(await harness.repository.wait(for: job.id, .done))

        #expect(await harness.provider.statusCalls == 0)
        #expect(done.chargedAt != nil)
        #expect(done.remote?.initialStatus == nil)
    }

    @Test func submitAnsweredRejectedEndsTheJobAtOnce() async throws {
        let harness = Harness()
        await harness.provider.answerSubmits(with: .rejected(.explicitContent))
        let engine = try await harness.makeEngine()

        let job = try await engine.enqueue(makeSpec())

        #expect(await harness.repository.wait(for: job.id, .rejected) != nil)
        #expect(await harness.provider.statusCalls == 0)
        #expect(await engine.limiter.inUse == 0)
    }

    /// A Topaz upscale is queued without a price; once it finishes, what the provider says it charged becomes its
    /// price, and the cap counts it from then on.
    @Test func anUnknownPriceIsFilledInWithTheChargeOnceTheJobFinishes() async throws {
        let harness = Harness()
        await harness.provider.setPreliminary(.unknownCredits)
        await harness.provider.setCharge(.success(.credits(40, isEstimate: false)))
        let engine = try await harness.makeEngine()

        let job = try await engine.enqueue(makeSpec())
        let done = try #require(await harness.repository.wait(for: job.id, .done))

        #expect(done.cost == .unknownCredits)
        #expect(done.serverPrice == .credits(40, isEstimate: false))
        #expect(!done.priceIsUnknown)
        #expect(harness.log.count("charge") == 1)
    }

    @Test func aChargeThatCantBeReadLeavesThePriceUnknown() async throws {
        let harness = Harness()
        await harness.provider.setPreliminary(.unknownCredits)
        await harness.provider.setCharge(.failure(.server(status: 503)))
        let engine = try await harness.makeEngine()

        let job = try await engine.enqueue(makeSpec())
        let done = try #require(await harness.repository.wait(for: job.id, .done))

        #expect(done.serverPrice == nil)
        #expect(done.priceIsUnknown)
    }

    @Test func aKnownPriceIsNeverLookedUpAfterTheRun() async throws {
        let harness = Harness()
        await harness.provider.setCharge(.success(.usd(9, isEstimate: false)))
        let engine = try await harness.makeEngine()

        let job = try await engine.enqueue(makeSpec())
        let done = try #require(await harness.repository.wait(for: job.id, .done))

        #expect(done.price == .usd(1.3, isEstimate: false))
        #expect(harness.log.count("charge") == 0)
    }
}
