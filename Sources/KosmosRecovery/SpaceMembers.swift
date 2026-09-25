import CKosmos
import Foundation
import KosmosSkyLight

/// The windows Kosmos concealed in each concealing Space. Reading a Space returns a list,
/// empty or not, while it exists, and nothing once it is destroyed or for an id that never
/// existed (`kosmos-probe destroyed-space`), so a Space that reads as nothing after retries
/// for about a second is gone: it holds no window.
public struct SpaceMembers: Equatable, Sendable {
    public var members: [UInt64: [UInt32]]
    public var gone: Set<UInt64>

    /// Reads `spaces` and keeps the windows `record` concealed. A Space that holds only
    /// other windows still exists.
    public static func read(_ spaces: [UInt64], of record: RecoveryRecord) -> SpaceMembers {
        var result = SpaceMembers(members: [:], gone: [])
        var pending = spaces
        for attempt in 0..<10 {
            if attempt > 0 { usleep(100_000) }
            pending = pending.filter { space in
                guard let list = kosmos_space_windows(space) as? [UInt32] else { return true }
                result.members[space] = list.sorted()
                return false
            }
            if pending.isEmpty { break }
        }
        result.gone = Set(pending)
        result.members = concealed(result.members, by: record, rows: rows)
        return result
    }

    /// What a read of a window's row gives: the owner, when its process could be identified,
    /// and the parent window, 0 for none.
    struct Row: Equatable {
        var owner: ProcessIdentity?
        var parent: UInt32
    }

    /// The windows of `members` that Kosmos concealed: the recorded ones; any other window of
    /// an app that owns a recorded one; a child of a concealed window, as the Open or Save
    /// panel of a sandboxed app, which the panel service owns; and a member `rows` did not
    /// find, since the Space just listed it and the read must have failed. Another process
    /// can have windows of its own in a holding Space, as JankyBorders' border windows follow
    /// the windows they border into it (docs/hiding.md). Kosmos never concealed them,
    /// so recovery and the ledger leave them out.
    static func concealed(_ members: [UInt64: [UInt32]], by record: RecoveryRecord,
                          rows: ([UInt32]) -> [UInt32: Row]) -> [UInt64: [UInt32]] {
        let recorded = Set(record.windows.map(\.id)), apps = Set(record.windows.map(\.owner))
        let others = members.values.joined().filter { !recorded.contains($0) }
        let read = rows(others)
        var concealed = recorded.union(others.filter { window in
            guard let row = read[window] else { return true }
            return row.owner.map(apps.contains) == true
        })
        // A sheet can have sheets of its own.
        var children: [UInt32]
        repeat {
            children = others.filter { !concealed.contains($0) && read[$0].map { concealed.contains($0.parent) } == true }
            concealed.formUnion(children)
        } while !children.isEmpty
        return members.mapValues { $0.filter(concealed.contains) }
    }

    private static func rows(_ windows: [UInt32]) -> [UInt32: Row] {
        var rows: [UInt32: Row] = [:]
        for row in SkyLight.rows(windows) { rows[row.id] = Row(owner: ProcessIdentity.of(row.pid), parent: row.parent) }
        return rows
    }
}
