/// What a Kosmos that takes over the recovery record keeps concealed, in place of startup
/// recovery: each recorded window that is ordered in, with the windows that stand on it, as
/// its sheets. Recovery brings back the rest (docs/hiding.md).
public struct Adoption: Equatable, Sendable {
    /// A window in a holding Space, as WindowServer's row has it.
    public struct Member: Equatable, Sendable {
        public var id: UInt32
        /// 0 for none.
        public var parent: UInt32
        public var orderedIn: Bool

        public init(id: UInt32, parent: UInt32, orderedIn: Bool) {
            self.id = id
            self.parent = parent
            self.orderedIn = orderedIn
        }
    }

    /// Each recorded window kept concealed, with the windows kept for standing on it.
    public private(set) var kept: [UInt32: Set<UInt32>] = [:]

    public init() {}

    /// `members` has a row for each window it names, so a member with none, closed or unread,
    /// comes back. A window ordered out, as minimized or hidden with its app, parks at its
    /// admission, which conceals nothing.
    public init(members: [Member], recorded: Set<UInt32>) {
        let roots = Set(members.filter { recorded.contains($0.id) && $0.orderedIn }.map(\.id))
        kept = SpaceMembers.sheets(of: roots, parents: Dictionary(members.map { ($0.id, $0.parent) }) { first, _ in first })
    }

    public var windows: Set<UInt32> { Set(kept.keys).union(kept.values.joined()) }

    /// The window is admitted, so a switch reveals it with its workspace from now on.
    public mutating func admitted(_ window: UInt32) {
        kept[window] = nil
    }

    /// The windows still waiting for their admission, with those standing on them, which a
    /// switch would never reveal.
    public var unadmitted: [UInt32] { kept.keys.sorted().flatMap { [$0] + kept[$0]!.sorted() } }
}
