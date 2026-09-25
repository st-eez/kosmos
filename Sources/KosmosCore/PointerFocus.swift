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
    /// focus. A native fullscreen window takes it, and nothing behind one can (DESIGN.md,
    /// section 5.11).
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

    /// The workspace to focus when the pointer entered `display` over the desktop: the one
    /// it shows, when that has no windows and is not focused already, as Hyprland's
    /// `follow_mouse` moves the monitor focus. Over the desktop or a gap of a display whose
    /// workspace has windows, focus stays where it is, as in Hyprland. So does a window
    /// Kosmos does not manage covering the display, as a slideshow, a game, the menu bar or
    /// a panel over a native fullscreen window.
    /// - Parameter overDesktop: the pointer is over the desktop or no window, read last.
    public func emptyWorkspace(entered display: DisplayID, overDesktop: @autoclosure () -> Bool,
                               in session: Session) -> String? {
        guard enabled, let name = session.workspace(shownOn: display), name != session.focusedWorkspace,
              session.windows(of: name).isEmpty, overDesktop() else { return nil }
        return name
    }

    /// Whether a window at `level` is the desktop: Finder's desktop window at the desktop
    /// icon level, or the wallpaper and backstop windows below it.
    public static func isDesktop(level: Int32) -> Bool {
        level <= CGWindowLevelForKey(.desktopIconWindow)
    }
}

/// How long before an app activation Kosmos adopts or follows the user's last input came, in
/// seconds, as the session's event state gives it (`CGEventSource.secondsSinceLastEventType`).
public struct ActivationInput: Equatable, Sendable {
    public var key: Double
    public var leftClick: Double
    public var rightClick: Double
    public var moved: Double

    public init(key: Double, leftClick: Double, rightClick: Double, moved: Double) {
        self.key = key
        self.leftClick = leftClick
        self.rightClick = rightClick
        self.moved = moved
    }

    /// Whether mouse-follows-focus brings the pointer to the activated window: the user
    /// picked an app away from the pointer (DESIGN.md, section 5.11). Either a key went down
    /// in the last second, after the last click and the last pointer movement, as with
    /// Command-Tab or a launcher's hotkey, or the last left mouse down, in the last second
    /// and after the last key and right mouse down, landed on the Dock. `onDock` is read only
    /// then. The pointer may have moved since the Dock click, on its way to the app. A click
    /// anywhere else, in the window, on the bar or on a link that opens another app, leaves
    /// the pointer where it is.
    public func bringsPointer(onDock: @autoclosure () -> Bool) -> Bool {
        if key < 1, key < leftClick, key < rightClick, key < moved { return true }
        return leftClick < 1 && leftClick < key && leftClick < rightClick && onDock()
    }
}

/// Where a command came from. Bar clicks, scripts and launchers send theirs through the CLI.
public enum CommandSource: Sendable {
    case hotkey
    case cli
}

extension Command {
    /// Whether mouse-follows-focus brings the pointer to the focus after this command, unless
    /// it is there already. `toAnotherDisplay`: the focus is on another display than the
    /// pointer (DESIGN.md, section 5.11).
    public func movesPointer(from source: CommandSource, toAnotherDisplay: Bool) -> Bool {
        guard source == .hotkey else { return false }
        switch self {
        case .focus, .focusMonitor, .move, .swap, .moveNodeToMonitor: return true
        case .workspace, .workspaceBackAndForth: return toAnotherDisplay
        case .moveNodeToWorkspace(_, let focusFollowsWindow, _): return !focusFollowsWindow || toAnotherDisplay
        default: return false
        }
    }
}
