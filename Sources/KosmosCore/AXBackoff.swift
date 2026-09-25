/// Whether an app's Accessibility worker calls the app, and whether it asks the app every
/// 0.5 s if it answers again (docs/geometry.md).
public struct AXBackoff: Sendable {
    /// When a call first waited out the timeout, or nil while calls go to the app.
    public private(set) var since: ContinuousClock.Instant?
    public private(set) var asking = false

    public var backedOff: Bool { since != nil }

    public init() {}

    /// True when asking starts now.
    public mutating func timedOut(at instant: ContinuousClock.Instant) -> Bool {
        if since == nil { since = instant }
        return startAsking()
    }

    /// The worker did not start during its launch retries. True when asking starts now.
    public mutating func notStarted() -> Bool {
        startAsking()
    }

    /// When the backoff began, or nil when the worker had only not started.
    public mutating func answered() -> ContinuousClock.Instant? {
        defer { since = nil }
        return since
    }

    /// After the calls that follow an answer: true when asking stops.
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
