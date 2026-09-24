/// Switches between native tabs, told from windows that come and go (DESIGN.md, section
/// 5.5). AppKit orders the deselected tab's window out: it keeps its id and leaves every
/// Space (kosmos-probe tabs), and WindowServer tags it as it tags a window its app ordered
/// out (alt-tab's measurements on macOS 26). A switch posts 1325 for the incoming tab, 816
/// and 1326 for the outgoing, then 815 for the incoming, within 0.2 ms (kosmos-probe tabs,
/// macOS 27). Closing a tab can destroy it instead, before or after the next tab arrives.
public struct TabSwitches: Sendable {
    /// Two changes this close form one switch. The yabai forks that follow tabs pair within
    /// 250 ms.
    public static let window: Duration = .milliseconds(250)
    /// Each app's last change of order not yet paired.
    private var last: [Int32: (window: WindowID, orderedIn: Bool, at: ContinuousClock.Instant)] = [:]

    public init() {}

    /// A window of `app` was ordered in, or ordered out or destroyed. Returns the switch it
    /// completes: `old`, the tab ordered out or destroyed, and `new`, the tab ordered in.
    public mutating func ordered(_ window: WindowID, in orderedIn: Bool, app: Int32,
                                 at now: ContinuousClock.Instant) -> (old: WindowID, new: WindowID)? {
        if let prior = last[app], prior.orderedIn != orderedIn, prior.window != window, now - prior.at <= Self.window {
            last[app] = nil
            return orderedIn ? (prior.window, window) : (window, prior.window)
        }
        last[app] = (window, orderedIn, now)
        return nil
    }
}

/// The order changes of candidate windows while the session is locked (DESIGN.md, section
/// 5.1). No window is admitted or removed then, yet a tab switch can create or destroy one
/// of its two windows. Every change is held with its time, creations and destroys too, and
/// reported at the unlock in the order it happened, before any change after it, so switches
/// pair as they would have unlocked. The sweep after the unlock then admits and removes
/// windows without reporting their order again.
public struct HeldOrder: Sendable {
    public struct Change: Equatable, Sendable {
        public let window: WindowID
        public let app: Int32
        public let orderedIn: Bool
        public let at: ContinuousClock.Instant

        public init(window: WindowID, app: Int32, orderedIn: Bool, at: ContinuousClock.Instant) {
            self.window = window
            self.app = app
            self.orderedIn = orderedIn
            self.at = at
        }
    }

    private var held: [Change] = []
    /// The order the controller heard last, or hears at the unlock, for windows whose rows
    /// were read, or that were removed, while locked. A window's row can say otherwise until
    /// the sweep after the unlock admits or removes it.
    private var heard: [WindowID: Bool] = [:]

    public init() {}

    /// A window's row was read at `now`. `was` is its order before, nil for a window not
    /// seen before, which counts as ordered out. Returns whether to report its order now;
    /// while locked a change is held instead.
    public mutating func ordered(_ window: WindowID, app: Int32, in orderedIn: Bool, was: Bool?,
                                 at now: ContinuousClock.Instant, locked: Bool) -> Bool {
        let last = heard.removeValue(forKey: window) ?? was ?? false
        guard locked else { return last != orderedIn }
        heard[window] = orderedIn
        if last != orderedIn { held.append(Change(window: window, app: app, orderedIn: orderedIn, at: now)) }
        return false
    }

    /// A window was destroyed at `now`, ordered in or not as its row says. Returns whether
    /// to report it ordered out now; while locked that is held instead.
    public mutating func removed(_ window: WindowID, app: Int32, orderedIn: Bool,
                                 at now: ContinuousClock.Instant, locked: Bool) -> Bool {
        let last = heard.removeValue(forKey: window) ?? orderedIn
        guard locked else { return last }
        heard[window] = false
        if last { held.append(Change(window: window, app: app, orderedIn: false, at: now)) }
        return false
    }

    /// The session is unlocked: the changes held, in the order they happened.
    public mutating func unlocked() -> [Change] {
        defer { held = [] }
        return held
    }

    /// The sweep after the unlock read every window: what it did not read is gone.
    public mutating func swept() {
        heard = [:]
    }
}

/// The tabs of native tab groups that hold no place (DESIGN.md, section 5.5): deselected
/// tabs, hidden members of the place their group's selected tab holds, and tabs selected
/// before Kosmos admitted them, which take their place once admitted. Only admitted windows
/// take places.
public struct TabGroups: Sendable {
    /// What a switch from one tab to another does.
    public enum Switch: Equatable, Sendable {
        /// The new tab takes the place of this tab now.
        case replace(WindowID)
        /// The new tab takes it once Kosmos admits it.
        case pending
        /// The old tab holds no place.
        case none
    }

    /// What admitting a window does.
    public enum Admission: Equatable, Sendable {
        /// A deselected tab: it waits out of the session.
        case hidden
        /// A tab selected before its admission: it takes this tab's place.
        case takes(WindowID)
        /// A window of its own.
        case own
    }

    public private(set) var hidden: Set<WindowID> = []
    private var pending: [WindowID: WindowID] = [:]

    public init() {}

    /// The selected tab changed from `old` to `new`. `admitted`: Kosmos admitted `new`.
    /// `placed`: whether a tab holds a place.
    public mutating func switched(from old: WindowID, to new: WindowID, admitted: Bool,
                                  placed: (WindowID) -> Bool) -> Switch {
        var holder = old
        // A tab deselected before its admission never took its place: its claim passes on,
        // as when Finder opens several tabs or Command-T is pressed twice.
        if let claim = pending.removeValue(forKey: old) {
            hidden.insert(old)
            holder = claim
        }
        guard holder != new, placed(holder) else { return .none }
        guard admitted else {
            pending[new] = holder
            return .pending
        }
        return .replace(holder)
    }

    /// `new` took the place of `old`, which waits as a hidden member.
    public mutating func replaced(_ old: WindowID, with new: WindowID) {
        hidden.remove(new)
        hidden.insert(old)
    }

    public mutating func admitting(_ window: WindowID) -> Admission {
        if hidden.contains(window) { return .hidden }
        if let old = pending.removeValue(forKey: window) { return .takes(old) }
        return .own
    }

    /// A hidden member back on screen with no tab leaving, as a tab dragged out of its
    /// group: true when it was one.
    public mutating func detached(_ window: WindowID) -> Bool {
        hidden.remove(window) != nil
    }

    /// The window is gone.
    public mutating func forget(_ window: WindowID) {
        hidden.remove(window)
        pending[window] = nil
        pending = pending.filter { $0.value != window }
    }
}
