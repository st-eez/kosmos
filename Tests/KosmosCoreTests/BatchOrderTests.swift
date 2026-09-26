import CoreGraphics
import Testing
@testable import KosmosCore

private let a = CGRect(x: 0, y: 0, width: 800, height: 600)
private let moved = CGRect(x: 100, y: 0, width: 800, height: 600)

private func write(_ frame: CGRect) -> BatchOrder.Write { (.frame(frame), frame) }

@Test func aBatchWithNoWriteLandingGoesAtOnce() {
    var order = BatchOrder()
    let batch = order.add(show: [1, 2], hide: [3])
    let now = order.write([:])
    #expect(now.isEmpty)
    let ready = order.ready { _ in false }
    #expect(ready == [batch])
    #expect(!order.isWaiting)
}

@Test func aBatchWaitsForTheWritesOfTheWindowsItRevealsAndLaterBatchesWaitBehindIt() {
    var order = BatchOrder()
    let first = order.add(show: [1], hide: [2])
    var ready = order.ready { $0 == 1 }
    #expect(ready.isEmpty)
    let second = order.add(show: [2], hide: [3])
    ready = order.ready { $0 == 1 }
    #expect(ready.isEmpty)
    #expect(order.isWaiting)
    ready = order.ready { _ in false }
    #expect(ready == [first, second])
}

@Test func aWindowABatchConcealsIsWrittenAtTheBatchsEnd() {
    var order = BatchOrder()
    let batch = order.add(show: [1], hide: [2])
    var now = order.write([1: write(a), 2: write(a)])
    #expect(now.keys.sorted() == [1])
    let ready = order.ready { _ in false }
    #expect(ready == [batch])
    // A later write joins the one waiting, so the app takes the whole frame first.
    now = order.write([2: (.position(moved.origin), moved)])
    #expect(now.isEmpty)
    let released = order.done(batch.number)
    #expect(released.count == 1)
    #expect(released[2]?.write == .frame(moved))
    #expect(released[2]?.target == moved)
    now = order.write([2: write(a)])
    #expect(now.count == 1)
}

@Test func aRevealWaitsForAWriteHeldByAnEarlierBatchButNotByALaterOne() {
    var order = BatchOrder()
    // Concealed by the first and revealed by the second: its write goes at the first's end,
    // and the second waits for it.
    let first = order.add(show: [], hide: [1])
    var now = order.write([1: write(a)])
    #expect(now.isEmpty)
    var ready = order.ready { _ in false }
    #expect(ready == [first])
    let second = order.add(show: [1], hide: [])
    ready = order.ready { _ in false }
    #expect(ready.isEmpty)
    var released = order.done(first.number)
    #expect(released[1] != nil)
    ready = order.ready { _ in false }
    #expect(ready == [second])
    _ = order.done(second.number)
    // Revealed by the third and concealed again by the fourth, after whose end its write goes.
    let third = order.add(show: [2], hide: [])
    let fourth = order.add(show: [], hide: [2])
    now = order.write([2: write(moved)])
    #expect(now.isEmpty)
    ready = order.ready { _ in false }
    #expect(ready == [third, fourth])
    released = order.done(third.number)
    #expect(released.isEmpty)
    released = order.done(fourth.number)
    #expect(released[2]?.target == moved)
}

@Test func aSwitchAwayDuringAWaitSendsBothBatchesAtOnce() {
    var order = BatchOrder()
    // move-node-to-workspace --focus-follows-window to 2 waits for window 1's write; the
    // switch back to 1 conceals window 1 again, so neither waits.
    let follow = order.add(show: [1], hide: [3])
    var ready = order.ready { $0 == 1 }
    #expect(ready.isEmpty)
    let back = order.add(show: [3], hide: [1])
    ready = order.ready { $0 == 1 }
    #expect(ready == [follow, back])
}

@Test func aWriteWaitsUntilNoBatchNotDoneConcealsItsWindow() {
    var order = BatchOrder()
    let first = order.add(show: [], hide: [1])
    let now = order.write([1: write(a)])
    #expect(now.isEmpty)
    var ready = order.ready { _ in false }
    #expect(ready == [first])
    let second = order.add(show: [1], hide: [])
    let third = order.add(show: [], hide: [1])
    var released = order.done(first.number)
    #expect(released.isEmpty)
    ready = order.ready { _ in false }
    #expect(ready == [second, third])
    released = order.done(second.number)
    #expect(released.isEmpty)
    released = order.done(third.number)
    #expect(released[1]?.target == a)
}

@Test func aWindowEnteringARevealedWorkspaceIsConcealedFirstAndRevealedWithIt() {
    var order = BatchOrder()
    // Window 9, moved on screen into workspace 2, is revealed with 2's window 3.
    let conceal = order.add(show: [], hide: [9])
    let reveal = order.add(show: [3, 9], hide: [1])
    #expect(order.lastNumber == reveal.number)
    let now = order.write([3: write(a), 9: write(moved), 1: write(a)])
    #expect(now.keys.sorted() == [3])
    var ready = order.ready { $0 == 3 }
    #expect(ready == [conceal])
    #expect(order.next == reveal)
    // 9's write waits for its conceal, and the reveal for 9's write.
    ready = order.ready { _ in false }
    #expect(ready.isEmpty)
    var released = order.done(conceal.number)
    #expect(released.keys.sorted() == [9])
    ready = order.ready { _ in false }
    #expect(ready == [reveal])
    released = order.done(reveal.number)
    #expect(released[1]?.target == a)
}

@Test func aWindowCountsAsConcealedFromItsBatchsAddToItsEnd() {
    var order = BatchOrder()
    let waiting = order.add(show: [1], hide: [2])
    // Waiting for window 1's write, the batch already counts for window 2.
    #expect(order.ready { $0 == 1 }.isEmpty)
    #expect(order.conceals(2))
    #expect(!order.conceals(1))
    #expect(order.ready { _ in false } == [waiting])
    #expect(order.conceals(2))
    _ = order.done(waiting.number)
    #expect(!order.conceals(2))
}
