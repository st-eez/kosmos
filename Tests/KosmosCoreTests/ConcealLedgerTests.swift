import Testing
@testable import KosmosCore

private let holding: SpaceID = 100

@Test func freshConcealsAreRecordedWithTheirSpace() {
    var ledger = ConcealLedger()
    let batch = ledger.batch(show: [], hide: [2, 1, 2], into: holding, isOnAnySpace: { _ in true })
    #expect(batch.fresh == [1, 2])
    #expect(batch.mustBeIn == [1: holding, 2: holding])
    ledger.commit(batch, into: holding)
    #expect(ledger.entries == [1: holding, 2: holding])
}

@Test func revealRemovesEachWindowAndAddsOnlyThoseOnNoOtherSpace() {
    var ledger = ConcealLedger(entries: [1: holding, 2: holding])
    let batch = ledger.batch(show: [1, 2, 3], hide: [], into: holding, isOnAnySpace: { $0 == 1 })
    #expect(batch.removals == [holding: [1, 2]])
    #expect(batch.adds == [2])
    ledger.commit(batch, into: holding)
    #expect(ledger.entries.isEmpty)
}

@Test func onlyWindowsConcealedNowAreStripped() {
    var ledger = ConcealLedger(entries: [3: holding])
    let batch = ledger.batch(show: [], hide: [1, 2, 3], stripping: [2, 3], into: holding, isOnAnySpace: { _ in true })
    #expect(batch.fresh == [1, 2])
    #expect(batch.strip == [2])
    #expect(batch.mustBeIn == [1: holding, 2: holding, 3: holding])
    ledger.commit(batch, into: holding)
    #expect(ledger.entries == [1: holding, 2: holding, 3: holding])
}

@Test func concealingAConcealedWindowChangesNothing() {
    var ledger = ConcealLedger(entries: [2: holding])
    let batch = ledger.batch(show: [], hide: [2], into: holding, isOnAnySpace: { _ in true })
    #expect(batch.fresh.isEmpty)
    #expect(batch.mustBeIn == [2: holding])
    ledger.commit(batch, into: holding)
    #expect(ledger.entries == [2: holding])
}

@Test func windowsLeftInAnOlderSpaceAreCheckedAndRevealedThere() {
    let old: SpaceID = 7
    let ledger = ConcealLedger(entries: [4: old])
    #expect(ledger.batch(show: [], hide: [4], into: holding, isOnAnySpace: { _ in true }).mustBeIn == [4: old])
    #expect(ledger.batch(show: [4], hide: [], into: holding, isOnAnySpace: { _ in true }).removals == [old: [4]])
}

@Test func aBatchIsDoneWhenEachWindowIsWhereItPutIt() {
    let desktop: SpaceID = 5
    let batch = ConcealLedger(entries: [1: holding]).batch(show: [1], hide: [2], into: holding, isOnAnySpace: { _ in true })
    #expect(batch.touched == [holding])
    #expect(batch.isDone(members: [holding: [2]]))
    #expect(!batch.isDone(members: [holding: [1, 2], desktop: [1]]))
    #expect(!batch.isDone(members: [holding: []]))
    #expect(!batch.isDone(members: [:]))   // a Space not read proves nothing
}

@Test func rebuildRecordsEachWindowsSpace() {
    #expect(ConcealLedger.rebuilt(members: [holding: [1, 2], 7: [3]])?.entries == [1: holding, 2: holding, 3: 7])
}

@Test func rebuildWithAFailedReadIsUnknown() {
    #expect(ConcealLedger.rebuilt(members: [holding: [1], 7: nil]) == nil)
    #expect(ConcealLedger.rebuilt(members: [:]) == ConcealLedger())
}

@Test func anAddedWindowIsRemovedOnlyOnceItsAddLanded() {
    let batch = ConcealLedger(entries: [1: holding, 2: holding])
        .batch(show: [1, 2], hide: [], into: holding, isOnAnySpace: { $0 == 1 })
    #expect(batch.removals(landed: { _ in true }) == [holding: [1, 2]])
    #expect(batch.removals(landed: { _ in false }) == [holding: [1]])
}

/// Space membership as WindowServer changes it (`kosmos-probe reveal`): an exclusive add
/// strips only managed Spaces, and a window removed from its only Space lands on the active one.
private struct Memberships {
    static let desktop: SpaceID = 5
    static let fullscreen: SpaceID = 6
    var spaces: [WindowID: Set<SpaceID>]
    var addsLand = true

    func members(of spaces: Set<SpaceID>) -> [SpaceID: Set<WindowID>] {
        Dictionary(uniqueKeysWithValues: spaces.map { space in (space, Set(self.spaces.filter { $0.value.contains(space) }.keys)) })
    }

