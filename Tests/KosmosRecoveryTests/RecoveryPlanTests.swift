import Testing
@testable import KosmosRecovery

@Test func windowsWithAnOrdinarySpaceAreRemovedFromTheRecordedSpace() {
    let plan = RecoveryPlan.make(members: [9: [1, 2]], stranded: [], hasOrdinarySpace: { _ in true }, destination: { _ in 5 })
    #expect(plan.removals == [9: [1, 2]])
    #expect(plan.adds.isEmpty && plan.stuck.isEmpty)
}

@Test func windowsWithoutOneAreAddedToTheirDestinationAndRemoved() {
    // The exclusive add strips only managed Spaces, so it leaves them in the recorded
    // Space; the removal after it takes them out.
    let plan = RecoveryPlan.make(members: [9: [1, 2]], stranded: [], hasOrdinarySpace: { $0 == 1 }, destination: { _ in 5 })
    #expect(plan.removals == [9: [1, 2]])
    #expect(plan.adds == [5: [2]])
    #expect(plan.windows == [1, 2])
}

@Test func windowsWithNowhereToGoStayConcealed() {
    let plan = RecoveryPlan.make(members: [9: [2]], stranded: [], hasOrdinarySpace: { _ in false }, destination: { _ in nil })
    #expect(plan.stuck == [2])
    #expect(plan.removals.isEmpty && plan.adds.isEmpty)
}

@Test func strandedRecordedWindowsAreAddedOnce() {
    let plan = RecoveryPlan.make(members: [9: [2]], stranded: [2, 3], hasOrdinarySpace: { _ in false }, destination: { _ in 5 })
    #expect(plan.adds == [5: [2, 3]])
    #expect(plan.removals == [9: [2]])   // 3 is in no recorded Space
}

@Test func anAddedWindowLeavesItsRecordedSpaceOnlyOnceItsAddLanded() {
    let plan = RecoveryPlan.make(members: [9: [1, 2]], stranded: [], hasOrdinarySpace: { $0 == 1 }, destination: { _ in 5 })
    #expect(plan.removals(landed: { _ in true }) == [9: [1, 2]])
    #expect(plan.removals(landed: { _ in false }) == [9: [1]])
}

/// Both halves: a window left in a recorded Space, as when its add did not land, and a
/// window of the plan on no Space each keep the record.
@Test func recoveryIsCompleteOnlyWhenNothingIsLeftAnywhere() {
    let plan = RecoveryPlan.make(members: [9: [1, 2]], stranded: [], hasOrdinarySpace: { $0 == 1 }, destination: { _ in 5 })
    #expect(plan.isComplete(remainingMembers: 0, isOnNoSpace: { _ in false }))
    #expect(!plan.isComplete(remainingMembers: 1, isOnNoSpace: { _ in false }))
    #expect(!plan.isComplete(remainingMembers: 0, isOnNoSpace: { $0 == 2 }))
}

@Test func aStuckStrandedWindowKeepsTheRecord() {
    // A stranded window with no destination is on no Space, so recovery is not complete.
    let plan = RecoveryPlan.make(members: [:], stranded: [3], hasOrdinarySpace: { _ in false }, destination: { _ in nil })
    #expect(plan.stuck == [3])
    #expect(!plan.isComplete(remainingMembers: 0, isOnNoSpace: { $0 == 3 }))
}

private let app = ProcessIdentity(pid: 3, start: 4)
private let record = RecoveryRecord(windowServer: ProcessIdentity(pid: 1, start: 2), manager: ProcessIdentity(pid: 5, start: 6),
                                    spaces: [9], windows: [.init(id: 1, owner: app, originalSpace: 5)])
/// Window 1 is recorded. 2 is a sheet of it that its app owns, 3 an Open panel of it that
/// the panel service owns, and 4 a sheet of that panel. 7 is a placeholder another process
/// added to the holding Space, and 5 a window whose process could not be identified. The
/// read finds no row for 6.
private let rows: [UInt32: SpaceMembers.Row] = [
    1: .init(owner: app, parent: 0), 2: .init(owner: app, parent: 1),
    3: .init(owner: ProcessIdentity(pid: 8, start: 9), parent: 1), 4: .init(owner: ProcessIdentity(pid: 8, start: 9), parent: 3),
    5: .init(owner: nil, parent: 0), 7: .init(owner: ProcessIdentity(pid: 10, start: 11), parent: 0),
]
private func concealed(_ members: [UInt64: [UInt32]]) -> [UInt64: [UInt32]] {
    SpaceMembers.concealed(members, by: record, rows: { ids in rows.filter { ids.contains($0.key) } })
}

/// Recovery restores the recorded window, its app's sheet and the panel with its sheet, and
/// leaves the placeholder where it is. Left behind, the placeholder does not keep the
/// record.
@Test func recoveryRestoresTheAppsWindowsAndLeavesOthersAlone() {
    let members = concealed([9: [1, 2, 3, 4, 5, 7]])
    #expect(members == [9: [1, 2, 3, 4]])
    let plan = RecoveryPlan.make(members: members, stranded: [], hasOrdinarySpace: { _ in true }, destination: { _ in 5 })
    #expect(plan.removals == [9: [1, 2, 3, 4]])
    let after = concealed([9: [5, 7]])
    #expect(after == [9: []])   // the Space still exists
    #expect(plan.isComplete(remainingMembers: after.values.joined().count, isOnNoSpace: { _ in false }))
    #expect(!plan.isComplete(remainingMembers: concealed([9: [3, 7]]).values.joined().count, isOnNoSpace: { _ in false }))
}

/// A member the read missed was listed by the Space, so the read failed: it counts, and
/// keeps the record.
@Test func aMemberWithNoRowKeepsTheRecord() {
    #expect(concealed([9: [1, 6]]) == [9: [1, 6]])
    let plan = RecoveryPlan.make(members: [9: [1]], stranded: [], hasOrdinarySpace: { _ in true }, destination: { _ in 5 })
    #expect(!plan.isComplete(remainingMembers: concealed([9: [6]]).values.joined().count, isOnNoSpace: { _ in false }))
}

@Test func aFullSlotDropsOnlyWindowsThatAreGoneAndNotKept() {
    let windows = (1...4).map { RecoveryRecord.Window(id: $0, owner: app, originalSpace: 5) }
    let full = RecoveryRecord(windowServer: app, manager: app, spaces: [9], windows: windows)
    // 2 is gone, 3 is gone but concealed, 4 is new and was just read.
    let pruned = full.pruned(alive: [1, 4], keeping: [3, 4], seen: [4])
    #expect(pruned?.windows.map(\.id) == [1, 3, 4])
    // A read that misses the new window it just found failed, as a failed query reads nothing.
    #expect(full.pruned(alive: [], keeping: [3, 4], seen: [4]) == nil)
}
