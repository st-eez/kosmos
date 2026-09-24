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

/// Decides which windows need a frame write (DESIGN.md, section 5.2). It remembers the frame
/// last read back from each window, the target sent and not yet confirmed, and sizes an app
/// refused.
public struct FrameLedger: Sendable {
    private var confirmed: [UInt32: CGRect] = [:]
    private var pending: [UInt32: CGRect] = [:]
    /// A target whose size the app refused, and the size it kept instead.
    private var refused: [UInt32: (target: CGRect, kept: CGSize)] = [:]

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

    /// Records the frame read back after a write. A size other than the target's is a
    /// refusal, remembered until the target changes.
    public mutating func confirm(_ id: UInt32, target: CGRect, readBack: CGRect) {
        confirmed[id] = readBack
        if pending[id] == target || pending[id] == CGRect(origin: target.origin, size: readBack.size) {
            pending[id] = nil
        }
        if readBack.size != target.size, refused[id]?.target != target {
            refused[id] = (target, readBack.size)
        }
    }

    /// Records a frame observed without a write of Kosmos's, such as a user resize.
    public mutating func observe(_ id: UInt32, frame: CGRect) {
        confirmed[id] = frame
    }

    public mutating func forget(_ id: UInt32) {
        confirmed[id] = nil
        pending[id] = nil
        refused[id] = nil
    }
}
