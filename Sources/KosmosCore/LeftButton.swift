/// The inventory applies a window change after reading its row off the main thread, so the
/// change is judged by the press on when it came (docs/geometry.md).
public struct LeftButton: Sendable {
    public enum State: Equatable, Sendable {
        case up
        case down
        /// A press was on, and its mouse up has come since.
        case released
    }

    private var down: ContinuousClock.Instant?
    private var lastPress: Range<ContinuousClock.Instant>?

    public init() {}

    public mutating func pressed(at now: ContinuousClock.Instant) {
        down = now
    }

    public mutating func released(at now: ContinuousClock.Instant) {
        lastPress = down.map { $0..<now }
        down = nil
    }

    /// Ceiling: only the last press that ended is kept, so a change from an earlier press reads
    /// as up. Keeping the presses back to the oldest change waiting to apply would cover it.
    public func state(at stamp: ContinuousClock.Instant) -> State {
        if let down, down <= stamp { return .down }
        return lastPress?.contains(stamp) == true ? .released : .up
    }
}
