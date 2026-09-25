public enum KeyWindow: Hashable, Sendable {
    case window(WindowID)
    /// No key window: an app with none, or Kosmos's own window for an empty workspace.
    case emptyWorkspace
}

/// What to do with a key window report (docs/focus.md; tla/Kosmos.tla, Adopt).
public enum ReportVerdict: Equatable, Sendable {
    /// Kosmos's own request coming back.
    case echo
    /// Request the focus intent again.
    case reassert
    /// The window becomes the focus intent, and its display the focused one.
    case adopt(WindowID)
    /// Switch to the workspace of a hidden window the user reached.
    case follow(WindowID)
    case ignore
    /// Hold the report until Kosmos knows whether the window key before it left, or a short
    /// grace ends, then classify it again (tla/Kosmos.tla, Hold).
    case undecided
}

/// Whether the window key before a report left the screen. WindowServer can still show a
/// hidden app's window after macOS keyed the next one, so it can be unknown for a moment.
public enum Departure: Sendable {
    case left
    case stayed
    case unknown
}

/// A repeat of the key window while a request for another window of its app awaits its
/// echo: the app kept its key window (tla/Kosmos.tla, Missed).
public enum Miss: Equatable, Sendable {
    case none
    /// Request the focus again, once for each requested window.
    case retry
    /// The retry missed too: leave the key window where macOS put it.
    case accept
}

/// What admitting a window does with the focus (docs/focus.md). A window its app keyed
/// before it had a place is the user's choice.
public enum AdmissionFocus: Equatable, Sendable {
    case none
    case adopt
    /// Adopt the window if its app keys it within a second, which brings the pointer
    /// (docs/focus-follows-mouse.md).
    case awaitKey
    /// Kosmos follows its key report there, as it follows a Command-Tab (docs/focus.md).
    case placedHidden

    /// `keyed`: the window is the key window Kosmos last heard of. A parked window's return
    /// decides the focus instead.
    public static func decide(keyed: Bool, shown: Bool, parked: Bool, atLaunch: Bool, locked: Bool) -> AdmissionFocus {
        guard !locked, !parked else { return .none }
        if shown { return keyed ? .adopt : atLaunch ? .none : .awaitKey }
        return atLaunch ? .none : .placedHidden
    }
}

/// Whether macOS shows a native fullscreen window's Space, which the app's own panel or
/// dialog keeps shown (docs/focus.md). `fullscreen` gives each such window's app.
public func showsFullscreenSpace(key: KeyWindow?, keyManaged: Bool, keyApp: Int32?,
                                 fullscreen: [WindowID: Int32]) -> Bool {
    guard case .window(let id)? = key else { return false }
    if fullscreen[id] != nil { return true }
    guard !keyManaged, let keyApp else { return false }
    return fullscreen.values.contains(keyApp)
}

/// Classifies key window reports against Kosmos's focus requests by their receipt stamps
/// (docs/focus.md).
public struct FocusReports: Sendable {
    private var expected: [(key: KeyWindow, app: Int32?, requested: ContinuousClock.Instant, publicly: Bool)] = []
    private var lastCommand: ContinuousClock.Instant?
    /// The window whose missed request Kosmos made again.
    private var retried: KeyWindow?

    public init() {}

    public mutating func commandExecuted(receivedAt stamp: ContinuousClock.Instant) {
        lastCommand = stamp
    }

    /// Call it right before the call that changes the key window, so no echo comes first.
    /// `app` is Kosmos for `.emptyWorkspace`.
    public mutating func focusRequested(_ key: KeyWindow, app: Int32?, at stamp: ContinuousClock.Instant, publicly: Bool = false) {
        if key != retried { retried = nil }
        expected.append((key, app, stamp, publicly))
    }

    /// A report from `app` that is no echo answers its public requests, since the public path
    /// lets the app choose the window, and private ones stay until matched (docs/focus.md).
    public mutating func publicRequestsAnswered(by app: Int32, receivedAt stamp: ContinuousClock.Instant) {
        expected.removeAll { $0.publicly && $0.app == app && $0.requested <= stamp }
    }

