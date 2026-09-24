import Testing
@testable import KosmosRecovery

@Test func windowsWithAnOrdinarySpaceAreRemovedFromTheRecordedSpace() {
    let plan = RecoveryPlan.make(members: [9: [1, 2]], stranded: [], hasOrdinarySpace: { _ in true }, destination: { _ in 5 })
    #expect(plan.removals == [9: [1, 2]])
    #expect(plan.moves.isEmpty && plan.stuck.isEmpty)
}

@Test func windowsWithoutOneMoveStraightToTheirDestination() {
    // A removal first would leave them on no Space; the exclusive add moves them in one step.
    let plan = RecoveryPlan.make(members: [9: [1, 2]], stranded: [], hasOrdinarySpace: { $0 == 1 }, destination: { _ in 5 })
    #expect(plan.removals == [9: [1]])
    #expect(plan.moves == [5: [2]])
}

@Test func windowsWithNowhereToGoStayConcealed() {
    let plan = RecoveryPlan.make(members: [9: [2]], stranded: [], hasOrdinarySpace: { _ in false }, destination: { _ in nil })
    #expect(plan.stuck == [2])
    #expect(plan.removals.isEmpty && plan.moves.isEmpty)
}

@Test func strandedRecordedWindowsAreMovedOnce() {
    let plan = RecoveryPlan.make(members: [9: [2]], stranded: [2, 3], hasOrdinarySpace: { _ in false }, destination: { _ in 5 })
    #expect(plan.moves == [5: [2, 3]])
}

@Test func recoveryIsCompleteOnlyWhenNothingIsLeftAnywhere() {
    #expect(RecoveryPlan.isComplete(remainingMembers: 0, withoutSpace: 0))
    #expect(!RecoveryPlan.isComplete(remainingMembers: 1, withoutSpace: 0))
    #expect(!RecoveryPlan.isComplete(remainingMembers: 0, withoutSpace: 1))
}

@Test func stuckWindowsAreAmongThoseChecked() {
    // A stranded window with no destination must keep the record: it is on no Space.
    let plan = RecoveryPlan.make(members: [:], stranded: [3], hasOrdinarySpace: { _ in false }, destination: { _ in nil })
    #expect(plan.windows == [3])
}
