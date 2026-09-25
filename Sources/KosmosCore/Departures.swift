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
