import CoreGraphics

// Tree commands. One that returns false or nil leaves the workspace unchanged.

public enum ResizeDimension: Sendable {
    case width
    case height
    /// Along the window's container.
    case smart
}

extension Workspace {
    /// Focuses the window next to `window` in the direction and returns it, or returns nil at
    /// the edge of the workspace (docs/tree.md).
    mutating func focus(_ direction: Direction, from window: WindowID, frame: (WindowID) -> CGRect?,
                        in rect: CGRect, gaps: Gaps, minimums: [WindowID: CGSize]) -> WindowID? {
        let seen = withFloatingTiled(frame, in: rect, gaps: gaps, minimums: minimums)
        guard let path = seen.neighbor(of: window, direction) else { return nil }
        let target = seen.mostRecentWindow(in: seen.root.node(at: path))
        focus(target)
        return target
    }

    /// The workspace with each floating window that `frame` places tiled, for a focus in a
    /// direction (docs/tree.md).
    func withFloatingTiled(_ frame: (WindowID) -> CGRect?, in rect: CGRect, gaps: Gaps,
                           minimums: [WindowID: CGSize]) -> Workspace {
        let area = tilingRect(rect, gaps.outer)
        let shares = tileFrames(in: rect, gaps: Gaps(outer: gaps.outer))
        let tiles = self.frames(in: rect, gaps: gaps, minimums: minimums)
        var places: [(window: WindowID, container: Int, index: Int, along: CGFloat)] = []
        for window in floating {
            guard let frame = frame(window) else { continue }
            let center = CGPoint(x: frame.midX, y: frame.midY)
            // The share under the center, whose right and bottom edges belong to the next
            // one. With no tiles there is none, and the window goes first in the root.
            let point = CGPoint(x: min(max(center.x, area.minX), area.maxX - 1), y: min(max(center.y, area.minY), area.maxY - 1))
            var (container, index, tile): (Container, Int, CGRect?) = (root, 0, nil)
            if let id = shares.first(where: { $0.value.contains(point) })?.key {
                let path = root.path(to: id)!
                (container, index, tile) = (root[path.dropLast()], path.last!, tiles[id])
            }
            let along: (CGPoint) -> CGFloat = container.orientation == .horizontal ? \.x : \.y
            if let tile, along(center) >= along(CGPoint(x: tile.midX, y: tile.midY)) { index += 1 }
            places.append((window, container.id, index, along(center)))
        }
        // Each index counts the tiles alone, so the windows furthest along go in first. The
        // search reads no weights, so the inserted windows' shares stay as `insert` gives them.
        var seen = self
        for place in places.sorted(by: { $0.along < $1.along }).reversed() {
            seen.root[seen.root.path(toContainer: place.container)![...]].insert(.window(place.window), at: place.index)
        }
        return seen
    }

    /// With the window `focus` reaches in the direction, each taking the other's place and
    /// share.
    @discardableResult
    mutating func swap(_ window: WindowID, _ direction: Direction) -> Bool {
        guard let neighbor = neighbor(of: window, direction) else { return false }
        let other = mostRecentWindow(in: root.node(at: neighbor))
        let path = root.path(to: window)!, otherPath = root.path(to: other)!
        root[path.dropLast()].children[path.last!].kind = .window(other)
        root[otherPath.dropLast()].children[otherPath.last!].kind = .window(window)
        edits += 1
        check()
        return true
    }

    /// One step (docs/tree.md). At the workspace's edge `implicitContainer` wraps the root along
    /// the direction, and without it the move returns false (docs/displays.md).
    @discardableResult
    mutating func move(_ window: WindowID, _ direction: Direction, implicitContainer: Bool = true) -> Bool {
        // Wrapping a lone window's root would only flip its orientation.
        guard root.path(to: window) != nil, root.children.count > 1,
              moveTiled(window, direction, implicitContainer: implicitContainer) else { return false }
        normalize()
        edits += 1
        check()
        return true
    }

    /// A neighbor that is a container already runs across its parent, so the window joins it.
    @discardableResult
    mutating func joinWith(_ window: WindowID, _ direction: Direction) -> Bool {
        guard let target = neighbor(of: window, direction) else { return false }
        let parent = target.dropLast(), index = target.last!
        // The new container keeps the pair's combined space, so the other siblings keep their
        // sizes and joining back out restores them exactly.
        let path = root.path(to: window)!
        let carried = path.dropLast() == parent ? root[parent].children[path.last!].weight : 0
        let joined: Container
        switch root[parent].children[index].kind {
        case .container(let container):
            joined = container
        case .window(let other):
            joined = makeContainer(root[parent].orientation.opposite, [Node(kind: .window(other), weight: 1)])
            root[parent].children[index].kind = .container(joined)
        }
        root[path.dropLast()].children.remove(at: path.last!)
        let joinedPath = root.path(toContainer: joined.id)![...]
        root[joinedPath.dropLast()].children[joinedPath.last!].weight += carried
        root[joinedPath].insert(.window(window), at: direction.isForward ? 0 : root[joinedPath].children.count)
        normalize()
        edits += 1
        check()
        return true
    }

