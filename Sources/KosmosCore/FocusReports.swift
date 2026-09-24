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

/// Classifies key window reports against the focus requests Kosmos made. Hotkeys, requests
/// and reports carry receipt stamps (`Stamp`) so "happened before" can be decided.
public struct FocusReports<Stamp: Comparable & Sendable>: Sendable {
    private var expected: [(key: KeyWindow, requested: Stamp)] = []
    private var lastCommand: Stamp?

    public init() {}

    public mutating func commandExecuted(receivedAt stamp: Stamp) {
        lastCommand = stamp
    }

    /// Records a request when it is queued, before it can come back.
    public mutating func focusRequested(_ key: KeyWindow, at stamp: Stamp) {
        expected.append((key, stamp))
    }

    /// A user action received before the latest command is stale: the command wins
    /// (tla/Kosmos.tla, Adopt and Rejoin).
    public func isStale(_ stamp: Stamp) -> Bool {
        lastCommand.map { stamp < $0 } ?? false
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
    ///   - keyLeft: whether the window key before this report has just left the screen. If
    ///     it has, macOS keyed this window itself, so it is not a Command-Tab to follow;
    ///     Kosmos keeps its workspace and focuses it again (tla/Kosmos.tla, KeyLeft).
    public mutating func classify(_ key: KeyWindow, receivedAt stamp: Stamp,
                                  onCurrentWorkspace: Bool, wasHidden: Bool, keyLeft: Departure) -> ReportVerdict {
        // An echo names the requested window and arrives after the request. Earlier
        // expectations are dropped with it; a report that matches none leaves them all.
        if let index = expected.firstIndex(where: { $0.key == key && $0.requested <= stamp }) {
            expected.removeFirst(index + 1)
            return .echo
        }
        if isStale(stamp) { return .reassert }
        // No key window: if the key window left, its departure focuses when this came
        // first.
        guard case .window(let id) = key else { return keyLeft == .left ? .reassert : .ignore }
        if onCurrentWorkspace { return .adopt(id) }
        guard wasHidden else { return .reassert }
        switch keyLeft {
        case .left: return .reassert
        case .stayed: return .follow(id)
        case .unknown: return .undecided
        }
    }
}
