import Testing
@testable import KosmosCore

private let holding: UInt64 = 100

@Test func freshConcealsAreRecordedWithTheirSpace() {
    var ledger = ConcealLedger()
    let batch = ledger.batch(show: [], hide: [1: .keepOrdinary, 2: .exclusive], into: holding, hasOrdinarySpace: { _ in true })
    #expect(batch.keep == [1] && batch.strip == [2])
    #expect(batch.mustBeIn == [1: holding, 2: holding])
    ledger.commit(batch, into: holding)
    #expect(ledger.entries == [1: holding, 2: holding])
}

/// Every revealed window leaves its concealing Space; one without an ordinary Space now is
/// added to one first, whatever kind it was concealed with.
@Test func revealRemovesEachWindowAndAddsOnlyThoseWithoutAnOrdinarySpace() {
    var ledger = ConcealLedger(entries: [1: holding, 2: holding])
    let batch = ledger.batch(show: [1, 2, 3], hide: [:], into: holding, hasOrdinarySpace: { $0 == 1 })
    #expect(batch.removals == [holding: [1, 2]])   // 3 was never concealed
    #expect(batch.adds == [2])
    ledger.commit(batch, into: holding)
    #expect(ledger.entries.isEmpty)
}

@Test func concealingAConcealedWindowChangesNothing() {
    var ledger = ConcealLedger(entries: [2: holding])
    let batch = ledger.batch(show: [], hide: [2: .keepOrdinary], into: holding, hasOrdinarySpace: { _ in true })
    #expect(batch.fresh.isEmpty)
    #expect(batch.mustBeIn == [2: holding])
    ledger.commit(batch, into: holding)
    #expect(ledger.entries == [2: holding])
}

@Test func windowsLeftInAnOlderSpaceAreCheckedAndRevealedThere() {
    let old: UInt64 = 7
    let ledger = ConcealLedger(entries: [4: old])
    #expect(ledger.batch(show: [], hide: [4: .exclusive], into: holding, hasOrdinarySpace: { _ in true }).mustBeIn == [4: old])
    #expect(ledger.batch(show: [4], hide: [:], into: holding, hasOrdinarySpace: { _ in true }).removals == [old: [4]])
}

@Test func rebuildRecordsEachWindowsSpace() {
    #expect(ConcealLedger.rebuilt(members: [holding: [1, 2], 7: [3]])?.entries == [1: holding, 2: holding, 3: 7])
}

/// A failed read is unknown, not empty: an empty ledger would forget concealed windows and
/// conceal one again as if it were fresh.
@Test func rebuildWithAFailedReadIsUnknown() {
    #expect(ConcealLedger.rebuilt(members: [holding: [1], 7: nil]) == nil)
    #expect(ConcealLedger.rebuilt(members: [:]) == ConcealLedger())
}

/// Space membership as WindowServer changes it (`kosmos-probe reveal`): an exclusive add
/// strips only managed Spaces, so a window leaves the holding Space by removal alone.
private struct Memberships {
    static let desktop: UInt64 = 5
    var spaces: [UInt32: Set<UInt64>]

    /// Carries out a batch in the order Hiding sends it: adds to the desktop, removals,
    /// then conceals.
    mutating func run(_ batch: ConcealLedger.Batch) {
        for window in batch.adds { spaces[window]!.insert(Self.desktop) }
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
        #expect(server.spaces == [shown: [Memberships.desktop], hidden: [holding]])
        ledger.commit(batch, into: holding)
        (shown, hidden) = (hidden, shown)
    }
}
