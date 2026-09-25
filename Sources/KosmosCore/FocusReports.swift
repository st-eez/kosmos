/// A window macOS reports as key, or no key window: an app with none, or Kosmos's own window for an
/// empty workspace.
public enum KeyWindow: Hashable, Sendable {
    case window(UInt32)
    case emptyWorkspace
}

/// What to do with a key window report (docs/focus.md; tla/Kosmos.tla, Adopt).
public enum ReportVerdict: Equatable, Sendable {
    /// Kosmos's own focus request coming back.
    case echo
    /// Request the current focus intent again: the report is older than the latest command,
    /// or it names a visible window of a workspace no display shows, during a switch.
    case reassert
    /// A window on a workspace a display shows becomes the focus intent, and its display
    /// the focused one (docs/displays.md).
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

/// What admitting a window does with the focus (docs/focus.md and docs/displays.md). A
/// window its app keyed before Kosmos gave it a place, as a launching app keys its first
/// window, is the user's choice.
public enum AdmissionFocus: Equatable, Sendable {
    case none
    /// The window was key before it had a place, on a shown workspace: it becomes the focus
    /// there.
    case adopt
    /// The window's place is on a shown workspace, and its app has not keyed it yet. A key
    /// window report of it within a second of the admission is its app keying the window
    /// it opened, as a launch does that keys its first window more than a second after the
    /// launcher's key, past the Command-Tab test's second (ActivationInput). Adopting it
    /// brings the pointer as `adopt` does (docs/focus-follows-mouse.md). A window there at
    /// launch waits for nothing.
    case awaitKey
    /// The window's place is on a hidden workspace. Its key window report, one that waited
    /// for the place or one that comes before its conceal completes, is decided as one of a
    /// concealed window whose key window before it stayed, which Kosmos follows as it
    /// follows a Command-Tab.
    case placedHidden

    /// - Parameters:
    ///   - keyed: the window is the key window Kosmos last heard of, which only the front
    ///     app reports: its app keyed it before Kosmos gave it a place.
    ///   - shown: its place is on a workspace a display shows.
    ///   - parked: it waits parked, as a window minimized, hidden with its app or in native
    ///     fullscreen when Kosmos admits it, and its return decides the focus.
    ///   - atLaunch: it was there when Kosmos launched, and the launch sweep follows none.
    ///   - locked: the session is locked, and Kosmos ignores focus reports.
    public static func decide(keyed: Bool, shown: Bool, parked: Bool, atLaunch: Bool, locked: Bool) -> AdmissionFocus {
        guard !locked, !parked else { return .none }
        if shown { return keyed ? .adopt : atLaunch ? .none : .awaitKey }
        return atLaunch ? .none : .placedHidden
    }
}

/// Whether macOS shows a native fullscreen window's Space: that window is key, or a window
/// Kosmos does not manage is key and its app owns one, as the fullscreen app's panel or
/// dialog. Only a command then requests focus, since focusing a desktop window takes the
/// user out of that Space (docs/focus.md).
/// - Parameter fullscreen: each window parked in native fullscreen, with its app.
public func showsFullscreenSpace(key: KeyWindow?, keyManaged: Bool, keyApp: Int32?,
                                 fullscreen: [WindowID: Int32]) -> Bool {
    guard case .window(let id)? = key else { return false }
    if fullscreen[id] != nil { return true }
    guard !keyManaged, let keyApp else { return false }
    return fullscreen.values.contains(keyApp)
}

/// Classifies key window reports against the focus requests Kosmos made. Hotkeys, requests
/// and reports carry receipt stamps so "happened before" can be decided.
public struct FocusReports: Sendable {
    /// `publicly`: the public path made the request.
    private var expected: [(key: KeyWindow, app: Int32?, requested: ContinuousClock.Instant, publicly: Bool)] = []
    private var lastCommand: ContinuousClock.Instant?
    /// The window whose missed request Kosmos requested again.
    private var retried: KeyWindow?

    public init() {}

    public mutating func commandExecuted(receivedAt stamp: ContinuousClock.Instant) {
        lastCommand = stamp
    }

    /// Records a request just before the focus queue makes its calls, before it can come back.
    /// `app` owns the window, or is Kosmos for no window. `publicly` says the public path
    /// makes the request, which lets the app key a window of its own choosing.
    public mutating func focusRequested(_ key: KeyWindow, app: Int32?, at stamp: ContinuousClock.Instant, publicly: Bool = false) {
        if key != retried { retried = nil }
        expected.append((key, app, stamp, publicly))
    }

    /// A report that is no echo, from an app a public request named and received after it,
    /// is that request's result: the app keyed another window of its choosing, and a later
    /// report of the requested window is the user's. Private requests keep their
    /// expectations until matched, or their late echo would pull focus back from the user's
    /// choice (tla/README.md, change 6); the spec does not model the public path.
    public mutating func publicRequestsAnswered(by app: Int32, receivedAt stamp: ContinuousClock.Instant) {
        expected.removeAll { $0.publicly && $0.app == app && $0.requested <= stamp }
    }

    /// A user action received before the latest command is stale: the command wins
    /// (tla/Kosmos.tla, Adopt and Rejoin).
    public func isStale(_ stamp: ContinuousClock.Instant) -> Bool {
        lastCommand.map { stamp < $0 } ?? false
    }

