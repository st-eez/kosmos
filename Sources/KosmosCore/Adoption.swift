/// What a Kosmos that takes over the recovery record keeps concealed, in place of startup
/// recovery: each recorded window its admission will conceal, with the windows that stand on
/// it, as its sheets. Recovery brings back the rest (docs/hiding.md).
public struct Adoption: Equatable, Sendable {
    /// A window in a holding Space, as WindowServer's row has it.
    public struct Member: Equatable, Sendable {
        public var id: WindowID
        public var pid: Int32
        /// 0 for none.
        public var parent: WindowID
        public var orderedIn: Bool

        public init(id: WindowID, pid: Int32, parent: WindowID, orderedIn: Bool) {
            self.id = id
            self.pid = pid
            self.parent = parent
            self.orderedIn = orderedIn
        }
    }

    /// Each recorded window kept concealed, with the windows kept for standing on it.
    public private(set) var kept: [WindowID: Set<WindowID>] = [:]

    public init() {}

    /// `members` has a row for each window it names, so a member with none, closed or unread,
    /// comes back. A window ordered out, as minimized or hidden with its app, parks at its
    /// admission, which conceals nothing. `conceals` says whether admitting the window
    /// conceals it (`Session.concealsAtAdmission`).
    public init(members: [Member], recorded: Set<WindowID>, conceals: (Member) -> Bool) {
        for member in members where recorded.contains(member.id) && member.orderedIn && conceals(member) {
            kept[member.id] = []
        }
        let parents = Dictionary(members.map { ($0.id, $0.parent) }) { first, _ in first }
        // A sheet can have sheets of its own.
        func root(of window: WindowID) -> WindowID? {
            var seen: Set<WindowID> = []
            var current = window
            while let parent = parents[current], parent != 0, seen.insert(current).inserted {
                if kept[parent] != nil { return parent }
                current = parent
            }
            return nil
        }
        for member in members where kept[member.id] == nil {
            if let root = root(of: member.id) { kept[root]!.insert(member.id) }
        }
    }

    public var windows: Set<WindowID> { Set(kept.keys).union(kept.values.joined()) }

    /// The window is admitted, so a switch reveals it with its workspace from now on.
    public mutating func admitted(_ window: WindowID) {
        kept[window] = nil
    }

    /// The windows still waiting for their admission, with those standing on them, which a
    /// switch would never reveal.
    public var unadmitted: [WindowID] { kept.keys.sorted().flatMap { [$0] + kept[$0]!.sorted() } }
}

extension Session {
    /// Whether admitting `window` now conceals it, for a window ordered in: the restored layout
    /// has it on a hidden workspace, or it lacks it and `rule`, the workspace its rule names, is
    /// hidden. Any other window joins a shown workspace (docs/tree.md).
    public func concealsAtAdmission(_ window: WindowID, rule: String?) -> Bool {
        if let saved = savedWorkspace(of: window) { return !isShown(saved) }
        guard let rule, workspaces[rule] != nil else { return false }
        return !isShown(rule)
    }
}
