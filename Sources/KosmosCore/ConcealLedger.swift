/// Which Space holds each concealed window, and the operations a batch of reveals and
/// conceals needs (DESIGN.md, section 5.3). Only the bridge queue changes it, in batch
/// order, so a reveal always undoes what was really done.
public struct ConcealLedger: Equatable, Sendable {
    /// How a hide asks for a window to be concealed.
    public enum Kind: Equatable, Sendable {
        /// Also keeps its ordinary Space, so Command-Tab can pick it.
        case keepOrdinary
        /// In the concealing Space only.
        case exclusive
    }

    /// The operations for one batch.
    public struct Batch: Equatable, Sendable {
        /// Revealed windows, by the concealing Space to remove them from.
        public var removals: [UInt64: [UInt32]] = [:]
        /// Revealed windows with no ordinary Space, to add to one before their removal. The
        /// add strips only managed Spaces, so it leaves them in the concealing Space.
        public var adds: [UInt32] = []
        /// Windows to conceal for the first time, by kind.
        public var keep: [UInt32] = []
        public var strip: [UInt32] = []
        /// After the batch: each window to hide and the Space it must be in.
        public var mustBeIn: [UInt32: UInt64] = [:]

        public var fresh: [UInt32] { keep + strip }

        /// The removals to send once the adds are confirmed. An added window leaves the
        /// concealing Space only if `landed` says its add took: removed from its only Space,
        /// it would land on the active Space, which can be a native fullscreen one. Left
        /// there, it fails the batch's confirmation, and recovery adds it again.
        public func removals(landed: (UInt32) -> Bool) -> [UInt64: [UInt32]] {
            let failed = Set(adds.filter { !landed($0) })
            return removals.mapValues { $0.filter { !failed.contains($0) } }
        }
    }

    /// The concealing Space of each concealed window.
    public private(set) var entries: [UInt32: UInt64] = [:]

    public init(entries: [UInt32: UInt64] = [:]) {
        self.entries = entries
    }

    /// The ledger for windows found in concealing Spaces, as after a recovery that could not
    /// restore them all. Nil when any Space's members could not be read: the state is then
    /// unknown, and a guess could strand a window.
    public static func rebuilt(members: [UInt64: [UInt32]?]) -> ConcealLedger? {
        var entries: [UInt32: UInt64] = [:]
        for (space, windows) in members {
            guard let windows else { return nil }
            for window in windows { entries[window] = space }
        }
        return ConcealLedger(entries: entries)
    }

    /// The operations that reveal `show` and conceal `hide` in `space`. A window that is
    /// already concealed keeps its Space, whatever kind `hide` asks for. A revealed window
    /// must still have an ordinary Space, or removing it would leave it on none; one that
    /// has none, as `hasOrdinarySpace` reads it now, is added to one first.
    public func batch(show: [UInt32], hide: [UInt32: Kind], into space: UInt64,
                      hasOrdinarySpace: (UInt32) -> Bool) -> Batch {
        var batch = Batch()
        for window in show {
            guard let held = entries[window] else { continue }
            if !hasOrdinarySpace(window) { batch.adds.append(window) }
            batch.removals[held, default: []].append(window)
        }
        for (window, kind) in hide.sorted(by: { $0.key < $1.key }) {
            if let held = entries[window] {
                batch.mustBeIn[window] = held
                continue
            }
            if kind == .keepOrdinary { batch.keep.append(window) } else { batch.strip.append(window) }
            batch.mustBeIn[window] = space
        }
        return batch
    }

    /// Records a batch once it is confirmed.
    public mutating func commit(_ batch: Batch, into space: UInt64) {
        for window in batch.removals.values.joined() { entries[window] = nil }
        for window in batch.fresh { entries[window] = space }
    }
}
