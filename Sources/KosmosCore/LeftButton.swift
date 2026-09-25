/// The left button's presses as Kosmos's global monitors hear them. The inventory applies a
/// window change after reading its row off the main thread, so the change is judged by the
/// press on when it came (DESIGN.md, section 5.2).
public struct LeftButton: Sendable {
    public enum State: Equatable, Sendable {
        /// No press was on.
        case up
        /// A press was on and still is.
        case down
        /// A press was on and its mouse up has come since.
        case released
    }

    /// When the button went down, while it is down.
    private var down: ContinuousClock.Instant?
    /// The last press that ended.
    private var last: Range<ContinuousClock.Instant>?

    public init() {}

    public mutating func pressed(at now: ContinuousClock.Instant) {
        down = now
    }

    public mutating func released(at now: ContinuousClock.Instant) {
        last = down.map { $0..<now }
        down = nil
    }

    /// The press on at `stamp`, and whether it still is.
    ///
    /// Ceiling: only the last press that ended is kept, so a change that came during an
    /// earlier one reads as up once two mouse ups have come before it applies. Keeping the
    /// presses back to the oldest change waiting to apply would cover it.
    public func state(at stamp: ContinuousClock.Instant) -> State {
        if let down, down <= stamp { return .down }
        return last?.contains(stamp) == true ? .released : .up
    }
}
