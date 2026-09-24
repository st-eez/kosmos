import Testing
@testable import KosmosCore

@Test func aTimeoutWhileRecoveringKeepsAsking() {
    var backoff = AXBackoff<Int>()
    let startsAsking = backoff.timedOut(at: 1)
    #expect(startsAsking && backoff.backedOff)
    let since = backoff.answered()
    #expect(since == 1 && !backoff.backedOff)
    // Writing the held frames times out again.
    let startsAgain = backoff.timedOut(at: 2)
    let stops = backoff.settled(started: true)
    #expect(!startsAgain && !stops)
    #expect(backoff.asking && backoff.backedOff)
    // The next answer, with no timeout after it, ends the backoff.
    let sinceAgain = backoff.answered()
    let stopsNow = backoff.settled(started: true)
    #expect(sinceAgain == 2 && stopsNow)
    #expect(!backoff.asking && !backoff.backedOff)
}

@Test func aWorkerThatHasNotStartedKeepsAsking() {
    var backoff = AXBackoff<Int>()
    let startsAsking = backoff.notStarted()
    // Calls still go: a launching app fails fast rather than waiting out the timeout.
    #expect(startsAsking && !backoff.backedOff)
    let since = backoff.answered()
    let stops = backoff.settled(started: false)
    #expect(since == nil && !stops && backoff.asking)
    let stopsOnceStarted = backoff.settled(started: true)
    #expect(stopsOnceStarted && !backoff.asking)
}

@Test func askingStartsOnce() {
    var backoff = AXBackoff<Int>()
    let first = backoff.notStarted(), second = backoff.timedOut(at: 1), third = backoff.notStarted()
    #expect(first && !second && !third)
}
