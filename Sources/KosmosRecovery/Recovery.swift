import CoreGraphics
import CKosmos
import Foundation
import KosmosSkyLight
import os

private let recoveryLog = Logger(subsystem: "io.github.st-eez.kosmos", category: "recovery")

/// Restores every window Kosmos concealed and destroys its Spaces (wm-research recovery
/// note, section 4). Every step can run again after an interruption. The caller holds
/// KosmosFiles.lock.
public enum Recovery {
    public enum Outcome: Equatable, Sendable {
        case nothingRecorded
        /// The record belongs to an earlier WindowServer, whose Spaces are gone.
        case staleSession
        /// The WindowServer could not be identified; the record is kept.
        case windowServerUnknown
        /// `spaces` counts the Spaces read back as gone after their destroy. One that is not
        /// stays in the record, with no windows.
        case restored(windows: Int, spaces: Int)
        /// Some windows are still in a recorded Space or on no Space; the record is kept
        /// for another attempt.
        case incomplete(remaining: Int)
    }

    /// `keepingAnimationSpaces`: the running Kosmos's recovery, after a batch that failed,
    /// leaves the Spaces windows slide in to it, recorded. After Kosmos exits, and at its
    /// startup and quit, they go too.
    public static func run(file: RecordFile, keepingAnimationSpaces keeping: Bool = false) -> Outcome {
        guard let record = file.read() else { return .nothingRecorded }
        guard let windowServer = ProcessIdentity.windowServer() else { return .windowServerUnknown }
        guard record.windowServer == windowServer else {
            file.clear()
            return .staleSession
        }

        // An animation Space goes back to identity and alpha 1 first, so a window left in one
        // shows where it is.
        let animation = keeping ? [] : record.animationSpaces
        for space in animation {
            kosmos_space_set_transform(space, .identity)
            kosmos_space_set_alpha(space, 1)
        }
        // An operation Kosmos sent just before it died may still be landing. A Space that no
        // longer exists holds nothing and leaves the record. Windows of other processes stay
        // where they are, except in an animation Space (SpaceMembers).
        let recorded = record.spaces + animation
        let (members, gone) = settledMembers(recorded, of: record)
        let liveSpaces = recorded.filter { !gone.contains($0) }
        // One snapshot of the displays and one read of the rows, so a display change during
        // recovery cannot mix destinations.
        let displays = Displays.current()
        let named = Set(members.values.joined()).union(record.windows.map(\.id))
        let frames = Dictionary(SkyLight.rows(Array(named)).map { ($0.id, $0.frame) }, uniquingKeysWith: { a, _ in a })
        let original = Dictionary(record.windows.map { ($0.id, $0.originalSpace) }, uniquingKeysWith: { a, _ in a })
        let plan = RecoveryPlan.make(members: members, recorded: record.windows.map(\.id), alive: Set(frames.keys),
                                     hasOrdinarySpace: { !spaces(of: $0).isEmpty },
                                     destination: { destination(for: frames[$0], original: original[$0], in: displays) })

        // Adds land before any removal is sent: a window removed from its only Space lands
        // on whichever Space is active, which can be a native fullscreen one.
        for (destination, windows) in plan.adds {
            var ids = windows
            kosmos_add_windows(destination, &ids, ids.count, true)
            _ = kosmos_barrier(destination)
        }
        for (space, windows) in plan.removals(landed: displays.isInOrdinarySpace) {
            var ids = windows
            kosmos_remove_windows(space, &ids, ids.count)
            _ = kosmos_barrier(space)
        }

        let handled = Set(plan.adds.values.joined()).union(plan.removals.values.joined())
        let after = SpaceMembers.read(liveSpaces, of: record)
        let remaining = after.members.values.reduce(0) { $0 + $1.count }
        let alive = Set(SkyLight.rows(Array(plan.windows)).map(\.id))
        let onNoSpace = { (window: UInt32) in alive.contains(window) && spaces(of: window).isEmpty }
        guard plan.isComplete(remainingMembers: remaining, isOnNoSpace: onNoSpace) else {
            let withoutSpace = plan.windows.filter(onNoSpace).count
            recoveryLog.error("\(remaining) windows still concealed, \(withoutSpace) on no Space; keeping the record")
            file.publish(record.keptAfterIncomplete(gone: gone.union(after.gone), keepingAnimationSpaces: keeping))
            return .incomplete(remaining: remaining + withoutSpace)
        }
        // A destroy's return says only that it was sent, and whether it takes away a Space
        // that still holds windows of other processes is unconfirmed. A barrier and a read
        // show each Space gone or not; one that is not stays in the record, with no windows,
        // for the next recovery to destroy again.
        for space in liveSpaces { kosmos_space_destroy(space) }
        let left = liveSpaces.filter { space in
            _ = kosmos_barrier(space)
            return (kosmos_space_windows(space) as? [UInt32]) != nil
        }
        if !left.isEmpty { recoveryLog.error("\(left.count) Spaces still exist after their destroy; keeping them in the record") }
        if let kept = record.keptAfterRestore(left: Set(left), keepingAnimationSpaces: keeping) {
            file.publish(kept)
        } else {
            file.clear()
        }
        let destroyed = liveSpaces.count - left.count
        recoveryLog.notice("restored \(handled.count) windows, destroyed \(destroyed) Spaces")
        return .restored(windows: handled.count, spaces: destroyed)
    }

    /// The windows to take out of each existing Space of `spaces` (SpaceMembers.read) once
    /// two reads 100 ms apart agree, for at most about 1 s; past that, the newest read, which
    /// the check after the adds and removals backs up. Spaces that are gone are listed apart.
    private static func settledMembers(_ spaces: [UInt64], of record: RecoveryRecord)
        -> (members: [UInt64: [UInt32]], gone: Set<UInt64>) {
        var previous = SpaceMembers.read(spaces, of: record)
        let existing = spaces.filter { !previous.gone.contains($0) }
        for _ in 0..<10 {
            usleep(100_000)
            let current = SpaceMembers.read(existing, of: record)
            if current.members == previous.members { break }
            previous.members = current.members
        }
        return (previous.members, previous.gone)
    }

    private static func spaces(of window: UInt32) -> [UInt64] {
        kosmos_window_spaces(window) as? [UInt64] ?? []
    }

    /// The current ordinary Space of the display under `frame`, else the Space a reveal would
    /// use; nil only when there is none.
    private static func destination(for frame: CGRect?, original: UInt64?, in displays: Displays) -> UInt64? {
        if let frame, let space = displays.currentSpace(at: CGPoint(x: frame.midX, y: frame.midY)) { return space }
        return displays.ordinarySpace(original: original)
    }
}
