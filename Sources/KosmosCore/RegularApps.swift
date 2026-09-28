/// Whether each process is a regular app, whose new windows the inventory admits. It records
/// each policy it is given and says what the change calls for (docs/inventory.md). A window
/// already admitted stays when its app stops being regular.
public struct RegularApps: Sendable {
    /// What a recorded policy calls for.
    public enum Change: Equatable, Sendable {
        case none
        /// Regular after a policy that was not, so the windows it left out wait for a sweep.
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
