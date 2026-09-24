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
    /// The user reached a hidden window with Command-Tab: switch to its workspace.
    case follow(UInt32)
    /// No key window and nothing to do.
    case ignore
}

/// Classifies key window reports against the focus requests Kosmos made. Hotkeys, requests
/// and reports carry receipt stamps (`Stamp`) so "happened before" can be decided.
public struct FocusReports<Stamp: Comparable & Sendable>: Sendable {
    /// `publicIn` is the target's app for a request of the public path.
    private var expected: [(key: KeyWindow, requested: Stamp, publicIn: Int32?)] = []
    private var lastCommand: Stamp?

    public init() {}

    public mutating func commandExecuted(receivedAt stamp: Stamp) {
        lastCommand = stamp
    }

    /// Records a request just before the focus queue makes its calls, before it can come back.
    /// `publicIn` names the target's app when the public path makes the request, which lets
    /// the app key a window of its own choosing.
    public mutating func focusRequested(_ key: KeyWindow, at stamp: Stamp, publicIn app: Int32? = nil) {
        expected.append((key, stamp, app))
    }

    /// A report that is no echo, from an app a public request named and received after it,
    /// is that request's result: the app keyed another window of its choosing, and a later
    /// report of the requested window is the user's. Private requests keep their
    /// expectations until matched, or their late echo would pull focus back from the user's
    /// choice (tla/README.md, change 6); the spec does not model the public path.
    public mutating func publicRequestsAnswered(by app: Int32, receivedAt stamp: Stamp) {
        expected.removeAll { $0.publicIn == app && $0.requested <= stamp }
    }

    /// Forgets every request, as when their echoes may have come and gone unclassified.
    public mutating func forgetRequests() {
        expected.removeAll()
    }

    /// Forgets a request the focus queue dropped, so it cannot swallow a later report.
    public mutating func requestDropped(_ key: KeyWindow, at stamp: Stamp) {
        if let index = expected.firstIndex(where: { $0.key == key && $0.requested == stamp }) {
            expected.remove(at: index)
        }
    }

    /// - Parameters:
    ///   - onCurrentWorkspace: the window belongs to the workspace Kosmos shows.
    ///   - wasHidden: the window was concealed when it became key, so only Command-Tab
    ///     could have reached it.
    public mutating func classify(_ key: KeyWindow, receivedAt stamp: Stamp,
                                  onCurrentWorkspace: Bool, wasHidden: Bool) -> ReportVerdict {
        // An echo names the requested window and arrives after the request. Earlier
        // expectations are dropped with it; a report that matches none leaves them all.
        if let index = expected.firstIndex(where: { $0.key == key && $0.requested <= stamp }) {
            expected.removeFirst(index + 1)
            return .echo
        }
        if let lastCommand, stamp < lastCommand { return .reassert }
        guard case .window(let id) = key else { return .ignore }
        if onCurrentWorkspace { return .adopt(id) }
        return wasHidden ? .follow(id) : .reassert
    }
}
