import Foundation

/// Whose turn it is to save a change of each job (`JobEngine.apply`, `save`): one writer per job at a time, so each
/// change starts from the last saved one. Owned and changed only by the engine's actor.
struct WriteTurns {
    private var writers: Set<UUID> = []
    private var waiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]

    /// Takes job `id`'s turn; `false` while another writer has it.
    mutating func take(_ id: UUID) -> Bool {
        writers.insert(id).inserted
    }

    /// `waiter` is resumed when job `id`'s turn ends; it then tries `take` again.
    mutating func wait(for id: UUID, _ waiter: CheckedContinuation<Void, Never>) {
        waiters[id, default: []].append(waiter)
    }

    /// Ends job `id`'s turn and resumes its waiters.
    mutating func end(_ id: UUID) {
        writers.remove(id)
        for waiter in waiters.removeValue(forKey: id) ?? [] { waiter.resume() }
    }

    func hasWaiters(for id: UUID) -> Bool {
        waiters[id]?.isEmpty == false
    }
}
