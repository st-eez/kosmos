import CoreGraphics

/// A tiled window of a shown workspace seen smaller than its tile gets the tile written again,
/// at most `limit` times in `span`, then not until its tile changes (docs/geometry.md).
public struct TileRewrites: Sendable {
    public static let limit = 3
    public static let span: Duration = .seconds(5)

    public enum Decision: Equatable, Sendable {
        case none
        /// The tile is written again, the `Int`th time in `span`.
        case rewrite(Int)
        /// Once a tile, when one more would pass the limit.
        case gaveUp
    }

    private struct Window {
        let tile: CGRect
        var rewrites: [ContinuousClock.Instant] = []
        var gaveUp = false
        /// When the window was first seen smaller, until a read back shows it at its tile.
        var since: ContinuousClock.Instant?
    }

    private var windows: [WindowID: Window] = [:]

    public init() {}

    /// `tile`: nil for a floating, parked or hidden window. `busy`: a write of Kosmos's in
    /// flight, the left button down, or a drag holding the window. `since`: when the change
    /// that showed the frame came.
    public mutating func judge(_ id: WindowID, seen frame: CGRect, tile: CGRect?, busy: Bool,
                               at now: ContinuousClock.Instant, since: ContinuousClock.Instant? = nil) -> Decision {
        guard let tile, !busy, frame.isSmaller(than: tile) else { return .none }
        var window = windows[id].flatMap { $0.tile == tile ? $0 : nil } ?? Window(tile: tile)
        guard !window.gaveUp else { return .none }
        window.rewrites.removeAll { now - $0 >= Self.span }
        window.gaveUp = window.rewrites.count == Self.limit
        if window.gaveUp {
            window.since = nil
        } else {
            window.rewrites.append(now)
            window.since = window.since ?? since ?? now
        }
        windows[id] = window
        return window.gaveUp ? .gaveUp : .rewrite(window.rewrites.count)
    }

    /// A read back of a write of `target`: when the window was first seen smaller than that
    /// tile, if a rewrite of it is under way. One at the tile ends the rewrites' wait.
    public mutating func readBack(_ id: WindowID, _ frame: CGRect, target: CGRect) -> ContinuousClock.Instant? {
        guard let window = windows[id], window.tile == target, let since = window.since else { return nil }
        if !frame.isSmaller(than: target) { windows[id]?.since = nil }
        return since
    }

    public mutating func forget(_ id: WindowID) {
        windows[id] = nil
    }
}
