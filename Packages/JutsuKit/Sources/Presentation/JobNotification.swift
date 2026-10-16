import Foundation
import JutsuCore

/// A system notification about one job reaching a state the user has to know about.
public struct JobNotification: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable {
        case done
        case failed
        case rejected
        case paused

        /// `nil` for the states that don't notify: work in progress, and canceled or paused by the user.
        init?(_ state: JobState) {
            switch state {
            case .done: self = .done
            case .failed: self = .failed
            case .rejected: self = .rejected
            case .paused(.byUser): return nil
            case .paused: self = .paused
            default: return nil
            }
        }
    }

    /// The screen a click on the notification opens.
    public enum Destination: String, Sendable, Hashable {
        case queue
        case library
    }

    /// A button on the notification. Each runs what the same button does in the app.
    public enum Action: String, Sendable, Hashable, CaseIterable {
        /// Opens the result's page, where its final is priced and rendered.
        case renderFinal
        case showInFinder
        /// Retry, Retry download or Check again, whichever the job's Queue row offers.
        case retry

        public var title: String {
            switch self {
            case .renderFinal: String(localized: "Render Final…", bundle: .module)
            case .showInFinder: String(localized: "Show in Finder", bundle: .module)
            case .retry: String(localized: "Retry", bundle: .module)
            }
        }
    }

    /// The set of buttons a notification has; registered with the system once, by identifier.
    public enum Category: String, Sendable, Hashable, CaseIterable {
        case draftResult = "job.draft-result"
        case result = "job.result"
        case retryable = "job.retryable"

        public var actions: [Action] {
            switch self {
            case .draftResult: [.renderFinal, .showInFinder]
            case .result: [.showInFinder]
            case .retryable: [.retry]
            }
        }
    }

    public var jobID: UUID
    public var kind: Kind
    /// What happened: "Video ready".
    public var title: String
    /// Which job: "dance · Motion transfer".
    public var subtitle: String
    /// Why, or how long it took; empty when there's nothing to add.
    public var body: String
    public var playsSound: Bool
    /// Groups the notifications of one batch in Notification Center; `nil` for a single job.
    public var threadID: String?
    /// The finished video, for the thumbnail of a "Video ready" notification.
    public var resultFile: URL?
    /// The notification's buttons; `nil` for none.
    public var category: Category?

    public var destination: Destination {
        kind == .done ? .library : .queue
    }

    init(_ job: Job, kind: Kind, playsSound: Bool = true) {
        let row = JobRowModel(job, now: job.createdAt)
        jobID = job.id
        self.kind = kind
        self.playsSound = playsSound
        title =
            switch kind {
            case .done: String(localized: "Video ready", bundle: .module)
            case .failed: String(localized: "Job failed", bundle: .module)
            case .rejected: String(localized: "Job rejected", bundle: .module)
            case .paused: String(localized: "Job paused", bundle: .module)
            }
        subtitle = row.title
        body = [row.note?.text, kind == .done ? Self.generated(job) : nil].compactMap(\.self)
            .joined(separator: "\n")
        threadID = job.batchID?.uuidString
        resultFile = kind == .done ? job.outputFile : nil
        category = Self.category(job, kind: kind, resultFile: resultFile)
    }

    private static func category(_ job: Job, kind: Kind, resultFile: URL?) -> Category? {
        switch kind {
        case .done where resultFile == nil: nil
        case .done: job.spec.isDraft ? .draftResult : .result
        case .failed: QueueJobCommands(job, now: job.createdAt).retry == nil ? nil : .retryable
        case .rejected, .paused: nil
        }
    }

    /// "Generated in 1 min 40 s": the API side, from submit until it finished; `nil` unless both are known.
    static func generated(_ job: Job) -> String? {
        guard let submittedAt = job.submittedAt, let chargedAt = job.chargedAt, chargedAt >= submittedAt
        else { return nil }
        let duration = JobRowModel.spoken(chargedAt.timeIntervalSince(submittedAt))
        return String(localized: "Generated in \(duration)", bundle: .module)
    }

    // MARK: Click payload

    private static let jobIDKey = "jobID"
    private static let destinationKey = "destination"
    private static let resultPathKey = "resultPath"

    /// Stored in the notification, so a click after a relaunch still finds the job and its file.
    public var userInfo: [String: String] {
        var info = [Self.jobIDKey: jobID.uuidString, Self.destinationKey: destination.rawValue]
        info[Self.resultPathKey] = resultFile?.path
        return info
    }

    /// The finished video `userInfo` names, for Show in Finder; `nil` when it names none.
    public static func resultFile(of userInfo: [AnyHashable: Any]) -> URL? {
        (userInfo[resultPathKey] as? String).map { URL(fileURLWithPath: $0) }
    }

    /// Reads back `userInfo`; `nil` for a notification this app didn't post.
    public static func target(of userInfo: [AnyHashable: Any]) -> (destination: Destination, jobID: UUID)? {
        guard let id = (userInfo[jobIDKey] as? String).flatMap(UUID.init(uuidString:)),
            let destination = (userInfo[destinationKey] as? String).flatMap(Destination.init(rawValue:))
        else { return nil }
        return (destination, id)
    }

    /// What the user did with a notification this app posted.
    public struct Response: Sendable, Hashable {
        public var destination: Destination
        public var jobID: UUID
        /// The button pressed; `nil` for a click on the notification itself.
        public var action: Action?
        /// The finished video, for Show in Finder.
        public var resultFile: URL?

        /// `nil` for a notification this app didn't post, or for a response that is neither a click nor one of
        /// its buttons, such as dismissing it.
        public init?(userInfo: [AnyHashable: Any], actionIdentifier: String, isDefaultAction: Bool) {
            guard let target = JobNotification.target(of: userInfo) else { return nil }
            if isDefaultAction {
                action = nil
            } else if let action = Action(rawValue: actionIdentifier) {
                self.action = action
            } else {
                return nil
            }
            destination = target.destination
            jobID = target.jobID
            resultFile = JobNotification.resultFile(of: userInfo)
        }
    }

    // MARK: Transitions

    /// The notifications for what changed between two snapshots of the queue.
    /// - Parameters:
    ///   - previous: the state of every job in the last snapshot.
    ///   - since: when observing started. A job missing from `previous` notifies only if it finished
    ///     after that, so finished jobs loaded from storage on launch stay quiet.
    public static func changes(
        from previous: [UUID: JobState], to current: [Job], since: Date, preferences: NotificationPreferences
    ) -> [JobNotification] {
        current.compactMap { job in
            guard let kind = Kind(job.state), preferences.allows(kind) else { return nil }
            if let old = previous[job.id] {
                guard Kind(old) != kind else { return nil }
            } else {
                guard kind != .paused, let finished = job.finishedAt, finished >= since else { return nil }
            }
            return JobNotification(job, kind: kind, playsSound: preferences.playsSound)
        }
    }
}

/// Remembers the last snapshot of the queue so each change notifies once.
public struct JobTransitionTracker: Sendable {
    private var states: [UUID: JobState] = [:]
    private let since: Date

    public init(since: Date) {
        self.since = since
    }

    /// The notifications to post for `jobs`, every job the app knows. Progress-only updates return none.
    public mutating func update(_ jobs: [Job], preferences: NotificationPreferences) -> [JobNotification] {
        let notifications = JobNotification.changes(from: states, to: jobs, since: since, preferences: preferences)
        states = Dictionary(jobs.map { ($0.id, $0.state) }) { _, latest in latest }
        return notifications
    }
}
