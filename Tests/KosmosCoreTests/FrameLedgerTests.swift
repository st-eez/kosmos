import CoreGraphics
import Testing
@testable import KosmosCore

private let a = CGRect(x: 0, y: 0, width: 800, height: 600)
private let moved = CGRect(x: 100, y: 0, width: 800, height: 600)
private let resized = CGRect(x: 0, y: 0, width: 400, height: 600)

@Test func firstTargetWritesTheWholeFrame() {
    var ledger = FrameLedger()
    #expect(ledger.writes(for: [1: a]) == [1: .frame(a)])
}

@Test func pendingOrConfirmedTargetIsNotWrittenAgain() {
    var ledger = FrameLedger()
    _ = ledger.writes(for: [1: a])
    #expect(ledger.writes(for: [1: a]).isEmpty)
    ledger.confirm(1, target: a, readBack: a)
    #expect(ledger.writes(for: [1: a]).isEmpty)
}

@Test func sameSizeWritesPositionOnly() {
    var ledger = FrameLedger()
    _ = ledger.writes(for: [1: a])
    ledger.confirm(1, target: a, readBack: a)
    #expect(ledger.writes(for: [1: moved]) == [1: .position(moved.origin)])
    #expect(ledger.writes(for: [1: resized]) == [1: .frame(resized)])
}

@Test func newestTargetWinsOverPending() {
    var ledger = FrameLedger()
    _ = ledger.writes(for: [1: a])
    #expect(ledger.writes(for: [1: resized]) == [1: .frame(resized)])
    // The read back of the older write does not clear the newer pending target.
    ledger.confirm(1, target: a, readBack: a)
    #expect(ledger.writes(for: [1: resized]).isEmpty)
}

@Test func refusedSizeIsNotRetriedUntilTargetChanges() {
    var ledger = FrameLedger()
    let kept = CGRect(x: 0, y: 0, width: 500, height: 600)
    _ = ledger.writes(for: [1: resized])
    ledger.confirm(1, target: resized, readBack: kept)
    #expect(ledger.writes(for: [1: resized]).isEmpty)
    // The same target at another origin moves the window at its kept size.
    let shifted = CGRect(x: 50, y: 0, width: 400, height: 600)
    #expect(ledger.writes(for: [1: shifted]) == [1: .frame(shifted)])
    ledger.confirm(1, target: shifted, readBack: CGRect(x: 50, y: 0, width: 500, height: 600))
    #expect(ledger.writes(for: [1: shifted]).isEmpty)
    // A new size is tried again.
    #expect(ledger.writes(for: [1: a]) == [1: .frame(a)])
}

@Test func userResizeIsWrittenBack() {
    var ledger = FrameLedger()
    _ = ledger.writes(for: [1: a])
    ledger.confirm(1, target: a, readBack: a)
    ledger.observe(1, frame: resized)
    #expect(ledger.writes(for: [1: a]) == [1: .frame(a)])
}
