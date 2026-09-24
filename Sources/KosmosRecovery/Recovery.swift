import CoreGraphics
import CSkyLight
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
        case restored(windows: Int, spaces: Int)
        /// Some windows stayed in a recorded Space; the record is kept for another attempt.
        case incomplete(remaining: Int)
    }

    public static func run(file: RecordFile) -> Outcome {
        guard let record = file.read() else { return .nothingRecorded }
        guard record.windowServer == ProcessIdentity.windowServer() else {
            file.clear()
            return .staleSession
        }

        // A move Kosmos issued just before it died may still be landing.
        var members = settledMembers(of: record.spaces)
        let recorded = Set(record.windows.map(\.id))
        let stranded = recorded.filter { !SkyLight.rows([$0]).isEmpty && spaces(of: $0).isEmpty }

        for (space, windows) in members where !windows.isEmpty {
            var ids = windows
            kosmos_remove_windows(space, &ids, ids.count)
            _ = kosmos_barrier(space)
        }

        // Windows left with no Space go to the current Space of the display under them.
        let candidates = Set(members.values.joined()).union(stranded)
        let homeless = candidates.filter { !SkyLight.rows([$0]).isEmpty && spaces(of: $0).isEmpty }
        let original = Dictionary(record.windows.map { ($0.id, $0.originalSpace) }, uniquingKeysWith: { a, _ in a })
        for (destination, windows) in Dictionary(grouping: homeless, by: { destinationSpace(for: $0, original: original[$0]) }) {
            guard destination != 0 else { continue }
            var ids = Array(windows)
            kosmos_add_windows(destination, &ids, ids.count, true)
            _ = kosmos_barrier(destination)
        }

        members = currentMembers(of: record.spaces)
        let remaining = members.values.reduce(0) { $0 + $1.count }
        guard remaining == 0 else {
            recoveryLog.error("\(remaining) windows still in recorded Spaces")
            return .incomplete(remaining: remaining)
        }
        for space in record.spaces { kosmos_space_destroy(space) }
        file.clear()
        recoveryLog.notice("restored \(candidates.count) windows, destroyed \(record.spaces.count) Spaces")
        return .restored(windows: candidates.count, spaces: record.spaces.count)
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
    /// original Space if it still exists, else the main display's current Space.
    private static func destinationSpace(for window: UInt32, original: UInt64?) -> UInt64 {
        let displays = Displays.current()
        if let frame = SkyLight.rows([window]).first?.frame,
           let space = displays.currentSpace(at: CGPoint(x: frame.midX, y: frame.midY)) {
            return space
        }
        if let original, displays.ordinarySpaces.contains(original) { return original }
        return displays.mainCurrentSpace ?? 0
    }
}
