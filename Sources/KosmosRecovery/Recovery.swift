import CoreGraphics
import CKosmos
import Foundation
import KosmosSkyLight
import os

private let recoveryLog = Logger(subsystem: "io.github.st-eez.kosmos", category: "recovery")

/// Every step can run again after an interruption. The caller holds KosmosFiles.lock
/// (docs/hiding.md).
public enum Recovery {
    public enum Outcome: Equatable, Sendable {
        case nothingRecorded
        /// The record belongs to an earlier WindowServer, whose Spaces are gone.
        case staleSession
        /// The WindowServer could not be identified; the record is kept.
        case windowServerUnknown
        /// `spaces` counts the Spaces read back as gone after their destroy.
        case restored(windows: Int, spaces: Int)
        /// A Kosmos took the record over: `kept` windows stay concealed and recorded, and the
        /// rest were restored.
        case adopted(kept: Int, restored: Int, spaces: Int)
        /// Windows are left in a recorded Space or on no Space; the record is kept.
        case incomplete(remaining: Int)

        /// False when another attempt could restore more.
        public var isFinal: Bool {
            switch self {
            case .incomplete, .windowServerUnknown: false
            case .nothingRecorded, .staleSession, .restored, .adopted: true
            }
        }
    }

    /// `keeping`: the running Kosmos keeps the Spaces windows slide in, recorded; after it
    /// exits, and at its startup and quit, they go too. `sparing`, for a Kosmos that takes the
    /// record over, names the windows that stay concealed, given the concealed members of the
    /// holding Spaces and the recorded windows (docs/hiding.md).
    public static func run(file: RecordFile, keepingAnimationSpaces keeping: Bool = false,
                           sparing: ((_ members: [UInt32], _ recorded: Set<UInt32>) -> Set<UInt32>)? = nil) -> Outcome {
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
        let recorded = record.spaces + animation
        let (members, gone) = settledMembers(recorded, of: record)
        let liveSpaces = recorded.filter { !gone.contains($0) }
        let holding = Set(record.spaces)
        let spared = sparing?(members.filter { holding.contains($0.key) }.values.flatMap { $0 }, Set(record.windows.map(\.id))) ?? []
        // One snapshot of the displays and one read of the rows, so a display change during
        // recovery cannot mix destinations.
        let displays = Displays.current()
        let named = Set(members.values.joined()).union(record.windows.map(\.id))
        let frames = Dictionary(SkyLight.rows(Array(named)).map { ($0.id, $0.frame) }, uniquingKeysWith: { a, _ in a })
        let original = Dictionary(record.windows.map { ($0.id, $0.originalSpace) }, uniquingKeysWith: { a, _ in a })
        let plan = RecoveryPlan.make(members: members, recorded: record.windows.map(\.id), sparing: spared, alive: Set(frames.keys),
                                     isOnAnySpace: { SkyLight.spaces(of: $0).map { !$0.isEmpty } },
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

        let handled = Set(plan.adds.values.joined()).union(plan.removalsBySpace.values.joined())
        let after = SpaceMembers.read(liveSpaces, of: record)
        let remaining = plan.remaining(after.members)
        let alive = Set(SkyLight.rows(Array(plan.windows)).map(\.id))
        let onNoSpace = { (window: UInt32) in alive.contains(window) && (SkyLight.spaces(of: window) ?? []).isEmpty }
        guard plan.isComplete(remainingMembers: remaining, isOnNoSpace: onNoSpace) else {
            let withoutSpace = plan.windows.filter(onNoSpace).count
            recoveryLog.error("\(remaining) windows still concealed, \(withoutSpace) on no Space; keeping the record")
            file.publish(record.keptAfterIncomplete(gone: gone.union(after.gone), keepingAnimationSpaces: keeping))
            return .incomplete(remaining: remaining + withoutSpace)
        }
        // A destroy is only sent, and one that leaves a Space holding another process's
        // windows is unconfirmed, so a barrier and a read show each Space gone or not.
        let destroying = liveSpaces.filter { !plan.sparedSpaces.contains($0) }
        for space in destroying { kosmos_space_destroy(space) }
        let left = destroying.filter { space in
            _ = kosmos_barrier(space)
            return SkyLight.windows(in: space) != nil
        }
        if !left.isEmpty { recoveryLog.error("\(left.count) Spaces still exist after their destroy; keeping them in the record") }
        if let kept = record.keptAfterRestore(left: Set(left).union(plan.sparedSpaces), keepingAnimationSpaces: keeping,
                                               sparing: spared) {
            file.publish(kept)
        } else {
            file.clear()
        }
        let destroyed = destroying.count - left.count
        guard !spared.isEmpty else {
            recoveryLog.notice("restored \(handled.count) windows, destroyed \(destroyed) Spaces")
            return .restored(windows: handled.count, spaces: destroyed)
        }
        recoveryLog.notice("kept \(spared.count) windows concealed, restored \(handled.count), destroyed \(destroyed) Spaces")
        return .adopted(kept: spared.count, restored: handled.count, spaces: destroyed)
    }

    /// An operation sent just before Kosmos died may still be landing, so the members are
    /// read until two reads 100 ms apart agree, for about 1 s at most.
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

    private static func destination(for frame: CGRect?, original: UInt64?, in displays: Displays) -> UInt64? {
        if let frame, let space = displays.currentSpace(at: CGPoint(x: frame.midX, y: frame.midY)) { return space }
        return displays.ordinarySpace(original: original)
    }
}
