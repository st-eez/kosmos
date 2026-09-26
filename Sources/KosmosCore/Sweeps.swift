/// The inventory's sweeps (docs/inventory.md). One reads at a time, and one asked for while it
/// reads starts when it ends. A window an event names after a sweep starts keeps what the
/// event said, as the sweep's snapshot may predate the change.
public struct Sweeps: Sendable {
    /// What a sweep's snapshot changes.
    public struct Snapshot: Equatable, Sendable {
        /// The windows whose rows apply.
        public let seen: Set<WindowID>
        /// The windows tracked that it no longer lists.
        public let lost: [WindowID]
        /// Whether it is the first since launch.
        public let first: Bool
    }

    /// Nil while no sweep reads.
    private var touched: Set<WindowID>?
    /// A sweep was asked for while one read.
    public private(set) var again = false
    private var swept = false
    /// The windows the first sweep saw, which were there at launch.
    public private(set) var atLaunch: Set<WindowID> = []

    public init() {}

    /// False while a sweep reads, which then sweeps again once it ends.
    public mutating func start() -> Bool {
        guard touched == nil else {
            again = true
            return false
        }
        touched = []
        return true
    }

    /// Windows an event named.
    public mutating func touch(_ windows: some Sequence<WindowID>) {
        touched?.formUnion(windows)
    }

    /// Ends the sweep that reads, with its snapshot, or nil when its read failed or came while
    /// locked, which changes nothing.
    public mutating func finish(read: [WindowID]?, tracked: some Sequence<WindowID>) -> Snapshot? {
        let touched = self.touched ?? []
        self.touched = nil
        guard let read else { return nil }
        let seen = Set(read).subtracting(touched)
        let first = !swept
        if first { atLaunch = seen }
        swept = true
        return Snapshot(seen: seen, lost: tracked.filter { !seen.contains($0) && !touched.contains($0) }, first: first)
    }

    /// Whether to sweep again now that a sweep ended.
    public mutating func takeAgain() -> Bool {
        defer { again = false }
        return again
    }
}
