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
    /// vertical container is on top. `minimums` bind as docs/tree.md says.
    func frames(in rect: CGRect, gaps: Gaps, minimums: [WindowID: CGSize]) -> [WindowID: CGRect] {
        var frames = splitFrames(in: rect, gaps: gaps, minimums: minimums)
        if let fullscreenWindow { frames[fullscreenWindow] = rect.standardized }
        return frames
    }

    /// The sizes the weights stand for, with no minimums and no fullscreen window.
    func tileFrames(in rect: CGRect, gaps: Gaps) -> [WindowID: CGRect] {
        splitFrames(in: rect, gaps: gaps, minimums: [:])
    }

    /// The windows with a minimum along a container whose minimums do not fit, so its
    /// children overlap.
    func overlapping(in rect: CGRect, gaps: Gaps, minimums: [WindowID: CGSize]) -> Set<WindowID> {
        guard !minimums.isEmpty else { return [] }
        var overlapping: Set<WindowID> = []
        _ = splitFrames(in: rect, gaps: gaps, minimums: minimums) { overlapping.insert($0) }
        return overlapping
    }

    /// The windows whose share is below their minimum, which `frames` gives them anyway.
    func bound(in rect: CGRect, gaps: Gaps, minimums: [WindowID: CGSize]) -> Set<WindowID> {
        guard !minimums.isEmpty else { return [] }
        let shares = tileFrames(in: rect, gaps: gaps)
        return Set(minimums.compactMap { id, minimum in
            shares[id].flatMap { $0.width < minimum.width.rounded(.up) || $0.height < minimum.height.rounded(.up) ? id : nil }
        })
    }

    private func splitFrames(in rect: CGRect, gaps: Gaps, minimums: [WindowID: CGSize],
                             overlapping: (WindowID) -> Void = { _ in }) -> [WindowID: CGRect] {
        var frames: [WindowID: CGRect] = [:]
        func place(_ container: Container, in rect: CGRect) {
            let orientation = container.orientation
            let least = container.children.map { minimumLength(of: $0, along: orientation, minimums, gap: gaps.inner) }
            let (split, overlaps) = split(rect, container, gap: gaps.inner, minimums: least)
            for (child, frame) in zip(container.children, split) {
                switch child.kind {
                case .window(let id): frames[id] = frame
                case .container(let nested): place(nested, in: frame)
                }
            }
            guard overlaps else { return }
            for id in container.windows where (minimums[id].map { orientation == .horizontal ? $0.width : $0.height } ?? 0) > 0 {
                overlapping(id)
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
            area = split(area, root[path[..<level]], gap: gaps.inner, minimums: []).frames[path[level]]
        }
        let container = root[path]
        let length = container.orientation == .horizontal ? area.width : area.height
        let count = container.children.count
        return length - innerGap(gaps.inner, count: count, length: length, orientation: container.orientation) * CGFloat(max(0, count - 1))
    }
}

/// Gaps shrink to leave each window this long, and where minimums do not fit, a window with
/// none takes it (docs/tree.md).
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
/// `overlaps` when the minimums do not fit even with no gaps.
private func split(_ rect: CGRect, _ container: Container, gap: CGFloat, minimums: [CGFloat]) -> (frames: [CGRect], overlaps: Bool) {
    let horizontal = container.orientation == .horizontal
    let start = horizontal ? rect.minX : rect.minY
    let length = horizontal ? rect.width : rect.height
    let count = container.children.count
    let gap = innerGap(gap, count: count, length: length, orientation: container.orientation)
    let usable = length - gap * CGFloat(max(0, count - 1))
    guard minimums.reduce(0, +) <= usable else {
        // The seams share the excess alike, their gaps first (docs/tree.md).
        let lengths = minimums.map { min($0 > 0 ? $0 : minimumLength(container.orientation), length) }
        let total = lengths.reduce(0, +)
        let step = count > 1 ? (total - length) / CGFloat(count - 1) : 0
        var edge = start
        let frames = lengths.map { size in
            defer { edge += size - step }
            let origin = min(max(edge.rounded(), start), start + length - size)
            return horizontal ? CGRect(x: origin, y: rect.minY, width: size, height: rect.height)
                : CGRect(x: rect.minX, y: origin, width: rect.width, height: size)
        }
        return (frames, total > length)
    }
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
    return (frames, false)
}

/// Each child at least its minimum and the rest by weight (docs/tree.md). Nil when no minimum
/// binds, and when the minimums do not fit.
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
