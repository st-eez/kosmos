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

    /// The Accessibility timeout. A write that has not landed by then counts as landed, so a
    /// reveal waits no longer (docs/hiding.md).
    public static let landingWait: Duration = .seconds(1)

    public init() {}

    public mutating func writes(for targets: [WindowID: CGRect]) -> [WindowID: FrameWrite] {
        var writes: [WindowID: FrameWrite] = [:]
        for (id, target) in targets {
            let current = pending[id] ?? confirmed[id]
            if current == target { continue }
            if let refusal = refused[id], refusal.target == target {
                let placed = CGRect(origin: target.origin, size: refusal.kept)
                if confirmed[id] != placed, pending[id] != placed {
                    writes[id] = .position(target.origin)
                    pending[id] = placed
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

    /// Whether the newest write sent is yet to show in a row, within `landingWait`.
    public func isLanding(_ id: WindowID, at now: ContinuousClock.Instant) -> Bool {
        landing[id].map { now < $0.sent + Self.landingWait } ?? false
    }

    /// Whether a change that came at `stamp` can be a write's. Ceiling: a change that came
    /// before the write was sent counts too (docs/geometry.md).
    public func isWriting(_ id: WindowID, at stamp: ContinuousClock.Instant) -> Bool {
        isWriting(id) || confirmedAt[id].map { stamp < $0 } == true
    }

    public mutating func forget(_ id: WindowID) {
        confirmed[id] = nil
        pending[id] = nil
        landing[id] = nil
        refused[id] = nil
        refusedLarger[id] = nil
    }
}
