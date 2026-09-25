import CoreGraphics

/// One frame write for one window.
public enum FrameWrite: Equatable, Sendable {
    /// Only the origin changes.
    case position(CGPoint)
    /// The size changes: write size, then position, then size again, because an app may
    /// clamp the size against the old position.
    case frame(CGRect)

    /// This write in place of `queued`, a write for the same window that has not run. The
    /// ledger chose a position write assuming the size of the write before it had landed, so
    /// after a frame write that has not run it writes its whole target instead.
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
    /// Larger again when the target was written again: the size kept on each axis it
    /// refused, zero on the other, which is the window's minimum.
    case minimum(CGSize)
}

/// Decides which windows need a frame write (docs/geometry.md). It remembers the frame
/// last read back from each window, the target sent and not yet confirmed, and sizes an app
/// refused.
public struct FrameLedger: Sendable {
    /// How much larger than its target a window may read back on an axis and still count as
    /// having taken it, so apps that round their size do not read as refusing it.
    public static let slack: CGFloat = 2

    private var confirmed: [UInt32: CGRect] = [:]
    private var pending: [UInt32: CGRect] = [:]
    /// When each window's last write was confirmed. It outlasts `forget`, as a change that
    /// came before the confirm is still that write's.
    private var confirmedAt: [UInt32: ContinuousClock.Instant] = [:]
    /// A target whose size the app refused, and the size it kept instead.
    private var refused: [UInt32: (target: CGRect, kept: CGSize)] = [:]
    /// A target the window read back larger than, past the slack, until the target changes.
    private var refusedLarger: [UInt32: CGRect] = [:]

    public init() {}

    /// The writes that bring each window to its target. A window already at its target, or
    /// already sent it, gets none. A window that refused this target's size gets its
    /// position only, until the target changes.
    public mutating func writes(for targets: [UInt32: CGRect]) -> [UInt32: FrameWrite] {
        var writes: [UInt32: FrameWrite] = [:]
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

    /// Records the frame read back after a write, confirmed `now`. A size other than the
    /// target's is a refusal, remembered until the target changes. The first time a window
    /// reads back larger than a target past the slack, the refusal is not remembered, so the
    /// next write of the target is whole: an app can ignore a size written as its window
    /// changes display or Space. Only a second such read back shows a minimum.
    @discardableResult
    public mutating func confirm(_ id: UInt32, target: CGRect, readBack: CGRect, at now: ContinuousClock.Instant) -> Fit {
        confirmed[id] = readBack
        confirmedAt[id] = now
        if pending[id] == target || pending[id] == CGRect(origin: target.origin, size: readBack.size) {
            pending[id] = nil
        }
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

    /// Records a frame observed without a write of Kosmos's, such as a user resize. A size
    /// other than the one the window kept when it refused its target ends that refusal, so
    /// the target's size is written again, and a larger read back is a first refusal.
    public mutating func observe(_ id: UInt32, frame: CGRect) {
        confirmed[id] = frame
        if let refusal = refused[id], refusal.kept != frame.size {
            refused[id] = nil
            refusedLarger[id] = nil
        }
    }

    /// Forgets the target the window read back larger than, so its next larger read back is
    /// a first refusal. A window concealed or on a hidden workspace can ignore a size on its
    /// way to the holding Space or another display, so a refusal read back then, or before
    /// its workspace was last shown, says nothing of the app's limit.
    public mutating func forgetLargerReadBack(_ id: UInt32) {
        refusedLarger[id] = nil
    }

    /// Records a frame read for a change that came before the last confirm, the write's own
    /// change, when it differs from the frame confirmed. The change applies after the
    /// confirm, and its row can hold a later change, as the app's next live resize step,
    /// whose own event then finds the frame the same.
    public mutating func observeAfterConfirm(_ id: UInt32, frame: CGRect) {
        if confirmed[id] != frame { observe(id, frame: frame) }
    }

    /// Whether a target sent for the window is not confirmed yet: a change of its frame now
    /// can be that write's.
    public func isWriting(_ id: UInt32) -> Bool { pending[id] != nil }

    /// Whether a change of the window's frame that came at `stamp` can be a write's: a target
    /// is not confirmed yet, or the change came before the last confirm. The inventory
    /// applies a change after an off main read, by which time the write can be confirmed.
    ///
    /// Ceiling: a change that came before a write was sent counts too. Recording when each
    /// write was sent would tell the two apart.
    public func isWriting(_ id: UInt32, at stamp: ContinuousClock.Instant) -> Bool {
        isWriting(id) || confirmedAt[id].map { stamp < $0 } == true
    }

    /// Forgets the window's frames and refusals, so its next write is whole and a larger read
    /// back is a first refusal again.
    public mutating func forget(_ id: UInt32) {
        confirmed[id] = nil
        pending[id] = nil
        refused[id] = nil
        refusedLarger[id] = nil
    }
}
