import Foundation
import Testing

@testable import JutsuCore

@Suite struct GenerationTimesTests {
    static let start = Date(timeIntervalSince1970: 1_000_000)

    static func finished(
        _ spec: JobSpec, queueWait: TimeInterval = 10, processing: TimeInterval, id: UUID = UUID()
    ) -> Job {
        var job = Job(id: id, spec: spec, providerKind: .apiKey, cost: .usd(1, isEstimate: false), createdAt: start)
        job.submittedAt = start.addingTimeInterval(5)
        job.processingAt = start.addingTimeInterval(5 + queueWait)
        job.chargedAt = start.addingTimeInterval(5 + queueWait + processing)
        job.state = .done
        return job
    }

    @Test(
        arguments: [
            ([], nil), ([4.0], 4.0), ([3.0, 1, 2], 2.0), ([4.0, 1, 3, 2], 2.5), ([5.0, 5, 100], 5.0),
        ] as [([Double], Double?)])
    func median(values: [Double], expected: Double?) {
        #expect(GenerationTimes.median(values) == expected)
    }

    @Test(arguments: [(0, 5), (5, 5), (6, 10), (12, 15), (30, 30), (31, 60), (61, Int.max)])
    func lengthBuckets(billedSeconds: Int, bucket: Int) {
        #expect(GenerationTimes.lengthBucket(billedSeconds: billedSeconds) == bucket)
    }

    @Test func noEstimateWithFewerThanThreeSimilarJobs() {
        let spec = makeSpec(duration: 10)
        let times = GenerationTimes([
            Self.finished(spec, processing: 100), Self.finished(spec, processing: 120),
        ])
        #expect(times.estimate(for: spec) == nil)
    }

    @Test func estimateIsTheMedianOfSimilarJobs() throws {
        let spec = makeSpec(duration: 10)
        let times = GenerationTimes([
            Self.finished(spec, queueWait: 4, processing: 100), Self.finished(spec, queueWait: 30, processing: 600),
            Self.finished(spec, queueWait: 10, processing: 110),
        ])
        let estimate = try #require(times.estimate(for: spec))
        #expect(estimate == GenerationTimes.Estimate(queueWait: 10, processing: 110, sampleCount: 3))
        #expect(estimate.total == 120)
    }

    @Test func onlySimilarJobsCount() {
        let spec = makeSpec(duration: 10, resolution: .p720)
        var other = [
            makeSpec(duration: 10, resolution: .p1080), makeSpec(mode: .restyle, duration: 10, resolution: .p720),
            makeSpec(duration: 20, resolution: .p720),
        ]
        var otherModel = spec
        otherModel.model = .seedance25
        other.append(otherModel)
        let jobs = other.flatMap { spec in (0..<3).map { _ in Self.finished(spec, processing: 50) } }
        let times = GenerationTimes(jobs + [Self.finished(spec, processing: 90)])
        #expect(times.estimate(for: spec) == nil)
        #expect(times.estimate(for: otherModel)?.processing == 50)
    }

    @Test func lengthsInOneBucketShareAnEstimate() {
        let times = GenerationTimes([
            Self.finished(makeSpec(duration: 6), processing: 60), Self.finished(makeSpec(duration: 8), processing: 70),
            Self.finished(makeSpec(duration: 10), processing: 80),
        ])
        #expect(times.estimate(for: makeSpec(duration: 9))?.processing == 70)
        #expect(times.estimate(for: makeSpec(duration: 11)) == nil)
    }

    @Test func jobsWithoutAllTimestampsAreIgnored() {
        let spec = makeSpec()
        var notStarted = Self.finished(spec, processing: 60)
        notStarted.processingAt = nil
        var notSubmitted = Self.finished(spec, processing: 60)
        notSubmitted.submittedAt = nil
        var notCharged = Self.finished(spec, processing: 60)
        notCharged.chargedAt = nil
        let times = GenerationTimes([notStarted, notSubmitted, notCharged, Self.finished(spec, processing: 60)])
        #expect(times.estimate(for: spec) == nil)
        #expect(!times.needsRecording(notCharged))
    }

    @Test func recordingAJobAgainReplacesIt() {
        let spec = makeSpec()
        let id = UUID()
        var times = GenerationTimes([
            Self.finished(spec, processing: 60), Self.finished(spec, processing: 60),
            Self.finished(spec, processing: 60, id: id),
        ])
        let same = Self.finished(spec, processing: 60, id: id)
        #expect(!times.needsRecording(same))
        let slower = Self.finished(spec, processing: 300, id: id)
        #expect(times.needsRecording(slower))
        times.record([slower])
        #expect(times.estimate(for: spec)?.sampleCount == 3)
    }
}
