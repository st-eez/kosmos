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
        guard reported != key else { return reported == .emptyWorkspace ? .emptyWorkspace : before }
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

    /// Another candidate window of the app whose key window closed, as the inventory has it.
    public struct OtherWindow: Equatable, Sendable {
        public let orderedIn: Bool
        public let minimized: Bool

        public init(orderedIn: Bool, minimized: Bool) {
            self.orderedIn = orderedIn
            self.minimized = minimized
        }

        /// macOS can key it: ordered in and not minimized. A concealed window stays ordered
        /// in (kosmos-probe reveal), and macOS keys concealed windows (docs/focus.md).
        var keyable: Bool { orderedIn && !minimized }
    }

    /// - Parameters:
    ///   - key: the key window macOS last reported.
    ///   - departing: the windows that left together.
    ///   - left: whether a window left the screen just now.
    ///   - remaining: for a window its app closed and kept, the app's other candidate
    ///     windows; nil for a minimize or a hide. With none macOS can key, the app stays
    ///     front with no window and no report comes, so the departure focuses now. With
    ///     one, macOS keys it as the window closes, and the departure waits for that report.
    public static func decide(focusLeft: Bool, key: KeyWindow?, departing: [WindowID],
                              left: (WindowID) -> Bool, remaining: [OtherWindow]? = nil) -> DepartureFocus {
        guard focusLeft else { return .none }
        guard case .window(let id)? = key, departing.contains(id) || left(id) else { return .now }
        if let remaining, !remaining.contains(where: \.keyable) { return .now }
        return .afterKeyReport
    }
}

/// When a managed window its app ordered out counts as closed and kept, as a closed
/// NSWindowController window does: still ordered out, for none of the reasons with reports
/// of their own (docs/tree.md). The inventory looks at it when Looks says, and `hold`
/// decides whether it waits more.
public enum ClosedAndKept {
    /// Outlasts a native fullscreen transition's order-out (docs/tree.md).
    static let longWait: Duration = .seconds(1)

    /// How much longer a window still ordered out at `now` waits, or nil to park it now. It
    /// waits until `longWait` after its order-out at `orderedOut` while a native fullscreen
    /// transition may be under way: the last Space event, at `spacesChanged`, came within
    /// `longWait` before the order-out or since. It waits too while a new tab Kosmos has not
    /// admitted yet claims its place, and until a tab pairing window after its order-out
    /// while its app has another window ordered out (`sibling`), a deselected tab that the
    /// other half of a switch may be ordering in (docs/tree.md).
    public static func hold(orderedOut: ContinuousClock.Instant, claimed: Bool, sibling: Bool,
                            spacesChanged: ContinuousClock.Instant?, at now: ContinuousClock.Instant) -> Duration? {
        let transition = spacesChanged.map { orderedOut - $0 < longWait } == true
        let wait: Duration = claimed || transition ? longWait : sibling ? TabSwitches.window : .zero
        guard now - orderedOut < wait else { return nil }
        return orderedOut + wait - now
    }

    /// The managed windows seen ordered out, waiting for their look until no read of window
    /// rows is under way and no event waits for one. A native tab switch's two halves came
    /// within 0.2 ms of each other (kosmos-probe tabs), so a switch whose halves came in
    /// separate reads has paired by then, and a close is looked at when the read that saw
    /// its order-out is applied. A half whose event reaches the main queue only after the
    /// other half's read came back is neither a read under way nor an event waiting, and
    /// `hold` waits for it while the app has another window ordered out.
    public struct Looks: Sendable {
        private var waiting: [(window: WindowID, orderedOut: ContinuousClock.Instant)] = []
        private var reads = 0

        public init() {}

        /// A read of window rows was asked for: a batch of events or a sweep.
        public mutating func readAsked() {
            reads += 1
        }

        /// A managed window was seen ordered out at `at`, in the read being applied.
        public mutating func orderedOut(_ window: WindowID, at: ContinuousClock.Instant) {
            waiting.append((window, at))
        }

        /// A read was applied. Returns the windows to look at now, with when each was seen
        /// ordered out: every one waiting once no other read is under way and no event waits
        /// for one (`eventsWaiting`), else none.
        public mutating func readApplied(eventsWaiting: Bool) -> [(window: WindowID, orderedOut: ContinuousClock.Instant)] {
            reads -= 1
            guard reads == 0, !eventsWaiting else { return [] }
            defer { waiting = [] }
            return waiting
        }
    }
}
