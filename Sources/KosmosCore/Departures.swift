/// When windows left the screen, from the first report of each departure: Accessibility
/// reports a minimize as it starts, and NSWorkspace a hide before WindowServer orders the
/// app's windows out (docs/focus.md).
public struct DepartureLog: Sendable {
    private var leftAt: [WindowID: ContinuousClock.Instant] = [:]
    /// How long a departure counts as just now.
    public let bound: Duration

    public init(bound: Duration) {
        self.bound = bound
    }

    public mutating func left(_ window: WindowID, at now: ContinuousClock.Instant) {
        leftAt = leftAt.filter { now - $0.value <= bound }
        leftAt[window] = now
    }

    public mutating func returned(_ window: WindowID) {
        leftAt[window] = nil
    }

    /// Only a change counts: a hidden app's rows read ordered in until WindowServer orders its
    /// windows out.
    public mutating func ordered(_ window: WindowID, in orderedIn: Bool, was old: Bool?, at now: ContinuousClock.Instant) {
        if orderedIn, old == false {
            returned(window)
        } else if !orderedIn, old == true {
            left(window, at: now)
        }
    }

    /// Nil when no departure is on record.
    public func justLeft(_ window: WindowID, at now: ContinuousClock.Instant) -> Bool? {
        leftAt[window].map { now - $0 <= bound }
    }
}

/// What a departure of Kosmos's focus does (tla/Kosmos.tla, Depart).
public enum DepartureFocus: Equatable, Sendable {
    case none
    /// Focus the workspace's next window now.
    case now
    /// macOS keys another window itself, and its report focuses: focusing first could put
    /// Kosmos's echo between the departure and that report. The departure bound caps the wait.
    case afterKeyReport

    /// Another candidate window of the app whose key window closed.
    public struct OtherWindow: Equatable, Sendable {
        public let orderedIn: Bool
        public let minimized: Bool

        public init(orderedIn: Bool, minimized: Bool) {
            self.orderedIn = orderedIn
            self.minimized = minimized
        }

        /// A concealed window stays ordered in (kosmos-probe reveal), and macOS keys concealed
        /// windows (docs/focus.md).
        var keyable: Bool { orderedIn && !minimized }
    }

    /// - Parameter remaining: the app's other candidate windows when its key window closed and
    ///   was kept, and nil for a minimize or a hide. With none macOS can key, no report comes
    ///   (docs/focus.md).
    public static func decide(focusLeft: Bool, key: KeyWindow?, departing: [WindowID],
                              left: (WindowID) -> Bool, remaining: [OtherWindow]? = nil) -> DepartureFocus {
        guard focusLeft else { return .none }
        guard case .window(let id)? = key, departing.contains(id) || left(id) else { return .now }
        if let remaining, !remaining.contains(where: \.keyable) { return .now }
        return .afterKeyReport
    }
}