    /// Whether the report would be the echo of a request of Kosmos's.
    public func isEcho(_ key: KeyWindow, receivedAt stamp: ContinuousClock.Instant) -> Bool {
        echo(of: key, receivedAt: stamp) != nil
    }

    /// The expectation a report echoes: the requested window, reported after the request.
    private func echo(of key: KeyWindow, receivedAt stamp: ContinuousClock.Instant) -> Int? {
        expected.firstIndex { $0.key == key && $0.requested <= stamp }
    }

    /// Consumes the expectation `key` answers, if any. An echo names the requested window and
    /// arrives after the request. Earlier expectations are dropped with it, so one whose echo
    /// never comes, as when an app the key record activated keys another window itself
    /// before reporting the requested one, goes once a later request's echo comes; a report
    /// that matches none leaves them all. A report from an app that is not front calls this
    /// alone: it is no key window report, but it can still be Kosmos's echo (tla/Kosmos.tla,
    /// ObserveSplit).
    ///
    /// The ceiling: each app reports on its own threads, so on a fast sweep of the pointer
    /// across apps an earlier request's echo can arrive after a later one's, find its
    /// expectation dropped, and read as the user's choice (tla/README.md, change 19). The
    /// spec removes only the matched expectation, and matches an activation read to its
    /// app's key record whatever window it reads; the two come together or not at all
    /// (docs/focus.md, Deferred).
    public mutating func consumeEcho(_ key: KeyWindow, receivedAt stamp: ContinuousClock.Instant) -> Bool {
        guard let index = echo(of: key, receivedAt: stamp) else { return false }
        expected.removeFirst(index + 1)
        if key == retried { retried = nil }
        return true
    }

    /// Forgets every request, as when their echoes may have come and gone unclassified.
    public mutating func forgetRequests() {
        expected.removeAll()
        retried = nil
    }

    /// Forgets a request the focus queue dropped, so it cannot swallow a later report.
    public mutating func requestDropped(_ key: KeyWindow, at stamp: ContinuousClock.Instant) {
        if let index = expected.firstIndex(where: { $0.key == key && $0.requested == stamp }) {
            expected.remove(at: index)
        }
    }

    /// Whether a report is a miss of Kosmos's own request (`Miss`). The missed request, the
    /// oldest to that app since the focus queue runs requests in order, never comes back:
    /// it leaves the expectations, so it cannot take a later report of its window for its
    /// echo. Call it for every report, before `classify`. A report that echoes a request is
    /// none: the raise after a key record repeats the window the key record keyed, and an app
    /// can report that window again after it (`kosmos-probe keying`, 6 of 40).
    ///
    /// The ceiling: the activation read of a Command-Tab repeats the window its own
    /// notification just reported, so while an older request to that app awaits its echo it
    /// reads as a miss, and the Command-Tab is lost (tla/README.md, change 21,
    /// `split-user-missrule`). The spec drops the rule together with matching an activation
    /// read to its app's key record whatever window it reads (docs/focus.md,
    /// Deferred).
    /// - Parameters:
    ///   - app: the app that owns the reported window.
    ///   - repeated: the report names the key window Kosmos last heard of.
    public mutating func miss(_ key: KeyWindow, app: Int32?, repeated: Bool, receivedAt stamp: ContinuousClock.Instant) -> Miss {
        guard repeated, let app, echo(of: key, receivedAt: stamp) == nil,
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
    ///   - onShownWorkspace: the window belongs to a workspace a display shows.
    ///   - concealed: the window was concealed when it became key, so only the user could
    ///     have reached it, with Command-Tab or by opening it.
    ///   - recovered: a batch failed, and recovery showed the windows of hidden workspaces,
    ///     so a click reaches them too. Otherwise a visible window of a workspace no display
    ///     shows is key only during a switch.
    ///   - miss: what `miss` said of the report.
    ///   - keyLeft: whether the window key before this report has just left the screen, read
    ///     only when the verdict depends on it, as it can read WindowServer. If
    ///     it has, macOS keyed this window itself, so it is not a Command-Tab to follow;
    ///     Kosmos keeps its workspace and focuses it again (tla/Kosmos.tla, KeyLeft).
    public mutating func classify(_ key: KeyWindow, receivedAt stamp: ContinuousClock.Instant, onShownWorkspace: Bool,
                                  concealed: Bool, recovered: Bool = false, miss: Miss = .none,
                                  keyLeft: @autoclosure () -> Departure) -> ReportVerdict {
        if consumeEcho(key, receivedAt: stamp) { return .echo }
        if isStale(stamp) { return .reassert }
        // No key window: if the key window left, its departure focuses when this came
        // first.
        guard case .window(let id) = key else { return keyLeft() == .left ? .reassert : .ignore }
        // A miss is no one's choice: request the focus again, and after one retry accept the
        // key window, which Kosmos can adopt only on a shown workspace.
        switch miss {
        case .retry: return .reassert
        case .accept: return onShownWorkspace ? .adopt(id) : .ignore
        case .none: break
        }
        if onShownWorkspace { return .adopt(id) }
        guard concealed || recovered else { return .reassert }
        switch keyLeft() {
        case .left: return .reassert
        case .stayed: return .follow(id)
        case .unknown: return .undecided
        }
    }
}
