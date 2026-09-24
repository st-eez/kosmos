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
    private var expected: [(key: KeyWindow, requested: Stamp)] = []
    private var lastCommand: Stamp?

    public init() {}

    public mutating func commandExecuted(receivedAt stamp: Stamp) {
        lastCommand = stamp
    }

    /// Records a request just before the focus queue makes its calls, before it can come back.
    public mutating func focusRequested(_ key: KeyWindow, at stamp: Stamp) {
        expected.append((key, stamp))
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
