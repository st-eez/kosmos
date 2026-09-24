/// What recovery does, decided from what WindowServer reports, kept apart from the calls
/// so its decisions can be tested.
struct RecoveryPlan: Equatable {
    /// Windows in a recorded Space that have an ordinary Space, or get one from a move:
    /// removing them from the recorded Space restores them.
    var removals: [UInt64: [UInt32]] = [:]
    /// Windows with no ordinary Space, by destination. Their add runs before the removals,
    /// so no window is ever on no Space. The add strips only managed Spaces, so a window in
    /// a recorded Space is in `removals` too.
    var moves: [UInt64: [UInt32]] = [:]
    /// Windows with nowhere to go. They stay where they are and the record is kept.
    var stuck: [UInt32] = []

    /// - Parameters:
    ///   - members: the windows in each recorded Space.
    ///   - stranded: recorded windows that still exist and are on no Space at all.
    ///   - hasOrdinarySpace: whether a window belongs to an ordinary Space besides the
    ///     recorded one.
    ///   - destination: the ordinary Space a window without one should go to, if any.
    static func make(members: [UInt64: [UInt32]], stranded: [UInt32],
                     hasOrdinarySpace: (UInt32) -> Bool, destination: (UInt32) -> UInt64?) -> RecoveryPlan {
        var plan = RecoveryPlan()
        /// Moves the window to its destination, or keeps it stuck when it has none. Returns
        /// whether it moves.
        func place(_ window: UInt32) -> Bool {
            guard let space = destination(window) else {
                plan.stuck.append(window)
                return false
            }
            plan.moves[space, default: []].append(window)
            return true
        }
        for (space, windows) in members.sorted(by: { $0.key < $1.key }) {
            for window in windows where hasOrdinarySpace(window) || place(window) {
                plan.removals[space, default: []].append(window)
            }
        }
        let inMembers = Set(members.values.joined())
        for window in stranded where !inMembers.contains(window) { _ = place(window) }
        return plan
    }

    /// Every window the plan covers, including the ones with nowhere to go.
    var windows: Set<UInt32> { Set(removals.values.joined()).union(moves.values.joined()).union(stuck) }

    /// The windows of the plan, stuck ones included, that are not back: on no Space, or
    /// moved and on no ordinary Space, as when an add failed and the removal after it left
    /// the window on a native fullscreen Space. Recovery is complete only when this is empty
    /// and no window is left in a recorded Space; otherwise the record stays for another
    /// attempt.
    func unplaced(isOnNoSpace: (UInt32) -> Bool, isInOrdinarySpace: (UInt32) -> Bool) -> Set<UInt32> {
        let moved = Set(moves.values.joined())
        return windows.filter { isOnNoSpace($0) || (moved.contains($0) && !isInOrdinarySpace($0)) }
    }
}
