/// Kosmos spawns kosmos-guardian again a second after it exits or fails to start, and gives
/// up after `limit` in `window`, as one that keeps dying cannot restore windows: hiding then
/// stays off (docs/overview.md, section 4.1).
public struct GuardianRestarts: Sendable {
    public static let limit = 3
    public static let window: Duration = .seconds(10)

    private var recent: [ContinuousClock.Instant] = []

    public init() {}

    /// True to spawn it again, false to give up.
    public mutating func failed(at now: ContinuousClock.Instant) -> Bool {
        recent = recent.filter { now - $0 < Self.window } + [now]
        return recent.count <= Self.limit
    }
}
