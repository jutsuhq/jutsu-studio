import Foundation
import Testing

@testable import JobEngine
@testable import JutsuCore

@Suite struct FailureReasonMappingTests {
    private struct Undescribed: Error {}

    @Test func aFullDiskBeforeSubmitIsItsOwnReason() {
        #expect(JobEngine.failureReason(for: POSIXError(.ENOSPC)) == .notEnoughDiskSpace)
    }

    @Test func anErrorWithADescriptionFailsWithIt() throws {
        let description = try #require(JobEngineError.notConnected.errorDescription)
        #expect(JobEngine.failureReason(for: JobEngineError.notConnected) == .message(description))
        guard case .message(let text) = JobEngine.failureReason(for: CocoaError(.fileWriteNoPermission)) else {
            Issue.record("A file system error should fail with Foundation's description")
            return
        }
        #expect(!text.isEmpty)
    }

    /// Its type name and payload mean nothing to the user.
    @Test func anErrorWithoutADescriptionIsAnInternalError() {
        #expect(JobEngine.failureReason(for: Undescribed()) == .internalError)
    }
}
