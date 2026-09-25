import CoreGraphics

/// The mouse buttons of a modifier drag: the left moves a window and the right resizes it, as
/// Omarchy binds Super with Hyprland's mouse:272 and mouse:273 (DESIGN.md, section 5.14).
public enum DragButton: Hashable, Sendable {
    case left
    case right
}

extension KeyCombo.Modifiers {
    /// The modifiers an event's flags hold. Caps Lock, Fn and the device bits are left out.
    public init(_ flags: CGEventFlags) {
        self = []
        if flags.contains(.maskCommand) { insert(.cmd) }
        if flags.contains(.maskControl) { insert(.ctrl) }
        if flags.contains(.maskAlternate) { insert(.alt) }
        if flags.contains(.maskShift) { insert(.shift) }
    }
}

/// Decides on the drag tap's thread which mouse button events Kosmos takes, so no event
/// waits on the main actor (DESIGN.md, section 5.14). A press with exactly the modifiers,
/// over a window the gate holds as WindowServer's hit test names it, begins a drag. Kosmos
/// takes that press, the drag's movements and the button's mouse up, whatever the modifiers
/// are by then, and a press of the other button during the drag with its own mouse up. Every
/// other event passes to the app under the pointer untouched.
public struct DragGate: Sendable {
    /// A drag, as its press began it.
    public struct Grab: Equatable, Sendable {
        /// Counts the drags, so the main actor can tell a late movement of an earlier one.
        public let number: Int
        public let button: DragButton
        public let window: WindowID
        /// Where the button went down.
        public let start: CGPoint
    }

    /// A drag that ended, and where the pointer was.
    public struct End: Equatable, Sendable {
        public let grab: Grab
        public let point: CGPoint
    }

    /// What the tap does with an event, and what it tells the main actor.
    public struct Outcome: Equatable, Sendable {
        /// Kosmos takes the event: the app under the pointer never gets it.
        public var take = false
        public var began: Grab?
        /// The drag's button came up, or went down again with no mouse up heard since, as
        /// while WindowServer had the tap off. That drag then ends where the pointer last
        /// moved.
        public var ended: End?
        /// The number of the drag whose movement the main actor is to take
        /// (`takeMovement`), when none was waiting.
        public var moved: Int?
        /// A press with the modifiers passed on, as over the Dock, for the log.
        public var passedOver: WindowID?
    }

    /// The modifiers a press must hold, exactly, or nil while modifier drags are off.
    public var modifiers: KeyCombo.Modifiers?
    /// The windows a press may take: the tiled and floating windows of the shown workspaces.
    public var windows: Set<WindowID> = []
    public private(set) var grab: Grab?
    /// Buttons whose press Kosmos took, until their mouse up.
    public private(set) var held: Set<DragButton> = []
    /// Where the pointer last moved during the drag.
    private var last: CGPoint?
    /// A movement waits for the main actor, which takes only the latest.
    private var waiting = false
    private var count = 0

    public init() {}

    public mutating func pressed(_ button: DragButton, over window: WindowID, flags: CGEventFlags,
                                 at point: CGPoint) -> Outcome {
        var outcome = Outcome()
        if held.remove(button) != nil, let grab, grab.button == button {
            outcome.ended = End(grab: grab, point: last ?? grab.start)
            self.grab = nil
        }
        if grab != nil {
            held.insert(button)
            outcome.take = true
            return outcome
        }
        guard let modifiers, KeyCombo.Modifiers(flags) == modifiers else { return outcome }
        guard windows.contains(window) else {
            outcome.passedOver = window
            return outcome
        }
        count += 1
        let grab = Grab(number: count, button: button, window: window, start: point)
        self.grab = grab
        held.insert(button)
        (last, waiting) = (point, false)
        outcome.take = true
        outcome.began = grab
        return outcome
    }

    public mutating func dragged(_ button: DragButton, to point: CGPoint) -> Outcome {
        guard held.contains(button) else { return Outcome() }
        var outcome = Outcome(take: true)
        if let grab {
            last = point
            if !waiting { outcome.moved = grab.number }
            waiting = true
        }
        return outcome
    }

    public mutating func released(_ button: DragButton, at point: CGPoint) -> Outcome {
        guard held.remove(button) != nil else { return Outcome() }
        var outcome = Outcome(take: true)
        if let grab, grab.button == button {
            outcome.ended = End(grab: grab, point: point)
            self.grab = nil
        }
        return outcome
    }

    /// Where the pointer last moved during drag `number`, once for each `moved` the gate
    /// gave. Nil once the drag has ended, as its end carries the point.
    public mutating func takeMovement(of number: Int) -> CGPoint? {
        guard waiting, grab?.number == number else { return nil }
        waiting = false
        return last
    }
}

/// A modifier drag as the main actor carries it out (DESIGN.md, section 5.14). Session's
/// `beginDrag` makes one.
public struct ModifierDrag: Equatable, Sendable {
    public let grab: DragGate.Grab
    /// The window's frame when the button went down, as WindowServer last reported it.
    public let frame: CGRect
    public let floating: Bool
    /// The edges a resize moves, at most one on each axis.
    public let edges: [Direction]
    /// A tiled window's tile when the button went down, where its edges start from.
    let tile: CGRect?
    private var started = false

    init(grab: DragGate.Grab, frame: CGRect, floating: Bool, edges: [Direction], tile: CGRect?) {
        (self.grab, self.frame, self.floating, self.edges, self.tile) = (grab, frame, floating, edges, tile)
    }

    /// How far the pointer at `point` is from where the button went down, in whole points,
    /// once it has gone more than `Session.liftDistance` away, and nil until then. A click
    /// that jitters changes nothing, and past the distance the window catches up with the
    /// pointer.
    public mutating func delta(to point: CGPoint) -> CGSize? {
        let delta = CGSize(width: (point.x - grab.start.x).rounded(), height: (point.y - grab.start.y).rounded())
        guard started || hypot(delta.width, delta.height) > Session.liftDistance else { return nil }
        started = true
        return delta
    }

    /// Where the window goes when the drag moves it `delta`.
    public func moved(by delta: CGSize) -> CGRect {
        frame.offsetBy(dx: delta.width, dy: delta.height)
    }
}
