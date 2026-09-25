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
    /// leaves the slide trial's Spaces to it, recorded. After Kosmos exits, and at its startup
    /// and quit, they go too.
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
        // where they are (SpaceMembers), except in an animation Space, where every window
        // came in through Kosmos.
        let recorded = record.spaces + animation
        let read = { (spaces: [UInt64]) in Self.members(spaces, of: record, animation: Set(animation)) }
        let (members, gone) = settledMembers(recorded, read: read)
        let liveSpaces = recorded.filter { !gone.contains($0) }
        let alive = Set(SkyLight.rows(Array(Set(members.values.joined()).union(record.windows.map(\.id)))).map(\.id))
        let original = Dictionary(record.windows.map { ($0.id, $0.originalSpace) }, uniquingKeysWith: { a, _ in a })
        let stranded = record.windows.map(\.id).filter { alive.contains($0) && spaces(of: $0).isEmpty }
        let plan = RecoveryPlan.make(members: members.mapValues { $0.filter(alive.contains) }, stranded: stranded,
                                     hasOrdinarySpace: { !spaces(of: $0).isEmpty },
                                     destination: { destinationSpace(for: $0, original: original[$0]) })

        // Adds land before any removal is sent: a window removed from its only Space lands
        // on whichever Space is active, which can be a native fullscreen one.
        for (destination, windows) in plan.adds {
            var ids = windows
            kosmos_add_windows(destination, &ids, ids.count, true)
            _ = kosmos_barrier(destination)
        }
        for (space, windows) in plan.removals(landed: Displays.current().isInOrdinarySpace) {
            var ids = windows
            kosmos_remove_windows(space, &ids, ids.count)
            _ = kosmos_barrier(space)
        }

        let handled = Set(plan.adds.values.joined()).union(plan.removals.values.joined())
        let after = read(liveSpaces)
        let remaining = after.members.values.reduce(0) { $0 + $1.count }
        let onNoSpace = { (window: UInt32) in !SkyLight.rows([window]).isEmpty && spaces(of: window).isEmpty }
        guard plan.isComplete(remainingMembers: remaining, isOnNoSpace: onNoSpace) else {
            let withoutSpace = plan.windows.filter(onNoSpace).count
            recoveryLog.error("\(remaining) windows still concealed, \(withoutSpace) on no Space; keeping the record")
            // The record keeps the Spaces that still exist, and every window.
            var kept = record
            kept.spaces = record.spaces.filter { !gone.contains($0) && !after.gone.contains($0) }
            if !keeping { kept.animationSpaces = animation.filter { !gone.contains($0) && !after.gone.contains($0) } }
            file.publish(kept)
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
        var kept = record
        (kept.spaces, kept.windows) = (left.filter(record.spaces.contains), [])
        if !keeping { kept.animationSpaces = left.filter(animation.contains) }
        if !left.isEmpty { recoveryLog.error("\(left.count) Spaces still exist after their destroy; keeping them in the record") }
        if kept.spaces.isEmpty && kept.animationSpaces.isEmpty {
            file.clear()
        } else {
            file.publish(kept)
        }
        let destroyed = liveSpaces.count - left.count
        recoveryLog.notice("restored \(handled.count) windows, destroyed \(destroyed) Spaces")
        return .restored(windows: handled.count, spaces: destroyed)
    }

    /// The windows to take out of each Space of `spaces` that exists: the ones `record`
    /// concealed, and every window in a Space of `animation`. Spaces that are gone are listed
    /// apart.
    private static func members(_ spaces: [UInt64], of record: RecoveryRecord, animation: Set<UInt64>) -> SpaceMembers {
        var read = SpaceMembers.read(spaces.filter { !animation.contains($0) }, of: record)
        let listed = SpaceMembers.listed(spaces.filter(animation.contains))
        read.members.merge(listed.members) { concealed, _ in concealed }
        read.gone.formUnion(listed.gone)
        return read
    }

    /// The windows `read` finds in each existing Space of `spaces` once two reads 100 ms
    /// apart agree, for at most about 1 s; past that, the newest read, which the check after
    /// the adds and removals backs up. Spaces that are gone are listed apart.
    private static func settledMembers(_ spaces: [UInt64], read: ([UInt64]) -> SpaceMembers)
        -> (members: [UInt64: [UInt32]], gone: Set<UInt64>) {
        var previous = read(spaces)
        let existing = spaces.filter { !previous.gone.contains($0) }
        for _ in 0..<10 {
            usleep(100_000)
            let current = read(existing)
            if current.members == previous.members { break }
            previous.members = current.members
        }
        return (previous.members, previous.gone)
    }

    private static func spaces(of window: UInt32) -> [UInt64] {
        kosmos_window_spaces(window) as? [UInt64] ?? []
    }

    /// The current ordinary Space of the display under the window, else the Space a reveal
    /// would use; nil only when there is none.
    private static func destinationSpace(for window: UInt32, original: UInt64?) -> UInt64? {
        let displays = Displays.current()
        if let frame = SkyLight.rows([window]).first?.frame,
           let space = displays.currentSpace(at: CGPoint(x: frame.midX, y: frame.midY)) {
            return space
        }
        return displays.ordinarySpace(original: original)
    }
}
