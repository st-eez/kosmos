import Testing
@testable import KosmosRecovery

private let t0 = ContinuousClock.now
private let deadline = t0 + .seconds(30)

@Test func theGuardianExitsOnceNoAttemptCouldRestoreMore() {
    let finals: [Recovery.Outcome] = [.nothingRecorded, .staleSession, .restored(windows: 2, spaces: 1),
                                      .adopted(kept: 1, restored: 1, spaces: 0)]
    for outcome in finals {
        #expect(Recovery.guardianExit(after: outcome, at: t0, retryingUntil: deadline) == 0)
        #expect(Recovery.guardianExit(after: outcome, at: deadline, retryingUntil: deadline) == 0)
    }
}

/// An exit here would leave the windows concealed with no process to restore them.
@Test func theGuardianAttemptsAgainUntilTheDeadlineWhileWindowsMayStayConcealed() {
    let open: [Recovery.Outcome?] = [.incomplete(remaining: 1), .windowServerUnknown, nil]
    for outcome in open {
        #expect(Recovery.guardianExit(after: outcome, at: t0, retryingUntil: deadline) == nil)
        #expect(Recovery.guardianExit(after: outcome, at: deadline - .milliseconds(1), retryingUntil: deadline) == nil)
        #expect(Recovery.guardianExit(after: outcome, at: deadline, retryingUntil: deadline) == 1)
    }
}
