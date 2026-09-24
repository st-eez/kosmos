import CoreGraphics

/// A display's CGDirectDisplayID.
public typealias DisplayID = UInt32

/// A connected display as the session tiles it (DESIGN.md, section 5.13).
public struct Monitor: Equatable, Sendable {
    public var id: DisplayID
    /// The whole display, in the top left origin coordinates Accessibility uses. The main
    /// display's origin is zero.
    public var frame: CGRect
    /// The visible frame, without the menu bar and the Dock: where windows tile.
    public var area: CGRect
    public var gaps: Gaps

    public init(id: DisplayID, frame: CGRect, area: CGRect? = nil, gaps: Gaps = Gaps()) {
        self.id = id
        self.frame = frame
        self.area = area ?? frame
        self.gaps = gaps
    }
}

extension Monitor {
    /// Left to right, then top to bottom, the order AeroSpace numbers monitors in.
    static func arranged(_ monitors: [Monitor]) -> [Monitor] {
        monitors.sorted { ($0.frame.minX, $0.frame.minY, $0.id) < ($1.frame.minX, $1.frame.minY, $1.id) }
    }

    /// The display `target` names, seen from `current`, or nil when there is none, as past
    /// the last display without `wrapAround`. `monitors` is in `arranged` order.
    ///
    /// A direction looks along the displays side by side with `current` for left and right,
    /// or stacked with it for up and down, as AeroSpace's `findRelativeMonitor` does: two
    /// displays are side by side when their vertical extents overlap. AeroSpace orders a
    /// column left to right too; this orders it top to bottom, so a display below and to
    /// the left of another is still below it.
    static func resolve(_ target: Command.MonitorTarget, from current: Monitor, in monitors: [Monitor],
                        wrapAround: Bool) -> Monitor? {
        func step(_ line: [Monitor], by offset: Int) -> Monitor? {
            guard let index = line.firstIndex(where: { $0.id == current.id }) else { return nil }
            let next = index + offset
            if wrapAround { return line[(next % line.count + line.count) % line.count] }
            return line.indices.contains(next) ? line[next] : nil
        }
        switch target {
        case .next: return step(monitors, by: 1)
        case .previous: return step(monitors, by: -1)
        case .number(let number): return monitors.indices.contains(number - 1) ? monitors[number - 1] : nil
        case .direction(let direction):
            let beside = { (other: Monitor) in
                other.frame.minY < current.frame.maxY && current.frame.minY < other.frame.maxY
            }
            var line = monitors.filter { $0.id == current.id || beside($0) == (direction.orientation == .horizontal) }
            if direction.orientation == .vertical {
                line.sort { ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX) }
            }
            return step(line, by: direction.step)
        }
    }
}
