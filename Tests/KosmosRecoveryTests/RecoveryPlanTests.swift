import Testing
@testable import KosmosRecovery

@Test func windowsWithAnOrdinarySpaceAreRemovedFromTheRecordedSpace() {
    let plan = RecoveryPlan.make(members: [9: [1, 2]], stranded: [], hasOrdinarySpace: { _ in true }, destination: { _ in 5 })
    #expect(plan.removals == [9: [1, 2]])
    #expect(plan.moves.isEmpty && plan.stuck.isEmpty)
}

@Test func windowsWithoutOneAreAddedToTheirDestinationAndRemoved() {
    // The exclusive add strips only managed Spaces, so it leaves them in the recorded
    // Space; the removal after it takes them out.
    let plan = RecoveryPlan.make(members: [9: [1, 2]], stranded: [], hasOrdinarySpace: { $0 == 1 }, destination: { _ in 5 })
    #expect(plan.removals == [9: [1, 2]])
    #expect(plan.moves == [5: [2]])
    #expect(plan.windows == [1, 2])
}

@Test func windowsWithNowhereToGoStayConcealed() {
    let plan = RecoveryPlan.make(members: [9: [2]], stranded: [], hasOrdinarySpace: { _ in false }, destination: { _ in nil })
    #expect(plan.stuck == [2])
    #expect(plan.removals.isEmpty && plan.moves.isEmpty)
}

@Test func strandedRecordedWindowsAreMovedOnce() {
    let plan = RecoveryPlan.make(members: [9: [2]], stranded: [2, 3], hasOrdinarySpace: { _ in false }, destination: { _ in 5 })
    #expect(plan.moves == [5: [2, 3]])
    #expect(plan.removals == [9: [2]])   // 3 is in no recorded Space
}

@Test func recoveryIsCompleteOnlyWhenNothingIsLeftAnywhere() {
    let plan = RecoveryPlan.make(members: [9: [1]], stranded: [], hasOrdinarySpace: { _ in true }, destination: { _ in 5 })
    #expect(plan.isComplete(remainingMembers: 0, isOnNoSpace: { _ in false }))
    #expect(!plan.isComplete(remainingMembers: 1, isOnNoSpace: { _ in false }))
    #expect(!plan.isComplete(remainingMembers: 0, isOnNoSpace: { $0 == 1 }))
}

@Test func aStuckStrandedWindowKeepsTheRecord() {
    // A stranded window with no destination is on no Space, so recovery is not complete.
    let plan = RecoveryPlan.make(members: [:], stranded: [3], hasOrdinarySpace: { _ in false }, destination: { _ in nil })
    #expect(plan.stuck == [3])
    #expect(!plan.isComplete(remainingMembers: 0, isOnNoSpace: { $0 == 3 }))
}
