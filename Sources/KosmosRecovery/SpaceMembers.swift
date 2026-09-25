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
        result.members = concealed(result.members, by: record, owners: owners)
        return result
    }

    /// The windows of `members` that Kosmos concealed: the recorded ones, and any other
    /// window of an app that owns a recorded one, such as a sheet. Another process can add
    /// windows of its own to a holding Space, as WindowManager.app appears to for Mission
    /// Control's placeholders (DESIGN.md, section 5.3). Kosmos never concealed them, so
    /// recovery and the ledger leave them out. `owners` gives the owner of each window that
    /// still exists.
    static func concealed(_ members: [UInt64: [UInt32]], by record: RecoveryRecord,
                          owners: ([UInt32]) -> [UInt32: ProcessIdentity]) -> [UInt64: [UInt32]] {
        let recorded = Set(record.windows.map(\.id)), apps = Set(record.windows.map(\.owner))
        let owner = owners(members.values.joined().filter { !recorded.contains($0) })
        return members.mapValues { $0.filter { recorded.contains($0) || owner[$0].map(apps.contains) == true } }
    }

    private static func owners(_ windows: [UInt32]) -> [UInt32: ProcessIdentity] {
        var owners: [UInt32: ProcessIdentity] = [:]
        for row in SkyLight.rows(windows) { owners[row.id] = ProcessIdentity.of(row.pid) }
        return owners
    }
}
