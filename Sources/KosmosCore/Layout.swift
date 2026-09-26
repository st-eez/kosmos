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
    /// `rect` is in Accessibility coordinates, where y grows down, so the first child of a
    /// vertical container is on top. A window whose minimum is longer than its tile spills as
    /// docs/tree.md says.
    func frames(in rect: CGRect, gaps: Gaps, minimums: [WindowID: CGSize]) -> [WindowID: CGRect] {
        var frames = tileFrames(in: rect, gaps: gaps)
        let area = tilingRect(rect, gaps.outer)
        for (id, minimum) in minimums {
            if let tile = frames[id] { frames[id] = spill(tile, to: minimum, from: area) }
        }
        if let fullscreenWindow { frames[fullscreenWindow] = rect.standardized }
        return frames
    }

    /// The sizes the weights stand for, with no minimums and no fullscreen window.
    func tileFrames(in rect: CGRect, gaps: Gaps) -> [WindowID: CGRect] {
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
        return frames
    }

    /// When the minimums of the children of the container holding `window`, or of every
    /// container when `window` is nil, fit, each child gets at least its minimum and the rest
    /// by weight, in whole points, as rift's `solve_axis_lengths` does, and the weights take
    /// those lengths (docs/tree.md).
    mutating func fit(_ window: WindowID?, in rect: CGRect, gaps: Gaps, minimums: [WindowID: CGSize]) {
        guard !minimums.isEmpty else { return }
        var only: Int?
        if let window {
            guard let path = root.path(to: window) else { return }
            only = root[path.dropLast()].id
        }
        // Top down, as a container's length comes from its parent's split.
        for path in containerPaths(root) where only == nil || root[path[...]].id == only {
            let container = root[path[...]]
            let least = container.children.map { minimumLength(of: $0, along: container.orientation, minimums, gap: gaps.inner) }
            guard let lengths = fitted(container.children.map(\.weight), least, usableLength(of: path[...], in: rect, gaps: gaps))
            else { continue }
            // Whole points, so the split's rounding puts each edge where the lengths do.
            var total: CGFloat = 0, edge: CGFloat = 0
            for (index, length) in lengths.enumerated() {
                total += length
                root[path[...]].children[index].weight = total.rounded() - edge
                edge = total.rounded()
            }
            root[path[...]].normalize()
        }
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

/// The path of each container, parents first.
private func containerPaths(_ container: Container, _ path: [Int] = []) -> [[Int]] {
    [path] + container.children.indices.flatMap { index -> [[Int]] in
        guard case .container(let nested) = container.children[index].kind else { return [] }
        return containerPaths(nested, path + [index])
    }
}

/// On each axis where the minimum is longer than the tile, the window keeps the tile's edge
/// that faces the other windows: at the far edge of the area its near edge, and at the near
/// edge its far edge, so the rest goes off screen, and between windows its near edge, so it
/// overlaps the next (docs/tree.md).
private func spill(_ tile: CGRect, to minimum: CGSize, from area: CGRect) -> CGRect {
    func span(_ start: CGFloat, _ length: CGFloat, _ least: CGFloat, _ low: CGFloat, _ high: CGFloat) -> (CGFloat, CGFloat) {
        let least = least.rounded(.up)
        guard least > length else { return (start, length) }
        return (start <= low && start + length < high ? start + length - least : start, least)
    }
    let (x, width) = span(tile.minX, tile.width, minimum.width, area.minX, area.maxX)
    let (y, height) = span(tile.minY, tile.height, minimum.height, area.minY, area.maxY)
    return CGRect(x: x, y: y, width: width, height: height)
}

/// Gaps shrink to leave each window this long (docs/tree.md).
private func minimumLength(_ orientation: Orientation) -> CGFloat {
    orientation == .horizontal ? 100 : 60
}

/// Inset by the outer gaps, with whole point edges. The gaps on an axis shrink in proportion
/// when they would leave less than the minimum length.
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

/// The gaps take at most what leaves each of `count` children the minimum length, in whole
/// points.
private func innerGap(_ gap: CGFloat, count: Int, length: CGFloat, orientation: Orientation) -> CGFloat {
    guard count > 1 else { return 0 }
    let total = min(max(0, gap) * CGFloat(count - 1), max(0, length - minimumLength(orientation) * CGFloat(count)))
    return (total / CGFloat(count - 1)).rounded(.down)
}

/// Edges are rounded from cumulative lengths and the last child ends at the container's
/// edge, so sizes add up, none is negative, and changing one weight moves only later edges.
private func split(_ rect: CGRect, _ container: Container, gap: CGFloat) -> [CGRect] {
    let horizontal = container.orientation == .horizontal
    let start = horizontal ? rect.minX : rect.minY
    let length = horizontal ? rect.width : rect.height
    let count = container.children.count
    let gap = innerGap(gap, count: count, length: length, orientation: container.orientation)
    let usable = length - gap * CGFloat(max(0, count - 1))
    var total = 0.0
    let ends = container.children.map { total += $0.weight; return (start + usable * total).rounded() }
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

/// Each child at least its minimum and the rest by weight (docs/tree.md). Nil when no minimum
/// binds, and when the minimums do not fit.
private func fitted(_ weights: [Double], _ minimums: [CGFloat], _ usable: CGFloat) -> [CGFloat]? {
    guard minimums.reduce(0, +) <= usable else { return nil }
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

/// A point at least, so a window with no minimum keeps one where the others' fit.
private func minimumLength(of node: Node, along orientation: Orientation, _ minimums: [WindowID: CGSize], gap: CGFloat) -> CGFloat {
    switch node.kind {
    case .window(let id):
        let size = minimums[id] ?? .zero
        return max(1, (orientation == .horizontal ? size.width : size.height).rounded(.up))
    case .container(let container):
        let lengths = container.children.map { minimumLength(of: $0, along: orientation, minimums, gap: gap) }
        guard container.orientation == orientation else { return lengths.max() ?? 0 }
        // Gaps are whole points and only ever shrink from the configured one.
        return lengths.reduce(0, +) + max(0, gap).rounded(.down) * CGFloat(lengths.count - 1)
    }
}
