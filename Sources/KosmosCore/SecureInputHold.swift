/// When the Secure Input badge shows: once a hold has lasted `delay`, as most holds last
/// about 35 ms and a badge at each would flicker (docs/hotkeys.md).
public struct SecureInputHold {
    public static var delay: Duration { .milliseconds(500) }

    /// When Secure Input turned on, nil while it is off. A new holder keeps the hold going.
    public private(set) var since: ContinuousClock.Instant?

    public init() {}

    public mutating func update(on: Bool, at now: ContinuousClock.Instant) {
        if !on {
            since = nil
        } else if since == nil {
            since = now
        }
    }

    /// When the badge is due, while Secure Input is on.
    public var due: ContinuousClock.Instant? { since.map { $0 + Self.delay } }

    public func shows(at now: ContinuousClock.Instant) -> Bool {
        guard let due else { return false }
        return now >= due
    }
}
