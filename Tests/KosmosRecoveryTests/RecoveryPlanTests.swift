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

/// Another process can add windows of its own to a holding Space, as WindowManager.app
/// appears to for Mission Control's placeholders. Recovery plans nothing for them, and one
/// left in the Space does not keep the record.
@Test func windowsTheRecordDoesNotNameAreLeftAlone() {
    let owner = ProcessIdentity(pid: 3, start: 4)
    let record = RecoveryRecord(windowServer: ProcessIdentity(pid: 1, start: 2), manager: owner, spaces: [9],
                                windows: [.init(id: 1, owner: owner, originalSpace: 5)])
    #expect(record.concealed(in: [9: [1, 7]]) == [9: [1]])
    #expect(record.concealed(in: [9: [7]]) == [9: []])
}
