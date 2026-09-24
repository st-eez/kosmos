import Testing
@testable import KosmosCore

private let holding: UInt64 = 100

@Test func freshConcealsAreRecordedWithTheirKind() {
    var ledger = ConcealLedger()
    let batch = ledger.batch(show: [], hide: [1: .keepOrdinary, 2: .exclusive], into: holding)
    #expect(batch.keep == [1] && batch.strip == [2])
    #expect(batch.mustBeIn == [1: holding, 2: holding])
    ledger.commit(batch, into: holding)
    #expect(ledger.entries == [1: .init(kind: .keepOrdinary, space: holding), 2: .init(kind: .exclusive, space: holding)])
}

@Test func revealUndoesWhatWasDone() {
    let ledger = ConcealLedger(entries: [1: .init(kind: .keepOrdinary, space: holding), 2: .init(kind: .exclusive, space: holding)])
    let batch = ledger.batch(show: [1, 2, 3], hide: [:], into: holding)
    #expect(batch.removals == [holding: [1]])
    #expect(batch.moves == [2])
    #expect(batch.mustHaveLeft == [1: holding, 2: holding])   // 3 was never concealed
}

/// The regression that stranded a window: concealing it again with another kind changed
/// the record but not its membership, and a removal then left it on no Space.
@Test func concealingAConcealedWindowChangesNothing() {
    var ledger = ConcealLedger(entries: [2: .init(kind: .exclusive, space: holding)])
    let batch = ledger.batch(show: [], hide: [2: .keepOrdinary], into: holding)
    #expect(batch.fresh.isEmpty)
    #expect(batch.mustBeIn == [2: holding])
    ledger.commit(batch, into: holding)
    #expect(ledger.entries[2] == .init(kind: .exclusive, space: holding))
    #expect(ledger.batch(show: [2], hide: [:], into: holding).moves == [2])
}

@Test func windowsLeftInAnOlderSpaceAreCheckedAndRevealedThere() {
    let old: UInt64 = 7
    let ledger = ConcealLedger(entries: [4: .init(kind: .keepOrdinary, space: old)])
    #expect(ledger.batch(show: [], hide: [4: .exclusive], into: holding).mustBeIn == [4: old])
    #expect(ledger.batch(show: [4], hide: [:], into: holding).removals == [old: [4]])
}

@Test func uncommittedBatchesLeaveTheLedgerAlone() {
    let ledger = ConcealLedger(entries: [1: .init(kind: .keepOrdinary, space: holding)])
    _ = ledger.batch(show: [1], hide: [2: .exclusive], into: holding)
    #expect(ledger.entries == [1: .init(kind: .keepOrdinary, space: holding)])
}
