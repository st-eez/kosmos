import CoreGraphics

/// Gaps in points.
public struct Gaps: Equatable, Sendable {
    /// Between neighboring windows.
    public var inner: CGFloat
    /// Between the windows and the edges of the display rectangle.
    public var outer: Insets

    public init(inner: CGFloat = 0, outer: Insets = Insets()) {
        self.inner = inner
        self.outer = outer
    }
}

public struct Insets: Equatable, Sendable {
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
    /// `minimums` holds the smallest sizes windows accept. When they fit, every window gets
    /// at least its minimum and the space left over goes by weight. The weights stay as the
    /// user set them, so they apply again once a minimum stops binding. When the minimums
    /// of a container's children do not fit, it splits by weight alone, and each window
    /// with a minimum takes it anyway, moved back inside the tiling rectangle where it would
    /// leave it, over its neighbors.
    func frames(in rect: CGRect, gaps: Gaps, minimums: [WindowID: CGSize]) -> [WindowID: CGRect] {
        var frames = layout(in: rect, gaps: gaps, minimums: minimums)
        let area = tilingRect(rect, gaps.outer)
        for (id, minimum) in minimums {
            if let frame = frames[id] { frames[id] = grow(frame, to: minimum, within: area) }
        }
        if let fullscreenWindow { frames[fullscreenWindow] = rect.standardized }
        return frames
    }

    /// The frame of every tiled window's tile by weight alone, with no minimums and none
    /// fullscreen: the sizes the weights stand for.
    func tileFrames(in rect: CGRect, gaps: Gaps) -> [WindowID: CGRect] {
        layout(in: rect, gaps: gaps, minimums: [:])
    }

    private func layout(in rect: CGRect, gaps: Gaps, minimums: [WindowID: CGSize]) -> [WindowID: CGRect] {
        var frames: [WindowID: CGRect] = [:]
        func place(_ container: Container, in rect: CGRect) {
            let least = container.children.map { minimumLength(of: $0, along: container.orientation, minimums, gap: gaps.inner) }
            for (child, frame) in zip(container.children, split(rect, container, gap: gaps.inner, minimums: least)) {
                switch child.kind {
                case .window(let id): frames[id] = frame
                case .container(let nested): place(nested, in: frame)
                }
            }
        }
        place(root, in: tilingRect(rect, gaps.outer))
        return frames
    }

    /// The length of a container along its orientation as `frames` lays it out, less the
    /// gaps between its children.
    func usableLength(of path: ArraySlice<Int>, in rect: CGRect, gaps: Gaps) -> CGFloat {
        var area = tilingRect(rect, gaps.outer)
        for level in path.indices {
            area = split(area, root[path[..<level]], gap: gaps.inner, minimums: [])[path[level]]
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
func tilingRect(_ rect: CGRect, _ outer: Insets) -> CGRect {
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

/// Splits a container's rectangle among its children by weight, with sway's inner gaps,
/// giving each child at least its length in `minimums` when they all fit. Edges are
/// rounded from cumulative lengths and the last child ends at the container's edge, so
/// sizes add up to the container, no size is negative, and changing one weight moves only
/// the edges after it.
private func split(_ rect: CGRect, _ container: Container, gap: CGFloat, minimums: [CGFloat]) -> [CGRect] {
    let horizontal = container.orientation == .horizontal
    let start = horizontal ? rect.minX : rect.minY
    let length = horizontal ? rect.width : rect.height
    let count = container.children.count
    let gap = innerGap(gap, count: count, length: length, orientation: container.orientation)
    let usable = length - gap * CGFloat(max(0, count - 1))
    var total = 0.0
    let ends: [CGFloat]
    if let lengths = fitted(container.children.map(\.weight), minimums, usable) {
        ends = lengths.map { total += $0; return (start + total).rounded() }
    } else {
        ends = container.children.map { total += $0.weight; return (start + usable * total).rounded() }
    }
    var frames: [CGRect] = []
    var edge = start
    for index in container.children.indices {
        let end = index == count - 1 ? start + usable : ends[index]
        let offset = gap * CGFloat(index)
        frames.append(horizontal
            ? CGRect(x: edge + offset, y: rect.minY, width: end - edge, height: rect.height)
            : CGRect(x: rect.minX, y: edge + offset, width: rect.width, height: end - edge))
        edge = end
    }
    return frames
}

/// Lengths that give each child at least its minimum and share what is left by weight, as
/// rift's `solve_axis_lengths` does with minimums alone. Children whose weighted share falls
/// short take their minimum, and the others split the rest, until none falls short. Nil
/// when no minimum binds, so the split is the plain weighted one, and when the minimums do
/// not fit.
private func fitted(_ weights: [Double], _ minimums: [CGFloat], _ usable: CGFloat) -> [CGFloat]? {
    guard minimums.contains(where: { $0 > 0 }), minimums.reduce(0, +) <= usable else { return nil }
    var bound: Set<Int> = []
    while true {
        let free = usable - bound.reduce(0) { $0 + minimums[$1] }
        let weight = weights.indices.filter { !bound.contains($0) }.reduce(0) { $0 + weights[$1] }
        let short = weights.indices.filter { !bound.contains($0) && free * weights[$0] / weight < minimums[$0] }
        guard !short.isEmpty else {
            return bound.isEmpty ? nil : weights.indices.map { bound.contains($0) ? minimums[$0] : free * weights[$0] / weight }
        }
        bound.formUnion(short)
    }
}

/// The least length a node needs along `orientation`: a window's minimum in whole points,
/// or for a container, its children's side by side with the gaps between them when it runs
/// along `orientation`, else the largest of them.
private func minimumLength(of node: Node, along orientation: Orientation, _ minimums: [WindowID: CGSize], gap: CGFloat) -> CGFloat {
    guard !minimums.isEmpty else { return 0 }
    switch node.kind {
    case .window(let id):
        guard let size = minimums[id] else { return 0 }
        return max(0, orientation == .horizontal ? size.width : size.height).rounded(.up)
    case .container(let container):
        let lengths = container.children.map { minimumLength(of: $0, along: orientation, minimums, gap: gap) }
        guard container.orientation == orientation else { return lengths.max() ?? 0 }
        let total = lengths.reduce(0, +)
        // Gaps are whole points and only ever shrink from the configured one.
        return total > 0 ? total + max(0, gap).rounded(.down) * CGFloat(lengths.count - 1) : 0
    }
}

/// The frame grown to at least `minimum`, but no larger than `area`, and moved back inside
/// `area` where it would leave it.
private func grow(_ frame: CGRect, to minimum: CGSize, within area: CGRect) -> CGRect {
    let width = min(max(frame.width, minimum.width.rounded(.up)), area.width)
    let height = min(max(frame.height, minimum.height.rounded(.up)), area.height)
    return CGRect(x: min(max(frame.minX, area.minX), area.maxX - width),
                  y: min(max(frame.minY, area.minY), area.maxY - height),
                  width: width, height: height)
}
