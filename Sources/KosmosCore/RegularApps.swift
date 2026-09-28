/// Which processes are regular apps, whose new windows the inventory admits: each read once,
/// then followed through each change of its activation policy until it exits
/// (docs/inventory.md). A window already admitted stays when its app stops being regular.
public struct RegularApps: Sendable {
    /// What a recorded policy calls for.
    public enum Change: Equatable, Sendable {
        case none
        /// Regular, with no policy recorded before. NSWorkspace posts no launch of an app that
        /// became regular after it launched, so this may be the first Kosmos hears of it.
        case seenRegular
        /// Regular after a policy that was not: the windows it left out wait for a sweep.
        case becameRegular
        /// Its windows already admitted stay.
        case leftRegular
    }

    private var regular: [Int32: Bool] = [:]

    public init() {}

    /// Nil for a process with no policy recorded.
    public subscript(pid: Int32) -> Bool? { regular[pid] }

    public mutating func record(_ pid: Int32, regular isRegular: Bool) -> Change {
        switch (regular.updateValue(isRegular, forKey: pid), isRegular) {
        case (nil, true): .seenRegular
        case (false, true): .becameRegular
        case (true, false): .leftRegular
        default: .none
        }
    }

    /// At the process's exit, as pids come round again.
    public mutating func forget(_ pid: Int32) {
        regular[pid] = nil
    }
}
