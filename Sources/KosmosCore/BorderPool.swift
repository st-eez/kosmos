import CoreGraphics

/// Which border window draws each target's ring, which wait ready for its slide on the other
/// displays it crosses, which the slide places the rings in, and each display's spare ones;
/// KosmosApp's `Borders` makes the AppKit calls each step names (docs/borders.md).
public struct BorderPool<Window: Equatable> {
    public enum Step: Equatable {
        /// Ordered out, into its display's pool.
        case putBack(Window)
        /// The ring left it. It stays ordered in below its target, drawing nothing.
        case clear(Window)
        /// Ordered in below the target to wait for the ring, showing nothing, and moved to the
        /// target's Space.
        case ready(Window, target: WindowID, ShownBorder)
        /// Ordered in below the target and moved to its Space.
        case orderIn(Window, target: WindowID, ShownBorder)
        /// Already ordered in below the target. `pin`: moved to the target's Space too, as a
        /// window taken from `ready` was pinned before the target reached its display.
        case show(Window, target: WindowID, ShownBorder, pin: Bool)
        /// On a display that may show a native fullscreen Space, ordered in only once its Space
        /// move is sent (`moved`).
        case wait(Window, target: WindowID)
        /// The sliding targets' windows ordered in, the ready ones and then the ring's, whose
        /// rings the slide's display frames place, in place of those given before. The held
        /// targets move from the first one on.
        case hand([WindowID: [Window]])
    }

    /// Each window keeps to one display, as one moved to another display's Space before its new
    /// frame landed showed there at its old frame (docs/borders.md).
    private var rings: [WindowID: (window: Window, display: DisplayID)] = [:]
    private var ready: [WindowID: [DisplayID: Window]] = [:]
    private var spare: [DisplayID: [Window]] = [:]
    /// Rings on a display that may show a native fullscreen Space, ordered out until their
    /// Space move is sent, with what to show then.
    private var waiting: [WindowID: ShownBorder] = [:]
    /// What the last `.hand` gave the slide, and the targets sliding as of the last `show`.
    private var handed: [WindowID: [Window]] = [:]
    private var sliding: Set<WindowID> = []

    public init() {}

