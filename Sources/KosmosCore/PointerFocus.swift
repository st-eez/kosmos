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
    /// Nil when the window takes focus (docs/focus-follows-mouse.md). `fullscreen`: the
    /// window is parked in native fullscreen.
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

    /// The empty workspace to focus when the pointer entered `display` over the desktop
    /// (docs/focus-follows-mouse.md).
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
    /// In seconds: an input older than this is not the one behind the activation.
    public static let maxAge: Double = 1

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
    /// Dock click, within the last second (docs/focus-follows-mouse.md).
    public func bringsPointer(onDock: Bool) -> Bool {
        if key < Self.maxAge, key < leftClick, key < rightClick, key < moved { return true }
        return onDock && leftClick < Self.maxAge && leftClick < key && leftClick < rightClick
    }
}

/// Bar clicks, scripts and launchers send their commands through the CLI.
public enum CommandSource: Sendable {
    case hotkey
    case cli
}

/// What moved the focus, for mouse-follows-focus (docs/focus-follows-mouse.md).
public enum FocusChange: Sendable {
    case command(Command, from: CommandSource)
    /// `atLaunch`: the window was there when Kosmos launched.
    case admission(AdmissionFocus, atLaunch: Bool)
    /// Kosmos adopts or follows the key window its app reported. `admitted`: a new window,
    /// keyed as Kosmos admitted it (KeyReportIntake.Report).
    case keyReport(admitted: Bool)
    /// Parked windows came back. `followed`: Kosmos follows one of them, with no command since.
    case returned(followed: Bool)
}

/// The user's input as the app reads it. The rule reads each only for a change that needs it.
public struct PointerReadings {
    /// The focus is on another display than the pointer (Session.focusIsOnAnotherDisplay).
    public var focusOnAnotherDisplay: () -> Bool
    public var leftButtonDown: () -> Bool
    /// Whether the last left mouse down landed on the Dock, read with the input.
    public var activation: () -> (input: ActivationInput, onDock: Bool)

    public init(focusOnAnotherDisplay: @escaping () -> Bool, leftButtonDown: @escaping () -> Bool,
                activation: @escaping () -> (input: ActivationInput, onDock: Bool)) {
        self.focusOnAnotherDisplay = focusOnAnotherDisplay
        self.leftButtonDown = leftButtonDown
        self.activation = activation
    }
}

extension FocusChange {
    /// Whether mouse-follows-focus brings the pointer to the focus after this change
    /// (docs/focus-follows-mouse.md).
    public func movesPointer(mouseFollowsFocus: Bool, reading input: PointerReadings) -> Bool {
        guard mouseFollowsFocus else { return false }
        switch self {
        case .command(let command, let source):
            guard source == .hotkey else { return false }
            switch command {
            case .focus, .focusMonitor, .move, .swap, .moveNodeToMonitor: return true
            case .workspace, .workspaceBackAndForth: return input.focusOnAnotherDisplay()
            case .moveNodeToWorkspace(_, let focusFollowsWindow, _): return !focusFollowsWindow || input.focusOnAnotherDisplay()
            default: return false
            }
        case .admission(let focus, let atLaunch):
            return focus == .adopt && !atLaunch && !input.leftButtonDown()
        case .keyReport(admitted: true):
            return !input.leftButtonDown()
        case .keyReport(admitted: false), .returned(followed: true):
            let (activation, onDock) = input.activation()
            return activation.bringsPointer(onDock: onDock)
        case .returned(followed: false):
            return false
        }
    }
}
