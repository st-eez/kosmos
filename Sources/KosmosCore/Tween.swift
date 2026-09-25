import CoreGraphics

/// One window's animated frame write, a trial behind `KOSMOS_ANIMATE=1`. As in rift's
/// `animation.rs`, the steps between move the window only: its size is written once at the
/// midpoint and again by the final write, since each size write makes the app lay itself
/// out. Progress follows the clock, not a step count, so a slow app skips steps and still
/// ends on time.
public struct Tween: Equatable, Sendable {
    public let from: CGRect
    public let to: CGRect
    /// Seconds, on the clock the caller passes to `step` and `frame`.
    public let start: Double
    public let duration: Double
    /// Whether the midpoint size write has run.
    public private(set) var sized = false
    /// Steps written so far, for the log.
    public private(set) var steps = 0

    public init(from: CGRect, to: CGRect, start: Double, duration: Double) {
        self.from = from
        self.to = to
        self.start = start
        self.duration = duration
    }

    public enum Step: Equatable, Sendable {
        case position(CGPoint)
        /// The midpoint: size, then position, then size, as `FrameWrite.frame`.
        case frame(CGRect)
        /// The tween is over; the caller writes the target as an ordinary write.
        case finish
    }

    public var resizes: Bool { from.size != to.size }

    public func progress(at now: Double) -> Double {
        duration > 0 ? min(1, max(0, (now - start) / duration)) : 1
    }

    /// Where the window is at `now`: the eased origin, with the start's size before the
    /// midpoint write and the target's after it.
    public func frame(at now: Double) -> CGRect {
        let s = Self.ease(progress(at: now))
        let size = sized ? to.size : from.size
        return CGRect(x: from.minX + (to.minX - from.minX) * s,
                      y: from.minY + (to.minY - from.minY) * s,
                      width: size.width, height: size.height)
    }

    /// The write due at `now`.
    public mutating func step(at now: Double) -> Step {
        let t = progress(at: now)
        if t >= 1 { return .finish }
        steps += 1
        if resizes, !sized, t >= 0.5 {
            sized = true
            return .frame(frame(at: now))
        }
        return .position(frame(at: now).origin)
    }

    /// A tween to `target` from where this one has the window at `now`, for a layout that
    /// changes during the animation. The window goes on from there instead of jumping.
    public func retargeted(to target: CGRect, at now: Double) -> Tween {
        Tween(from: frame(at: now), to: target, start: now, duration: duration)
    }

    /// Circular ease in and out, rift's curve.
    public static func ease(_ t: Double) -> Double {
        t < 0.5 ? (1 - (1 - (2 * t) * (2 * t)).squareRoot()) / 2
                : ((1 - (-2 * t + 2) * (-2 * t + 2)).squareRoot() + 1) / 2
    }
}
