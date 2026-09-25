struct RecoveryPlan: Equatable {
    /// By recorded Space.
    var removals: [UInt64: [UInt32]] = [:]
    /// By destination, sent before the removals. An exclusive add strips only managed Spaces,
    /// so an added window in a recorded Space is in `removals` too (`kosmos-probe reveal`).
    var adds: [UInt64: [UInt32]] = [:]
    /// Windows with nowhere to go, or whose Spaces do not read, left where they are.
    var stuck: [UInt32] = []
    /// Members with no row. A closed window a Space still lists reads as on no Space, so it is
    /// added, and its add never lands.
    var withoutRow: Set<UInt32> = []

    /// Each member is planned whether or not `alive`, a read of rows, found it: removing a
    /// window that is gone does nothing, and left out, it would keep the record for good.
    /// `isOnAnySpace` counts native fullscreen Spaces, and is nil when the Spaces do not read.
    static func make(members: [UInt64: [UInt32]], recorded: [UInt32], alive: Set<UInt32>,
                     isOnAnySpace: (UInt32) -> Bool?, destination: (UInt32) -> UInt64?) -> RecoveryPlan {
        var plan = RecoveryPlan()
        plan.withoutRow = Set(members.values.joined()).subtracting(alive)
        // False when the window is stuck, since a removal would leave it on no Space.
        func place(_ window: UInt32) -> Bool {
            switch isOnAnySpace(window) {
            case true?:
                return true
            case false?:
                if let space = destination(window) {
                    plan.adds[space, default: []].append(window)
                    return true
                }
            case nil:
                break
            }
            plan.stuck.append(window)
            return false
        }
        for (space, windows) in members.sorted(by: { $0.key < $1.key }) {
            for window in windows where place(window) {
                plan.removals[space, default: []].append(window)
            }
        }
        let inMembers = Set(members.values.joined())
        for window in recorded where alive.contains(window) && !inMembers.contains(window) {
            _ = place(window)
        }
        return plan
    }

    var windows: Set<UInt32> { Set(removals.values.joined()).union(adds.values.joined()).union(stuck) }

    /// An added window leaves its recorded Space only once its add landed: removed from its
    /// only Space, it would land on the active Space, which can be a native fullscreen one.
    /// A member with no row leaves regardless, or a closed one would keep the record for good.
    func removals(landed: (UInt32) -> Bool) -> [UInt64: [UInt32]] {
        let failed = Set(adds.values.joined().filter { !withoutRow.contains($0) && !landed($0) })
        return removals.mapValues { $0.filter { !failed.contains($0) } }
    }

    func isComplete(remainingMembers: Int, isOnNoSpace: (UInt32) -> Bool) -> Bool {
        remainingMembers == 0 && !windows.contains(where: isOnNoSpace)
    }
}

extension RecoveryRecord {
    func keptAfterIncomplete(gone: Set<UInt64>, keepingAnimationSpaces keeping: Bool) -> RecoveryRecord {
        var kept = self
        kept.spaces.removeAll(where: gone.contains)
        if !keeping { kept.animationSpaces.removeAll(where: gone.contains) }
        return kept
    }

    /// Nil when no Space is left, which clears the record.
    func keptAfterRestore(left: Set<UInt64>, keepingAnimationSpaces keeping: Bool) -> RecoveryRecord? {
        var kept = self
        kept.windows = []
        kept.spaces.removeAll { !left.contains($0) }
        if !keeping { kept.animationSpaces.removeAll { !left.contains($0) } }
        return kept.spaces.isEmpty && kept.animationSpaces.isEmpty ? nil : kept
    }
}
