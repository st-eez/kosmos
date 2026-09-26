import Testing
@testable import KosmosCore

@Test func theFirstSweepSeesTheWindowsThereAtLaunch() {
    var sweeps = Sweeps()
    let started = sweeps.start()
    let first = sweeps.finish(read: [1, 2], tracked: [])
    #expect(started && first == Sweeps.Snapshot(seen: [1, 2], lost: [], first: true))
    #expect(sweeps.atLaunch == [1, 2])
    _ = sweeps.start()
    let second = sweeps.finish(read: [3], tracked: [1, 2])
    #expect(second == Sweeps.Snapshot(seen: [3], lost: [1, 2], first: false))
    #expect(sweeps.atLaunch == [1, 2])
}

/// 5 was created and 6 destroyed after the snapshot, and 1 changed: each keeps what its event
/// said. 3 is gone with no event, which the sweep catches.
@Test func aWindowAnEventNamesDuringASweepKeepsWhatTheEventSaid() {
    var sweeps = Sweeps()
    _ = sweeps.start()
    sweeps.touch([1, 5, 6])
    let snapshot = sweeps.finish(read: [1, 2, 6], tracked: [1, 3, 5, 6])
    #expect(snapshot?.seen == [2])
    #expect(snapshot?.lost == [3])
    // Named with no sweep reading, a window counts for no sweep.
    sweeps.touch([2])
    _ = sweeps.start()
    let next = sweeps.finish(read: [2], tracked: [2])
    #expect(next?.seen == [2])
}

@Test func aSweepAskedForWhileOneReadsStartsOnceItEnds() {
    var sweeps = Sweeps()
    let first = sweeps.start(), second = sweeps.start(), third = sweeps.start()
    #expect(first && !second && !third && sweeps.again)
    sweeps.touch([4])
    _ = sweeps.finish(read: [], tracked: [4])
    let again = sweeps.takeAgain(), twice = sweeps.takeAgain()
    #expect(again && !twice)
    // The next sweep counts no window touched during the one before.
    let restarted = sweeps.start()
    let snapshot = sweeps.finish(read: [], tracked: [4])
    #expect(restarted && snapshot?.lost == [4])
}

/// A failed read, or one that came while locked, would read as every window gone.
@Test func aSweepWhoseReadFailedChangesNothingAndIsNotTheFirst() {
    var sweeps = Sweeps()
    _ = sweeps.start()
    sweeps.touch([1])
    let failed = sweeps.finish(read: nil, tracked: [1, 2])
    #expect(failed == nil && sweeps.atLaunch.isEmpty)
    let started = sweeps.start()
    let snapshot = sweeps.finish(read: [1], tracked: [1, 2])
    #expect(started && snapshot == Sweeps.Snapshot(seen: [1], lost: [2], first: true))
}
