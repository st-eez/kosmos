import Testing
@testable import KosmosRecovery

@Test func windowsWithAnOrdinarySpaceAreRemovedFromTheRecordedSpace() {
    let plan = RecoveryPlan.make(members: [9: [1, 2]], recorded: [], alive: [], isOnAnySpace: { _ in true }, destination: { _ in 5 })
    #expect(plan.removalsBySpace == [9: [1, 2]])
    #expect(plan.adds.isEmpty && plan.stuck.isEmpty)
}

@Test func windowsWithoutOneAreAddedToTheirDestinationAndRemoved() {
    // The exclusive add strips only managed Spaces, so it leaves them in the recorded
    // Space; the removal after it takes them out.
    let plan = RecoveryPlan.make(members: [9: [1, 2]], recorded: [], alive: [], isOnAnySpace: { $0 == 1 }, destination: { _ in 5 })
    #expect(plan.removalsBySpace == [9: [1, 2]])
    #expect(plan.adds == [5: [2]])
    #expect(plan.windows == [1, 2])
}

@Test func windowsWithNowhereToGoStayConcealed() {
    let plan = RecoveryPlan.make(members: [9: [2]], recorded: [], alive: [], isOnAnySpace: { _ in false }, destination: { _ in nil })
    #expect(plan.stuck == [2])
    #expect(plan.removalsBySpace.isEmpty && plan.adds.isEmpty)
}

/// 4 is recorded and gone, so it is left out.
@Test func strandedRecordedWindowsAreAddedOnce() {
    let plan = RecoveryPlan.make(members: [9: [2]], recorded: [2, 3, 4], alive: [2, 3], isOnAnySpace: { _ in false },
                                 destination: { _ in 5 })
    #expect(plan.adds == [5: [2, 3]])
    #expect(plan.removalsBySpace == [9: [2]])   // 3 is in no recorded Space
}

@Test func anAddedWindowLeavesItsRecordedSpaceOnlyOnceItsAddLanded() {
    let plan = RecoveryPlan.make(members: [9: [1, 2]], recorded: [], alive: [1, 2], isOnAnySpace: { $0 == 1 }, destination: { _ in 5 })
    #expect(plan.removals(landed: { _ in true }) == [9: [1, 2]])
    #expect(plan.removals(landed: { _ in false }) == [9: [1]])
}

/// A removal could leave such a window on no Space, and an add could take it off its own.
/// 2 stays in the recorded Space and 3 counts as on no Space, and each keeps the record.
@Test func aWindowWhoseSpacesDoNotReadStaysWhereItIs() {
    let plan = RecoveryPlan.make(members: [9: [1, 2]], recorded: [1, 3], alive: [1, 3], isOnAnySpace: { $0 == 1 ? true : nil },
                                 destination: { _ in 5 })
    #expect(plan.removalsBySpace == [9: [1]])
    #expect(plan.adds.isEmpty)
    #expect(plan.stuck == [2, 3])
    #expect(!plan.isComplete(remainingMembers: 1, isOnNoSpace: { _ in false }))
    #expect(!plan.isComplete(remainingMembers: 0, isOnNoSpace: { $0 == 3 }))
}

/// Both halves: a window left in a recorded Space, as when its add did not land, and a
/// window of the plan on no Space each keep the record.
@Test func recoveryIsCompleteOnlyWhenNothingIsLeftAnywhere() {
    let plan = RecoveryPlan.make(members: [9: [1, 2]], recorded: [], alive: [], isOnAnySpace: { $0 == 1 }, destination: { _ in 5 })
    #expect(plan.isComplete(remainingMembers: 0, isOnNoSpace: { _ in false }))
    #expect(!plan.isComplete(remainingMembers: 1, isOnNoSpace: { _ in false }))
    #expect(!plan.isComplete(remainingMembers: 0, isOnNoSpace: { $0 == 2 }))
}

@Test func aStuckStrandedWindowKeepsTheRecord() {
    // A stranded window with no destination is on no Space, so recovery is not complete.
    let plan = RecoveryPlan.make(members: [:], recorded: [3], alive: [3], isOnAnySpace: { _ in false }, destination: { _ in nil })
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
    let plan = RecoveryPlan.make(members: members, recorded: [], alive: [], isOnAnySpace: { _ in true }, destination: { _ in 5 })
    #expect(plan.removalsBySpace == [9: [1, 2, 3, 4]])
    let after = concealed([9: [5, 7]])
    #expect(after == [9: []])   // the Space still exists
    #expect(plan.isComplete(remainingMembers: after.values.joined().count, isOnNoSpace: { _ in false }))
    #expect(!plan.isComplete(remainingMembers: concealed([9: [3, 7]]).values.joined().count, isOnNoSpace: { _ in false }))
}

