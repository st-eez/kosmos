/// When the Secure Input overlay shows: once a hold has lasted `delay`, as most holds last
/// about 35 ms and a panel at each would flicker (docs/hotkeys.md).
public struct SecureInputHold<Holder: Equatable> {
    public static var delay: Duration { .milliseconds(500) }

    public private(set) var holder: Holder?
    /// When Secure Input turned on. A new holder while it stays on keeps the hold going.
    public private(set) var since: ContinuousClock.Instant?

    public init() {}

    /// `holder`: nil once Secure Input is off.
    public mutating func update(_ holder: Holder?, at now: ContinuousClock.Instant) {
        if holder == nil {
            since = nil
        } else if self.holder == nil {
            since = now
        }
        self.holder = holder
    }

    /// When the overlay is due, while Secure Input is on.
    public var due: ContinuousClock.Instant? { since.map { $0 + Self.delay } }

    /// The holder the overlay names at `now`, nil for no overlay.
    public func shown(at now: ContinuousClock.Instant) -> Holder? {
        guard let due, now >= due else { return nil }
        return holder
    }
}
