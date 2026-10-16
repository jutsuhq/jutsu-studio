import Testing

@testable import JutsuCore

private let allStates: [JobState] = [
    .preparing, .uploading, .waitingForSlot, .queued, .processing, .downloading, .done, .failed(reason: .message("x")),
    .rejected, .canceled, .paused(.insufficientFunds), .paused(.connectionNeedsAttention), .paused(.priceAboveCap),
    .paused(.notEnoughDiskSpace), .paused(.keptFailing), .paused(.byUser),
]

private let allEvents: [JobEvent] = [
    .prepared, .uploaded, .submitted, .hitConcurrencyLimit, .started, .completed, .downloaded,
    .failed(reason: .message("boom")),
    .rejected, .paused(.insufficientFunds), .paused(.connectionNeedsAttention), .paused(.priceAboveCap),
    .paused(.notEnoughDiskSpace), .paused(.keptFailing), .paused(.byUser), .cancel,
    .resume, .retry,
    .retryDownload, .checkAgain,
]

private struct Step: Hashable {
    let state: JobState
    let event: JobEvent
}

private let validTransitions: [Step: JobState] = {
    var table: [Step: JobState] = [
        Step(state: .preparing, event: .prepared): .uploading,
        Step(state: .uploading, event: .uploaded): .waitingForSlot,
        Step(state: .waitingForSlot, event: .submitted): .queued,
        Step(state: .waitingForSlot, event: .hitConcurrencyLimit): .waitingForSlot,
        Step(state: .queued, event: .started): .processing,
        Step(state: .queued, event: .completed): .downloading,
        Step(state: .processing, event: .completed): .downloading,
        Step(state: .downloading, event: .downloaded): .done,
        Step(state: .queued, event: .rejected): .rejected,
        Step(state: .processing, event: .rejected): .rejected,
        Step(state: .failed(reason: .message("x")), event: .retry): .preparing,
        Step(state: .canceled, event: .retry): .preparing,
        Step(state: .failed(reason: .message("x")), event: .retryDownload): .downloading,
        Step(state: .canceled, event: .retryDownload): .downloading,
        Step(state: .failed(reason: .message("x")), event: .checkAgain): .queued,
    ]
    for reason in [PauseReason.insufficientFunds, .connectionNeedsAttention, .priceAboveCap, .keptFailing, .byUser] {
        for state in [JobState.preparing, .uploading, .waitingForSlot] {
            table[Step(state: state, event: .paused(reason))] = .paused(reason)
        }
        table[Step(state: .paused(reason), event: .resume)] = .preparing
        table[Step(state: .paused(reason), event: .cancel)] = .canceled
    }
    table[Step(state: .paused(.connectionNeedsAttention), event: .paused(.byUser))] = .paused(.byUser)
    // Only a paid result waits for disk space, and resuming continues its download.
    table[Step(state: .downloading, event: .paused(.notEnoughDiskSpace))] = .paused(.notEnoughDiskSpace)
    table[Step(state: .paused(.notEnoughDiskSpace), event: .resume)] = .downloading
    table[Step(state: .paused(.notEnoughDiskSpace), event: .cancel)] = .canceled
    for state in [JobState.preparing, .uploading, .waitingForSlot, .queued, .downloading] {
        table[Step(state: state, event: .cancel)] = .canceled
    }
    for state in [JobState.preparing, .uploading, .waitingForSlot, .queued, .processing, .downloading] {
        table[Step(state: state, event: .failed(reason: .message("boom")))] = .failed(reason: .message("boom"))
    }
    return table
}()

@Test(arguments: allStates)
func everyStateEventPairMatchesTheTable(state: JobState) {
    for event in allEvents {
        let expected = validTransitions[Step(state: state, event: event)]
        #expect(JobState.transition(state, event) == expected, "\(state) + \(event)")
    }
}

@Test func terminalAndActiveFlags() {
    let terminal: [JobState] = [.done, .failed(reason: .message("x")), .rejected, .canceled]
    for state in allStates {
        #expect(state.isTerminal == terminal.contains(state), "\(state)")
        #expect(state.isActive == !terminal.contains(state), "\(state)")
    }
}

@Test func cancellableExceptWhileProcessing() {
    let cancellable: [JobState] = [
        .preparing, .uploading, .waitingForSlot, .queued, .downloading, .paused(.insufficientFunds),
        .paused(.connectionNeedsAttention), .paused(.priceAboveCap), .paused(.notEnoughDiskSpace),
        .paused(.keptFailing), .paused(.byUser),
    ]
    for state in allStates {
        #expect(state.isCancellable == cancellable.contains(state), "\(state)")
    }
}

@Test func userPausesOnlyWhatIsNotSubmittedOrHeldByTheUser() {
    let pausable: [JobState] = [.preparing, .uploading, .waitingForSlot, .paused(.connectionNeedsAttention)]
    for state in allStates {
        #expect(state.isPausableByUser == pausable.contains(state), "\(state)")
    }
}
