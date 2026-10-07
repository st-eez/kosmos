import CoreGraphics

public enum FrameWrite: Equatable, Sendable {
    case position(CGPoint)
    /// Written size, position, then size again: an app can clamp the size against the old
    /// position (docs/geometry.md).
    case frame(CGRect)

    /// `queued` is a write for the same window that has not run. A position write assumed
    /// the size before it had landed, so after a queued frame write it writes the whole target.
    public func replacing(_ queued: FrameWrite, target: CGRect) -> FrameWrite {
        if case .position = self, case .frame = queued { return .frame(target) }
        return self
    }
}

/// What a frame read back after a write shows of the window's size.
public enum Fit: Equatable, Sendable {
    /// No larger than the target on either axis, past the slack.
    case took
    /// Larger than a target written for the first time: the target is written whole again.
    case refused
    /// Larger at the target's second write: the size kept on each axis it refused, zero on
    /// the other.
    case minimum(CGSize)
}

extension CGRect {
    /// More than the ledger's slack smaller than `target` on an axis.
    public func isSmaller(than target: CGRect) -> Bool {
        width < target.width - FrameLedger.slack || height < target.height - FrameLedger.slack
    }
}

/// Decides which windows need a frame write (docs/geometry.md).
public struct FrameLedger: Sendable {
    /// Apps round their size, so a window may read back this much larger than its target on
    /// an axis and still have taken it.
    public static let slack: CGFloat = 2

    private var confirmed: [WindowID: CGRect] = [:]
    private var pending: [WindowID: CGRect] = [:]
    /// Outlasts `forget`: a change that came before the confirm is still that write's.
    private var confirmedAt: [WindowID: ContinuousClock.Instant] = [:]
    private var refused: [WindowID: (target: CGRect, kept: CGSize)] = [:]
    /// A target the window read back larger than once, past the slack.
    private var refusedLarger: [WindowID: CGRect] = [:]
    /// The newest write sent to each window's app, until a row shows its read back.
    private var landing: [WindowID: (target: CGRect, sent: ContinuousClock.Instant, readBack: CGRect?)] = [:]

    public init() {}

    public mutating func writes(for targets: [WindowID: CGRect]) -> [WindowID: FrameWrite] {
        var writes: [WindowID: FrameWrite] = [:]
        for (id, target) in targets {
            let current = pending[id] ?? confirmed[id]
            if current == target { continue }
            if let refusal = refused[id], refusal.target == target {
                let placed = CGRect(origin: target.origin, size: refusal.kept)
                if current != placed {
                    // A write of another size in flight, or a size seen since, leaves the
                    // window at that size.
                    let whole = current?.size != placed.size
                    writes[id] = whole ? .frame(target) : .position(target.origin)
                    pending[id] = whole ? target : placed
                }
                continue
            }
            refused[id] = nil
            writes[id] = current?.size == target.size ? .position(target.origin) : .frame(target)
            pending[id] = target
        }
        return writes
    }

    /// A first read back larger than the target is not remembered, so the next write is whole:
    /// an app can ignore a size written as its window changes display or Space.
    @discardableResult
    public mutating func confirm(_ id: WindowID, target: CGRect, readBack: CGRect, at now: ContinuousClock.Instant) -> Fit {
        confirmed[id] = readBack
        confirmedAt[id] = now
        if pending[id] == target || pending[id] == CGRect(origin: target.origin, size: readBack.size) {
            pending[id] = nil
        }
        if landing[id]?.target == target { landing[id]?.readBack = readBack }
        let kept = CGSize(width: readBack.width > target.width + Self.slack ? readBack.width : 0,
                          height: readBack.height > target.height + Self.slack ? readBack.height : 0)
        guard kept == .zero || refusedLarger[id] == target else {
            refusedLarger[id] = target
            refused[id] = nil
            return .refused
        }
        if kept == .zero { refusedLarger[id] = nil }
        if readBack.size != target.size, refused[id]?.target != target {
            refused[id] = (target, readBack.size)
        }
        return kept == .zero ? .took : .minimum(kept)
    }

