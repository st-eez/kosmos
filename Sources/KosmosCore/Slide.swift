import CoreGraphics

/// The frame a window shows at through its Space's transform, and the Space's alpha
/// (docs/geometry.md).
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

    public static func move(from shown: CGRect, alpha: Double = 1, to target: CGRect, at now: Double) -> Slide {
        Slide(from: shown, to: target, fromAlpha: alpha, start: now, duration: moveDuration)
    }

    public static func pop(to frame: CGRect, at now: Double) -> Slide {
        Slide(from: frame.scaled(popScale), to: frame, fromAlpha: 0, start: now, duration: popDuration)
    }

    public func isOver(at now: Double) -> Bool { now >= start + duration }

    public func shown(at now: Double) -> (frame: CGRect, alpha: Double) {
        let s = Self.ease(duration > 0 ? (now - start) / duration : 1)
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * s }
        return (CGRect(x: mix(from.minX, to.minX), y: mix(from.minY, to.minY),
                       width: mix(from.width, to.width), height: mix(from.height, to.height)),
                fromAlpha + (1 - fromAlpha) * s)
    }

    public func retargeted(to target: CGRect, at now: Double) -> Slide {
        let (frame, alpha) = shown(at: now)
        return .move(from: frame, alpha: alpha, to: target, at: now)
    }

    /// Maps where a point shows to the window's point, in the window's own coordinates with
    /// the origin at its top left and y down, as kosmos_space_set_transform takes it.
    public static func transform(showing shown: CGRect, at actual: CGRect) -> CGAffineTransform {
        let sx = actual.width / shown.width, sy = actual.height / shown.height
        return CGAffineTransform(a: sx, b: 0, c: 0, d: sy, tx: (actual.minX - shown.minX) * sx, ty: (actual.minY - shown.minY) * sy)
    }

    /// cubic-bezier(0.23, 1, 0.32, 1): the curve's y where its x is `t`.
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

/// A window from the write that starts its slide to the slide's end (docs/geometry.md). A
/// write lands once WindowServer has the frame the worker read back after it.
public struct SlidingWindow: Sendable {
    /// A new window waits this long, transparent, for its write to land before it pops in.
    public static let popWait = 0.25
    /// The Accessibility timeout: reads follow a write this long, and a slide that is over
    /// holds its window at its end this long for the write to land.
    public static let landingWait = 1.0

    public let space: SpaceID
    public let display: DisplayID
    public let pop: Bool
    public private(set) var target: CGRect
    public private(set) var readBack: CGRect?
    /// Where the window shows through its Space's transform.
    public private(set) var shown: CGRect
    public private(set) var alpha: Double
    /// The window's frame as WindowServer last had it.
    public private(set) var actual: CGRect
    /// Nil while a pop waits for its write to land.
    public private(set) var slide: Slide?
    /// When the newest write was queued and when it landed, on the display link's clock.
    public private(set) var sent: Double
    public private(set) var landed: Double?
    public private(set) var changedAt: Double
    /// Display frames stepped, for the log.
    public private(set) var frames = 0

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

    /// False for a write to another target that does not slide, which ends the slide. One to
    /// the same target that does not slide, as the retry after a refused size, is followed.
    public mutating func wrote(_ target: CGRect, sliding: Bool, at now: Double) -> Bool {
        guard sliding || target == self.target else { return false }
        if target != self.target { slide = slide?.retargeted(to: target, at: now) }
        (self.target, readBack, landed, sent, changedAt) = (target, nil, nil, now, now)
        return true
    }

    public mutating func confirmed(target: CGRect, readBack: CGRect, at now: Double) {
        guard target == self.target, landed == nil else { return }
        self.readBack = readBack
        changedAt = now
        if let slide, slide.to != readBack { self.slide = slide.retargeted(to: readBack, at: now) }
        if actual == readBack { landed = now }
    }

    public func isAwaiting(at now: Double) -> Bool { landed == nil && now < sent + Self.landingWait }

    public func isWrite(_ frame: CGRect) -> Bool { frame == target || frame == readBack }

    /// True when the frame is new, so the Space's transform must change.
    public mutating func observed(_ frame: CGRect, at now: Double) -> Bool {
        if frame == readBack, landed == nil { landed = now }
        guard frame != actual else { return false }
        (actual, changedAt) = (frame, now)
        return true
    }

    /// True once the slide is done.
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