    /// Sets the orientation of the window's container.
    @discardableResult
    mutating func layout(_ window: WindowID, _ orientation: Orientation) -> Bool {
        guard let path = root.path(to: window), root[path.dropLast()].orientation != orientation else { return false }
        root[path.dropLast()].orientation = orientation
        normalize()
        edits += 1
        check()
        return true
    }

    @discardableResult
    mutating func toggleLayout(_ window: WindowID) -> Bool {
        guard let path = root.path(to: window) else { return false }
        return layout(window, root[path.dropLast()].orientation.opposite)
    }

    @discardableResult
    mutating func toggleFullscreen(_ window: WindowID) -> Bool {
        guard root.path(to: window) != nil else { return false }
        fullscreenWindow = fullscreenWindow == window ? nil : window
        if fullscreenWindow == window { stamp(window) }
        check()
        return true
    }

    /// Takes the space from the siblings in proportion to their shares, and stops at the
    /// limits `change` keeps (docs/tree.md).
    @discardableResult
    mutating func resize(_ window: WindowID, _ dimension: ResizeDimension, by amount: CGFloat, in rect: CGRect, gaps: Gaps, minimums: [WindowID: CGSize]) -> Bool {
        guard let path = root.path(to: window) else { return false }
        let orientation = switch dimension {
            case .width: Orientation.horizontal
            case .height: Orientation.vertical
            case .smart: root[path.dropLast()].orientation
        }
        guard let depth = (0..<path.count).last(where: { root[path.prefix($0)].orientation == orientation }) else { return false }
        let parent = path.prefix(depth), index = path[depth]
        let children = root[parent].children
        let usable = usableLength(of: parent, in: rect, gaps: gaps)
        guard children.count > 1, usable > 0 else { return false }
        return change(by: amount, along: orientation, in: rect, gaps: gaps, minimums: minimums) { workspace, points in
            let old = children[index].weight
            let new = old + points / usable
            let scale = (1 - new) / (1 - old)
            guard new > 0, scale > 0 else { return false }
            for sibling in children.indices {
                workspace.root[parent].children[sibling].weight = sibling == index ? new : children[sibling].weight * scale
            }
            return true
        }
    }

    /// Outward when `amount` is positive. Only the neighbour across the edge gives or takes
    /// the space, and every other edge stays (docs/modifier-drags.md).
    @discardableResult
    mutating func moveEdge(_ window: WindowID, _ direction: Direction, by amount: CGFloat, in rect: CGRect, gaps: Gaps,
                           minimums: [WindowID: CGSize]) -> Bool {
        guard let path = root.path(to: window), let beyond = neighbor(of: window, direction) else { return false }
        let depth = beyond.count - 1
        let inner = (depth + 1 ..< path.count).filter { root[path.prefix($0)].orientation == direction.orientation }
        let usable = Dictionary(uniqueKeysWithValues: ([depth] + inner).map { ($0, usableLength(of: path.prefix($0), in: rect, gaps: gaps)) })
        guard usable[depth]! > 0 else { return false }
        let before = root
        return change(by: amount, along: direction.orientation, in: rect, gaps: gaps, minimums: minimums) { workspace, points in
            let parent = path.prefix(depth), index = path[depth], neighbour = beyond[depth]
            let children = before[parent].children
            let share = points / usable[depth]!
            let new = children[index].weight + share, left = children[neighbour].weight - share
            guard new > 0, left > 0 else { return false }
            workspace.root[parent].children[index].weight = new
            workspace.root[parent].children[neighbour].weight = left
            for level in inner {
                let parent = path.prefix(level), index = path[level]
                let children = before[parent].children
                let length = usable[level]!, grown = length + points
                guard grown > 0 else { return false }
                var others = 0.0
                for sibling in children.indices where sibling != index {
                    workspace.root[parent].children[sibling].weight = children[sibling].weight * length / grown
                    others += children[sibling].weight * length / grown
                }
                guard others < 1 else { return false }
                workspace.root[parent].children[index].weight = 1 - others
            }
            return true
        }
    }

