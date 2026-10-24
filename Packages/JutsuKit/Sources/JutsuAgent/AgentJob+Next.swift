import Foundation

extension AgentJob {
    /// This job as read again, keeping the `next` an earlier answer gave it while it still waits in the same state for
    /// the same reason: a raise of `max_cost` still held says why, and a `create_video` wait reads the job again.
    public func keepingNext(of earlier: AgentJob) -> AgentJob {
        guard next == nil, state == earlier.state, pauseReason == earlier.pauseReason, hold == earlier.hold else {
            return self
        }
        var job = self
        job.next = earlier.next
        return job
    }
}
