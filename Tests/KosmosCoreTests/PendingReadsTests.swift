import Testing
@testable import KosmosCore

@Test func aBurstReadsEachWindowOnceAndKeepsItsEventsInOrder() {
    var pending = PendingReads<Int>()
    pending.add(.read(7, 1))
    pending.add(.read(8, 2))
    pending.add(.destroyed(8))
    pending.add(.read(7, 3))
    pending.add(.appExited(42))
    let (events, windows) = pending.take()
    #expect(windows == [7, 8])
    #expect(pending.isEmpty)
    #expect(events == [.read(7, 1), .read(8, 2), .destroyed(8), .read(7, 3), .appExited(42)])
}

@Test func eventsThatNameNoWindowToReadNeedNoRead() {
    var pending = PendingReads<Int>()
    pending.add(.destroyed(8))
    pending.add(.appExited(42))
    #expect(pending.take().windows.isEmpty)
}
