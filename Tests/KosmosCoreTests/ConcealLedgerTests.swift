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

@Test func anAddedWindowIsRemovedOnlyOnceItsAddLanded() {
    let batch = ConcealLedger(entries: [1: holding, 2: holding])
        .batch(show: [1, 2], hide: [:], into: holding, hasOrdinarySpace: { $0 == 1 })
    #expect(batch.removals(landed: { _ in true }) == [holding: [1, 2]])
    #expect(batch.removals(landed: { _ in false }) == [holding: [1]])
}

/// Space membership as WindowServer changes it (`kosmos-probe reveal`): an exclusive add
/// strips only managed Spaces, so a window leaves the holding Space by removal alone, and a
/// window removed from its only Space lands on the active Space.
private struct Memberships {
    static let desktop: UInt64 = 5
    static let fullscreen: UInt64 = 6
    var spaces: [UInt32: Set<UInt64>]
    var addsLand = true

    /// Carries out a batch in the order Hiding sends it: adds to the desktop, the removals
    /// of windows whose add landed, then conceals.
    mutating func run(_ batch: ConcealLedger.Batch) {
        if addsLand { for window in batch.adds { spaces[window]!.insert(Self.desktop) } }
        let removals = batch.removals(landed: { [spaces] in spaces[$0]!.contains(Self.desktop) })
        for (space, windows) in removals {
            for window in windows {
                spaces[window]!.remove(space)
                if spaces[window]!.isEmpty { spaces[window] = [Self.fullscreen] }   // the active Space
            }
        }
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

/// An add that does not land leaves the window concealed, where recovery finds it, instead of
/// on the active Space, which can be a native fullscreen one.
@Test func aRevealWhoseAddFailsLeavesTheWindowConcealed() {
    let ledger = ConcealLedger(entries: [2: holding])
    var server = Memberships(spaces: [2: [holding]], addsLand: false)
    server.run(ledger.batch(show: [2], hide: [:], into: holding, hasOrdinarySpace: { _ in false }))
    #expect(server.spaces[2] == [holding])
}
