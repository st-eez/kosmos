/// Window events waiting for one WindowServer read of every window they name, in the order
/// they came. The inventory reads the rows off the main thread, then applies each event in
/// that order, so an event never applies before one that came first (DESIGN.md, section 5.1).
/// `FollowUp` is what the inventory does after applying a window's row.
public struct PendingReads<FollowUp> {
    public enum Event {
        /// The window changed: read its row again.
        case read(WindowID, FollowUp)
        /// WindowServer destroyed the window.
        case destroyed(WindowID)
        /// The app exited.
        case appExited(Int32)
    }

    public enum Action {
        /// The read found the window: apply its row.
        case apply(WindowID, FollowUp)
        /// The read found no such window: WindowServer no longer has it.
        case gone(WindowID, FollowUp)
        case destroyed(WindowID)
        case appExited(Int32)
    }

    private var events: [Event] = []

    public init() {}

    public var isEmpty: Bool { events.isEmpty }

    public mutating func add(_ event: Event) {
        events.append(event)
    }

    /// Takes every waiting event, with the windows to read for them, each once, in the
    /// order they were first named.
    public mutating func take() -> (events: [Event], windows: [WindowID]) {
        defer { events = [] }
        var seen: Set<WindowID> = []
        let windows = events.compactMap { event -> WindowID? in
            guard case .read(let id, _) = event, seen.insert(id).inserted else { return nil }
            return id
        }
        return (events, windows)
    }

    /// Each event as what to do, in the order the events came, given the windows the read
    /// found.
    public static func actions(_ events: [Event], found: Set<WindowID>) -> [Action] {
        events.map { event in
            switch event {
            case .read(let id, let followUp): found.contains(id) ? .apply(id, followUp) : .gone(id, followUp)
            case .destroyed(let id): .destroyed(id)
            case .appExited(let pid): .appExited(pid)
            }
        }
    }
}

extension PendingReads: Sendable where FollowUp: Sendable {}
extension PendingReads.Event: Sendable where FollowUp: Sendable {}
extension PendingReads.Action: Sendable where FollowUp: Sendable {}
extension PendingReads.Event: Equatable where FollowUp: Equatable {}
extension PendingReads.Action: Equatable where FollowUp: Equatable {}