/// A member the read missed is either unread or closed and still listed. It counts, and
/// recovery takes it out with the rest, though a closed window's add never lands. It keeps
/// the record only while the Space lists it.
@Test func aMemberWithNoRowIsTakenOut() {
    let members = concealed([9: [1, 6]])
    #expect(members == [9: [1, 6]])
    let plan = RecoveryPlan.make(members: members, recorded: [1], alive: [1], isOnAnySpace: { $0 == 1 },
                                 destination: { _ in 5 })
    #expect(plan.adds == [5: [6]])
    #expect(plan.removals(landed: { _ in false }) == [9: [1, 6]])
    #expect(plan.isComplete(remainingMembers: concealed([9: []]).values.joined().count, isOnNoSpace: { _ in false }))
    #expect(!plan.isComplete(remainingMembers: concealed([9: [6]]).values.joined().count, isOnNoSpace: { _ in false }))
}

/// Every window in an animation Space came in through Kosmos, so recovery takes each out,
/// another process's too, and keeps the holding Space's rule for the rest.
@Test func recoveryTakesEveryWindowOutOfAnAnimationSpace() {
    var sliding = record
    sliding.animationSpaces = [12]
    let members = SpaceMembers.concealed([9: [1, 7], 12: [5, 6, 7]], by: sliding, rows: { ids in rows.filter { ids.contains($0.key) } })
    #expect(members == [9: [1], 12: [5, 6, 7]])
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

private let kept = RecoveryRecord(windowServer: ProcessIdentity(pid: 1, start: 2), manager: ProcessIdentity(pid: 5, start: 6),
                                  spaces: [9, 10], windows: [.init(id: 1, owner: app, originalSpace: 5)],
                                  animationSpaces: [12, 13])

@Test func anIncompleteRecoveryKeepsEveryWindowAndEachSpaceNotGone() {
    let after = kept.keptAfterIncomplete(gone: [10, 13], keepingAnimationSpaces: false)
    #expect(after.windows == kept.windows)
    #expect(after.spaces == [9])
    #expect(after.animationSpaces == [12])
}

@Test func aCompleteRecoveryKeepsOnlyTheSpacesLeftAfterTheirDestroy() {
    let after = kept.keptAfterRestore(left: [10, 12], keepingAnimationSpaces: false)
    #expect(after?.windows == [])
    #expect(after?.spaces == [10])
    #expect(after?.animationSpaces == [12])
}

@Test func aCompleteRecoveryWithNoSpaceLeftClearsTheRecord() {
    #expect(kept.keptAfterRestore(left: [], keepingAnimationSpaces: false) == nil)
}

/// The running Kosmos's recovery leaves the Spaces windows slide in to it, gone or not.
@Test func whileKeepingThemTheAnimationSpacesStayRecorded() {
    #expect(kept.keptAfterIncomplete(gone: [10, 13], keepingAnimationSpaces: true).animationSpaces == [12, 13])
    let after = kept.keptAfterRestore(left: [], keepingAnimationSpaces: true)
    #expect(after?.spaces == [])
    #expect(after?.animationSpaces == [12, 13])
}

/// A Kosmos that takes the record over keeps the windows it spares, recorded, with the Space
/// that holds them, and the rest goes as after any recovery.
@Test func anAdoptionKeepsTheSparedWindowsAndTheirSpace() {
    var handedOver = kept
    handedOver.windows.append(.init(id: 2, owner: app, originalSpace: 5))
    handedOver.handover = true
    let after = handedOver.keptAfterRestore(left: [10], keepingAnimationSpaces: false, sparing: [2])
    #expect(after?.windows.map(\.id) == [2])
    #expect(after?.spaces == [10])
    #expect(after?.animationSpaces == [])
    #expect(after?.handover == false)
}

/// The handover ends at the first recovery, so a crash after it gets a crash's grace.
@Test func anyRecoveryEndsTheHandover() {
    var handedOver = kept
    handedOver.handover = true
    #expect(!handedOver.keptAfterIncomplete(gone: [], keepingAnimationSpaces: false).handover)
    #expect(handedOver.keptAfterRestore(left: [9], keepingAnimationSpaces: false)?.handover == false)
}
