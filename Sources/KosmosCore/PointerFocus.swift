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
