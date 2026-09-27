import CoreGraphics

/// Which border window draws each target's ring, which wait ready for its slide on the other
/// displays it crosses, and each display's spare ones; KosmosApp's `Borders` makes the AppKit
/// calls each step names (docs/borders.md).
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
    }

    /// Each window keeps to one display, as one moved to another display's Space before its new
    /// frame landed showed there at its old frame (docs/borders.md).
    private var rings: [WindowID: (window: Window, display: DisplayID)] = [:]
    private var ready: [WindowID: [DisplayID: Window]] = [:]
    private var spare: [DisplayID: [Window]] = [:]
    /// Rings on a display that may show a native fullscreen Space, ordered out until their
    /// Space move is sent, with what to show then.
    private var waiting: [WindowID: ShownBorder] = [:]

    public init() {}

    /// `fullscreen`: the displays that may show a native fullscreen Space. `make` makes a
    /// window for a display, given the display's frame.
    public mutating func show(_ shown: [WindowID: ShownBorder], fullscreen: Set<DisplayID>,
                              make: (DisplayID, CGRect) -> Window) -> [Step] {
        var steps: [Step] = []
        for (target, ring) in rings where shown[target]?.border.display != ring.display {
            rings[target] = nil
            let waited = waiting.removeValue(forKey: target) != nil
            if !waited, shown[target]?.sliding == true {
                ready[target, default: [:]][ring.display] = ring.window
                steps.append(.clear(ring.window))
            } else {
                steps.append(putBack(ring.window, on: ring.display))
            }
        }
        for (target, windows) in ready where shown[target]?.sliding != true {
            steps += windows.map { putBack($0.value, on: $0.key) }
            ready[target] = nil
        }
        for (target, next) in shown {
            // None is made ready where a border stays ordered out until its Space move is sent.
            for monitor in next.border.slideDisplays
            where next.sliding && ready[target]?[monitor.id] == nil && !fullscreen.contains(monitor.id) {
                let window = take(monitor, make)
                var blank = next
                (blank.border.display, blank.border.displayFrame, blank.alpha) = (monitor.id, monitor.frame, 0)
                ready[target, default: [:]][monitor.id] = window
                steps.append(.ready(window, target: target, blank))
            }
            let display = next.border.display
            if let ring = rings[target] {
                if waiting[target] != nil {
                    waiting[target] = next
                } else {
                    steps.append(.show(ring.window, target: target, next, pin: false))
                }
            } else if let window = ready[target]?.removeValue(forKey: display) {
                rings[target] = (window, display)
                steps.append(.show(window, target: target, next, pin: true))
            } else {
                let window = take(Monitor(id: display, frame: next.border.displayFrame), make)
                rings[target] = (window, display)
                if fullscreen.contains(display) {
                    waiting[target] = next
                    steps.append(.wait(window, target: target))
                } else {
                    steps.append(.orderIn(window, target: target, next))
                }
            }
        }
        return steps
    }

    /// What a waiting ring shows once its Space move is sent, unless it went back to its pool
    /// meanwhile.
    public mutating func moved(_ window: Window, of target: WindowID) -> ShownBorder? {
        guard rings[target]?.window == window else { return nil }
        return waiting.removeValue(forKey: target)
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
