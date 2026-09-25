import CoreGraphics

/// One window's slide, the trial behind `KOSMOS_ANIMATE=slide` (docs/geometry.md): the frame
/// the window shows at through its Space's transform, eased from `from` to `to`, and the
/// Space's alpha, eased from `fromAlpha` to 1. As Omarchy animates Hyprland's windows, a move
/// takes 0.38 s and a new window pops in from 87% of its size about its center and alpha 0
/// over 0.41 s, both along easeOutQuint.
public struct Slide: Equatable, Sendable {
    public static let moveDuration = 0.38
    public static let popDuration = 0.41
    public static let popScale: CGFloat = 0.87

    public let from: CGRect
    /// The window's target, then the frame WindowServer has once the write lands, which an
    /// app that rounds its size leaves a few points off the target.
    public var to: CGRect
    public let fromAlpha: Double
    /// Seconds, on the clock the caller passes to `shown` and `alpha`.
    public let start: Double
    public let duration: Double

    /// A window moving from where it shows, `shown` at `alpha`, to `target`.
    public static func move(from shown: CGRect, alpha: Double = 1, to target: CGRect, at now: Double) -> Slide {
        Slide(from: shown, to: target, fromAlpha: alpha, start: now, duration: moveDuration)
    }

    /// A new window popping in at `frame`.
    public static func pop(to frame: CGRect, at now: Double) -> Slide {
        Slide(from: frame.scaled(popScale), to: frame, fromAlpha: 0, start: now, duration: popDuration)
    }

    public func progress(at now: Double) -> Double {
        duration > 0 ? min(1, max(0, (now - start) / duration)) : 1
    }

    public func isOver(at now: Double) -> Bool { progress(at: now) >= 1 }

    /// Where the window shows at `now`.
    public func shown(at now: Double) -> CGRect {
        let s = Self.ease(progress(at: now))
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * s }
        return CGRect(x: mix(from.minX, to.minX), y: mix(from.minY, to.minY),
                      width: mix(from.width, to.width), height: mix(from.height, to.height))
    }

    public func alpha(at now: Double) -> Double {
        fromAlpha + (1 - fromAlpha) * Self.ease(progress(at: now))
    }

    /// A move to `target` from where this slide shows the window at `now`, at the alpha it has
    /// there: a relayout mid-slide continues from the shown frame, a pop included.
    public func retargeted(to target: CGRect, at now: Double) -> Slide {
        .move(from: shown(at: now), alpha: alpha(at: now), to: target, at: now)
    }

    /// The Space transform that shows a window whose frame is `actual` at `shown`, both with
    /// the origin at the top left of the main display and y down. The transform maps where a
    /// point shows to the window's point, in the window's own coordinates, origin at its top
    /// left and y down (kosmos_space_set_transform).
    public static func transform(showing shown: CGRect, at actual: CGRect) -> CGAffineTransform {
        let sx = actual.width / shown.width, sy = actual.height / shown.height
        return CGAffineTransform(a: sx, b: 0, c: 0, d: sy, tx: (actual.minX - shown.minX) * sx, ty: (actual.minY - shown.minY) * sy)
    }

    /// Omarchy's easeOutQuint, the timing curve cubic-bezier(0.23, 1, 0.32, 1): the curve's y
    /// where its x is `t`, found by bisection on the curve's parameter, along which x only
    /// grows.
    public static func ease(_ t: Double) -> Double {
        guard t > 0 else { return 0 }
        guard t < 1 else { return 1 }
        func bezier(_ p1: Double, _ p2: Double, _ u: Double) -> Double {
            3 * (1 - u) * (1 - u) * u * p1 + 3 * (1 - u) * u * u * p2 + u * u * u
        }
        var low = 0.0, high = 1.0
        for _ in 0..<40 {
            let mid = (low + high) / 2
            if bezier(0.23, 0.32, mid) < t { low = mid } else { high = mid }
        }
        return bezier(1, 1, (low + high) / 2)
    }
}

extension CGRect {
    /// The rectangle scaled by `factor` about its center.
    public func scaled(_ factor: CGFloat) -> CGRect {
        insetBy(dx: width * (1 - factor) / 2, dy: height * (1 - factor) / 2)
    }
}
