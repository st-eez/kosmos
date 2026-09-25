/// When windows left the screen, from the first word of each departure (DESIGN.md, section
/// 5.4). Accessibility reports a minimize as it starts, and NSWorkspace can report a hide
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

/// What a departure of Kosmos's focus does, when it minimized, hid with its app, or was
/// closed and kept by its app (tla/Kosmos.tla, Depart).
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
    ///   - closed: its app closed the window and kept it. A close keys the app's next window
    ///     as it happens, and the window counts as closed a pairing window later
    ///     (ClosedAndKept), so any report of that key change has come: the focus is replaced
    ///     at once, as a closed window's is.
    ///   - key: the key window macOS last reported.
    ///   - departing: the windows that left together.
    ///   - left: whether a window left the screen just now.
    public static func decide(focusLeft: Bool, closed: Bool = false, key: KeyWindow?, departing: [WindowID],
                              left: (WindowID) -> Bool) -> DepartureFocus {
        guard focusLeft else { return .none }
        guard !closed, case .window(let id)? = key, departing.contains(id) || left(id) else { return .now }
        return .afterKeyReport
    }
}

/// When a managed window its app ordered out counts as closed and kept, as a closed
/// NSWindowController window does (DESIGN.md, section 5.5): still ordered out after a wait,
/// for none of the reasons with reports of their own.
public enum ClosedAndKept {
    /// The wait while a native fullscreen transition may be under way. A transition orders
    /// its window out for about 0.53 s: entering, from 84 ms after toggleFullScreen to 612 ms,
    /// and leaving, from 225 ms to 751 ms (kosmos-probe fullscreen, September 23, 2026).
    public static let longWait: Duration = .seconds(1)

    /// How long after its order-out at `orderedOut` the window is judged. A native tab switch
    /// pairs within the tab pairing window, so a deselected tab has left the session by then.
    /// A native fullscreen transition created Spaces 37 to 46 ms before its order-out on the
    /// way in and 193 ms before on the way out, and a window leaving still counts as in
    /// fullscreen at its order-out, until it joins the desktop Space 318 ms later. So a
    /// window in fullscreen, or ordered out within `longWait` of the last Space event at
    /// `spacesChanged`, waits `longWait`. A close posts
    /// no Space event: a probe panel's close posted its order-out, then its leaving its Space,
    /// in one millisecond (Kosmos's debug log, September 23, 2026).
    public static func wait(orderedOut: ContinuousClock.Instant, fullscreen: Bool,
                            spacesChanged: ContinuousClock.Instant?) -> Duration {
        let transition = fullscreen || spacesChanged.map { orderedOut - $0 < longWait } == true
        return transition ? longWait : TabSwitches.window
    }

    /// How much longer a window judged at `now` waits, or nil to park it now. A new tab
    /// Kosmos has not admitted yet claims its place and takes it once admitted
    /// (TabGroups.switched), and parking the window first would reflow twice. A claimed
    /// window waits for the admission until `longWait` after its order-out, then parks.
    public static func claimWait(orderedOut: ContinuousClock.Instant, claimed: Bool,
                                 at now: ContinuousClock.Instant) -> Duration? {
        guard claimed, now - orderedOut < longWait else { return nil }
        return orderedOut + longWait - now
    }
}
