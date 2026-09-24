/// When an app's Accessibility worker calls the app, and when it asks the app again every
/// 0.5 s (DESIGN.md, section 5.2). A call that waits out the timeout backs the app off, and
/// no call goes to it. An answer to the probe lets calls go again. Asking stops only once the
/// calls after that answer, which start the worker or write the frames held meanwhile, got
/// answers too, and the worker has started.
public struct AXBackoff<Instant: Sendable>: Sendable {
    /// When the app let a call wait out the timeout, while no call goes to it.
    public private(set) var since: Instant?
    /// Whether the worker asks the app every 0.5 s.
    public private(set) var asking = false

    public var backedOff: Bool { since != nil }

    public init() {}

    /// A call waited out the timeout. Returns true when asking starts now.
    public mutating func timedOut(at instant: Instant) -> Bool {
        if since == nil { since = instant }
        return startAsking()
    }

    /// The worker did not start during its launch retries. Returns true when asking starts
    /// now.
    public mutating func notStarted() -> Bool {
        startAsking()
    }

    /// The app answered the probe, and calls go to it again. Returns when the backoff began,
    /// or nil when the worker had only not started.
    public mutating func answered() -> Instant? {
        defer { since = nil }
        return since
    }

    /// After the calls that follow an answer. Returns true when asking stops: the worker has
    /// started and none of those calls timed out.
    public mutating func settled(started: Bool) -> Bool {
        guard started, since == nil else { return false }
        asking = false
        return true
    }

    private mutating func startAsking() -> Bool {
        defer { asking = true }
        return !asking
    }
}
