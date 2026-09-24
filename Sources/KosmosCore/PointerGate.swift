import CoreGraphics

/// Decides which pointer movements focus follows mouse looks at (DESIGN.md, section 5.11).
/// It runs in the event tap's callback, so it only compares numbers.
public struct PointerGate: Sendable {
    /// The pointer must move at least this far, in points, from where it last counted.
    public static let minimumMovement: CGFloat = 2

    private var anchor: CGPoint?
    /// The window the last admitted movement found under the pointer.
    private var window: UInt32?

    public init() {}

    /// Whether a movement to `point`, with `window` under the pointer as WindowServer found
    /// it, goes on to the main actor: the pointer moved at least `minimumMovement` since the
    /// last movement that counted, the pause key is up, and the pointer entered another
    /// window than the last admitted movement found. A movement while paused still counts
    /// as movement, so after the key is released the next one focuses the window under
    /// the pointer.
    public mutating func admit(_ point: CGPoint, over window: UInt32, paused: Bool) -> Bool {
        if let anchor {
            let dx = point.x - anchor.x, dy = point.y - anchor.y
            guard dx * dx + dy * dy >= Self.minimumMovement * Self.minimumMovement else { return false }
        }
        anchor = point
        guard !paused, window != self.window else { return false }
        self.window = window
        return true
    }
}
