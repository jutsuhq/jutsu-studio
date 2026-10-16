import Foundation
import JutsuTestSupport
import Testing

@testable import JobEngine
@testable import JutsuCore

/// One submit of several variants (`JobSpec.variants`) becomes one job per variant, grouped as a batch.
@Suite(.timeLimit(.minutes(1)))
struct VariantsTests {
    func makeVariantSpec(_ variants: Int) -> JobSpec {
        var spec = makeSpec()
        spec.variants = variants
        return spec
    }

    @Test func oneSubmitBecomesAJobPerVariantInOneBatch() async throws {
        let harness = Harness()
        let engine = try await harness.makeEngine()

        let job = try await engine.enqueue(makeVariantSpec(3))
        #expect(job.batchID != nil)
        #expect(job.cost == .usd(3.9, isEstimate: false))
        await harness.repository.wait { snapshot in
            snapshot.jobs.values.filter { $0.batchID == job.batchID && $0.state == .done }.count == 3
        }

        let jobs = await harness.repository.snapshotJobs().filter { $0.batchID == job.batchID }
        #expect(harness.log.count("submit") == 1)
        #expect(jobs.count == 3)
        #expect(jobs.allSatisfy { $0.variantGroupID != nil })
        #expect(Set(jobs.compactMap(\.variantGroupID)).count == 1)
        #expect(Set(jobs.compactMap(\.remote?.requestID)) == ["r1", "r1-v1", "r1-v2"])
        #expect(jobs.allSatisfy { $0.spec.variants == 1 })
        #expect(jobs.allSatisfy { $0.outputFile != nil })
        #expect(jobs.allSatisfy { $0.missingVariants == nil })
        #expect(jobs.map(\.price.amount).reduce(0, +) == Decimal(string: "3.9"))
    }

    /// The quote is for the whole request: the jobs share it, so together they count it once.
    @Test func theRequestsQuoteIsSharedNotRepeated() async throws {
        let harness = Harness()
        await harness.provider.setQuote(.success(.credits(10, isEstimate: false)))
        let engine = try await harness.makeEngine()

        let job = try await engine.enqueue(makeVariantSpec(3))
        await harness.repository.wait { snapshot in
            snapshot.jobs.values.filter { $0.batchID == job.batchID && $0.state == .done }.count == 3
        }

        let jobs = await harness.repository.snapshotJobs().filter { $0.batchID == job.batchID }
        let sender = try #require(jobs.first { $0.id == job.id })
        #expect(sender.serverPrice == .credits(4, isEstimate: false))
        #expect(jobs.compactMap(\.serverPrice).map(\.amount).reduce(0, +) == 10)
        #expect(harness.log.count("serverEstimate") == 1)
    }

    @Test func fewerJobsThanAskedAreTrackedAndNoted() async throws {
        let harness = Harness()
        await harness.provider.startVariants(2)
        let engine = try await harness.makeEngine()

        let job = try await engine.enqueue(makeVariantSpec(4))
        await harness.repository.wait { snapshot in
            snapshot.jobs.values.filter { $0.batchID == job.batchID && $0.state == .done }.count == 2
        }
        await quiesce()

        let jobs = await harness.repository.snapshotJobs().filter { $0.batchID == job.batchID }
        let sender = try #require(jobs.first { $0.id == job.id })
        #expect(jobs.count == 2)
        #expect(sender.missingVariants == 2)
        #expect(Set(jobs.compactMap(\.remote?.requestID)) == ["r1", "r1-v1"])
        // Two of four shares: what the two started variants cost, not the whole request.
        #expect(jobs.map(\.price.amount).reduce(0, +) == Decimal(string: "2.6"))
    }

    /// Every job the answer names is saved and polling before the job that sent it takes its own answer, so a
    /// crash in between can't lose a paid variant.
    @Test func variantsAreSavedBeforeTheSendersAnswer() async throws {
        let harness = Harness()
        let gates = await harness.repository.holdSave {
            $0.state == .queued && $0.spec.variants == 1 && $0.remote?.requestID == "r1"
        }
        let engine = try await harness.makeEngine()

        let job = try await engine.enqueue(makeVariantSpec(3))
        try await gates.reached.wait()

        let variants = await harness.repository.snapshotJobs().filter { $0.batchID == job.batchID && $0.id != job.id }
        #expect(variants.count == 2)
        #expect(variants.allSatisfy { $0.remote != nil && $0.submittedAt != nil })
        await gates.release.open(.success(()))
        await harness.repository.wait { snapshot in
            snapshot.jobs.values.filter { $0.batchID == job.batchID && $0.state == .done }.count == 3
        }
    }

    /// The account caps an unlimited request to one generation, so the job asks for one.
    @Test func theUnlimitedAllowanceMakesOne() async throws {
        let harness = Harness()
        await harness.provider.payUnlimited(true)
        let engine = try await harness.makeEngine()

        let job = try await engine.enqueue(makeVariantSpec(3))
        _ = try #require(await harness.repository.wait(for: job.id, .done))

        #expect(job.spec.variants == 1)
        #expect(job.batchID == nil)
        #expect(await harness.repository.snapshotJobs().count == 1)
    }

    /// A submit of variants is sent once, like any other: an unknown outcome fails it without sending it again.
    @Test func anUnknownOutcomeIsNotSentAgain() async throws {
        let harness = Harness()
        await harness.provider.setIdempotent(false)
        await harness.provider.script(submit: [.fail(.outcomeUnknown)])
        let engine = try await harness.makeEngine()

        let job = try await engine.enqueue(makeVariantSpec(4))
        await harness.repository.wait(for: job.id, .failed(reason: .outcomeUnknown))
        await quiesce()

        #expect(harness.log.count("submit") == 1)
        #expect(await harness.repository.snapshotJobs().count == 1)
    }
}
