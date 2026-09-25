/// Counts private focus requests that keyed another window of their app, so the private
/// path can turn itself off (docs/focus.md, the kill switch). Any echo clears the count, and
/// a request with no report neither misses nor clears it.
public struct FocusMisses: Sendable {
    /// The private path keyed the right window in 60 of 60 trials, a miss rate of at most 5%,
    /// so five misses in a row come once in about 3 million runs (docs/focus.md).
    public static let limit = 5

    private var pending: (window: WindowID, pid: Int32, requested: ContinuousClock.Instant, wrongWindow: Bool)?
    public private(set) var inARow = 0

    public init() {}

    /// Judges the request before this one, and returns true once it is the `limit`th miss in
    /// a row. A `retry` (FocusReports.miss) is the missed request's attempt, which counts once.
    public mutating func willRequest(_ window: WindowID, pid: Int32, at stamp: ContinuousClock.Instant, retry: Bool = false) -> Bool {
        if retry, pending?.wrongWindow == true { return false }
        if pending?.wrongWindow == true { inARow += 1 }
        pending = (window, pid, stamp, false)
        return inARow >= Self.limit
    }

    public mutating func requestDropped(at stamp: ContinuousClock.Instant) {
        if pending?.requested == stamp { pending = nil }
    }

    /// `echo`: FocusReports matched the report to a request. A report of the requested window
    /// settles the request even as no echo, since a background report can consume the echo.
    public mutating func reported(_ key: KeyWindow, pid: Int32, receivedAt stamp: ContinuousClock.Instant, echo: Bool) {
        guard case .window(let window) = key else { return }
        if echo {
            inARow = 0
            pending = nil
        } else if let request = pending, request.pid == pid, request.requested <= stamp {
            if request.window == window {
                pending = nil
            } else {
                pending?.wrongWindow = true
            }
        }
    }
}
