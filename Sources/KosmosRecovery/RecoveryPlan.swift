/// What recovery does, decided from what WindowServer reports, kept apart from the calls
/// so its decisions can be tested.
struct RecoveryPlan: Equatable {
    /// Windows in a recorded Space that have an ordinary Space, or get one from an add:
    /// removing them from the recorded Space restores them.
    var removals: [UInt64: [UInt32]] = [:]
    /// Windows with no ordinary Space, by destination. Their add runs before the removals,
    /// so no window is ever on no Space. The add strips only managed Spaces, so a window in
    /// a recorded Space is in `removals` too.
    var adds: [UInt64: [UInt32]] = [:]
    /// Windows with nowhere to go, or whose Spaces did not read. They stay where they are and
    /// the record is kept.
    var stuck: [UInt32] = []

    /// - Parameters:
    ///   - members: the windows in each recorded Space, each one planned whether or not a
    ///     read of rows found it: removing a window that is gone does nothing, and one left
    ///     out would keep the record for good.
    ///   - recorded: the recorded windows. Each that `alive` names and that is on no Space is
    ///     added to one.
    ///   - alive: the windows a read of rows found.
    ///   - isOnAnySpace: whether a window belongs to a Space besides the recorded one, a native
    ///     fullscreen one included, or nil when its Spaces do not read.
    ///   - destination: the ordinary Space a window without one should go to, if any.
    static func make(members: [UInt64: [UInt32]], recorded: [UInt32], alive: Set<UInt32>,
                     isOnAnySpace: (UInt32) -> Bool?, destination: (UInt32) -> UInt64?) -> RecoveryPlan {
        var plan = RecoveryPlan()
        /// Adds the window to its destination, or keeps it stuck when it has none. Returns
        /// whether it is added.
        func place(_ window: UInt32) -> Bool {
            guard let space = destination(window) else {
                plan.stuck.append(window)
                return false
            }
            plan.adds[space, default: []].append(window)
            return true
        }
        for (space, windows) in members.sorted(by: { $0.key < $1.key }) {
            for window in windows {
                // Without another Space or a destination, a removal would leave the window on
                // no Space.
                switch isOnAnySpace(window) {
                case true?: plan.removals[space, default: []].append(window)
                case false?: if place(window) { plan.removals[space, default: []].append(window) }
                case nil: plan.stuck.append(window)
                }
            }
        }
        let inMembers = Set(members.values.joined())
        for window in recorded where alive.contains(window) && !inMembers.contains(window) {
            switch isOnAnySpace(window) {
            case true?: break
            case false?: _ = place(window)
            case nil: plan.stuck.append(window)
            }
        }
        return plan
    }

    /// Every window the plan covers, including the ones with nowhere to go.
    var windows: Set<UInt32> { Set(removals.values.joined()).union(adds.values.joined()).union(stuck) }

    /// The removals to send once the adds are confirmed. An added window leaves its recorded
    /// Space only if `landed` says its add took: removed from its only Space, it would land
    /// on the active Space, which can be a native fullscreen one. Left there, it keeps the
    /// record for another attempt.
    func removals(landed: (UInt32) -> Bool) -> [UInt64: [UInt32]] {
        let failed = Set(adds.values.joined().filter { !landed($0) })
        return removals.mapValues { $0.filter { !failed.contains($0) } }
    }

    /// Recovery is complete only when no window is left in a recorded Space and every
    /// window of the plan, including the stuck ones, is on a Space. Otherwise the record
    /// stays for another attempt.
    func isComplete(remainingMembers: Int, isOnNoSpace: (UInt32) -> Bool) -> Bool {
        remainingMembers == 0 && !windows.contains(where: isOnNoSpace)
    }
}

extension RecoveryRecord {
    /// The record an incomplete recovery keeps for another attempt: every window, and each
    /// Space not read as `gone`. While `keeping`, the Spaces windows slide in stay as they are.
    func keptAfterIncomplete(gone: Set<UInt64>, keepingAnimationSpaces keeping: Bool) -> RecoveryRecord {
        var kept = self
        kept.spaces.removeAll(where: gone.contains)
        if !keeping { kept.animationSpaces.removeAll(where: gone.contains) }
        return kept
    }

    /// The record a complete recovery keeps: no window, and each Space `left` after its
    /// destroy, for the next recovery to destroy again. While `keeping`, the Spaces windows
    /// slide in stay as they are. Nil when no Space is left, which clears the record.
    func keptAfterRestore(left: Set<UInt64>, keepingAnimationSpaces keeping: Bool) -> RecoveryRecord? {
        var kept = self
        kept.windows = []
        kept.spaces.removeAll { !left.contains($0) }
        if !keeping { kept.animationSpaces.removeAll { !left.contains($0) } }
        return kept.spaces.isEmpty && kept.animationSpaces.isEmpty ? nil : kept
    }
}
