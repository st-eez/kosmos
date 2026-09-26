/// A Space's id, as SkyLight's calls take it.
public typealias SpaceID = UInt64

/// Which Space holds each concealed window (docs/hiding.md). Only the bridge queue changes
/// it, in batch order, so a reveal undoes what was really done.
public struct ConcealLedger: Equatable, Sendable {
    public struct Batch: Equatable, Sendable {
        /// Revealed windows, by the concealing Space they leave.
        public var removals: [SpaceID: [WindowID]] = [:]
        /// Revealed windows on no other Space, to add to an ordinary one before their removal.
        /// The add strips only managed Spaces, so it leaves them in the concealing Space.
        public var adds: [WindowID] = []
        /// Windows concealed for the first time, which keep their ordinary Space unless in
        /// `strip` (docs/displays.md).
        public var fresh: [WindowID] = []
        public var strip: [WindowID] = []
        public var mustBeIn: [WindowID: SpaceID] = [:]

        public var touched: Set<SpaceID> { Set(mustBeIn.values).union(removals.keys) }

        public func isDone(members: [SpaceID: Set<WindowID>]) -> Bool { failed(members: members).isEmpty }

        /// A concealed window its Space does not list, or a revealed one it still lists. A Space
        /// missing from `members`, whose read failed, fails each of its windows.
        public func failed(members: [SpaceID: Set<WindowID>]) -> Set<WindowID> {
            var failed = Set(mustBeIn.filter { members[$0.value]?.contains($0.key) != true }.keys)
            for (space, windows) in removals {
                failed.formUnion(windows.filter { members[space]?.contains($0) != false })
            }
            return failed
        }

        /// The batch less the windows it failed, once none of them is ordered in: each closed or
        /// was ordered out after the batch read its row, as at Command-W right before a switch,
        /// and recovery would restore every other window and not it. Nil when a failed window is
        /// still ordered in (docs/hiding.md).
        public func confirmed(members: [SpaceID: Set<WindowID>],
                              orderedIn: (Set<WindowID>) -> Set<WindowID>) -> (batch: Batch, left: Set<WindowID>)? {
            let left = failed(members: members)
            guard !left.isEmpty else { return (self, []) }
            guard orderedIn(left).isEmpty else { return nil }
            var batch = self
            batch.removals = removals.mapValues { $0.filter { !left.contains($0) } }
            batch.adds.removeAll(where: left.contains)
            batch.fresh.removeAll(where: left.contains)
            batch.strip.removeAll(where: left.contains)
            batch.mustBeIn = mustBeIn.filter { !left.contains($0.key) }
            return (batch, left)
        }

        /// An added window leaves the concealing Space only once its add landed: removed from
        /// its only Space, it would land on the active Space, which can be a fullscreen one.
        public func removals(landed: (WindowID) -> Bool) -> [SpaceID: [WindowID]] {
            let failed = Set(adds.filter { !landed($0) })
            return removals.mapValues { $0.filter { !failed.contains($0) } }
        }
    }

    /// Each concealed window's concealing Space.
    public private(set) var entries: [WindowID: SpaceID] = [:]

    public init(entries: [WindowID: SpaceID] = [:]) {
        self.entries = entries
    }

    /// For a recovery that could not restore every window. Nil when any Space's members
    /// could not be read: a guess could strand a window.
    public static func rebuilt(members: [SpaceID: [WindowID]?]) -> ConcealLedger? {
        var entries: [WindowID: SpaceID] = [:]
        for (space, windows) in members {
            guard let windows else { return nil }
            for window in windows { entries[window] = space }
        }
        return ConcealLedger(entries: entries)
    }

    /// A revealed window on no other Space, as `isOnAnySpace` reads it now, is added to an
    /// ordinary one first: removing it would leave it on none.
    public func batch(show: [WindowID], hide: [WindowID], stripping: Set<WindowID> = [], into space: SpaceID,
                      isOnAnySpace: (WindowID) -> Bool) -> Batch {
        var batch = Batch()
        for window in show {
            guard let held = entries[window] else { continue }
            if !isOnAnySpace(window) { batch.adds.append(window) }
            batch.removals[held, default: []].append(window)
        }
        for window in Set(hide).sorted() {
            if let held = entries[window] {
                batch.mustBeIn[window] = held
                continue
            }
            batch.fresh.append(window)
            if stripping.contains(window) { batch.strip.append(window) }
            batch.mustBeIn[window] = space
        }
        return batch
    }

    /// For windows that left their concealing Space on their own, as a deselected native tab
    /// does (kosmos-probe tabs).
    public mutating func forget(_ windows: [WindowID]) {
        for window in windows { entries[window] = nil }
    }

    /// A failed `members` read, nil, keeps the Space's windows. A window the ledger does not
    /// hold departs when `settled`: one alive on no Space stays for recovery to restore.
    public func departed(_ windows: [WindowID], members: (SpaceID) -> [WindowID]?, settled: (WindowID) -> Bool) -> [WindowID] {
        windows.filter { window in
            guard let space = entries[window] else { return settled(window) }
            return members(space).map { !$0.contains(window) } ?? false
        }
    }

    /// Once the batch is confirmed.
    public mutating func commit(_ batch: Batch, into space: SpaceID) {
        for window in batch.removals.values.joined() { entries[window] = nil }
        for window in batch.fresh { entries[window] = space }
    }
}
