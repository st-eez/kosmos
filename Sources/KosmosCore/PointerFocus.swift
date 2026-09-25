import CoreGraphics

/// Runs on the event tap's thread, so it only compares numbers (docs/focus-follows-mouse.md).
public struct PointerGate: Sendable {
    public struct Entered: Equatable, Sendable {
        public let window: WindowID
        /// Nil unless the movement entered another display.
        public let display: DisplayID?

        public init(window: WindowID, display: DisplayID? = nil) {
            self.window = window
            self.display = display
        }
    }

    public var monitors: [Monitor] = []
    /// Nil when the next movement counts wherever it is.
    public private(set) var window: WindowID?
    private var display: DisplayID?
    private var warpPending = false

    public init() {}

    /// A movement with Control held changes nothing, so the first one after Control comes up
    /// enters the window and display under the pointer.
    public mutating func admit(_ window: WindowID, at location: CGPoint, control: Bool) -> Entered? {
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

    public mutating func reset() {
        (window, display, warpPending) = (nil, nil, false)
    }

    /// Kosmos moved the pointer. The next movement enters nothing, whether or not the warp
    /// posted an event of its own.
    public mutating func warped() {
        warpPending = true
    }
}

/// Why the window the pointer entered does not take focus.
public enum PointerSkip: Equatable, Sendable {
    /// Turned off after the movement.
    case off
    /// A command, or a focus follows mouse focus, came after the movement.
    case stale
    /// Neither a visible tiled or floating window nor a native fullscreen one, as a menu, the
    /// Dock or a window a switch is hiding.
    case notTiled
    case ignoredApp
    /// The window is the focus intent and key already.
    case focused
}

extension FocusFollowsMouse {
    /// Nil when the window takes focus (docs/focus-follows-mouse.md).
    /// - Parameters:
    ///   - fullscreen: the window is parked in native fullscreen.
    ///   - stale: a command, or a focus follows mouse focus, came after the movement
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

    /// The empty workspace to focus when the pointer entered `display` over the desktop, as
    /// Hyprland's `follow_mouse` moves the monitor focus (docs/focus-follows-mouse.md).
    public func emptyWorkspace(entered display: DisplayID, overDesktop: @autoclosure () -> Bool,
                               in session: Session) -> String? {
        guard enabled, let name = session.workspace(shownOn: display), name != session.focusedWorkspace,
              session.windows(of: name).isEmpty, overDesktop() else { return nil }
        return name
    }

    /// Finder's desktop window is at the desktop icon level, and the wallpaper and backstop
    /// windows are below it.
    public static func isDesktop(level: Int32) -> Bool {
        level <= CGWindowLevelForKey(.desktopIconWindow)
    }
}

/// Seconds from the user's last input of each kind to an app activation, as
/// `CGEventSource.secondsSinceLastEventType` gives them.
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

    /// The user picked an app away from the pointer, with a key such as Command-Tab or with a
    /// Dock click, within the last second (docs/focus-follows-mouse.md). A Command-Tab
    /// switcher held open for over a second reads as a click.
    public func bringsPointer(onDock: Bool) -> Bool {
        if key < 1, key < leftClick, key < rightClick, key < moved { return true }
        return onDock && leftClick < 1 && leftClick < key && leftClick < rightClick
    }
}

/// Bar clicks, scripts and launchers send their commands through the CLI.
public enum CommandSource: Sendable {
    case hotkey
    case cli
}

extension Command {
    /// Whether mouse-follows-focus brings the pointer to the focus after this command, unless
    /// it is there already. `toAnotherDisplay`: the focus is on another display than the
    /// pointer (docs/focus-follows-mouse.md).
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