    /// In the order Hiding sends a batch.
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

/// As in a ledger rebuilt after a recovery that could not restore every window.
@Test func aWindowWithNoListedSpaceIsAddedThenRemoved() {
    var ledger = ConcealLedger(entries: [2: holding])
    var server = Memberships(spaces: [1: [Memberships.desktop], 2: [holding]])
    var (shown, hidden): (WindowID, WindowID) = (2, 1)
    for _ in 0..<4 {
        let batch = ledger.batch(show: [shown], hide: [hidden], into: holding,
                                 isOnAnySpace: { server.spaces[$0]!.contains(Memberships.desktop) })
        server.run(batch)
        #expect(batch.isDone(members: server.members(of: batch.touched)))
        #expect(server.spaces == [shown: [Memberships.desktop], hidden: [Memberships.desktop, holding]])
        ledger.commit(batch, into: holding)
        (shown, hidden) = (hidden, shown)
    }
}

@Test func windowsThatKeepTheDesktopAreRevealedByRemovalAlone() {
    var ledger = ConcealLedger()
    var server = Memberships(spaces: [1: [Memberships.desktop], 2: [Memberships.desktop]])
    var (shown, hidden): (WindowID, WindowID) = (1, 2)
    for _ in 0..<4 {
        let batch = ledger.batch(show: [shown], hide: [hidden], into: holding,
                                 isOnAnySpace: { server.spaces[$0]!.contains(Memberships.desktop) })
        #expect(batch.adds.isEmpty)
        server.run(batch)
        #expect(batch.isDone(members: server.members(of: batch.touched)))
        #expect(server.spaces == [shown: [Memberships.desktop], hidden: [Memberships.desktop, holding]])
        ledger.commit(batch, into: holding)
        (shown, hidden) = (hidden, shown)
    }
}

@Test func aRevealWhoseAddFailsLeavesTheWindowConcealed() {
    let ledger = ConcealLedger(entries: [2: holding])
    var server = Memberships(spaces: [2: [holding]], addsLand: false)
    let batch = ledger.batch(show: [2], hide: [], into: holding, isOnAnySpace: { _ in false })
    server.run(batch)
    #expect(server.spaces[2] == [holding])
    #expect(!batch.isDone(members: server.members(of: batch.touched)))
}

/// Command-W right before a switch: 3 closed, or its app ordered it out and kept it, after the
/// batch read its row, so no Space lists it.
@Test func aWindowGoneBeforeItsConcealLeavesTheBatch() {
    var ledger = ConcealLedger(entries: [1: holding])
    let batch = ledger.batch(show: [1], hide: [2, 3], stripping: [3], into: holding, isOnAnySpace: { _ in true })
    var read: Set<WindowID> = []
    let confirmed = batch.confirmed(members: [holding: [2]], orderedIn: { read = $0; return [] })
    #expect(read == [3])
    #expect(confirmed?.left == [3])
    #expect(confirmed?.batch.fresh == [2] && confirmed?.batch.strip == [])
    ledger.commit(confirmed!.batch, into: holding)
    #expect(ledger.entries == [2: holding])
}

@Test func aFailedWindowStillOrderedInFailsTheBatch() {
    let batch = ConcealLedger(entries: [1: holding]).batch(show: [1], hide: [2, 3], into: holding, isOnAnySpace: { _ in true })
    #expect(batch.confirmed(members: [holding: [2]], orderedIn: { $0 }) == nil)
    // A revealed window still listed.
    #expect(batch.failed(members: [holding: [1, 2, 3]]) == [1])
    #expect(batch.confirmed(members: [holding: [1, 2, 3]], orderedIn: { $0 }) == nil)
    // A Space not read fails each of its windows, and one of them is ordered in.
    #expect(batch.failed(members: [:]) == [1, 2, 3])
    #expect(batch.confirmed(members: [:], orderedIn: { $0.intersection([2]) }) == nil)
}

@Test func aConfirmedBatchReadsNoRows() {
    let batch = ConcealLedger().batch(show: [], hide: [2], into: holding, isOnAnySpace: { _ in true })
    let confirmed = batch.confirmed(members: [holding: [2]], orderedIn: { _ in
        Issue.record("rows read for a confirmed batch")
        return []
    })
    #expect(confirmed?.batch == batch && confirmed?.left == [])
}

@Test func aWindowThatLeftTheHoldingSpaceOnItsOwnIsForgotten() {
    // A native tab deselected while concealed leaves the holding Space (kosmos-probe tabs).
    var ledger = ConcealLedger(entries: [1: 9, 2: 9])
    ledger.forget([1])
    #expect(ledger.entries == [2: 9])
    let batch = ledger.batch(show: [], hide: [1], into: 9, isOnAnySpace: { _ in true })
    #expect(batch.fresh == [1] && batch.mustBeIn == [1: 9])
}

/// 1 is out of its Space, 2 is still listed, 3's Space could not be read, 4 is gone or has a
/// Space, and 5 is alive on no Space.
@Test func onlyWindowsOutOfTheirSpaceDepart() {
    let ledger = ConcealLedger(entries: [1: 9, 2: 9, 3: 8])
    #expect(ledger.departed([1, 2, 3, 4, 5], members: { $0 == 9 ? [2] : nil }, settled: { $0 == 4 }) == [1, 4])
}
