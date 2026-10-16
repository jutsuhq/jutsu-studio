import Foundation

/// How long the API took to generate the user's past jobs, grouped by what drives that time. The API reports
/// no progress while it generates, so the median of similar jobs is the only sense of time left there is.
public struct GenerationTimes: Sendable, Hashable {
    /// What makes two jobs comparable. Billed length is bucketed rather than scaled per second: generation
    /// time has a large fixed part, so scaling a 5 s job to a 60 s one would be far off.
    public struct Key: Sendable, Hashable {
        public var model: VideoModel
        public var mode: Mode
        public var resolution: Resolution
        /// The upper bound of the billed length bucket, in seconds; `Int.max` for the longest one.
        public var lengthBucket: Int

        public init(_ spec: JobSpec) {
            model = spec.model
            mode = spec.mode
            resolution = spec.resolution
            lengthBucket = GenerationTimes.lengthBucket(
                billedSeconds: Pricing.billedSeconds(spec.duration))
        }
    }

    /// The typical API side of a job: the Generate step, from submit until the API finished it.
    public struct Estimate: Sendable, Hashable {
        /// Median seconds from submit until the API started generating.
        public var queueWait: TimeInterval
        /// Median seconds from the start of the generation until the API finished it.
        public var processing: TimeInterval
        /// How many past jobs the medians come from.
        public var sampleCount: Int

        public init(queueWait: TimeInterval, processing: TimeInterval, sampleCount: Int) {
            self.queueWait = queueWait
            self.processing = processing
            self.sampleCount = sampleCount
        }

        public var total: TimeInterval { queueWait + processing }
    }

    /// Fewer similar jobs than this give no estimate: one slow outlier would be the whole answer.
    public static let minimumSamples = 3

    /// Upper bounds of the billed length buckets, in seconds.
    static let lengthBuckets = [5, 10, 15, 30, 60]

    private struct Sample: Sendable, Hashable {
        var queueWait: TimeInterval
        var processing: TimeInterval

        init?(_ job: Job) {
            guard let submittedAt = job.submittedAt, let processingAt = job.processingAt,
                let processing = job.processingTime
            else { return nil }
            let queueWait = processingAt.timeIntervalSince(submittedAt)
            guard queueWait >= 0, processing >= 0 else { return nil }
            self.queueWait = queueWait
            self.processing = processing
        }
    }

    private var samples: [Key: [UUID: Sample]] = [:]
    private var estimates: [Key: Estimate] = [:]

    public init(_ jobs: [Job] = []) {
        record(jobs)
    }

    /// The typical time for `spec`; `nil` with fewer than `minimumSamples` similar jobs.
    public func estimate(for spec: JobSpec) -> Estimate? {
        estimates[Key(spec)]
    }

    /// `record` would change the estimates: the job has timings not recorded yet.
    public func needsRecording(_ job: Job) -> Bool {
        guard let sample = Sample(job) else { return false }
        return samples[Key(job.spec)]?[job.id] != sample
    }

    /// Adds the timings of jobs the API finished; other jobs are ignored, and a job recorded again replaces itself.
    public mutating func record(_ jobs: [Job]) {
        var changed: Set<Key> = []
        for job in jobs {
            guard let sample = Sample(job) else { continue }
            let key = Key(job.spec)
            samples[key, default: [:]][job.id] = sample
            changed.insert(key)
        }
        for key in changed {
            estimates[key] = Self.estimate(from: Array(samples[key, default: [:]].values))
        }
    }

    private static func estimate(from samples: [Sample]) -> Estimate? {
        guard samples.count >= minimumSamples, let queueWait = median(samples.map(\.queueWait)),
            let processing = median(samples.map(\.processing))
        else { return nil }
        return Estimate(queueWait: queueWait, processing: processing, sampleCount: samples.count)
    }

    /// The middle value, or the mean of the two middle ones; `nil` for no values.
    public static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

    static func lengthBucket(billedSeconds: Int) -> Int {
        lengthBuckets.first { billedSeconds <= $0 } ?? .max
    }
}
