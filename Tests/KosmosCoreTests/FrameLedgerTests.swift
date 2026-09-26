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
    ledger.confirm(1, target: a, readBack: a, at: t0)
    #expect(ledger.writes(for: [1: resized]).isEmpty)
}

@Test func refusedSizeIsNotRetriedUntilTargetChanges() {
    var ledger = FrameLedger()
    let kept = CGRect(x: 0, y: 0, width: 500, height: 600)
    _ = ledger.writes(for: [1: resized])
    #expect(ledger.confirm(1, target: resized, readBack: kept, at: t0) == .refused)
    #expect(ledger.writes(for: [1: resized]) == [1: .frame(resized)])
    #expect(ledger.confirm(1, target: resized, readBack: kept, at: t0) == .minimum(CGSize(width: 500, height: 0)))
    #expect(ledger.writes(for: [1: resized]).isEmpty)
    #expect(ledger.writes(for: [1: a]) == [1: .frame(a)])
}

@Test func aSizeReadBackLargerIsWrittenAgainBeforeItShowsAMinimum() {
    var ledger = FrameLedger()
    // Asked 945 as it moved to another display, the window kept its old 1900.
    let target = CGRect(x: 10, y: 35, width: 945, height: 1035)
    let kept = CGRect(x: 10, y: 35, width: 1900, height: 1035)
    _ = ledger.writes(for: [1: target])
    #expect(ledger.confirm(1, target: target, readBack: kept, at: t0) == .refused)
    #expect(ledger.writes(for: [1: target]) == [1: .frame(target)])
    #expect(ledger.confirm(1, target: target, readBack: target, at: t0) == .took)
    let within = CGRect(x: 10, y: 35, width: 947, height: 1035)
    #expect(ledger.confirm(1, target: target, readBack: within, at: t0) == .took)
    #expect(ledger.confirm(1, target: target, readBack: resized, at: t0) == .took)
}

@Test func aNewTargetOrForgettingTheWindowStartsTheRefusalsOver() {
    var ledger = FrameLedger()
    let kept = CGRect(x: 0, y: 0, width: 500, height: 600)
    _ = ledger.writes(for: [1: resized])
    #expect(ledger.confirm(1, target: resized, readBack: kept, at: t0) == .refused)
    let shifted = resized.offsetBy(dx: 50, dy: 0)
    _ = ledger.writes(for: [1: shifted])
    #expect(ledger.confirm(1, target: shifted, readBack: kept.offsetBy(dx: 50, dy: 0), at: t0) == .refused)
    // A mouse up forgets the window: its write can read back an app's live resize step.
    ledger.forget(1)
    _ = ledger.writes(for: [1: shifted])
    #expect(ledger.confirm(1, target: shifted, readBack: kept.offsetBy(dx: 50, dy: 0), at: t0) == .refused)
}

@Test func aSizeRefusedWhileHiddenIsAFirstRefusalOnceShown() {
    var ledger = FrameLedger()
    let target = CGRect(x: 10, y: 35, width: 945, height: 1035)
    let kept = CGRect(x: 10, y: 35, width: 1900, height: 1035)
    // Written twice while hidden, each read back forgotten before its confirm.
    for _ in 1...2 {
        #expect(ledger.writes(for: [1: target]) == [1: .frame(target)])
        ledger.forgetLargerReadBack(1)
        #expect(ledger.confirm(1, target: target, readBack: kept, at: t0) == .refused)
    }
    // The write that shows it, sent before the reveal lands, reads back larger once more.
    ledger.forgetLargerReadBack(1)
    #expect(ledger.writes(for: [1: target]) == [1: .frame(target)])
    #expect(ledger.confirm(1, target: target, readBack: kept, at: t0) == .refused)
    #expect(ledger.writes(for: [1: target]) == [1: .frame(target)])
    #expect(ledger.confirm(1, target: target, readBack: target, at: t0) == .took)
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
    _ = ledger.writes(for: [1: resized])
    ledger.confirm(1, target: resized, readBack: kept, at: t0)
    ledger.observe(1, frame: kept)
    #expect(ledger.writes(for: [1: resized]).isEmpty)
    ledger.observe(1, frame: CGRect(x: 30, y: 0, width: 700, height: 600))
    #expect(ledger.writes(for: [1: resized]) == [1: .frame(resized)])
    #expect(ledger.confirm(1, target: resized, readBack: kept, at: t0) == .refused)
}

@Test func aPositionWriteReplacingAnUnwrittenFrameWriteWritesTheWholeFrame() {
    var ledger = FrameLedger()
    let first = ledger.writes(for: [1: a])[1]!
    let second = ledger.writes(for: [1: moved])[1]!
    #expect(second == .position(moved.origin))
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
    ledger.forget(1)
    #expect(ledger.isWriting(1, at: t0 + .milliseconds(1)))
}

@Test func theWritesChangeAppliedAfterTheConfirmRecordsALaterFrame() {
    var ledger = FrameLedger()
    _ = ledger.writes(for: [1: a])
    ledger.confirm(1, target: a, readBack: a, at: t0)
    ledger.observeAfterConfirm(1, frame: a)
    #expect(ledger.writes(for: [1: a]).isEmpty)
    // The row holds the app's next live resize step, whose own event finds no change.
    ledger.observeAfterConfirm(1, frame: resized)
    #expect(ledger.writes(for: [1: a]) == [1: .frame(a)])
}

@Test func aWriteLandsOnceItsReadBackAndARowShowIt() {
    var ledger = FrameLedger()
    let rounded = CGRect(x: 100, y: 0, width: 801, height: 600)
    _ = ledger.writes(for: [1: moved])
    #expect(!ledger.isLanding(1, at: t0))
    ledger.sent(1, target: moved, at: t0)
    #expect(ledger.isLanding(1, at: t0))
    // The row before the write lands, then the read back, which the app rounded.
    var landed = ledger.seen(1, frame: a)
    #expect(!landed)
    ledger.confirm(1, target: moved, readBack: rounded, at: t0)
    landed = ledger.seen(1, frame: moved)
    #expect(!landed)
    #expect(ledger.isLanding(1, at: t0))
    landed = ledger.seen(1, frame: rounded)
    #expect(landed)
    #expect(!ledger.isLanding(1, at: t0))
}

@Test func onlyTheNewestWriteSentCanLand() {
    var ledger = FrameLedger()
    _ = ledger.writes(for: [1: a])
    ledger.sent(1, target: a, at: t0)
    _ = ledger.writes(for: [1: moved])
    ledger.sent(1, target: moved, at: t0)
    ledger.confirm(1, target: a, readBack: a, at: t0)
    var landed = ledger.seen(1, frame: a)
    #expect(!landed)
    ledger.confirm(1, target: moved, readBack: moved, at: t0)
    landed = ledger.seen(1, frame: moved)
    #expect(landed)
}

@Test func aWriteNoRowShowsCountsAsLandedAfterTheAccessibilityTimeout() {
    var ledger = FrameLedger()
    _ = ledger.writes(for: [1: a])
    ledger.sent(1, target: a, at: t0)
    #expect(ledger.isLanding(1, at: t0 + FrameLedger.landingWait - .milliseconds(1)))
    #expect(!ledger.isLanding(1, at: t0 + FrameLedger.landingWait))
    ledger.sent(1, target: a, at: t0)
    ledger.forget(1)
    #expect(!ledger.isLanding(1, at: t0))
}
