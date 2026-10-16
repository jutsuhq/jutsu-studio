import Foundation
import JutsuCore

/// What the app does outside its window while jobs run (ARCHITECTURE §6, Background).
public enum BackgroundPolicy {
    /// Closing the last window keeps the app alive while the queue holds a job, paused ones included, or work outside
    /// the queue runs, so the menu bar and notifications keep working and nothing being paid for is cut off.
    public static func keepsRunning(activeCount: Int, images: ImageWork = .none) -> Bool {
        activeCount > 0 || images.running > 0
    }

    /// Whether App Nap has to be held off: some job is being prepared, uploaded, polled or downloaded.
    /// Paused jobs wait for the user and need no CPU.
    public static func needsActivity(_ jobs: [Job]) -> Bool {
        jobs.contains { $0.state.isActive && !$0.state.isPaused }
    }

    /// The Dock badge; `nil` removes it.
    public static func dockBadge(activeCount: Int) -> String? {
        activeCount > 0 ? String(activeCount) : nil
    }

    /// How long quitting waits for submits already sent to be answered (`JobEngine.stop`). Cut off, a submit
    /// without an idempotency key can't be sent again, so the job fails as possibly started.
    public static let submitGrace: Duration = .seconds(5)

    /// The confirmation shown on quit; `nil` quits right away. Logout, restart and shutdown never wait
    /// for an answer: blocking them would stall the system, and the jobs resume on next launch anyway.
    /// - Parameters:
    ///   - submittingCount: jobs among `activeCount` whose submit is out (`LiveJobs.submittingCount`).
    ///   - images: the image and character sheet requests outside the queue.
    public static func quitPrompt(
        activeCount: Int, submittingCount: Int = 0, images: ImageWork = .none, reason: QuitReason = .user
    )
        -> QuitPrompt?
    {
        guard reason == .user, activeCount > 0 || images.running > 0 else { return nil }
        guard activeCount > 0 else {
            return QuitPrompt(
                message: String(localized: "\(images.running) image requests are still running.", bundle: .module),
                detail: imageDetail(images))
        }
        let jobs = jobsPrompt(activeCount: activeCount, submittingCount: submittingCount)
        guard images.running > 0 else { return jobs }
        let also = String(localized: "\(images.running) image requests are running too.", bundle: .module)
        return QuitPrompt(message: jobs.message, detail: "\(jobs.detail) \(also) \(imageDetail(images))")
    }

    /// What quitting does to the requests outside the queue: the ones being sent or saved are waited for, and the
    /// ones being made are followed again on next launch.
    private static func imageDetail(_ images: ImageWork) -> String {
        let resumes = String(localized: "Images still being made are followed again on next launch.", bundle: .module)
        guard images.waiting > 0 else { return resumes }
        let seconds = submitGrace.components.seconds
        let waits = String(
            localized: "Quitting waits up to \(seconds) seconds for the ones being sent or saved.", bundle: .module)
        return "\(waits) \(resumes)"
    }

    private static func jobsPrompt(activeCount: Int, submittingCount: Int) -> QuitPrompt {
        let message = String(localized: "\(activeCount) jobs are still running.", bundle: .module)
        // Neither sentence names the count, and a plural variation must, so these are two strings.
        let resumes =
            activeCount == 1
            ? String(localized: "It resumes on next launch.", bundle: .module)
            : String(localized: "They resume on next launch.", bundle: .module)
        guard submittingCount > 0 else { return QuitPrompt(message: message, detail: resumes) }
        let seconds = submitGrace.components.seconds
        let sending =
            activeCount == 1
            ? String(
                localized: """
                    It is being sent to Higgsfield right now, so quitting waits up to \(seconds) seconds \
                    for Higgsfield to answer.
                    """, bundle: .module)
            : String(
                localized: """
                    \(submittingCount) of them are being sent to Higgsfield right now, so quitting waits up to \
                    \(seconds) seconds for Higgsfield to answer.
                    """, bundle: .module)
        return QuitPrompt(message: message, detail: "\(sending) \(resumes)")
    }
}

/// The work outside the queue a quit or a closed last window has to wait for: Generate… requests and character sheets
/// being sent or made, and finished images being saved into Library › Images.
public struct ImageWork: Sendable, Hashable {
    /// Requests being sent or followed, and images being saved.
    public var running: Int
    /// Among them, submits whose answer hasn't come and images being saved: quitting waits for these
    /// (`BackgroundPolicy.submitGrace`), since a cut-off submit or download loses what may be paid for.
    public var waiting: Int

    public init(running: Int, waiting: Int) {
        self.running = running
        self.waiting = waiting
    }

    public static let none = ImageWork(running: 0, waiting: 0)
}

/// Why the app is quitting, from the quit Apple event.
public enum QuitReason: Sendable, Hashable {
    /// ⌘Q, the menu bar's Quit, or a quit event without a reason.
    case user
    case logOut
    case restart
    case shutDown
}

public struct QuitPrompt: Sendable, Hashable {
    public var message: String
    public var detail: String
}
