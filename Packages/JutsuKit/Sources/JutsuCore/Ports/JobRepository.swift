import Foundation

/// Durable job storage. The engine saves every state change before acting on it,
/// so a crash at any point resumes from the last saved state.
public protocol JobRepository: Sendable {
    func save(_ job: Job) async throws
    func job(id: UUID) async throws -> Job?
    /// Jobs that are not terminal, oldest first; resumed on launch.
    func activeJobs() async throws -> [Job]
    /// IDs of every stored job that is not terminal, including records `activeJobs` skips because they don't
    /// decode, so their scratch files are kept for a build that can read them.
    func activeJobIDs() async throws -> Set<UUID>
    func delete(id: UUID) async throws
}
