import Foundation
import KosmosSkyLight

/// A Space reads as a list while it exists and as nothing once destroyed
/// (`kosmos-probe destroyed-space`), so one that reads as nothing for about a second is gone.
public struct SpaceMembers: Equatable, Sendable {
    public var members: [UInt64: [UInt32]]
    public var gone: Set<UInt64>

    public static func read(_ spaces: [UInt64], of record: RecoveryRecord) -> SpaceMembers {
        var result = SpaceMembers(members: [:], gone: [])
        var pending = spaces
        for attempt in 0..<10 {
            if attempt > 0 { usleep(100_000) }
            pending = pending.filter { space in
                guard let list = SkyLight.windows(in: space) else { return true }
                result.members[space] = list.sorted()
                return false
            }
            if pending.isEmpty { break }
        }
        result.gone = Set(pending)
        result.members = concealed(result.members, by: record, rows: rows)
        return result
    }

    /// `owner` is nil when the process could not be identified, and `parent` 0 for none.
    struct Row: Equatable {
        var owner: ProcessIdentity?
        var parent: UInt32
    }

    /// The members Kosmos concealed or slides, by the rule in docs/hiding.md. A member whose
    /// row does not read counts, since the Space just listed it.
    static func concealed(_ members: [UInt64: [UInt32]], by record: RecoveryRecord,
                          rows: ([UInt32]) -> [UInt32: Row]) -> [UInt64: [UInt32]] {
        let animation = Set(record.animationSpaces)
        let recorded = Set(record.windows.map(\.id)), apps = Set(record.windows.map(\.owner))
        let others = members.filter { !animation.contains($0.key) }.values.joined().filter { !recorded.contains($0) }
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
        return members.reduce(into: [:]) { kept, entry in
            kept[entry.key] = animation.contains(entry.key) ? entry.value : entry.value.filter(concealed.contains)
        }
    }

    private static func rows(_ windows: [UInt32]) -> [UInt32: Row] {
        var rows: [UInt32: Row] = [:]
        for row in SkyLight.rows(windows) { rows[row.id] = Row(owner: ProcessIdentity.of(row.pid), parent: row.parent) }
        return rows
    }
}
