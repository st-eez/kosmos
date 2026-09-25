import CoreGraphics

/// One window's slide (docs/geometry.md): the frame the window shows at through its Space's
/// transform, eased from `from` to `to`, and the Space's alpha, eased from `fromAlpha` to 1.
/// As Omarchy animates Hyprland's windows, a move takes 0.38 s and a new window pops in from
/// 87% of its size about its center and alpha 0 over 0.41 s, both along easeOutQuint.
public struct Slide: Equatable, Sendable {
    public static let moveDuration = 0.38
    public static let popDuration = 0.41
    public static let popScale: CGFloat = 0.87

    public let from: CGRect
    public let to: CGRect
    public let fromAlpha: Double
    /// Seconds, on the clock the caller passes to `shown`.
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

    public func isOver(at now: Double) -> Bool { now >= start + duration }

    /// Where the window shows at `now`, and its Space's alpha, from one easing.
    public func shown(at now: Double) -> (frame: CGRect, alpha: Double) {
        let s = Self.ease(duration > 0 ? (now - start) / duration : 1)
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * s }
        return (CGRect(x: mix(from.minX, to.minX), y: mix(from.minY, to.minY),
                       width: mix(from.width, to.width), height: mix(from.height, to.height)),
                fromAlpha + (1 - fromAlpha) * s)
    }

    /// A move to `target` from where this slide shows the window at `now`, at the alpha it has
    /// there: a relayout mid-slide continues from the shown frame, a pop included.
    public func retargeted(to target: CGRect, at now: Double) -> Slide {
        let (frame, alpha) = shown(at: now)
        return .move(from: frame, alpha: alpha, to: target, at: now)
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

/// A window from the write that starts its slide to the slide's end (docs/geometry.md): its
/// Space, the display whose link steps it, where it shows and where WindowServer has it, and
/// the newest write, which reads follow until it lands. A write lands once WindowServer has
/// the frame the worker read back after it.
public struct SlidingWindow: Sendable {
    /// How long a new window waits, transparent, for its write to land before it pops in at
    /// its target.
    public static let popWait = 0.25
    /// How long reads follow a write, and how long a slide that is over holds its window at
    /// its end while the write has not landed: the Accessibility timeout.
    public static let landingWait = 1.0

    public let space: SpaceID
    public let display: DisplayID
    public let pop: Bool
    /// The newest write's target, and the frame the worker read back after it.
    public private(set) var target: CGRect
    public private(set) var readBack: CGRect?
    /// Where the window shows through its Space's transform, and the Space's alpha.
    public private(set) var shown: CGRect
    public private(set) var alpha: Double
    /// The window's frame as WindowServer last had it.
    public private(set) var actual: CGRect
    /// Nil while a pop waits for its write to land.
    public private(set) var slide: Slide?
    /// When the newest write was queued and when it landed, on the display link's clock.
    public private(set) var sent: Double
    public private(set) var landed: Double?
    /// When the newest write was queued or read back, or the window's frame last changed.
    public private(set) var changedAt: Double
    /// The display frames the slide moved the window in, for the log.
    public private(set) var frames = 0

    /// A window at `from` whose write to `target` is queued at `now`. A move shows it at
    /// `from`; a pop shows nothing until its write lands.
    public init(space: SpaceID, display: DisplayID, from: CGRect, to target: CGRect, pop: Bool, at now: Double) {
        self.space = space
        self.display = display
        self.pop = pop
        self.target = target
        shown = pop ? target.scaled(Slide.popScale) : from
        alpha = pop ? 0 : 1
        actual = from
        slide = pop ? nil : .move(from: from, to: target, at: now)
        sent = now
        changedAt = now
    }

    /// Takes a newer write, queued at `now`. One that slides goes on from where the window
    /// shows. One to the same target that does not slide, as the retry after a refused size,
    /// is followed too. False for a write to another target that does not slide, which ends
    /// the slide at once.
    public mutating func wrote(_ target: CGRect, sliding: Bool, at now: Double) -> Bool {
        guard sliding || target == self.target else { return false }
        if target != self.target { slide = slide?.retargeted(to: target, at: now) }
        (self.target, readBack, landed, sent, changedAt) = (target, nil, nil, now, now)
        return true
    }

    /// The worker read `readBack` after writing `target`. A read back of an older write is
    /// left out. A slide to another frame goes on to this one, as for an app that rounds its
    /// size or refuses the move, and a window WindowServer has there already has landed.
    public mutating func confirmed(target: CGRect, readBack: CGRect, at now: Double) {
        guard target == self.target, landed == nil else { return }
        self.readBack = readBack
        changedAt = now
        if let slide, slide.to != readBack { self.slide = slide.retargeted(to: readBack, at: now) }
        if actual == readBack { landed = now }
    }

    /// Whether reads still follow the newest write: it has not landed, and was queued within
    /// `landingWait`.
    public func isAwaiting(at now: Double) -> Bool { landed == nil && now < sent + Self.landingWait }

    /// Whether WindowServer having the window at `frame` is the newest write's doing: `frame`
    /// is the write's target or the frame the worker read back after it.
    public func isWrite(_ frame: CGRect) -> Bool { frame == target || frame == readBack }

    /// A read found the window at `frame` at `now`. True when the frame is new, and the
    /// Space's transform must show the window where it shows from there.
    public mutating func observed(_ frame: CGRect, at now: Double) -> Bool {
        if frame == readBack, landed == nil { landed = now }
        guard frame != actual else { return false }
        (actual, changedAt) = (frame, now)
        return true
    }

    /// Steps the window to the display frame shown at `now`. A waiting pop starts once its
    /// write lands, or after `popWait` at its target. A slide that is over holds the window at
    /// its end until the write lands, for `landingWait` at most. True once the slide is done.
    public mutating func step(at now: Double) -> Bool {
        if slide == nil {
            guard landed != nil || now >= sent + Self.popWait else { return false }
            slide = .pop(to: readBack ?? target, at: now)
        }
        let slide = slide!
        if slide.isOver(at: now) {
            if landed != nil || now >= sent + Self.landingWait { return true }
            (shown, alpha) = (slide.to, 1)
            return false
        }
        (shown, alpha) = slide.shown(at: now)
        frames += 1
        return false
    }
}

extension CGRect {
    /// The rectangle scaled by `factor` about its center.
    public func scaled(_ factor: CGFloat) -> CGRect {
        insetBy(dx: width * (1 - factor) / 2, dy: height * (1 - factor) / 2)
    }
}
