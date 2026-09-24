/// What recovery does, decided from what WindowServer reports, kept apart from the calls
/// so its decisions can be tested.
struct RecoveryPlan: Equatable {
    /// Windows that keep an ordinary Space: removing them from the recorded Space restores
    /// them.
    var removals: [UInt64: [UInt32]] = [:]
    /// Windows with no ordinary Space, by destination. One exclusive add moves each into
    /// its destination and out of the recorded Space, so no window is ever on no Space.
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
        func place(_ window: UInt32) {
            if let space = destination(window) { plan.moves[space, default: []].append(window) } else { plan.stuck.append(window) }
        }
        for (space, windows) in members.sorted(by: { $0.key < $1.key }) {
            for window in windows {
                if hasOrdinarySpace(window) { plan.removals[space, default: []].append(window) } else { place(window) }
            }
        }
        let inMembers = Set(members.values.joined())
        for window in stranded where !inMembers.contains(window) { place(window) }
        return plan
    }

    /// Recovery is complete only when no window is left in a recorded Space and every
    /// window it handled is on an ordinary Space. Otherwise the record stays for another
    /// attempt.
    static func isComplete(remainingMembers: Int, withoutSpace: Int) -> Bool {
        remainingMembers == 0 && withoutSpace == 0
    }
}
