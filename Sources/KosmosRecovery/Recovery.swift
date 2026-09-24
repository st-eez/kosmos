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
        /// Some windows are still in a recorded Space or on no Space; the record is kept
        /// for another attempt.
        case incomplete(remaining: Int)
    }

    public static func run(file: RecordFile) -> Outcome {
        guard let record = file.read() else { return .nothingRecorded }
        guard let windowServer = ProcessIdentity.windowServer() else { return .windowServerUnknown }
        guard record.windowServer == windowServer else {
            file.clear()
            return .staleSession
        }

        // A move Kosmos issued just before it died may still be landing.
        let members = settledMembers(of: record.spaces)
        let alive = Set(SkyLight.rows(Array(Set(members.values.joined()).union(record.windows.map(\.id)))).map(\.id))
        let original = Dictionary(record.windows.map { ($0.id, $0.originalSpace) }, uniquingKeysWith: { a, _ in a })
        let stranded = record.windows.map(\.id).filter { alive.contains($0) && spaces(of: $0).isEmpty }
        let plan = RecoveryPlan.make(members: members.mapValues { $0.filter(alive.contains) }, stranded: stranded,
                                     hasOrdinarySpace: { !spaces(of: $0).isEmpty },
                                     destination: { destinationSpace(for: $0, original: original[$0]) })

        for (destination, windows) in plan.moves {
            var ids = windows
            kosmos_add_windows(destination, &ids, ids.count, true)
            _ = kosmos_barrier(destination)
        }
        for (space, windows) in plan.removals {
            var ids = windows
            kosmos_remove_windows(space, &ids, ids.count)
            _ = kosmos_barrier(space)
        }

        let handled = Array(plan.moves.values.joined()) + Array(plan.removals.values.joined())
        let remaining = currentMembers(of: record.spaces).values.reduce(0) { $0 + $1.count }
        let withoutSpace = handled.filter { !SkyLight.rows([$0]).isEmpty && spaces(of: $0).isEmpty }.count
        guard RecoveryPlan.isComplete(remainingMembers: remaining, withoutSpace: withoutSpace) else {
            recoveryLog.error("\(remaining) windows still concealed, \(withoutSpace) on no Space; keeping the record")
            return .incomplete(remaining: remaining + withoutSpace)
        }
        // Destroying an empty Space cannot be confirmed through the bridge. One left behind
        // is empty and hides nothing.
        for space in record.spaces { kosmos_space_destroy(space) }
        file.clear()
        recoveryLog.notice("restored \(handled.count) windows, destroyed \(record.spaces.count) Spaces")
        return .restored(windows: handled.count, spaces: record.spaces.count)
    }

    /// Members of each Space once two reads 100 ms apart agree, for at most about 1 s.
    private static func settledMembers(of spaces: [UInt64]) -> [UInt64: [UInt32]] {
        var previous = currentMembers(of: spaces)
        for _ in 0..<10 {
            usleep(100_000)
            let current = currentMembers(of: spaces)
            if current == previous { return current }
            previous = current
        }
        return previous
    }

    private static func currentMembers(of spaces: [UInt64]) -> [UInt64: [UInt32]] {
        Dictionary(uniqueKeysWithValues: spaces.map { ($0, (kosmos_space_windows($0) as? [UInt32] ?? []).sorted()) })
    }

    private static func spaces(of window: UInt32) -> [UInt64] {
        kosmos_window_spaces(window) as? [UInt64] ?? []
    }

    /// The current ordinary Space of the display under the window, else the window's
    /// original Space if it still exists, else the main display's current Space, else any
    /// ordinary Space; nil only when there is none.
    private static func destinationSpace(for window: UInt32, original: UInt64?) -> UInt64? {
        let displays = Displays.current()
        if let frame = SkyLight.rows([window]).first?.frame,
           let space = displays.currentSpace(at: CGPoint(x: frame.midX, y: frame.midY)) {
            return space
        }
        if let original, displays.ordinarySpaces.contains(original) { return original }
        return displays.mainCurrentSpace ?? displays.displays.lazy.flatMap(\.spaces).first
    }
}
