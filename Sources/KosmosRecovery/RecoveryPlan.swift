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
    /// Windows with nowhere to go. They stay where they are and the record is kept.
    var stuck: [UInt32] = []

    /// - Parameters:
    ///   - members: the windows in each recorded Space, each one planned whether or not a
    ///     read of rows found it: removing a window that is gone does nothing, and one left
    ///     out would keep the record for good.
    ///   - recorded: the recorded windows. Each that `alive` names and that is on no Space is
    ///     added to one.
    ///   - alive: the windows a read of rows found.
    ///   - hasOrdinarySpace: whether a window belongs to an ordinary Space besides the
    ///     recorded one.
    ///   - destination: the ordinary Space a window without one should go to, if any.
    static func make(members: [UInt64: [UInt32]], recorded: [UInt32], alive: Set<UInt32>,
                     hasOrdinarySpace: (UInt32) -> Bool, destination: (UInt32) -> UInt64?) -> RecoveryPlan {
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
                // Without an ordinary Space or a destination, a removal would leave the
                // window on no Space.
                if hasOrdinarySpace(window) || place(window) { plan.removals[space, default: []].append(window) }
            }
        }
        let inMembers = Set(members.values.joined())
        for window in recorded where alive.contains(window) && !inMembers.contains(window) && !hasOrdinarySpace(window) {
            _ = place(window)
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