    /// `held`: the targets that began to slide with their ring showing, and take no display
    /// frame until the first `.hand`. `fullscreen`: the displays that may show a native
    /// fullscreen Space. `make` makes a window for a display, given the display's frame.
    /// The first `.hand` comes once each sliding target's windows it keeps are shown and each
    /// held target's ring that goes is put back, before any other step, as ordering a window
    /// below its target can wait on WindowServer tens of ms at a slide's start. So a window
    /// the slide may still place a ring in leaves it before a step takes it back, as the same
    /// steps can give it to another target. A sliding target's new windows are ordered in
    /// showing nothing, and go to the slide at a second `.hand` once they are (docs/borders.md).
    public mutating func show(_ shown: [WindowID: ShownBorder], held: Set<WindowID> = [], fullscreen: Set<DisplayID>,
                              make: (DisplayID, CGRect) -> Window) -> [Step] {
        var first: [Step] = [], steps: [Step] = [], readies: [Step] = []
        var fresh: [Window] = []
        func append(_ step: Step, first isFirst: Bool) {
            if isFirst { first.append(step) } else { steps.append(step) }
        }
        for (target, ring) in rings where shown[target]?.border.display != ring.display {
            rings[target] = nil
            let waited = waiting.removeValue(forKey: target) != nil
            if !waited, shown[target]?.sliding == true {
                ready[target, default: [:]][ring.display] = ring.window
                first.append(.clear(ring.window))
            } else {
                // A held target's ring leaves the screen before its window moves.
                append(putBack(ring.window, on: ring.display), first: held.contains(target))
            }
        }
        for (target, windows) in ready where shown[target]?.sliding != true {
            // A slide that ended on another display leaves its ring in the window ready there,
            // which stays ordered in as the ring's.
            let kept = shown[target]?.border.display
            steps += windows.filter { $0.key != kept }.map { putBack($0.value, on: $0.key) }
            ready[target] = windows.filter { $0.key == kept }
        }
        for (target, next) in shown {
            // None is made ready where a border stays ordered out until its Space move is sent.
            for monitor in next.border.slideDisplays
            where next.sliding && ready[target]?[monitor.id] == nil && !fullscreen.contains(monitor.id) {
                let window = take(monitor, make)
                var blank = next
                (blank.border.display, blank.border.displayFrame, blank.alpha) = (monitor.id, monitor.frame, 0)
                ready[target, default: [:]][monitor.id] = window
                readies.append(.ready(window, target: target, blank))
                fresh.append(window)
            }
            let display = next.border.display
            if let ring = rings[target] {
                if waiting[target] != nil {
                    waiting[target] = next
                } else {
                    append(.show(ring.window, target: target, next, pin: false), first: next.sliding)
                }
            } else if let window = ready[target]?.removeValue(forKey: display) {
                rings[target] = (window, display)
                append(.show(window, target: target, next, pin: true), first: next.sliding)
            } else {
                let window = take(Monitor(id: display, frame: next.border.displayFrame), make)
                rings[target] = (window, display)
                if fullscreen.contains(display) {
                    waiting[target] = next
                    steps.append(.wait(window, target: target))
                } else if next.sliding {
                    // The target may have moved on since this update read where it shows, so
                    // the ring shows only once the slide places it.
                    var blank = next
                    blank.alpha = 0
                    steps.append(.orderIn(window, target: target, blank))
                    fresh.append(window)
                } else {
                    steps.append(.orderIn(window, target: target, next))
                }
            }
        }
        for (target, windows) in ready where windows.isEmpty { ready[target] = nil }
        sliding = Set(shown.filter(\.value.sliding).keys)
        // The held windows move from the first hand-off on, even with no ring to hand.
        let hand = handOff(leavingOut: fresh) ?? (held.isEmpty ? nil : .hand([:]))
        steps = first + [hand].compactMap { $0 } + steps + readies
        if !fresh.isEmpty, let hand = handOff() { steps.append(hand) }
        return steps
    }

    /// Gives the slide each sliding target's windows ordered in, as after a waiting ring shows;
    /// nil when there is none to give or take back.
    public mutating func handOff(leavingOut fresh: [Window] = []) -> Step? {
        var next: [WindowID: [Window]] = [:]
        for target in sliding {
            var windows = (ready[target] ?? [:]).sorted { $0.key < $1.key }.map(\.value)
            if let ring = rings[target], waiting[target] == nil { windows.append(ring.window) }
            windows.removeAll(where: fresh.contains)
            if !windows.isEmpty { next[target] = windows }
        }
        guard !(next.isEmpty && handed.isEmpty) else { return nil }
        handed = next
        return .hand(next)
    }

    /// What a waiting ring shows once its Space move is sent, unless it went back to its pool
    /// meanwhile: nothing while its target slides, until the slide places the ring.
    public mutating func moved(_ window: Window, of target: WindowID) -> ShownBorder? {
        guard rings[target]?.window == window, var next = waiting.removeValue(forKey: target) else { return nil }
        if next.sliding { next.alpha = 0 }
        return next
    }

    /// The target's windows ordered in below it, the ring's last, so a raise can order each
    /// below it again.
    public func ordered(below target: WindowID) -> [Window] {
        var windows = ready[target].map { Array($0.values) } ?? []
        if waiting[target] == nil, let ring = rings[target] { windows.append(ring.window) }
        return windows
    }

    private mutating func take(_ monitor: Monitor, _ make: (DisplayID, CGRect) -> Window) -> Window {
        spare[monitor.id]?.popLast() ?? make(monitor.id, monitor.frame)
    }

    private mutating func putBack(_ window: Window, on display: DisplayID) -> Step {
        spare[display, default: []].append(window)
        return .putBack(window)
    }
}
