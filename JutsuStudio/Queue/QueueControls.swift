import JobEngine
import Presentation
import SwiftUI

/// Pause all and Resume all, in the Queue header and the menu bar panel. Each is disabled while it
/// would change no job, or while one of them runs.
struct QueueControls: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        HStack(spacing: Theme.Spacing.small) {
            Button {
                environment.runOnAllJobs { await $0.pauseAll() }
            } label: {
                Label("Pause all", systemImage: "pause.fill")
            }
            .disabled(!environment.canPauseAll)
            .hoverHint("Pause all: jobs not yet submitted wait; submitted jobs still finish and download")
            Button {
                environment.runOnAllJobs { await $0.resumeAll() }
            } label: {
                Label("Resume all", systemImage: "play.fill")
            }
            .disabled(!environment.canResumeAll)
            .hoverHint("Resume all: the jobs you paused start again")
        }
    }
}

/// Pause All and Resume All for the Queue header, the menu bar panel and the Queue menu, one at a time.
extension AppEnvironment {
    /// Pause All has a job to stop and neither runs yet.
    var canPauseAll: Bool { !isChangingAllJobs && liveJobs.canPauseAll }

    /// Resume All has a job the user paused and neither runs yet.
    var canResumeAll: Bool { !isChangingAllJobs && liveJobs.canResumeAll }

    /// Runs `action` unless Pause All or Resume All is already running; both stay disabled until it returns.
    func runOnAllJobs(_ action: @escaping @Sendable (JobEngine) async -> Void) {
        guard !isChangingAllJobs else { return }
        let engine = engine
        isChangingAllJobs = true
        Task {
            defer { isChangingAllJobs = false }
            await action(engine)
        }
    }
}
