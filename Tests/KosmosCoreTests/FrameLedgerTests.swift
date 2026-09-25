import CoreGraphics
import Testing
@testable import KosmosCore

private let a = CGRect(x: 0, y: 0, width: 800, height: 600)
private let moved = CGRect(x: 100, y: 0, width: 800, height: 600)
private let resized = CGRect(x: 0, y: 0, width: 400, height: 600)
private let t0 = ContinuousClock.now

@Test func firstTargetWritesTheWholeFrame() {
    var ledger = FrameLedger()
    #expect(ledger.writes(for: [1: a]) == [1: .frame(a)])
}

@Test func pendingOrConfirmedTargetIsNotWrittenAgain() {
    var ledger = FrameLedger()
    _ = ledger.writes(for: [1: a])
    #expect(ledger.writes(for: [1: a]).isEmpty)
    ledger.confirm(1, target: a, readBack: a, at: t0)
    #expect(ledger.writes(for: [1: a]).isEmpty)
}

@Test func sameSizeWritesPositionOnly() {
    var ledger = FrameLedger()
    _ = ledger.writes(for: [1: a])
    ledger.confirm(1, target: a, readBack: a, at: t0)
    #expect(ledger.writes(for: [1: moved]) == [1: .position(moved.origin)])
    #expect(ledger.writes(for: [1: resized]) == [1: .frame(resized)])
}

@Test func newestTargetWinsOverPending() {
    var ledger = FrameLedger()
    _ = ledger.writes(for: [1: a])
    #expect(ledger.writes(for: [1: resized]) == [1: .frame(resized)])
    // The read back of the older write does not clear the newer pending target.
    ledger.confirm(1, target: a, readBack: a, at: t0)
    #expect(ledger.writes(for: [1: resized]).isEmpty)
}

@Test func refusedSizeIsNotRetriedUntilTargetChanges() {
    var ledger = FrameLedger()
    let kept = CGRect(x: 0, y: 0, width: 500, height: 600)
    _ = ledger.writes(for: [1: resized])
    ledger.confirm(1, target: resized, readBack: kept, at: t0)
    #expect(ledger.writes(for: [1: resized]).isEmpty)
    // The same target at another origin moves the window at its kept size.
    let shifted = CGRect(x: 50, y: 0, width: 400, height: 600)
    #expect(ledger.writes(for: [1: shifted]) == [1: .frame(shifted)])
    ledger.confirm(1, target: shifted, readBack: CGRect(x: 50, y: 0, width: 500, height: 600), at: t0)
    #expect(ledger.writes(for: [1: shifted]).isEmpty)
    // A new size is tried again.
    #expect(ledger.writes(for: [1: a]) == [1: .frame(a)])
}

@Test func userResizeIsWrittenBack() {
    var ledger = FrameLedger()
    _ = ledger.writes(for: [1: a])
    ledger.confirm(1, target: a, readBack: a, at: t0)
    ledger.observe(1, frame: resized)
    #expect(ledger.writes(for: [1: a]) == [1: .frame(a)])
}

@Test func aUserResizeEndsARefusal() {
    var ledger = FrameLedger()
    let kept = CGRect(x: 0, y: 0, width: 500, height: 600)
    _ = ledger.writes(for: [1: resized])
    ledger.confirm(1, target: resized, readBack: kept, at: t0)
    // The app's own report of the size it kept changes nothing.
    ledger.observe(1, frame: kept)
    #expect(ledger.writes(for: [1: resized]).isEmpty)
    // A drag to another size does: the target's size is written again.
    ledger.observe(1, frame: CGRect(x: 30, y: 0, width: 700, height: 600))
    #expect(ledger.writes(for: [1: resized]) == [1: .frame(resized)])
}

@Test func aPositionWriteReplacingAnUnwrittenFrameWriteWritesTheWholeFrame() {
    var ledger = FrameLedger()
    let first = ledger.writes(for: [1: a])[1]!
    // The ledger takes `a`'s size as landed, so the next target of that size moves only.
    let second = ledger.writes(for: [1: moved])[1]!
    #expect(second == .position(moved.origin))
    // Both wait in the worker's queue: the size must still be written.
    #expect(second.replacing(first, target: moved) == .frame(moved))
    #expect(second.replacing(.position(a.origin), target: moved) == .position(moved.origin))
    #expect(FrameWrite.frame(resized).replacing(.position(a.origin), target: resized) == .frame(resized))
}

@Test func aChangeThatCameBeforeTheConfirmIsTheWrites() {
    var ledger = FrameLedger()
    _ = ledger.writes(for: [1: a])
    #expect(ledger.isWriting(1, at: t0))
    ledger.confirm(1, target: a, readBack: a, at: t0 + .milliseconds(2))
    // The write's own change, applied after its read back confirmed it.
    #expect(ledger.isWriting(1, at: t0 + .milliseconds(1)))
    #expect(!ledger.isWriting(1, at: t0 + .milliseconds(3)))
    // Forgetting the window, as a mouse up does, keeps the confirm's time.
    ledger.forget(1)
    #expect(ledger.isWriting(1, at: t0 + .milliseconds(1)))
}
