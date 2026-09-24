/// How each concealed window was concealed and which Space holds it, and the operations a
/// batch of reveals and conceals needs (DESIGN.md, section 5.3). Only the bridge queue
/// changes it, in batch order, so a reveal always undoes what was really done.
public struct ConcealLedger: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// Also keeps its ordinary Space, so Command-Tab can pick it; revealed by removal.
        case keepOrdinary
        /// In the concealing Space only; revealed by moving it back to an ordinary Space.
        case exclusive
    }

    public struct Entry: Equatable, Sendable {
        public let kind: Kind
        public let space: UInt64

        public init(kind: Kind, space: UInt64) {
            self.kind = kind
            self.space = space
        }
    }

    /// The operations for one batch.
    public struct Batch: Equatable, Sendable {
        /// Windows to remove from the Space that holds them.
        public var removals: [UInt64: [UInt32]] = [:]
        /// Windows to move back to an ordinary Space.
        public var moves: [UInt32] = []
        /// Windows to conceal for the first time, by kind.
        public var keep: [UInt32] = []
        public var strip: [UInt32] = []
        /// After the batch: each window to hide and the Space it must be in.
        public var mustBeIn: [UInt32: UInt64] = [:]
        /// After the batch: each window to show and the Space it must have left.
        public var mustHaveLeft: [UInt32: UInt64] = [:]

        public var fresh: [UInt32] { keep + strip }
    }

    public private(set) var entries: [UInt32: Entry] = [:]

    public init(entries: [UInt32: Entry] = [:]) {
        self.entries = entries
    }

    /// The ledger for windows found in concealing Spaces, as after a recovery that could not
    /// restore them all. Nil when any Space's members could not be read: the state is then
    /// unknown, and a guess could strand a window.
    public static func rebuilt(members: [UInt64: [UInt32]?], hasOrdinarySpace: (UInt32) -> Bool) -> ConcealLedger? {
        var entries: [UInt32: Entry] = [:]
        for (space, windows) in members {
            guard let windows else { return nil }
            for window in windows {
                entries[window] = Entry(kind: hasOrdinarySpace(window) ? .keepOrdinary : .exclusive, space: space)
            }
        }
        return ConcealLedger(entries: entries)
    }

    /// The operations that reveal `show` and conceal `hide` in `space`. A window that is
    /// already concealed keeps its kind and its Space, whatever kind `hide` asks for. A
    /// window revealed by removal must still have an ordinary Space, or removing it would
    /// leave it on none; one that lost it is moved instead.
    public func batch(show: [UInt32], hide: [UInt32: Kind], into space: UInt64,
                      hasOrdinarySpace: (UInt32) -> Bool = { _ in true }) -> Batch {
        var batch = Batch()
        for window in show {
            guard let entry = entries[window] else { continue }
            if entry.kind == .keepOrdinary, hasOrdinarySpace(window) {
                batch.removals[entry.space, default: []].append(window)
            } else {
                batch.moves.append(window)
            }
            batch.mustHaveLeft[window] = entry.space
        }
        for (window, kind) in hide.sorted(by: { $0.key < $1.key }) {
            if let entry = entries[window] {
                batch.mustBeIn[window] = entry.space
                continue
            }
            if kind == .keepOrdinary { batch.keep.append(window) } else { batch.strip.append(window) }
            batch.mustBeIn[window] = space
        }
        return batch
    }

    /// Records a batch once it is confirmed.
    public mutating func commit(_ batch: Batch, into space: UInt64) {
        for window in batch.mustHaveLeft.keys { entries[window] = nil }
        for window in batch.keep { entries[window] = Entry(kind: .keepOrdinary, space: space) }
        for window in batch.strip { entries[window] = Entry(kind: .exclusive, space: space) }
    }
}
