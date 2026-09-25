import Testing
@testable import KosmosCore

private let holding: SpaceID = 100

@Test func freshConcealsAreRecordedWithTheirSpace() {
    var ledger = ConcealLedger()
    let batch = ledger.batch(show: [], hide: [2, 1, 2], into: holding, hasOrdinarySpace: { _ in true })
    #expect(batch.fresh == [1, 2])
    #expect(batch.mustBeIn == [1: holding, 2: holding])
    ledger.commit(batch, into: holding)
    #expect(ledger.entries == [1: holding, 2: holding])
}

/// Every revealed window leaves its concealing Space; one without an ordinary Space now is
/// added to one first.
@Test func revealRemovesEachWindowAndAddsOnlyThoseWithoutAnOrdinarySpace() {
    var ledger = ConcealLedger(entries: [1: holding, 2: holding])
    let batch = ledger.batch(show: [1, 2, 3], hide: [], into: holding, hasOrdinarySpace: { $0 == 1 })
    #expect(batch.removals == [holding: [1, 2]])   // 3 was never concealed
    #expect(batch.adds == [2])
    ledger.commit(batch, into: holding)
    #expect(ledger.entries.isEmpty)
}

/// With several displays, windows concealed now can be stripped of their ordinary Space; a
/// window concealed before keeps what it had (docs/hiding.md and docs/displays.md).
@Test func onlyWindowsConcealedNowAreStripped() {
    var ledger = ConcealLedger(entries: [3: holding])
    let batch = ledger.batch(show: [], hide: [1, 2, 3], stripping: [2, 3], into: holding, hasOrdinarySpace: { _ in true })
    #expect(batch.fresh == [1, 2])
    #expect(batch.strip == [2])
    #expect(batch.mustBeIn == [1: holding, 2: holding, 3: holding])
    ledger.commit(batch, into: holding)
    #expect(ledger.entries == [1: holding, 2: holding, 3: holding])
}

@Test func concealingAConcealedWindowChangesNothing() {
    var ledger = ConcealLedger(entries: [2: holding])
    let batch = ledger.batch(show: [], hide: [2], into: holding, hasOrdinarySpace: { _ in true })
    #expect(batch.fresh.isEmpty)
    #expect(batch.mustBeIn == [2: holding])
    ledger.commit(batch, into: holding)
    #expect(ledger.entries == [2: holding])
}

@Test func windowsLeftInAnOlderSpaceAreCheckedAndRevealedThere() {
    let old: SpaceID = 7
    let ledger = ConcealLedger(entries: [4: old])
    #expect(ledger.batch(show: [], hide: [4], into: holding, hasOrdinarySpace: { _ in true }).mustBeIn == [4: old])
    #expect(ledger.batch(show: [4], hide: [], into: holding, hasOrdinarySpace: { _ in true }).removals == [old: [4]])
}

@Test func aBatchIsDoneWhenEachWindowIsWhereItPutIt() {
    let desktop: SpaceID = 5
    let batch = ConcealLedger(entries: [1: holding]).batch(show: [1], hide: [2], into: holding, hasOrdinarySpace: { _ in true })
    #expect(batch.touched == [holding])
    #expect(batch.isDone(members: [holding: [2]]))
    // Revealed onto the desktop but still in the holding Space too: it is still concealed.
    #expect(!batch.isDone(members: [holding: [1, 2], desktop: [1]]))
    #expect(!batch.isDone(members: [holding: []]))   // 2 is not concealed yet
    #expect(!batch.isDone(members: [:]))             // a Space that was not read proves nothing
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
        .batch(show: [1, 2], hide: [], into: holding, hasOrdinarySpace: { $0 == 1 })
    #expect(batch.removals(landed: { _ in true }) == [holding: [1, 2]])
    #expect(batch.removals(landed: { _ in false }) == [holding: [1]])
}

/// Space membership as WindowServer changes it (`kosmos-probe reveal`): an exclusive add
/// strips only managed Spaces, so a window leaves the holding Space by removal alone, and a
/// window removed from its only Space lands on the active Space.
private struct Memberships {
    static let desktop: SpaceID = 5
    static let fullscreen: SpaceID = 6
    var spaces: [WindowID: Set<SpaceID>]
    var addsLand = true