    /// A frame seen with no write of Kosmos's in flight, as after a user resize.
    public mutating func observe(_ id: WindowID, frame: CGRect) {
        confirmed[id] = frame
        if let refusal = refused[id], refusal.kept != frame.size {
            refused[id] = nil
            refusedLarger[id] = nil
        }
    }

    /// A window concealed or on a hidden workspace can ignore a size on its way to the
    /// holding Space or another display, so such a refusal says nothing of the app's limit.
    public mutating func forgetLargerReadBack(_ id: WindowID) {
        refusedLarger[id] = nil
    }

    /// For a change that came before the last confirm. Its row, read after the confirm, can
    /// hold the app's next live resize step, whose own event then finds no difference.
    public mutating func observeAfterConfirm(_ id: WindowID, frame: CGRect) {
        if confirmed[id] != frame { observe(id, frame: frame) }
    }

    public func isWriting(_ id: WindowID) -> Bool { pending[id] != nil }

    /// Where the newest write puts the window until a row shows it: the target in flight, then
    /// the read back that confirmed it, until the write counts as landed or a move that was not
    /// Kosmos's replaces it. A row can still show where the window was (docs/displays.md).
    public func newestWrite(of id: WindowID, at now: ContinuousClock.Instant) -> CGRect? {
        if let target = pending[id] { return target }
        guard isLanding(id, at: now), let readBack = landing[id]?.readBack, confirmed[id] == readBack else { return nil }
        return readBack
    }

    /// A write gone to its app's worker, with the target its read back names.
    public mutating func sent(_ id: WindowID, target: CGRect, at now: ContinuousClock.Instant) {
        landing[id] = (target, now, nil)
    }

    /// A row of the window from WindowServer. True when it shows the newest write landed.
    @discardableResult
    public mutating func seen(_ id: WindowID, frame: CGRect) -> Bool {
        guard let readBack = landing[id]?.readBack, readBack == frame else { return false }
        landing[id] = nil
        return true
    }

    /// Whether the newest write sent is yet to show in a row.
    public func isLanding(_ id: WindowID, at now: ContinuousClock.Instant) -> Bool {
        landingEnds(id).map { now < $0 } ?? false
    }

    /// A write no row has shown counts as landed after the Accessibility timeout, so a reveal
    /// waits no longer (docs/hiding.md).
    public func landingEnds(_ id: WindowID) -> ContinuousClock.Instant? {
        landing[id].map { $0.sent + AXBackoff.timeout }
    }

    /// Whether a change that came at `stamp` can be a write's. Ceiling: a change that came
    /// before the write was sent counts too (docs/geometry.md).
    public func isWriting(_ id: WindowID, at stamp: ContinuousClock.Instant) -> Bool {
        isWriting(id) || confirmedAt[id].map { stamp < $0 } == true
    }

    /// Whose a frame change of the window is (docs/geometry.md).
    public enum Change: Equatable, Sendable {
        /// A write is in flight, whose read back comes next.
        case writing
        /// Kosmos's own write: the change shows the newest write's read back (`landed`), or
        /// came before the last confirm, at `changedAt`, nil for a frame read with no event.
        case written
        /// The user's move or resize, or the app's.
        case other
    }

    public func change(of id: WindowID, changedAt: ContinuousClock.Instant?, landed: Bool) -> Change {
        if isWriting(id) { return .writing }
        return landed || changedAt.map { isWriting(id, at: $0) } == true ? .written : .other
    }

    public mutating func forget(_ id: WindowID) {
        confirmed[id] = nil
        pending[id] = nil
        landing[id] = nil
        refused[id] = nil
        refusedLarger[id] = nil
    }
}

extension FrameLedger {
    /// AppKit holds a window that grows onto another display to the old display's edge until
    /// its app takes the move, 10 to 30 ms after the position write. So after a write that
    /// moves a window there, the worker writes the size again every 2 ms while the window
    /// reads back smaller, for up to this long from when it starts, after the drain's other
    /// writes and any earlier window's own writes again (docs/geometry.md).
    public static let displayMoveBound: Duration = .milliseconds(50)

    public static func writesSizeAgain(_ readBack: CGRect, target: CGRect, after elapsed: Duration) -> Bool {
        readBack.isSmaller(than: target) && elapsed < displayMoveBound
    }
}
