import Foundation
import Testing

@testable import JutsuCore

@Suite struct FailureReasonTests {
    private func roundTrip(_ state: JobState) throws -> JobState {
        try JSONDecoder().decode(JobState.self, from: JSONEncoder().encode(state))
    }

    @Test func everyReasonRoundTripsInAFailedState() throws {
        for reason in FailureReason.coded + [.message("Prompt is too long"), .message("")] {
            #expect(try roundTrip(.failed(reason: reason)) == .failed(reason: reason))
        }
    }

    @Test func eachReasonOfTheAppHasItsOwnCode() throws {
        let encoded = try FailureReason.coded.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
        #expect(Set(encoded).count == FailureReason.coded.count)
        #expect(encoded.allSatisfy { $0.hasPrefix(#"{"code":"#) })
    }

    /// Server text is stored as it came, so a message that reads like a code stays a message.
    @Test func aMessageIsStoredAsPlainText() throws {
        let data = try JSONEncoder().encode(JobState.failed(reason: .message("deadline")))
        #expect(String(decoding: data, as: UTF8.self) == #"{"failed":{"reason":"deadline"}}"#)
        #expect(try roundTrip(.failed(reason: .message("deadline"))) == .failed(reason: .message("deadline")))
    }

    /// The shape of a failed job stored before the reasons had cases.
    @Test func aReasonStoredAsTextReadsAsAMessage() throws {
        let json = #"{"failed":{"reason":"Higgsfield didn't finish this job in time."}}"#
        #expect(
            try JSONDecoder().decode(JobState.self, from: Data(json.utf8))
                == .failed(reason: .message("Higgsfield didn't finish this job in time.")))
    }

    /// A newer version's reason still lets the job load.
    @Test func anUnknownCodeReadsAsAnInternalError() throws {
        let json = #"{"failed":{"reason":{"code":"somethingNew"}}}"#
        #expect(try JSONDecoder().decode(JobState.self, from: Data(json.utf8)) == .failed(reason: .internalError))
    }
}
