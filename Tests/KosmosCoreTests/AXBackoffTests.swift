import Testing
@testable import KosmosCore

@Test func aTimeoutWhileRecoveringKeepsAsking() {
    var backoff = AXBackoff()
    let startsAsking = backoff.timedOut(at: t0 + .milliseconds(1))
    #expect(startsAsking && backoff.backedOff)
    let since = backoff.answered()
    #expect(since == t0 + .milliseconds(1) && !backoff.backedOff)
    // Writing the held frames times out again.
    let startsAgain = backoff.timedOut(at: t0 + .milliseconds(2))
    let stops = backoff.settled(started: true)
    #expect(!startsAgain && !stops)
    #expect(backoff.asking && backoff.backedOff)
    // The next answer, with no timeout after it, ends the backoff.
    let sinceAgain = backoff.answered()
    let stopsNow = backoff.settled(started: true)
    #expect(sinceAgain == t0 + .milliseconds(2) && stopsNow)
    #expect(!backoff.asking && !backoff.backedOff)
}

@Test func aWorkerThatHasNotStartedKeepsAsking() {
    var backoff = AXBackoff()
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
    var backoff = AXBackoff()
    let first = backoff.notStarted(), second = backoff.timedOut(at: t0 + .milliseconds(1)), third = backoff.notStarted()
    #expect(first && !second && !third)
}
