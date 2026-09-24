/// A window macOS reports as key, or no key window (Finder fronted for an empty workspace).
public enum KeyWindow: Hashable, Sendable {
    case window(UInt32)
    case none
}

/// What to do with a key window report (DESIGN.md, section 5.4; tla/Kosmos.tla, Adopt).
public enum ReportVerdict: Equatable, Sendable {
    /// Kosmos's own focus request coming back.
    case echo
    /// Request the current focus intent again: the report is older than the latest command,
    /// or it names a visible window of another workspace during a switch.
    case reassert
    /// A window on the current workspace becomes the focus intent.
    case adopt(UInt32)
    /// The user reached a hidden window, with Command-Tab or by opening it: switch to its
    /// workspace.
    case follow(UInt32)
    /// No key window and nothing to do.
    case ignore
    /// The verdict depends on whether the window key before the report left the screen,
    /// which is not known yet: hold the report until the departure arrives or a short grace
    /// ends, then classify it again (tla/Kosmos.tla, Hold).
    case undecided
}

/// Whether the window key before a report has left the screen: it closed or minimized, or
/// its app hid. WindowServer can still show a hidden app's window after macOS keyed the next
/// one, so a departure can be unknown for a moment.
public enum Departure: Sendable {
    case left
    case stayed
    case unknown
}

/// A report that repeats the key window while Kosmos awaits the echo of its request for
/// another window of the same app: the app kept its key window, and the request missed
/// (tla/Kosmos.tla, Missed).
public enum Miss: Equatable, Sendable {
    case none
    /// Request the focus again, once for each requested window.
    case retry
    /// The retry missed too: stop asking, and leave the key window where macOS put it.
    case accept
}

/// Whether macOS shows a native fullscreen window's Space: that window is key, or a window
/// Kosmos does not manage is key and its app owns one, as the fullscreen app's panel or
/// dialog. Only a command then requests focus, since focusing a desktop window takes the
/// user out of that Space (DESIGN.md, section 5.4).
/// - Parameter fullscreen: each window parked in native fullscreen, with its app.
public func showsFullscreenSpace(key: KeyWindow?, keyManaged: Bool, keyApp: Int32?,
                                 fullscreen: [WindowID: Int32]) -> Bool {
    guard case .window(let id)? = key else { return false }
    if fullscreen[id] != nil { return true }
    guard !keyManaged, let keyApp else { return false }
    return fullscreen.values.contains(keyApp)
}

/// Classifies key window reports against the focus requests Kosmos made. Hotkeys, requests
/// and reports carry receipt stamps (`Stamp`) so "happened before" can be decided.
public struct FocusReports<Stamp: Comparable & Sendable>: Sendable {
    private var expected: [(key: KeyWindow, app: Int32?, requested: Stamp)] = []
    private var lastCommand: Stamp?
    /// The window whose missed request Kosmos requested again.
    private var retried: KeyWindow?

    public init() {}

    public mutating func commandExecuted(receivedAt stamp: Stamp) {
        lastCommand = stamp
    }

    /// Records a request when it is queued, before it can come back. `app` owns the window,
    /// or is Finder for no window.
    public mutating func focusRequested(_ key: KeyWindow, app: Int32?, at stamp: Stamp) {
        if key != retried { retried = nil }
        expected.append((key, app, stamp))
    }

    /// A user action received before the latest command is stale: the command wins
    /// (tla/Kosmos.tla, Adopt and Rejoin).
    public func isStale(_ stamp: Stamp) -> Bool {
        lastCommand.map { stamp < $0 } ?? false
    }

    /// Whether the report would be the echo of a request of Kosmos's.
    public func isEcho(_ key: KeyWindow, receivedAt stamp: Stamp) -> Bool {
        expected.contains { $0.key == key && $0.requested <= stamp }
    }

    /// Forgets a request the focus queue dropped, so it cannot swallow a later report.
    public mutating func requestDropped(_ key: KeyWindow, at stamp: Stamp) {
        if let index = expected.firstIndex(where: { $0.key == key && $0.requested == stamp }) {
            expected.remove(at: index)
        }
    }

    /// Whether a report is a miss of Kosmos's own request (`Miss`). The missed request, the
    /// oldest to that app since the focus queue runs requests in order, never comes back:
    /// it leaves the expectations, so it cannot take a later report of its window for its
    /// echo. Call it for every report, before `classify`.
    /// - Parameters:
    ///   - app: the app that owns the reported window.
    ///   - repeated: the report names the key window Kosmos last heard of.
    public mutating func miss(_ key: KeyWindow, app: Int32?, repeated: Bool, receivedAt stamp: Stamp) -> Miss {
        guard repeated, let app,
              let index = expected.firstIndex(where: { $0.app == app && $0.key != key && $0.requested <= stamp })
        else { return .none }
        let missed = expected.remove(at: index).key
        if retried == missed {
            retried = nil
            return .accept
        }
        retried = missed
        return .retry
    }

    /// - Parameters:
    ///   - onCurrentWorkspace: the window belongs to the workspace Kosmos shows.
    ///   - concealed: the window was concealed when it became key, so only the user could
    ///     have reached it, with Command-Tab or by opening it.
    ///   - recovered: a batch failed, and recovery showed the windows of hidden workspaces,
    ///     so a click reaches them too. Otherwise a visible window of another workspace is
    ///     key only during a switch.
    ///   - miss: what `miss` said of the report.
    ///   - keyLeft: whether the window key before this report has just left the screen. If
    ///     it has, macOS keyed this window itself, so it is not a Command-Tab to follow;
    ///     Kosmos keeps its workspace and focuses it again (tla/Kosmos.tla, KeyLeft).
    public mutating func classify(_ key: KeyWindow, receivedAt stamp: Stamp, onCurrentWorkspace: Bool,
                                  concealed: Bool, recovered: Bool = false, miss: Miss = .none,
                                  keyLeft: Departure) -> ReportVerdict {
        // An echo names the requested window and arrives after the request. Earlier
        // expectations are dropped with it; a report that matches none leaves them all.
        if let index = expected.firstIndex(where: { $0.key == key && $0.requested <= stamp }) {
            expected.removeFirst(index + 1)
            if key == retried { retried = nil }
            return .echo
        }
        if isStale(stamp) { return .reassert }
        // No key window: if the key window left, its departure focuses when this came
        // first.
        guard case .window(let id) = key else { return keyLeft == .left ? .reassert : .ignore }
        // A miss is no one's choice: request the focus again, and after one retry accept the
        // key window, which Kosmos can adopt only on the shown workspace.
        switch miss {
        case .retry: return .reassert
        case .accept: return onCurrentWorkspace ? .adopt(id) : .ignore
        case .none: break
        }
        if onCurrentWorkspace { return .adopt(id) }
        guard concealed || recovered else { return .reassert }
        switch keyLeft {
        case .left: return .reassert
        case .stayed: return .follow(id)
        case .unknown: return .undecided
        }
    }
}
