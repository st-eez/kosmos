import CoreGraphics

/// A display's CGDirectDisplayID.
public typealias DisplayID = UInt32

/// A connected display as the session tiles it (docs/displays.md).
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
    static func arranged(_ monitors: [Monitor]) -> [Monitor] {
        monitors.sorted { ($0.frame.minX, $0.frame.minY, $0.id) < ($1.frame.minX, $1.frame.minY, $1.id) }
    }

    /// `monitors` is in `arranged` order. A direction takes the nearest display past
    /// `current`'s edge that way, of those that overlap `current` across it if any do, and of
    /// the nearest the one that overlaps most, or with no overlap lies closest across it.
    /// With no display that way, a wrap takes the farthest the other way by the same
    /// preference (docs/displays.md).
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
            typealias Lying = (monitor: Monitor, gap: CGFloat, overlap: CGFloat)
            let (along, across) = (direction.orientation, direction.orientation.opposite)
            func lying(_ way: Direction) -> [Lying] {
                let here = along.span(of: current.frame)
                let all: [Lying] = monitors.compactMap { other in
                    let there = along.span(of: other.frame)
                    let gap = way.isForward ? there.min - here.max : here.min - there.max
                    return gap >= 0 ? (other, gap, across.overlap(current.frame, other.frame)) : nil
                }
                let overlapping = all.filter { $0.overlap > 0 }
                return overlapping.isEmpty ? all : overlapping
            }
            if let nearest = lying(direction).min(by: { ($0.gap, -$0.overlap) < ($1.gap, -$1.overlap) }) {
                return nearest.monitor
            }
            guard wrapAround else { return nil }
            return lying(direction.opposite).max(by: { ($0.gap, $0.overlap) < ($1.gap, $1.overlap) })?.monitor
        }
    }
}
