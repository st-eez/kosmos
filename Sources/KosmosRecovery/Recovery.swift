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
        case restored(windows: Int, spaces: Int)
        /// Some windows are still in a recorded Space or not back on a Space; the record
        /// is kept for another attempt.
        case incomplete(remaining: Int)
    }

    public static func run(file: RecordFile) -> Outcome {
        guard let record = file.read() else { return .nothingRecorded }
        guard let windowServer = ProcessIdentity.windowServer() else { return .windowServerUnknown }
        guard record.windowServer == windowServer else {
            file.clear()
            return .staleSession
        }

        // An operation Kosmos sent just before it died may still be landing. A Space that no
        // longer exists holds nothing and leaves the record.
        let (members, gone) = settledMembers(of: record.spaces)
        let liveSpaces = record.spaces.filter { !gone.contains($0) }
        let alive = Set(SkyLight.rows(Array(Set(members.values.joined()).union(record.windows.map(\.id)))).map(\.id))
        let original = Dictionary(record.windows.map { ($0.id, $0.originalSpace) }, uniquingKeysWith: { a, _ in a })
        let stranded = record.windows.map(\.id).filter { alive.contains($0) && spaces(of: $0).isEmpty }
        let plan = RecoveryPlan.make(members: members.mapValues { $0.filter(alive.contains) }, stranded: stranded,
                                     hasOrdinarySpace: { !spaces(of: $0).isEmpty },
                                     destination: { destinationSpace(for: $0, original: original[$0]) })

        // Adds before removals: a window removed from its only Space lands on whichever
        // Space is active, which can be a native fullscreen one.
        for (destination, windows) in plan.adds {
            var ids = windows
            kosmos_add_windows(destination, &ids, ids.count, true)
            _ = kosmos_barrier(destination)
        }
        for (space, windows) in plan.removals {
            var ids = windows
            kosmos_remove_windows(space, &ids, ids.count)
            _ = kosmos_barrier(space)
        }

        let handled = Set(plan.adds.values.joined()).union(plan.removals.values.joined())
        let after = SpaceMembers.read(liveSpaces)
        let remaining = after.members.values.reduce(0) { $0 + $1.count }
        let displays = Displays.current()
        let exists = { (window: UInt32) in !SkyLight.rows([window]).isEmpty }
        // A window that closed needs no Space.
        let unplaced = plan.unplaced(isOnNoSpace: { exists($0) && spaces(of: $0).isEmpty },
                                     isInOrdinarySpace: { !exists($0) || displays.isInOrdinarySpace($0) })
        guard remaining == 0 && unplaced.isEmpty else {
            recoveryLog.error("\(remaining) windows still concealed, \(unplaced.count) not back on a Space; keeping the record")
            // The record keeps the Spaces that still exist, and every window.
            var kept = record
            kept.spaces = liveSpaces.filter { !after.gone.contains($0) }
            file.publish(kept)
            return .incomplete(remaining: remaining + unplaced.count)
        }
        // Destroying an empty Space cannot be confirmed through the bridge. One left behind
        // is empty and hides nothing.
        for space in liveSpaces { kosmos_space_destroy(space) }
        file.clear()
        recoveryLog.notice("restored \(handled.count) windows, destroyed \(liveSpaces.count) Spaces")
        return .restored(windows: handled.count, spaces: liveSpaces.count)
    }

    /// Members of each existing Space once two reads 100 ms apart agree, for at most about
    /// 1 s; past that, the newest read, which the check after the adds and removals backs
    /// up. Spaces that are gone are listed apart.
    private static func settledMembers(of spaces: [UInt64]) -> (members: [UInt64: [UInt32]], gone: Set<UInt64>) {
        var previous = SpaceMembers.read(spaces)
        let existing = spaces.filter { !previous.gone.contains($0) }
        for _ in 0..<10 {
            usleep(100_000)
            let current = SpaceMembers.read(existing)
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
