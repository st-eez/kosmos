import CoreGraphics

/// A native tab switch orders the deselected tab's window out, or destroys it, and orders the
/// selected tab's in. Only two windows with one frame pair, as the tabs of a group share
/// theirs (kosmos-probe tabs, docs/tree.md).
public struct TabSwitches: Sendable {
    /// Two changes this close form one switch, as in the yabai forks that follow tabs.
    public static let window: Duration = .milliseconds(250)
    private struct Change {
        let window: WindowID
        let orderedIn: Bool
        let frame: CGRect
        let at: ContinuousClock.Instant
    }
    /// Oldest first, within the pairing window.
    private var unpaired: [Int32: [Change]] = [:]

    public init() {}

    /// A destroy comes as `orderedIn` false. Returns the switch the change completes.
    public mutating func ordered(_ window: WindowID, in orderedIn: Bool, frame: CGRect, app: Int32,
                                 at now: ContinuousClock.Instant) -> (old: WindowID, new: WindowID)? {
        // A window's newer change replaces its older one: a window back is no switch.
        var changes = (unpaired[app] ?? []).filter { now - $0.at <= Self.window && $0.window != window }
        defer { unpaired[app] = changes.isEmpty ? nil : changes }
        if let index = changes.lastIndex(where: { $0.orderedIn != orderedIn && $0.frame == frame }) {
            let prior = changes.remove(at: index)
            return orderedIn ? (prior.window, window) : (window, prior.window)
        }
        changes.append(Change(window: window, orderedIn: orderedIn, frame: frame, at: now))
        return nil
    }
}

/// A managed window its app ordered out for none of the reasons with reports of their own,
/// as a closed NSWindowController window (docs/tree.md).
public enum ClosedAndKept {
    /// Outlasts a native fullscreen transition's order-out (docs/tree.md).
    static let longWait: Duration = .seconds(1)

    /// How much longer a window still ordered out at `now` waits, or nil to park it now. A
    /// `sibling` is another window of its app ordered out, which a tab switch may order in.
    public static func hold(orderedOut: ContinuousClock.Instant, claimed: Bool, sibling: Bool,
                            spacesChanged: ContinuousClock.Instant?, at now: ContinuousClock.Instant) -> Duration? {
        let transition = spacesChanged.map { orderedOut - $0 < longWait } == true
        let wait: Duration = claimed || transition ? longWait : sibling ? TabSwitches.window : .zero
        guard now - orderedOut < wait else { return nil }
        return orderedOut + wait - now
    }

    /// Windows seen ordered out wait for their look until no read of window rows is under
    /// way and no event waits for one, so a tab switch split across two reads pairs first
    /// (docs/tree.md).
    public struct Looks: Sendable {
        private var waiting: [(window: WindowID, orderedOut: ContinuousClock.Instant)] = []
        private var reads = 0

        public init() {}

        /// For a batch of events or a sweep.
        public mutating func readAsked() {
            reads += 1
        }

        public mutating func orderedOut(_ window: WindowID, at: ContinuousClock.Instant) {
            waiting.append((window, at))
        }

        /// Every window waiting, once no other read is under way and no event waits for one.
        public mutating func readApplied(eventsWaiting: Bool) -> [(window: WindowID, orderedOut: ContinuousClock.Instant)] {
            reads -= 1
            guard reads == 0, !eventsWaiting else { return [] }
            defer { waiting = [] }
            return waiting
        }
    }
}

/// Order changes of candidate windows while the session is locked, reported at the unlock in
/// the order they happened, so tab switches pair as they would have (docs/inventory.md).
public struct HeldOrder: Sendable {
    public struct Change: Equatable, Sendable {
        public let window: WindowID
        public let app: Int32
        public let orderedIn: Bool
        public let frame: CGRect
        public let at: ContinuousClock.Instant

        public init(window: WindowID, app: Int32, orderedIn: Bool, frame: CGRect, at: ContinuousClock.Instant) {
            self.window = window
            self.app = app
            self.orderedIn = orderedIn
            self.frame = frame
            self.at = at
        }
    }

