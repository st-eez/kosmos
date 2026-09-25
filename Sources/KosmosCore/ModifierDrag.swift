import CoreGraphics

/// The mouse buttons of a modifier drag: the left moves a window and the right resizes it, as
/// Omarchy binds Super with Hyprland's mouse:272 and mouse:273 (docs/modifier-drags.md).
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
/// waits on the main actor (docs/modifier-drags.md). A press with exactly the modifiers, on
/// a display and over a window the gate holds as WindowServer's hit test names it, begins a
/// drag. Kosmos takes that press, every movement until its mouse up and that mouse up,
/// whatever the modifiers are by then. Every other event passes to the app under the
/// pointer untouched, a press of the other button during the drag too.
public struct DragGate: Sendable {
    /// A drag, as its press began it.
    public struct Grab: Equatable, Sendable {
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
        public var ended: End?
        /// Where the pointer moved during the drag.
        public var moved: CGPoint?
        /// A press with the modifiers passed on for its window, as over the Dock, for the log.
        public var passedOver: WindowID?
    }

    /// A mouse button as HID reads it now.
    public struct ButtonState: Equatable, Sendable {
        public var down: Bool
        /// The presses of the button HID has counted.
        public var presses: UInt32

        public init(down: Bool, presses: UInt32) {
            (self.down, self.presses) = (down, presses)
        }
    }

    /// The modifiers a press must hold, exactly, or nil while modifier drags are off.
    public var modifiers: KeyCombo.Modifiers?
    /// The windows a press may take: the tiled and floating windows of the shown workspaces.
    public var windows: Set<WindowID> = []
    /// The displays, from the session. A press off every display passes and changes nothing,
    /// as the focus path's key record is one (Controller.leftMouseDown).
    public var monitors: [Monitor] = []
    public private(set) var grab: Grab?
    /// The mouse event number of the drag's press, which its mouse up carries too.
    private var number: Int64 = 0
    /// The presses of the drag's button HID had counted when the tap saw the drag's press.
    private var presses: UInt32 = 0
    /// The press number of each button's drag `endIfReleased` ended. HID reads ahead of the
    /// tap, so the press's mouse up can still come, and the tap takes it before the button's
    /// next press.
    private var unheard: [DragButton: Int64] = [:]
    /// Where the pointer last moved during the drag.
    private var last = CGPoint.zero
    /// The drag's press is the last event the gate decided (`timedOut`).
    private var pressWasLast = false

    public init() {}

    /// A press of `button`, with mouse event number `number`, over `window`. `hid` reads a
    /// button as HID has it now.
    public mutating func pressed(_ button: DragButton, number: Int64, over window: WindowID, flags: CGEventFlags,
                                 at point: CGPoint, hid: (DragButton) -> ButtonState) -> Outcome {
        pressWasLast = false
        // The focus path's key record, a left down off every display with no mouse up, passes
        // and changes nothing, during a drag too.
        guard monitors.contains(where: { $0.frame.contains(point) }) else { return Outcome() }
        unheard[button] = nil
        var outcome = Outcome()
        if let grab, grab.button == button {
            // The drag's button went down again, so its mouse up went unheard, as while
            // WindowServer had the tap off. The drag ends where the pointer last moved, and
            // this press is decided afresh.
            outcome.ended = End(grab: grab, point: last)
            self.grab = nil
        } else if grab != nil {
            // The other button's press passes while the drag's own press goes on, and is
            // decided afresh once that press is over.
            outcome = endIfReleased(hid: hid, at: point)
            guard grab == nil else { return outcome }
        }
        guard let modifiers, KeyCombo.Modifiers(flags) == modifiers else { return outcome }
        guard windows.contains(window) else {
            outcome.passedOver = window
            return outcome
        }
        let grab = Grab(button: button, window: window, start: point)
        (self.grab, self.number, presses, last, pressWasLast) = (grab, number, hid(button).presses, point, true)
        outcome.take = true
        outcome.began = grab
        return outcome
    }

