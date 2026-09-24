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

@Test func aWindowOnNoSpaceIsNotBack() {
    let plan = RecoveryPlan.make(members: [9: [1]], stranded: [], hasOrdinarySpace: { _ in true }, destination: { _ in 5 })
    #expect(plan.unplaced(isOnNoSpace: { _ in false }, isInOrdinarySpace: { _ in false }).isEmpty)
    #expect(plan.unplaced(isOnNoSpace: { $0 == 1 }, isInOrdinarySpace: { _ in false }) == [1])
}

/// A removal after a failed add leaves the window on the active Space, which can be a native
/// fullscreen one. A window revealed by removal alone may stay on one: it was there.
@Test func anAddedWindowIsBackOnlyOnAnOrdinarySpace() {
    let plan = RecoveryPlan.make(members: [9: [1, 2]], stranded: [], hasOrdinarySpace: { $0 == 1 }, destination: { _ in 5 })
    #expect(plan.unplaced(isOnNoSpace: { _ in false }, isInOrdinarySpace: { _ in false }) == [2])
    #expect(plan.unplaced(isOnNoSpace: { _ in false }, isInOrdinarySpace: { $0 == 2 }).isEmpty)
}

@Test func aStuckStrandedWindowKeepsTheRecord() {
    // A stranded window with no destination is on no Space, so recovery is not complete.
    let plan = RecoveryPlan.make(members: [:], stranded: [3], hasOrdinarySpace: { _ in false }, destination: { _ in nil })
    #expect(plan.stuck == [3])
    #expect(plan.unplaced(isOnNoSpace: { $0 == 3 }, isInOrdinarySpace: { _ in false }) == [3])
}
