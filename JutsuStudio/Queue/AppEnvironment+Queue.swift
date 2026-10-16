import Foundation
import JutsuCore
import Presentation

extension AppEnvironment {
    /// Runs `command` on a job, for its Queue row, the Queue menu and its notification alike. Returns what to tell
    /// the user when the engine refuses it, e.g. a job that changed state meanwhile; `nil` when it ran.
    /// - Parameter kind: the job's connection, for the wording of the alert.
    func perform(_ command: JobCommand, on id: UUID, kind: ProviderKind?) async -> UserMessage? {
        do {
            switch command {
            case .cancel: try await engine.cancel(id)
            case .retry: try await engine.retry(id)
            case .checkAgain: try await engine.checkAgain(id)
            case .resume: try await engine.resume(id)
            case .runNext: try await engine.runNext(id)
            }
            return nil
        } catch {
            return UserMessage(error, kind: kind)
        }
    }
}
