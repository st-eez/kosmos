/// Filters pointer movements for focus follows mouse on the event tap's thread (DESIGN.md,
/// section 5.11), so it only compares numbers. A movement goes on to the main actor when it
/// enters another window than the last movement that went on, with Control up.
public struct PointerGate: Sendable {
    /// The window the pointer was in at the last movement that counted, or nil when the next
    /// movement counts wherever it is.
    public private(set) var window: UInt32?
    /// Kosmos moved the pointer since the last movement.
    private var warpPending = false

    public init() {}

    /// Whether a movement with `window` under the pointer goes on. A movement with Control
    /// held changes nothing, so after Control is released the next movement enters the
    /// window under the pointer.
    public mutating func admit(_ window: UInt32, control: Bool) -> Bool {
        if warpPending {
            warpPending = false
            self.window = window
            return false
        }
        guard !control, window != self.window else { return false }
        self.window = window
        return true
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
    /// Not a tiled or floating window of the shown workspace: a menu, the bar, a panel, the
    /// Dock, Mission Control, a native fullscreen window, a window of Kosmos's own or of a
    /// workspace a switch is hiding.
    case notTiled
    case ignoredApp
    /// macOS shows a native fullscreen window's Space (`showsFullscreenSpace`).
    case fullscreen
    /// The window is the focus intent and key already.
    case focused
}

extension FocusFollowsMouse {
    /// Why the pointer entering `window` leaves focus alone, or nil when the window takes
    /// focus (DESIGN.md, section 5.11).
    /// - Parameters:
    ///   - key: the key window macOS last reported.
    ///   - app: the window's app, for a window the session has.
    ///   - stale: a command, or a focus follows mouse focus, was received after the movement
    ///     (`FocusReports.isStale`).
    ///   - fullscreenShown: macOS shows a native fullscreen window's Space.
    public func skip(_ window: WindowID, in session: Session, key: KeyWindow?,
                     app: (bundleID: String?, name: String?)?, stale: Bool, fullscreenShown: Bool) -> PointerSkip? {
        guard enabled else { return .off }
        if stale { return .stale }
        guard session.isVisible(window) else { return .notTiled }
        if let app, ignores(appID: app.bundleID, appName: app.name) { return .ignoredApp }
        if fullscreenShown { return .fullscreen }
        if session.focused == window, key == .window(window) { return .focused }
        return nil
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
    /// The user activated a window of a shown workspace, which Kosmos adopts. `keyboard`: a
    /// key press came after the last click, as with Command-Tab. Otherwise a click on the
    /// window or the Dock did it.
    case activation(keyboard: Bool)

    /// Whether the pointer goes to the focused window, unless it is over it already. It
    /// does when the keyboard moves focus to another window, or moves the focused window,
    /// and no workspace is switched, as in Omarchy. A hotkey's focus and move commands
    /// qualify, across displays too, and so does sending the window to another workspace
    /// while focus stays. A workspace switch never moves the pointer, nor does anything
    /// from the CLI, a click, or following an activation into a hidden workspace, which
    /// is a switch.
    public var movesPointer: Bool {
        switch self {
        case .command(let command, let source):
            guard source == .hotkey else { return false }
            switch command {
            case .focus, .focusMonitor, .move, .swap, .moveNodeToMonitor: return true
            case .moveNodeToWorkspace(_, let focusFollowsWindow, _): return !focusFollowsWindow
            default: return false
            }
        case .activation(let keyboard):
            return keyboard
        }
    }
}
