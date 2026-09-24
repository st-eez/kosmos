import CoreGraphics

/// Gaps in points.
public struct Gaps: Sendable {
    /// Between neighboring windows.
    public var inner: CGFloat
    /// Between the windows and the edges of the display rectangle.
    public var outer: Insets

    public init(inner: CGFloat = 0, outer: Insets = Insets()) {
        self.inner = inner
        self.outer = outer
    }
}

public struct Insets: Sendable {
    public var top: CGFloat
    public var left: CGFloat
    public var bottom: CGFloat
    public var right: CGFloat

    public init(top: CGFloat = 0, left: CGFloat = 0, bottom: CGFloat = 0, right: CGFloat = 0) {
        self.top = top
        self.left = left
        self.bottom = bottom
        self.right = right
    }
}

extension Workspace {
    /// The frame of every tiled window. `rect` is the display rectangle in Accessibility
    /// coordinates, where y grows down, so the first child of a vertical container is on
    /// top. Frames have whole point edges, and the fullscreen window gets all of `rect`.
    ///
    /// Frames ignore the minimum sizes of apps. A window that refuses a narrower frame
    /// overlaps its neighbor until layout solves each axis with the minimums the geometry
    /// layer observes.
    func frames(in rect: CGRect, gaps: Gaps) -> [WindowID: CGRect] {
        var frames: [WindowID: CGRect] = [:]
        func place(_ container: Container, in rect: CGRect) {
            for (child, frame) in zip(container.children, split(rect, container, gap: gaps.inner)) {
                switch child.kind {
                case .window(let id): frames[id] = frame
                case .container(let nested): place(nested, in: frame)
                }
            }
        }
        place(root, in: tilingRect(rect, gaps.outer))
        if let fullscreenWindow { frames[fullscreenWindow] = rect.standardized }
        return frames
    }

    /// The length of a container along its orientation as `frames` lays it out, less the
    /// gaps between its children.
    func usableLength(of path: ArraySlice<Int>, in rect: CGRect, gaps: Gaps) -> CGFloat {
        var area = tilingRect(rect, gaps.outer)
        for level in path.indices {
            area = split(area, root[path[..<level]], gap: gaps.inner)[path[level]]
        }
        let container = root[path]
        let length = container.orientation == .horizontal ? area.width : area.height
        let count = container.children.count
        return length - innerGap(gaps.inner, count: count, length: length, orientation: container.orientation) * CGFloat(max(0, count - 1))
    }
}

/// sway's smallest sane window size (`MIN_SANE_W` and `MIN_SANE_H` in
/// include/sway/tree/node.h). Gaps shrink before they squeeze a window below it.
private func minimumLength(_ orientation: Orientation) -> CGFloat {
    orientation == .horizontal ? 100 : 60
}

/// The display rectangle inset by the outer gaps, with whole point edges. As in sway's
/// `workspace_add_gaps`, the gaps on an axis shrink in proportion when they would leave
/// less than the minimum length.
private func tilingRect(_ rect: CGRect, _ outer: Insets) -> CGRect {
    let rect = rect.standardized
    let (left, right) = fit(outer.left, outer.right, in: rect.width, keeping: minimumLength(.horizontal))
    let (top, bottom) = fit(outer.top, outer.bottom, in: rect.height, keeping: minimumLength(.vertical))
    let minX = (rect.minX + left).rounded(), maxX = (rect.maxX - right).rounded()
    let minY = (rect.minY + top).rounded(), maxY = (rect.maxY - bottom).rounded()
    return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
}

private func fit(_ first: CGFloat, _ second: CGFloat, in length: CGFloat, keeping minimum: CGFloat) -> (CGFloat, CGFloat) {
    let first = max(0, first), second = max(0, second)
    guard length - first - second < minimum, first + second > 0 else { return (first, second) }
    let total = max(0, length - minimum)
    let share = first / (first + second) * total
    return (share, total - share)
}

/// sway's inner gap (`apply_horiz_layout` in sway/tree/arrange.c): the gaps between
/// `count` children take at most what leaves each child the minimum length, and each gap
/// is a whole number of points.
private func innerGap(_ gap: CGFloat, count: Int, length: CGFloat, orientation: Orientation) -> CGFloat {
    guard count > 1 else { return 0 }
    let total = min(max(0, gap) * CGFloat(count - 1), max(0, length - minimumLength(orientation) * CGFloat(count)))
    return (total / CGFloat(count - 1)).rounded(.down)
}

/// Splits a container's rectangle among its children by weight, with sway's inner gaps.
/// Edges are rounded from cumulative weights and the last child ends at the container's
/// edge, so sizes add up to the container, no size is negative, and changing one weight
/// moves only the edges after it.
private func split(_ rect: CGRect, _ container: Container, gap: CGFloat) -> [CGRect] {
    let horizontal = container.orientation == .horizontal
    let start = horizontal ? rect.minX : rect.minY
    let length = horizontal ? rect.width : rect.height
    let count = container.children.count
    let gap = innerGap(gap, count: count, length: length, orientation: container.orientation)
    let usable = length - gap * CGFloat(max(0, count - 1))
    var frames: [CGRect] = []
    var edge = start, cumulative = 0.0
    for (index, child) in container.children.enumerated() {
        cumulative += child.weight
        let end = index == count - 1 ? start + usable : (start + usable * cumulative).rounded()
        let offset = gap * CGFloat(index)
        frames.append(horizontal
            ? CGRect(x: edge + offset, y: rect.minY, width: end - edge, height: rect.height)
            : CGRect(x: rect.minX, y: edge + offset, width: rect.width, height: end - edge))
        edge = end
    }
    return frames
}
