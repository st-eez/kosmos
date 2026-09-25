/// When each window was last concealed or revealed, to judge a report by whether its window
/// was hidden at the report's stamp (docs/focus.md; tla/README.md, change 19).
public struct ConcealHistory: Sendable {
    private var last: [WindowID: (concealed: Bool, at: ContinuousClock.Instant)] = [:]

    public init() {}

    public mutating func changed(_ windows: [WindowID], concealed: Bool, at stamp: ContinuousClock.Instant) {
        for window in windows { last[window] = (concealed, stamp) }
    }

    public mutating func forgetAll() {
        last.removeAll()
    }

    public mutating func forget(_ window: WindowID) {
        last[window] = nil
    }

    /// `now`: whether the window is concealed now, for a window with no change recorded.
    public func wasConcealed(_ window: WindowID, at stamp: ContinuousClock.Instant, now: Bool) -> Bool {
        guard let change = last[window] else { return now }
        return change.at <= stamp ? change.concealed : !change.concealed
    }
}
