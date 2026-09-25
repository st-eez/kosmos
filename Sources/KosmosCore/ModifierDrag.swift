import CoreGraphics

/// The left button moves a window and the right resizes it (docs/modifier-drags.md).
public enum DragButton: Hashable, Sendable {
    case left
    case right
}

extension KeyCombo.Modifiers {
    public init(_ flags: CGEventFlags) {
        self = []
        if flags.contains(.maskCommand) { insert(.cmd) }
        if flags.contains(.maskControl) { insert(.ctrl) }
        if flags.contains(.maskAlternate) { insert(.alt) }
        if flags.contains(.maskShift) { insert(.shift) }
    }
}

/// Decides on the drag tap's thread which mouse button events Kosmos takes, so no event
/// waits on the main actor (docs/modifier-drags.md).
public struct DragGate: Sendable {
    public struct Grab: Equatable, Sendable {
        public let button: DragButton
        public let window: WindowID
        /// Where the button went down.
        public let start: CGPoint
    }

    public struct End: Equatable, Sendable {
        public let grab: Grab
        public let point: CGPoint
    }

    /// What the tap does with an event, and what it tells the main actor.
    public struct Outcome: Equatable, Sendable {
        /// The app under the pointer never gets the event.
        public var take = false
        public var began: Grab?
        public var ended: End?
        public var moved: CGPoint?
        /// A press with the modifiers passed on over this window, as over the Dock, for the log.
        public var passedOver: WindowID?
    }

    /// A mouse button as HID reads it now.
    public struct ButtonState: Equatable, Sendable {
        public var down: Bool
        public var presses: UInt32

        public init(down: Bool, presses: UInt32) {
            (self.down, self.presses) = (down, presses)
        }
    }

    /// The modifiers a press must hold, exactly, or nil while modifier drags are off.
    public var modifiers: KeyCombo.Modifiers?
    /// The tiled and floating windows of the shown workspaces.
    public var windows: Set<WindowID> = []
    public var monitors: [Monitor] = []
    public private(set) var grab: Grab?
    /// The mouse event number of the drag's press, which its mouse up carries too.
    private var pressNumber: Int64 = 0
    /// HID's count of the drag button's presses as the tap saw the drag's press.
    private var pressesAtGrab: UInt32 = 0
    /// The press number of each button's drag `endIfReleased` ended. HID reads ahead of the
    /// tap, so that press's mouse up can still come.
    private var unheard: [DragButton: Int64] = [:]
    private var lastMoved = CGPoint.zero
    private var pressWasLast = false

    public init() {}

    public mutating func pressed(_ button: DragButton, number: Int64, over window: WindowID, flags: CGEventFlags,
                                 at point: CGPoint, hid: (DragButton) -> ButtonState) -> Outcome {
        pressWasLast = false
        // The focus path's key record is a left down off every display (docs/modifier-drags.md).
        guard monitors.contains(where: { $0.frame.contains(point) }) else { return Outcome() }
        unheard[button] = nil
        var outcome = Outcome()
        if let grab, grab.button == button {
            // Its mouse up went unheard, as while WindowServer had the tap off.
            outcome.ended = End(grab: grab, point: lastMoved)
            self.grab = nil
        } else if grab != nil {
            outcome = endIfReleased(hid: hid, at: point)
            guard grab == nil else { return outcome }
        }
        guard let modifiers, KeyCombo.Modifiers(flags) == modifiers else { return outcome }
        guard windows.contains(window) else {
            outcome.passedOver = window
            return outcome
        }
        let grab = Grab(button: button, window: window, start: point)
        (self.grab, pressNumber, pressesAtGrab, lastMoved, pressWasLast) = (grab, number, hid(button).presses, point, true)
        outcome.take = true
        outcome.began = grab
        return outcome
    }

    /// A nil `point` ends the drag where the pointer last moved. Ceiling: a press HID counted
    /// before the tap saw the drag's own counts as the drag's (docs/modifier-drags.md).
    public mutating func endIfReleased(hid: (DragButton) -> ButtonState, at point: CGPoint?) -> Outcome {
        guard let grab else { return Outcome() }
        let state = hid(grab.button)
        guard !state.down || state.presses != pressesAtGrab else { return Outcome() }
        self.grab = nil
        unheard[grab.button] = pressNumber
        return Outcome(ended: End(grab: grab, point: point ?? lastMoved))
    }

    /// With both buttons down, macOS can name the one the drag does not hold.
    public mutating func dragged(to point: CGPoint) -> Outcome {
        pressWasLast = false
        guard grab != nil else { return Outcome() }
        lastMoved = point
        return Outcome(take: true, moved: point)
    }

    /// Kosmos takes only the mouse up of a press it took, so the app gets the mouse up of
    /// every press it got.
    public mutating func released(_ button: DragButton, number: Int64, at point: CGPoint) -> Outcome {
        pressWasLast = false
        if unheard.removeValue(forKey: button) == number { return Outcome(take: true) }
        guard let grab, grab.button == button else { return Outcome() }
        self.grab = nil
        // Another number is the mouse up of a press that passed while the tap was off, and the
        // app has that press.
        return Outcome(take: number == pressNumber, ended: End(grab: grab, point: point))
    }

    /// WindowServer turned the tap off and passed on the event it waited for. When that was
    /// the drag's press, the app has it, so the drag ends and the rest of the press passes.
    public mutating func timedOut() -> Outcome {
        guard pressWasLast, let grab else { return Outcome() }
        self.grab = nil
        pressWasLast = false
        return Outcome(ended: End(grab: grab, point: grab.start))
    }
}

/// A modifier drag as the main actor carries it out (docs/modifier-drags.md).
public struct ModifierDrag: Equatable, Sendable {
    public let grab: DragGate.Grab
    /// The window's frame when the button went down, as WindowServer last reported it.
    public let frame: CGRect
    /// The edges a resize moves, at most one on each axis.
    public let edges: [Direction]
    /// A tiled window's tile when the button went down.
    let tile: CGRect?
    private var started = false

    public var floating: Bool { tile == nil }

    init(grab: DragGate.Grab, frame: CGRect, edges: [Direction], tile: CGRect?) {
        (self.grab, self.frame, self.edges, self.tile) = (grab, frame, edges, tile)
    }

    public mutating func delta(to point: CGPoint) -> CGSize? {
        let delta = CGSize(width: (point.x - grab.start.x).rounded(), height: (point.y - grab.start.y).rounded())
        guard started || hypot(delta.width, delta.height) > TitleBarDrag.liftDistance else { return nil }
        started = true
        return delta
    }

    public func moved(by delta: CGSize) -> CGRect {
        frame.offsetBy(dx: delta.width, dy: delta.height)
    }
}
