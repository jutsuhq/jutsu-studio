import Foundation
import JutsuCore

/// Gathers the members of each batch at the place of the first of them; everything else keeps its place.
/// A batch with a single member in the list stays a plain element: a group of one compares nothing.
enum BatchGrouping {
    enum Group<Element> {
        case single(Element)
        case batch(UUID, [Element])
    }

    static func group<Element>(_ elements: [Element], batchID: (Element) -> UUID?) -> [Group<Element>] {
        var members: [UUID: [Element]] = [:]
        for element in elements {
            if let id = batchID(element) { members[id, default: []].append(element) }
        }
        var placed = Set<UUID>()
        var groups: [Group<Element>] = []
        for element in elements {
            guard let id = batchID(element), let batch = members[id], batch.count > 1 else {
                groups.append(.single(element))
                continue
            }
            if placed.insert(id).inserted { groups.append(.batch(id, batch)) }
        }
        return groups
    }

    /// "4 styles" or "3 characters", after the mode the batch varies; "3 variants" for the jobs of one submit of
    /// variants (`areVariants`).
    static func variantText(count: Int, specs: [JobSpec]) -> String {
        if areVariants(specs) { return String(localized: "\(count) variants", bundle: .module) }
        return variantText(count: count, mode: specs.first?.mode ?? .restyle)
    }

    /// "4 styles" or "3 characters", after the mode the batch varies.
    static func variantText(count: Int, mode: Mode) -> String {
        mode == .restyle
            ? String(localized: "\(count) styles", bundle: .module)
            : String(localized: "\(count) characters", bundle: .module)
    }

    /// The jobs of one submit of variants (`JobSpec.variants`) share every input, where a batch of styles differs
    /// in its style and a batch of characters in its images.
    static func areVariants(_ specs: [JobSpec]) -> Bool {
        guard let first = specs.first, specs.count > 1, first.mode != .restyle else { return false }
        return specs.allSatisfy {
            $0.references == first.references && $0.presetID == first.presetID && $0.source == first.source
                && $0.prompt == first.prompt
        }
    }
}

/// The jobs of one batch under one Queue header, with their combined progress.
public struct JobBatch: Sendable, Hashable, Identifiable {
    public var id: UUID
    /// In the order they were queued.
    public var jobs: [Job]

    public init(id: UUID, jobs: [Job]) {
        self.id = id
        self.jobs = jobs.sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
    }

    /// "dance · Restyle batch · 4 styles".
    public var title: String {
        guard let first = jobs.first else { return String(localized: "Batch", bundle: .module) }
        let mode = first.spec.mode
        return [
            first.spec.name, String(localized: "\(mode.title) batch", bundle: .module),
            BatchGrouping.variantText(count: jobs.count, specs: jobs.map(\.spec)),
        ].joined(separator: " · ")
    }

    public var isActive: Bool { jobs.contains { $0.state.isActive } }

    /// 0…1 over all jobs: a finished job counts whole, a running one by its step and that step's progress.
    public var progress: Double {
        guard !jobs.isEmpty else { return 0 }
        return jobs.reduce(0) { $0 + Self.progress(of: $1) } / Double(jobs.count)
    }

    /// "2 of 4 done", "2 of 4 done · 1 failed".
    public var progressText: String {
        let done = jobs.count { $0.state == .done }
        let stopped = jobs.count { $0.state.isTerminal && $0.state != .done }
        let base = String(localized: "\(done) of \(jobs.count) done", bundle: .module)
        return stopped == 0 ? base : "\(base) · " + String(localized: "\(stopped) stopped", bundle: .module)
    }

    /// What the batch costs so far, "~$7.63" or "96 cr": the best known prices of the jobs that are or will be
    /// charged. `nil` when none is, or when they are paid in different units.
    public var totalCostText: String? {
        Cost.total(jobs.filter { !JobRowModel.isNotCharged($0) }.map(\.price)).map {
            JobRowModel.format($0, charged: true)
        }
    }

    static func progress(of job: Job) -> Double {
        if job.state.isTerminal { return 1 }
        guard let stage = JobRowModel.stage(job.state) else { return 0 }
        let within = job.state.reportsProgress ? min(max(job.progress, 0), 1) : 0
        return (Double(stage.rawValue) + within) / Double(JobRowModel.Stage.allCases.count)
    }
}

/// One row of the Queue: a job on its own, or a batch with its jobs under one header.
public enum QueueEntry: Sendable, Hashable, Identifiable {
    case job(Job)
    case batch(JobBatch)

    public var id: UUID {
        switch self {
        case .job(let job): job.id
        case .batch(let batch): batch.id
        }
    }

    /// The job, or the batch's jobs.
    public var jobs: [Job] {
        switch self {
        case .job(let job): [job]
        case .batch(let batch): batch.jobs
        }
    }

    /// `jobs` in order, a batch at the place of its first job.
    public static func group(_ jobs: [Job]) -> [QueueEntry] {
        BatchGrouping.group(jobs, batchID: \.batchID).map { group in
            switch group {
            case .single(let job): .job(job)
            case .batch(let id, let members): .batch(JobBatch(id: id, jobs: members))
            }
        }
    }
}
