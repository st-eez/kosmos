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
    #expect(batch.removals == [holding: [1, 2]])
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
    let reveal = ledger.batch(show: [2], hide: [:], into: holding)
    #expect(reveal.moves == [2] && reveal.removals == [holding: [2]])
}

@Test func windowsLeftInAnOlderSpaceAreCheckedAndRevealedThere() {
    let old: UInt64 = 7
    let ledger = ConcealLedger(entries: [4: .init(kind: .keepOrdinary, space: old)])
    #expect(ledger.batch(show: [], hide: [4: .exclusive], into: holding).mustBeIn == [4: old])
    #expect(ledger.batch(show: [4], hide: [:], into: holding).removals == [old: [4]])
}

@Test func rebuildKeepsEachWindowsRealKind() {
    let ledger = ConcealLedger.rebuilt(members: [holding: [1, 2], 7: [3]], hasOrdinarySpace: { $0 == 1 })
    #expect(ledger?.entries == [1: .init(kind: .keepOrdinary, space: holding),
                                2: .init(kind: .exclusive, space: holding),
                                3: .init(kind: .exclusive, space: 7)])
}

/// A failed read is unknown, not empty: an empty ledger would forget concealed windows and
/// let a later conceal relabel one.
@Test func rebuildWithAFailedReadIsUnknown() {
    #expect(ConcealLedger.rebuilt(members: [holding: [1], 7: nil], hasOrdinarySpace: { _ in true }) == nil)
    #expect(ConcealLedger.rebuilt(members: [:], hasOrdinarySpace: { _ in true }) == ConcealLedger())
}

@Test func aWindowThatLostItsOrdinarySpaceIsAddedToOneAndRemoved() {
    let ledger = ConcealLedger(entries: [1: .init(kind: .keepOrdinary, space: holding), 2: .init(kind: .keepOrdinary, space: holding)])
    let batch = ledger.batch(show: [1, 2], hide: [:], into: holding, hasOrdinarySpace: { $0 == 1 })
    #expect(batch.removals == [holding: [1, 2]])
    #expect(batch.moves == [2])
}

/// Space membership as WindowServer changes it (`kosmos-probe reveal`): an exclusive add
/// strips only managed Spaces, so a window leaves the holding Space by removal alone.
private struct Memberships {
    static let desktop: UInt64 = 5
    var spaces: [UInt32: Set<UInt64>]

    /// Carries out a batch in the order Hiding sends it: adds to the desktop, removals,
    /// then conceals.
    mutating func run(_ batch: ConcealLedger.Batch) {
        for window in batch.moves { spaces[window]!.insert(Self.desktop) }
        for (space, windows) in batch.removals { for window in windows { spaces[window]!.remove(space) } }
        for window in batch.keep { spaces[window]!.insert(holding) }
        for window in batch.strip { spaces[window] = [holding] }
    }
}

/// The live failure: an app with a window on each of two workspaces. Each switch strips the
/// hidden window, because the app has one on the shown workspace, and the switch back
/// reveals it. Adding it to the desktop alone left it in the holding Space, and every
/// switch back failed its confirmation.
@Test func anAppOnTwoWorkspacesSwitchesBackAndForth() {
    var ledger = ConcealLedger()
    var server = Memberships(spaces: [1: [Memberships.desktop], 2: [Memberships.desktop]])
    var (shown, hidden): (UInt32, UInt32) = (1, 2)
    for _ in 0..<4 {
        let batch = ledger.batch(show: [shown], hide: [hidden: .exclusive], into: holding,
                                 hasOrdinarySpace: { server.spaces[$0]!.contains(Memberships.desktop) })
        server.run(batch)
        #expect(batch.mustBeIn.allSatisfy { server.spaces[$0.key]!.contains($0.value) })
        #expect(batch.mustHaveLeft.allSatisfy { !server.spaces[$0.key]!.contains($0.value) })
        #expect(server.spaces == [shown: [Memberships.desktop], hidden: [holding]])
        ledger.commit(batch, into: holding)
        (shown, hidden) = (hidden, shown)
    }
}
