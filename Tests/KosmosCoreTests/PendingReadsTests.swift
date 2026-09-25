import Testing
@testable import KosmosCore

@Test func aBurstReadsEachWindowOnceAndAppliesItsEventsInOrder() {
    var pending = PendingReads<Int>()
    pending.add(.read(7, 1))
    pending.add(.read(8, 2))
    pending.add(.destroyed(8))
    pending.add(.read(7, 3))
    pending.add(.appExited(42))
    let (events, windows) = pending.take()
    #expect(windows == [7, 8])
    #expect(pending.isEmpty)
    // Window 8 was destroyed before the read, which finds only 7.
    #expect(PendingReads.actions(events, found: [7]) == [.apply(7, 1), .gone(8, 2), .destroyed(8), .apply(7, 3), .appExited(42)])
}

@Test func eventsThatNameNoWindowToReadNeedNoRead() {
    var pending = PendingReads<Int>()
    pending.add(.destroyed(8))
    pending.add(.appExited(42))
    #expect(pending.take().windows.isEmpty)
}