    /// The latest command wins over a user action received before it (tla/Kosmos.tla, Adopt
    /// and Rejoin).
    public func isStale(_ stamp: ContinuousClock.Instant) -> Bool {
        lastCommand.map { stamp < $0 } ?? false
    }

    public func isEcho(_ key: KeyWindow, receivedAt stamp: ContinuousClock.Instant) -> Bool {
        echo(of: key, receivedAt: stamp) != nil
    }

    private func echo(of key: KeyWindow, receivedAt stamp: ContinuousClock.Instant) -> Int? {
        expected.firstIndex { $0.key == key && $0.requested <= stamp }
    }

    /// Consumes the expectation `key` answers and every one before it. Ceiling: an earlier
    /// echo after a later one reads as the user's choice (docs/focus.md, Deferred).
    public mutating func consumeEcho(_ key: KeyWindow, receivedAt stamp: ContinuousClock.Instant) -> Bool {
        guard let index = echo(of: key, receivedAt: stamp) else { return false }
        expected.removeFirst(index + 1)
        if key == retried { retried = nil }
        return true
    }

    public mutating func forgetRequests() {
        expected.removeAll()
        retried = nil
    }

    public mutating func requestDropped(_ key: KeyWindow, at stamp: ContinuousClock.Instant) {
        if let index = expected.firstIndex(where: { $0.key == key && $0.requested == stamp }) {
            expected.remove(at: index)
        }
    }

    /// Call it for every report, before `classify`. `repeated`: it names the last key window.
    /// Ceiling: a Command-Tab's activation read can be lost as a miss (docs/focus.md, Deferred).
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

    /// `concealed` and `recovered` say whether only the user could reach the window.
    /// `keyLeft` is read only when the verdict needs it, as it can read WindowServer.
    public mutating func classify(_ key: KeyWindow, receivedAt stamp: ContinuousClock.Instant, onShownWorkspace: Bool,
                                  concealed: Bool, recovered: Bool = false, miss: Miss = .none,
                                  keyLeft: @autoclosure () -> Departure) -> ReportVerdict {
        if consumeEcho(key, receivedAt: stamp) { return .echo }
        if isStale(stamp) { return .reassert }
        guard case .window(let id) = key else { return keyLeft() == .left ? .reassert : .ignore }
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

/// The key window Kosmos last heard of and the one before it (tla/Kosmos.tla, KeyLeft). Only
/// the front app's reports go in.
public struct KeyHistory: Sendable {
    public var key: KeyWindow?
    private var before: KeyWindow?

    public init() {}

    /// Returns the window key before `reported`, the one before that for a repeat
    /// (docs/focus.md). A repeat of no key window has none, since any app can report it.
    public mutating func heard(_ reported: KeyWindow) -> KeyWindow? {
        guard reported != key else { return reported == .emptyWorkspace ? .emptyWorkspace : before }
        before = key
        key = reported
        return before
    }
}

/// A report held until Kosmos knows whether the window key before it left (tla/Kosmos.tla,
/// Hold). The grace timer of a replaced or ended hold decides nothing.
public struct HeldReport<Report: Sendable>: Sendable {
    public private(set) var report: Report?
    private var key: KeyWindow?
    private var number = 0

    public init() {}

    /// Returns the number of the report's grace timer.
    public mutating func hold(_ report: Report, of key: KeyWindow) -> Int {
        number += 1
        self.report = report
        self.key = key
        return number
    }

    /// A repeat of the held window is the same activation, as after a miss.
    public func holds(_ key: KeyWindow, repeated: Bool) -> Bool {
        repeated && report != nil && self.key == key
    }

    public mutating func end() -> Report? {
        defer { report = nil }
        return report
    }

    public mutating func expire(_ number: Int) -> Report? {
        guard number == self.number else { return nil }
        return end()
    }
}
