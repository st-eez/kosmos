/// When windows left the screen, from the first word of each departure (docs/focus.md).
/// Accessibility reports a minimize as it starts, and NSWorkspace can report a hide
/// before WindowServer orders the app's windows out.
public struct DepartureLog: Sendable {
    private var leftAt: [WindowID: ContinuousClock.Instant] = [:]
    /// How long a departure counts as just now.
    public let bound: Duration

    public init(bound: Duration) {
        self.bound = bound
    }

    /// The window left: it closed or minimized, its app hid, or WindowServer ordered it out.
    public mutating func left(_ window: WindowID, at now: ContinuousClock.Instant) {
        leftAt = leftAt.filter { now - $0.value <= bound }
        leftAt[window] = now
    }

    /// The window is back: restored, or its app unhid.
    public mutating func returned(_ window: WindowID) {
        leftAt[window] = nil
    }

    /// WindowServer read the window's order. Only a change counts: before WindowServer
    /// orders a hidden app's windows out, their rows still read ordered in.
    public mutating func ordered(_ window: WindowID, in orderedIn: Bool, was old: Bool?, at now: ContinuousClock.Instant) {
        if orderedIn, old == false {
            returned(window)
        } else if !orderedIn, old == true {
            left(window, at: now)
        }
    }

    /// Whether the window left within the bound before `now`, or nil when no departure is
    /// on record.
    public func justLeft(_ window: WindowID, at now: ContinuousClock.Instant) -> Bool? {
        leftAt[window].map { now - $0 <= bound }
    }
}

/// The key window Kosmos last heard of and the one before it, by which a report is judged to
/// follow a departure (tla/Kosmos.tla, ObserveSplit and KeyLeft). Only key window reports
/// change them; a report from an app that is not front does not.
public struct KeyHistory: Sendable {
    /// The key window macOS last reported.
    public var key: KeyWindow?
    private var before: KeyWindow?

    public init() {}

    /// Hears a key window report and returns the window key before it. A report that
    /// repeats the window last heard of, as an activation read after its app's notification
    /// of the same change does, has the window before that one. Otherwise, after the key
    /// window left and macOS keyed a concealed window, the notification would keep the
    /// workspace and the read would follow that re-key (tla/README.md, change 24). A
    /// repeated report of no key window has none: any app can make it, as Finder fronted by
    /// a click on the desktop after the empty workspace's window was keyed.
    public mutating func heard(_ reported: KeyWindow) -> KeyWindow? {
        guard reported != key else { return reported == .none ? KeyWindow.none : before }
        before = key
        key = reported
        return before
    }
}

/// A key window report held until Kosmos knows whether the window key before it left
/// (tla/Kosmos.tla, Hold). The grace decides it. Each hold carries the number of its grace
/// timer, so a timer of a replaced or ended hold decides nothing.
public struct HeldReport<Report: Sendable>: Sendable {
    public private(set) var report: Report?
    private var key: KeyWindow?
    private var number = 0

    public init() {}

    /// Holds `report` of `key` in place of any held one, and returns the number of its grace
    /// timer.
    public mutating func hold(_ report: Report, of key: KeyWindow) -> Int {
        number += 1
        self.report = report
        self.key = key
        return number
    }

    /// A report that repeats the held window is the same activation, as after a miss: it
    /// leaves the hold standing.
    public func holds(_ key: KeyWindow, repeated: Bool) -> Bool {
        repeated && report != nil && self.key == key
    }

    /// A newer activation of a window ends the hold. Returns the report it ended.
    public mutating func end() -> Report? {
        defer { report = nil }
        return report
    }

    /// The grace numbered `number` ended: the report to decide, if that hold still stands.
    public mutating func expire(_ number: Int) -> Report? {
        guard number == self.number else { return nil }
        return end()
    }
}

/// What a departure of Kosmos's focus does, when it minimized or hid with its app
/// (tla/Kosmos.tla, Leaves).
public enum DepartureFocus: Equatable, Sendable {
    /// The focus stayed: nothing to do.
    case none
    /// Focus the workspace's next window, or the empty workspace's, now.
    case now
    /// The key window left too, so macOS keys another window itself, and that report
    /// focuses. Focusing first could put Kosmos's echo between the departure and that
    /// report. A report that never comes is bounded by the departure bound.
    case afterKeyReport

    /// - Parameters:
    ///   - key: the key window macOS last reported.
    ///   - departing: the windows that left together.
    ///   - left: whether a window left the screen just now.
    public static func decide(focusLeft: Bool, key: KeyWindow?, departing: [WindowID],
                              left: (WindowID) -> Bool) -> DepartureFocus {
        guard focusLeft else { return .none }
        guard case .window(let id)? = key, departing.contains(id) || left(id) else { return .now }
        return .afterKeyReport
    }
}
