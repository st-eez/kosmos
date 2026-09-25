import CoreGraphics

/// Filters pointer movements for focus follows mouse on the event tap's thread (DESIGN.md,
/// section 5.11), so it only compares numbers. A movement goes on to the main actor when it
/// enters another window or another display than the last movement that went on, with
/// Control up.
public struct PointerGate: Sendable {
    /// What a movement that goes on entered.
    public struct Entered: Equatable, Sendable {
        /// The window under the pointer, as WindowServer found it.
        public let window: UInt32
        /// The display under the pointer, when the movement entered another display.
        public let display: DisplayID?

        public init(window: UInt32, display: DisplayID? = nil) {
            self.window = window
            self.display = display
        }
    }

    /// The displays, from the session, to tell which one the pointer is on.
    public var monitors: [Monitor] = []
    /// The window the pointer was in at the last movement that counted, or nil when the next
    /// movement counts wherever it is.
    public private(set) var window: UInt32?
    private var display: DisplayID?
    /// Kosmos moved the pointer since the last movement.
    private var warpPending = false

    public init() {}

    /// What a movement to `location`, with `window` under the pointer, entered, or nil when
    /// it goes no further. A movement with Control held changes nothing, so after Control is
    /// released the next movement enters the window and the display under the pointer.
    public mutating func admit(_ window: UInt32, at location: CGPoint, control: Bool) -> Entered? {
        let display = monitors.first { $0.frame.contains(location) }?.id
        if warpPending {
            warpPending = false
            (self.window, self.display) = (window, display)
            return nil
        }
        guard !control, window != self.window || display != self.display else { return nil }
        let crossed = display != self.display
        (self.window, self.display) = (window, display)
        return Entered(window: window, display: crossed ? display : nil)
    }

    /// The next movement counts wherever it is, as when focus follows mouse turns on.
    public mutating func reset() {
        (window, display, warpPending) = (nil, nil, false)
    }

    /// Kosmos moved the pointer into a window it focused. The next movement starts where
    /// Kosmos put the pointer, so it enters nothing: whether or not the move posts an event
    /// of its own, focus follows mouse leaves Kosmos's focus alone.
    public mutating func warped() {
        warpPending = true
    }
}

/// Why the window the pointer entered does not take focus.
public enum PointerSkip: Equatable, Sendable {
    /// Focus follows mouse was turned off after the movement.
    case off
    /// A command, or a focus follows mouse focus, came after the movement.
    case stale
    /// Neither a tiled or floating window of a workspace a display shows nor a native
    /// fullscreen window: a menu, the bar, a panel, the Dock, Mission Control, a minimized or
    /// hidden window, a window of Kosmos's own or of a workspace a switch is hiding.
    case notTiled
    case ignoredApp
    /// The window is the focus intent and key already.
    case focused
}

extension FocusFollowsMouse {
    /// Why the pointer entering `window` leaves focus alone, or nil when the window takes
    /// focus (DESIGN.md, section 5.11). WindowServer found `window` under the pointer, so it
    /// is on screen: on a display that shows a native fullscreen Space, the only windows
    /// there are the fullscreen window, which takes focus as Omarchy's does, and its app's
    /// panels, which the session does not tile. So nothing behind a fullscreen window takes
    /// focus, and a fullscreen Space on another display leaves this one free.
    /// - Parameters:
    ///   - fullscreen: the window is parked in native fullscreen.
    ///   - key: the key window macOS last reported.
    ///   - app: the window's app, for a window the session has.
    ///   - stale: a command, or a focus follows mouse focus, was received after the movement
    ///     (`FocusReports.isStale`).
    public func skip(_ window: WindowID, in session: Session, fullscreen: Bool, key: KeyWindow?,
                     app: (bundleID: String?, name: String?)?, stale: Bool) -> PointerSkip? {
        guard enabled else { return .off }
        if stale { return .stale }
        guard fullscreen || session.isVisible(window) else { return .notTiled }
        if let app, ignores(appID: app.bundleID, appName: app.name) { return .ignoredApp }
        // The session never has a parked window as its focus.
        if key == .window(window), fullscreen || session.focused == window { return .focused }
        return nil
    }
    /// The workspace to focus when the pointer entered `display`: the one it shows, when
    /// that has no windows and is not focused already, as Hyprland's `follow_mouse` moves
    /// the monitor focus. Over the desktop or a gap of a display whose workspace has
    /// windows, focus stays where it is, as in Hyprland.
    public func emptyWorkspace(entered display: DisplayID, in session: Session) -> String? {
        guard enabled, let name = session.workspace(shownOn: display), name != session.focusedWorkspace,
              session.windows(of: name).isEmpty else { return nil }
        return name
    }
}

/// Where a command came from. Bar clicks, scripts and launchers send theirs through the CLI.
public enum CommandSource: Sendable {
    case hotkey
    case cli
}

/// A focus change that mouse-follows-focus may bring the pointer along for (DESIGN.md,
/// section 5.11).
public enum FocusChange: Equatable, Sendable {
    case command(Command, from: CommandSource)
    /// The user activated a window, which Kosmos adopts on a shown workspace or follows
    /// into a hidden one, a switch. `keyboard`: a key press came after the last click, as
    /// with Command-Tab. Otherwise a click on the window or the Dock did it.
    case activation(keyboard: Bool, intoHiddenWorkspace: Bool)

    /// Whether the pointer goes to the focused window, unless it is inside it already.
    /// `toAnotherDisplay`: that window is on another display than the pointer.
    ///
    /// It does when the keyboard moves focus to another window, or moves the focused window:
    /// a hotkey's focus and move commands, sending the window to another workspace while
    /// focus stays, and Command-Tab. A workspace switch moves it only to another display,
    /// as when a launcher's hotkey activates an app on a workspace another display hides; on
    /// the pointer's own display the pointer stays, as in Omarchy. Nothing from the CLI or a
    /// click moves it.
    public func movesPointer(toAnotherDisplay: Bool) -> Bool {
        switch self {
        case .command(let command, let source):
            guard source == .hotkey else { return false }
            switch command {
            case .focus, .focusMonitor, .move, .swap, .moveNodeToMonitor: return true
            case .workspace, .workspaceBackAndForth: return toAnotherDisplay
            case .moveNodeToWorkspace(_, let focusFollowsWindow, _): return !focusFollowsWindow || toAnotherDisplay
            default: return false
            }
        case .activation(let keyboard, let intoHiddenWorkspace):
            return keyboard && (!intoHiddenWorkspace || toAnotherDisplay)
        }
    }
}
