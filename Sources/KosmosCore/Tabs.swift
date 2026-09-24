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
