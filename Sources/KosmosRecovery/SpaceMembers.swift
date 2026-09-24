import CKosmos
import Foundation

/// The windows in each concealing Space. Reading a Space returns a list, empty or not,
/// while it exists, and nothing once it is destroyed or for an id that never existed
/// (`kosmos-probe destroyed-space`), so a Space that reads as nothing after retries for
/// about a second is gone: it holds no window.
public struct SpaceMembers: Equatable, Sendable {
    public var members: [UInt64: [UInt32]]
    public var gone: Set<UInt64>

    public static func read(_ spaces: [UInt64]) -> SpaceMembers {
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
        return result
    }
}
