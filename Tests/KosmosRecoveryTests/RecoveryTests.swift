import Testing
@testable import KosmosRecovery

/// The guardian tries again after these, while windows may still be concealed.
@Test func onlyAnIncompleteOrUnidentifiedRecoveryIsRetried() {
    #expect(!Recovery.Outcome.incomplete(remaining: 1).isFinal)
    #expect(!Recovery.Outcome.windowServerUnknown.isFinal)
    #expect(Recovery.Outcome.nothingRecorded.isFinal)
    #expect(Recovery.Outcome.staleSession.isFinal)
    #expect(Recovery.Outcome.restored(windows: 2, spaces: 1).isFinal)
}