    private var held: [Change] = []
    /// Whether the controller heard each window read or removed while locked ordered in, as
    /// of the unlock. A row can say otherwise until the sweep after the unlock.
    private var heard: [WindowID: Bool] = [:]

    public init() {}

    /// `was` is nil for a window not seen before, which counts as ordered out. Returns whether
    /// to report its order now; while locked a change is held instead.
    public mutating func ordered(_ window: WindowID, app: Int32, in orderedIn: Bool, was: Bool?, frame: CGRect,
                                 at now: ContinuousClock.Instant, locked: Bool) -> Bool {
        let last = heard.removeValue(forKey: window) ?? was ?? false
        guard locked else { return last != orderedIn }
        heard[window] = orderedIn
        if last != orderedIn {
            held.append(Change(window: window, app: app, orderedIn: orderedIn, frame: frame, at: now))
        }
        return false
    }

    /// Returns whether to report the destroyed window ordered out now; while locked that is
    /// held instead.
    public mutating func removed(_ window: WindowID, app: Int32, orderedIn: Bool, frame: CGRect,
                                 at now: ContinuousClock.Instant, locked: Bool) -> Bool {
        let last = heard.removeValue(forKey: window) ?? orderedIn
        guard locked else { return last }
        heard[window] = false
        if last { held.append(Change(window: window, app: app, orderedIn: false, frame: frame, at: now)) }
        return false
    }

    /// In the order they happened.
    public mutating func unlocked() -> [Change] {
        defer { held = [] }
        return held
    }

    /// The sweep after the unlock read every window, so what it did not read is gone.
    public mutating func swept() {
        heard = [:]
    }
}

/// Tabs that hold no place: deselected tabs, hidden members of their group's place, and tabs
/// selected before their admission, which take the place once admitted (docs/tree.md).
public struct TabGroups: Sendable {
    public enum Switch: Equatable, Sendable {
        /// The new tab takes the place of this tab now.
        case replace(WindowID)
        /// The new tab takes it once Kosmos admits it.
        case pending
        /// The old tab holds no place.
        case none
    }

    public enum Admission: Equatable, Sendable {
        /// A deselected tab: it waits out of the session.
        case hidden
        /// A tab selected before its admission: it takes this tab's place.
        case takes(WindowID)
        case own
    }

    public private(set) var hidden: Set<WindowID> = []
    private var pending: [WindowID: WindowID] = [:]

    public init() {}

    /// `sharesFrame` is asked of the holder a claim passes the place to, since the pairing
    /// compared only the two windows that switched, so no window takes a native fullscreen
    /// tab's parked place without its frame.
    public mutating func switched(from old: WindowID, to new: WindowID, admitted: Bool,
                                  placed: (WindowID) -> Bool, sharesFrame: (WindowID) -> Bool) -> Switch {
        var holder = old
        // A tab deselected before its admission never took its place, so its claim passes on.
        if let claim = pending.removeValue(forKey: old) {
            hidden.insert(old)
            guard sharesFrame(claim) else { return .none }
            holder = claim
        }
        guard holder != new, placed(holder) else { return .none }
        guard admitted else {
            pending[new] = holder
            return .pending
        }
        return .replace(holder)
    }

    public mutating func replaced(_ old: WindowID, with new: WindowID) {
        hidden.remove(new)
        hidden.insert(old)
    }

    /// Whether a tab selected before its admission claims `window`'s place.
    public func isClaimed(_ window: WindowID) -> Bool {
        pending.values.contains(window)
    }

    public mutating func admitting(_ window: WindowID) -> Admission {
        if hidden.contains(window) { return .hidden }
        if let old = pending.removeValue(forKey: window) { return .takes(old) }
        return .own
    }

    /// A hidden member back on screen with no tab leaving, as a tab dragged out of its group.
    /// True when it was one.
    public mutating func detached(_ window: WindowID) -> Bool {
        hidden.remove(window) != nil
    }

    public mutating func forget(_ window: WindowID) {
        hidden.remove(window)
        pending[window] = nil
        pending = pending.filter { $0.value != window }
    }
}