    /// Ends the drag if its press is over by now, as when its mouse up passed while
    /// WindowServer had the tap off: `hid` reads its button up, or with a newer press
    /// counted. The drag ends at `point`, or where the pointer last moved when nil, and its
    /// mouse up, if the tap has yet to see it, is taken (`unheard`).
    ///
    /// Ceiling: a press HID counted before the tap saw the drag's own counts as the drag's.
    /// The tap sees it next, as a press of the drag's button, unless WindowServer turns the
    /// tap off first; then the drag takes that press's movements, and its mouse up passes
    /// and ends the drag (`released`). Nothing public tells which press HID counted when.
    public mutating func endIfReleased(hid: (DragButton) -> ButtonState, at point: CGPoint?) -> Outcome {
        guard let grab else { return Outcome() }
        let state = hid(grab.button)
        guard !state.down || state.presses != presses else { return Outcome() }
        self.grab = nil
        unheard[grab.button] = number
        return Outcome(ended: End(grab: grab, point: point ?? last))
    }

    /// A movement with a button down, whichever button macOS names: with both down it can
    /// name the one the drag does not hold.
    public mutating func dragged(to point: CGPoint) -> Outcome {
        pressWasLast = false
        guard grab != nil else { return Outcome() }
        last = point
        return Outcome(take: true, moved: point)
    }

    /// A mouse up of `button` with mouse event number `number`, which its press carries too.
    /// Kosmos takes only the mouse up of a press it took, so the app gets the mouse up of
    /// every press it got.
    public mutating func released(_ button: DragButton, number: Int64, at point: CGPoint) -> Outcome {
        pressWasLast = false
        if unheard.removeValue(forKey: button) == number { return Outcome(take: true) }
        guard let grab, grab.button == button else { return Outcome() }
        self.grab = nil
        // With another number, it is the mouse up of a press that passed while WindowServer
        // had the tap off, after the drag's own mouse up: it ends the drag, and the app that
        // has the press gets it.
        return Outcome(take: number == self.number, ended: End(grab: grab, point: point))
    }

    /// WindowServer turned the tap off after waiting too long on an event, and passed that
    /// event on. When it was the drag's press, the last event the gate decided, the app has
    /// the press: the drag ends where it began, and the rest of the press passes, so the app
    /// gets its mouse up. After any other event the drag goes on.
    public mutating func timedOut() -> Outcome {
        guard pressWasLast, let grab else { return Outcome() }
        self.grab = nil
        pressWasLast = false
        return Outcome(ended: End(grab: grab, point: grab.start))
    }
}

/// A modifier drag as the main actor carries it out (docs/modifier-drags.md). Session's
/// `beginDrag` makes one.
public struct ModifierDrag: Equatable, Sendable {
    public let grab: DragGate.Grab
    /// The window's frame when the button went down, as WindowServer last reported it.
    public let frame: CGRect
    /// The edges a resize moves, at most one on each axis.
    public let edges: [Direction]
    /// A tiled window's tile when the button went down, where its edges start from, and nil
    /// for a floating window.
    let tile: CGRect?
    private var started = false

    public var floating: Bool { tile == nil }

    init(grab: DragGate.Grab, frame: CGRect, edges: [Direction], tile: CGRect?) {
        (self.grab, self.frame, self.edges, self.tile) = (grab, frame, edges, tile)
    }

    /// How far the pointer at `point` is from where the button went down, in whole points,
    /// once it has gone more than `TitleBarDrag.liftDistance` away, and nil until then. A click
    /// that jitters changes nothing, and past the distance the window catches up with the
    /// pointer.
    public mutating func delta(to point: CGPoint) -> CGSize? {
        let delta = CGSize(width: (point.x - grab.start.x).rounded(), height: (point.y - grab.start.y).rounded())
        guard started || hypot(delta.width, delta.height) > TitleBarDrag.liftDistance else { return nil }
        started = true
        return delta
    }

    /// Where the window goes when the drag moves it `delta`.
    public func moved(by delta: CGSize) -> CGRect {
        frame.offsetBy(dx: delta.width, dy: delta.height)
    }
}
