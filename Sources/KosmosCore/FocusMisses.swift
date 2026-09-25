/// Counts private focus requests that keyed the wrong window, so the private path can turn
/// itself off (docs/focus.md). A request misses when its app reports another of its
/// windows key and no echo of any request arrives before Kosmos's next request. Any echo
/// shows the path working and clears the count, including one that arrives late, after an
/// activation read of the window that was key before.
///
/// Silence is no evidence: a request that changes no report, as when the app does not
/// answer, neither misses nor clears the count.
public struct FocusMisses<Stamp: Comparable & Sendable>: Sendable {
    /// On this Mac AXRaise and then the private sequence keyed the right window in 60 of 60
    /// AutoRaise trials, 9 of them between two windows of the active app, so the miss rate
    /// is at most about 5% at 95% confidence (autoraise-steez trial results, September 8,
    /// 2026). Those trials posted a down and up record pair where Kosmos posts the down
    /// alone, which keyed every case of the hover branch's `kosmos-probe raise` once the
    /// window was raised first. The public path keyed the wrong window in 9 of 9. A false
    /// trip costs the better path until a reload and a late one a few wrong windows. Five
    /// misses in a row at 5% come once in about 3 million runs.
    public static var limit: Int { 5 }

    private var pending: (window: UInt32, pid: Int32, requested: Stamp, wrongWindow: Bool)?
    public private(set) var inARow = 0

    public init() {}

    /// Records a private request for `window` of app `pid`, and judges the one before it.
    /// Returns true when that one was the `limit`th miss in a row. A `retry` of a missed
    /// request (FocusReports.miss) is the same focus attempt: the missed request stays
    /// pending, so the attempt counts at most once.
    public mutating func willRequest(_ window: UInt32, pid: Int32, at stamp: Stamp, retry: Bool = false) -> Bool {
        if retry, pending?.wrongWindow == true { return false }
        if pending?.wrongWindow == true { inARow += 1 }
        pending = (window, pid, stamp, false)
        return inARow >= Self.limit
    }

    /// A request the focus queue did not perform has nothing to read back.
    public mutating func requestDropped(at stamp: Stamp) {
        if pending?.requested == stamp { pending = nil }
    }

    /// A key window report. `echo` is true when the report classifier matched it to one of
    /// Kosmos's requests. A report of the requested window that is no echo also settles the
    /// request: a background report can consume the echo first, and the user's later click
    /// on another window of that app would otherwise count as a miss.
    public mutating func reported(_ key: KeyWindow, pid: Int32, receivedAt stamp: Stamp, echo: Bool) {
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