    /// The windows each of `spaces` holds, as a read of them returns.
    func members(of spaces: Set<SpaceID>) -> [SpaceID: Set<WindowID>] {
        Dictionary(uniqueKeysWithValues: spaces.map { space in (space, Set(self.spaces.filter { $0.value.contains(space) }.keys)) })
    }

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
        for window in batch.fresh { spaces[window]!.insert(holding) }
    }
}

/// A window concealed with no listed Space, as in a ledger that load() rebuilt after an
/// incomplete recovery: its reveal adds it to the desktop, then removes it from the holding
/// Space. The add alone left it in the holding Space, and the switch failed its
/// confirmation (2026-09-24). Concealed again, it keeps the desktop, so its next reveal is a
/// removal.
@Test func aWindowWithNoListedSpaceIsAddedThenRemoved() {
    var ledger = ConcealLedger(entries: [2: holding])
    var server = Memberships(spaces: [1: [Memberships.desktop], 2: [holding]])
    var (shown, hidden): (WindowID, WindowID) = (2, 1)
    for _ in 0..<4 {
        let batch = ledger.batch(show: [shown], hide: [hidden], into: holding,
                                 hasOrdinarySpace: { server.spaces[$0]!.contains(Memberships.desktop) })
        server.run(batch)
        #expect(batch.isDone(members: server.members(of: batch.touched)))
        #expect(server.spaces == [shown: [Memberships.desktop], hidden: [Memberships.desktop, holding]])
        ledger.commit(batch, into: holding)
        (shown, hidden) = (hidden, shown)
    }
}

/// The path production takes: every window keeps the desktop while concealed, so each
/// reveal is a removal alone.
@Test func windowsThatKeepTheDesktopAreRevealedByRemovalAlone() {
    var ledger = ConcealLedger()
    var server = Memberships(spaces: [1: [Memberships.desktop], 2: [Memberships.desktop]])
    var (shown, hidden): (WindowID, WindowID) = (1, 2)
    for _ in 0..<4 {
        let batch = ledger.batch(show: [shown], hide: [hidden], into: holding,
                                 hasOrdinarySpace: { server.spaces[$0]!.contains(Memberships.desktop) })
        #expect(batch.adds.isEmpty)
        server.run(batch)
        #expect(batch.isDone(members: server.members(of: batch.touched)))
        #expect(server.spaces == [shown: [Memberships.desktop], hidden: [Memberships.desktop, holding]])
        ledger.commit(batch, into: holding)
        (shown, hidden) = (hidden, shown)
    }
}

/// An add that does not land leaves the window concealed, where recovery finds it, instead of
/// on the active Space, which can be a native fullscreen one.
@Test func aRevealWhoseAddFailsLeavesTheWindowConcealed() {
    let ledger = ConcealLedger(entries: [2: holding])
    var server = Memberships(spaces: [2: [holding]], addsLand: false)
    let batch = ledger.batch(show: [2], hide: [], into: holding, hasOrdinarySpace: { _ in false })
    server.run(batch)
    #expect(server.spaces[2] == [holding])
    #expect(!batch.isDone(members: server.members(of: batch.touched)))
}

@Test func aWindowThatLeftTheHoldingSpaceOnItsOwnIsForgotten() {
    // A native tab deselected while concealed leaves the holding Space (kosmos-probe tabs).
    var ledger = ConcealLedger(entries: [1: 9, 2: 9])
    ledger.forget([1])
    #expect(ledger.entries == [2: 9])
    // Selected again on a hidden workspace, it is concealed afresh and checked.
    let batch = ledger.batch(show: [], hide: [1], into: 9, hasOrdinarySpace: { _ in true })
    #expect(batch.fresh == [1] && batch.mustBeIn == [1: 9])
}

/// A closed window leaves once its concealing Space no longer lists it. One still listed, or
/// in a Space that could not be read, stays, so recovery restores it. Of the windows the
/// ledger does not hold, 4 is gone or has a Space and leaves, and 5 is alive on no Space and
/// stays.
@Test func onlyWindowsOutOfTheirSpaceDepart() {
    let ledger = ConcealLedger(entries: [1: 9, 2: 9, 3: 8])
    #expect(ledger.departed([1, 2, 3, 4, 5], members: { $0 == 9 ? [2] : nil }, settled: { $0 == 4 }) == [1, 4])
}
