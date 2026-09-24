/// Counts private focus requests that keyed the wrong window, so the private path can turn
/// itself off (DESIGN.md, section 5.4). A request misses when its app reports another of its
/// windows key and no echo of any request arrives before Kosmos's next request. Any echo
/// shows the path working and clears the count, including one that arrives late, after an
/// activation read of the window that was key before.
///
/// Silence is no evidence: a request that changes no report, as when the app does not
/// answer, neither misses nor clears the count.
public struct FocusMisses<Stamp: Comparable & Sendable>: Sendable {
    /// On this Mac the private path keyed the right window in 60 of 60 trials, so its miss
    /// rate is at most about 5% at 95% confidence, and the public path keyed the wrong one in
    /// 9 of 9 (wm-research focus note, section 4). A false trip costs the better path until
    /// a reload and a late one a few wrong windows. Five misses in a row at 5% come once in
    /// about 3 million runs.
    public static var limit: Int { 5 }

    private var pending: (window: UInt32, pid: Int32, requested: Stamp, wrongWindow: Bool)?
    public private(set) var inARow = 0

    public init() {}

    /// Records a private request for `window` of app `pid`, and judges the one before it.
    /// Returns true when that one was the `limit`th miss in a row.
    public mutating func willRequest(_ window: UInt32, pid: Int32, at stamp: Stamp) -> Bool {
        if pending?.wrongWindow == true { inARow += 1 }
        pending = (window, pid, stamp, false)
        return inARow >= Self.limit
    }

    /// A request the focus queue did not perform has nothing to read back.
    public mutating func requestDropped(at stamp: Stamp) {
        if pending?.requested == stamp { pending = nil }
    }

    /// A key window report. `echo` is true when the report classifier matched it to one of
    /// Kosmos's requests.
    public mutating func reported(_ key: KeyWindow, pid: Int32, receivedAt stamp: Stamp, echo: Bool) {
        guard case .window(let window) = key else { return }
        if echo {
            inARow = 0
            pending = nil
        } else if let request = pending, request.pid == pid, request.window != window, request.requested <= stamp {
            pending?.wrongWindow = true
        }
    }
}