    /// The change for `amount` points, else the most whole points toward it that keep the
    /// limits of docs/tree.md. `apply` returns false for a share at or below zero.
    private mutating func change(by amount: CGFloat, along orientation: Orientation, in rect: CGRect, gaps: Gaps,
                                 minimums: [WindowID: CGSize], _ apply: (inout Workspace, CGFloat) -> Bool) -> Bool {
        let length: (CGRect) -> CGFloat = orientation == .horizontal ? \.width : \.height
        func limit(_ id: WindowID) -> CGFloat {
            let minimum = minimums[id].map { orientation == .horizontal ? $0.width : $0.height } ?? 0
            return max(1, minimum.rounded(.up))
        }
        let before = tileFrames(in: rect, gaps: gaps)
        func changed(by points: CGFloat) -> Workspace? {
            var changed = self
            guard apply(&changed, points) else { return nil }
            changed.normalize()
            let kept = changed.tileFrames(in: rect, gaps: gaps).allSatisfy { id, frame in
                length(frame) >= min(limit(id), length(before[id]!))
            }
            return kept ? changed : nil
        }
        var result = changed(by: amount)
        if result == nil {
            let sign: CGFloat = amount < 0 ? -1 : 1
            var fits: CGFloat = 0, fails = abs(amount).rounded(.up)
            while fails - fits > 1 {
                let middle = ((fits + fails) / 2).rounded(.down)
                if changed(by: middle * sign) != nil { fits = middle } else { fails = middle }
            }
            result = fits > 0 ? changed(by: fits * sign) : nil
        }
        guard let result else { return false }
        self = result
        edits += 1
        check()
        return true
    }

    mutating func balanceSizes() {
        root.balance()
        edits += 1
        check()
    }

    mutating func flattenWorkspaceTree() {
        let windows = root.windows
        root.children = windows.map { Node(kind: .window($0), weight: 1 / Double(windows.count)) }
        edits += 1
        check()
    }
}

extension Workspace {
    /// The path of the node `focus` reaches in the direction.
    func neighbor(of window: WindowID, _ direction: Direction) -> [Int]? {
        guard var path = root.path(to: window) else { return nil }
        while let index = path.popLast() {
            let container = root[path[...]], sibling = index + direction.step
            if container.orientation == direction.orientation, container.children.indices.contains(sibling) {
                return path + [sibling]
            }
        }
        return nil
    }

    /// Returns false at the edge of the workspace, before changing anything.
    private mutating func moveTiled(_ window: WindowID, _ direction: Direction, implicitContainer: Bool) -> Bool {
        var path = root.path(to: window)!
        let orientation = direction.orientation
        if root[path.dropLast()].orientation == orientation {
            let parent = path.dropLast(), index = path.last!, sibling = index + direction.step
            if root[parent].children.indices.contains(sibling) {
                if case .container(let container) = root[parent].children[sibling].kind {
                    move(window, beside: edgeWindow(of: container, direction), direction)
                } else {
                    root[parent].children.swapAt(index, sibling)
                }
                return true
            }
            if parent.isEmpty { return false }
        }
        var depth = (0..<path.count - 1).last { root[path.prefix($0)].orientation == orientation }
        if depth == nil {
            guard implicitContainer else { return false }
            wrapRoot(orientation)
            path.insert(0, at: 0)
            depth = 0
        }
        let ancestor = path.prefix(depth!), branch = path[depth!], next = branch + direction.step
        if root[ancestor].children.indices.contains(next), case .container(let container) = root[ancestor].children[next].kind {
            move(window, beside: edgeWindow(of: container, direction), direction)
        } else {
            // The window sits inside the branch, so removing it leaves the branch's index.
            root[path.dropLast()].children.remove(at: path.last!)
            root[ancestor].insert(.window(window), at: direction.isForward ? branch + 1 : branch)
        }
        return true
    }

    /// The window a move lands beside when it enters `container`.
    private func edgeWindow(of container: Container, _ direction: Direction) -> WindowID {
        let child: Node
        if container.orientation == direction.orientation {
            child = direction.isForward ? container.children.first! : container.children.last!
        } else {
            child = mostRecentChild(of: container)!
        }
        switch child.kind {
        case .window(let id): return id
        case .container(let nested): return edgeWindow(of: nested, direction)
        }
    }

    private mutating func move(_ window: WindowID, beside target: WindowID, _ direction: Direction) {
        let path = root.path(to: window)!
        root[path.dropLast()].children.remove(at: path.last!)
        let targetPath = root.path(to: target)!
        let parent = targetPath.dropLast()
        let after = root[parent].orientation != direction.orientation || !direction.isForward
        root[parent].insert(.window(window), at: targetPath.last! + (after ? 1 : 0))
    }
}
