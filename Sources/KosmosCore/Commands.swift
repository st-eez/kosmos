import CoreGraphics

// Tree commands. One that returns false or nil leaves the workspace unchanged.

public enum ResizeDimension: Sendable {
    case width
    case height
    /// Along the window's container.
    case smart
}

extension Workspace {
    /// Focuses the window next to `window` in the direction and returns it, or returns nil
    /// at the edge of the workspace. Like i3's `focus`, it walks up to the nearest container
    /// that runs along the direction and has a sibling on that side, then descends into the
    /// sibling by focus order.
    mutating func focus(_ direction: Direction, from window: WindowID) -> WindowID? {
        guard let path = neighbor(of: window, direction) else { return nil }
        let target = mostRecentWindow(in: root.node(at: path))
        focus(target)
        return target
    }

    /// Exchanges the window with the one `focus` reaches in the direction. Each takes the
    /// other's place and share.
    @discardableResult
    mutating func swap(_ window: WindowID, _ direction: Direction) -> Bool {
        guard let neighbor = neighbor(of: window, direction) else { return false }
        let other = mostRecentWindow(in: root.node(at: neighbor))
        let path = root.path(to: window)!, otherPath = root.path(to: other)!
        root[path.dropLast()].children[path.last!].kind = .window(other)
        root[otherPath.dropLast()].children[otherPath.last!].kind = .window(window)
        check()
        return true
    }

    /// Moves a tiled window one step in the direction, with i3's `tree_move` (src/move.c).
    /// In a container along the direction, it swaps with a sibling window or enters a
    /// sibling container beside the window it borders. Otherwise it leaves for the nearest
    /// ancestor along the direction, entering the container past its old branch if there is
    /// one. With no such ancestor, the root is first wrapped in a new root along the
    /// direction. Returns false at the edge of the workspace, where i3 would move the window
    /// to the next display.
    @discardableResult
    mutating func move(_ window: WindowID, _ direction: Direction) -> Bool {
        // A lone window has nowhere to go. Wrapping the root would only flip its orientation.
        guard root.path(to: window) != nil, root.children.count > 1, moveTiled(window, direction) else { return false }
        normalize()
        check()
        return true
    }

    /// Puts the window into a container with its neighbor in the direction, across the
    /// neighbor's parent (AeroSpace's `join-with`). A neighbor that is a container already
    /// runs across, so the window joins it. The window goes first when joining right or
    /// down and last when joining left or up.
    @discardableResult
    mutating func joinWith(_ window: WindowID, _ direction: Direction) -> Bool {
        guard let target = neighbor(of: window, direction) else { return false }
        let parent = target.dropLast(), index = target.last!
        let joined: Container
        switch root[parent].children[index].kind {
        case .container(let container):
            joined = container
        case .window(let other):
            joined = makeContainer(root[parent].orientation.opposite, [Node(kind: .window(other), weight: 1)])
            root[parent].children[index].kind = .container(joined)
        }
        let path = root.path(to: window)!
        root[path.dropLast()].children.remove(at: path.last!)
        let joinedPath = root.path(toContainer: joined.id)![...]
        root[joinedPath].insert(.window(window), at: direction.isForward ? 0 : root[joinedPath].children.count)
        normalize()
        check()
        return true
    }

    /// Sets the orientation of the window's container. A container that ends up with its
    /// parent's orientation is spliced into the parent, and so is a child container that
    /// ends up with its orientation.
    @discardableResult
    mutating func layout(_ window: WindowID, _ orientation: Orientation) -> Bool {
        guard let path = root.path(to: window), root[path.dropLast()].orientation != orientation else { return false }
        root[path.dropLast()].orientation = orientation
        normalize()
        check()
        return true
    }

    @discardableResult
    mutating func toggleLayout(_ window: WindowID) -> Bool {
        guard let path = root.path(to: window) else { return false }
        return layout(window, root[path.dropLast()].orientation.opposite)
    }

    /// Makes a tiled window cover the display rectangle, taking over from any other
    /// fullscreen window, or returns it to its tile.
    @discardableResult
    mutating func toggleFullscreen(_ window: WindowID) -> Bool {
        guard root.path(to: window) != nil else { return false }
        fullscreenWindow = fullscreenWindow == window ? nil : window
        if fullscreenWindow == window { stamp(window) }
        check()
        return true
    }

    /// Grows the window by `amount` points, or shrinks it when negative, taking the space
    /// from its siblings in proportion to their shares. For a dimension across the
    /// window's container, the nearest ancestor inside a container along the dimension
    /// resizes. `rect` and `gaps` are the ones `frames` gets, to turn points into shares.
    /// Returns false when the change would leave any sibling under one point, as i3 does.
    @discardableResult
    mutating func resize(_ window: WindowID, _ dimension: ResizeDimension, by amount: CGFloat, in rect: CGRect, gaps: Gaps) -> Bool {
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
        let old = children[index].weight
        let new = old + amount / usable
        let scale = (1 - new) / (1 - old)
        let onePoint = 1 / usable
        guard new >= onePoint, children.indices.allSatisfy({ $0 == index || children[$0].weight * scale >= onePoint }) else { return false }
        for sibling in children.indices {
            root[parent].children[sibling].weight = sibling == index ? new : children[sibling].weight * scale
        }
        normalize()
        check()
        return true
    }

    /// Gives every child of every container an equal share.
    mutating func balanceSizes() {
        root.balance()
        check()
    }

    /// Puts every tiled window directly under the root in depth first order, with equal
    /// shares.
    mutating func flattenWorkspaceTree() {
        let windows = root.windows
        root.children = windows.map { Node(kind: .window($0), weight: 1 / Double(windows.count)) }
        check()
    }
}

extension Workspace {
    /// The path of the node `focus` reaches in the direction: the sibling on that side of
    /// the window, or of its nearest ancestor, in the nearest container along the direction
    /// (i3's `get_tree_next`, AeroSpace's `closestParent(hasChildrenInDirection:)`).
    private func neighbor(of window: WindowID, _ direction: Direction) -> [Int]? {
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
    private mutating func moveTiled(_ window: WindowID, _ direction: Direction) -> Bool {
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
        // Leave for the nearest ancestor along the direction above the window's container.
        var depth = (0..<path.count - 1).last { root[path.prefix($0)].orientation == orientation }
        if depth == nil {
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

    /// The window a move lands beside when it enters `container`: the child facing the
    /// move in a container along the direction, else the most recently focused child, down
    /// to a window (i3's `con_descend_direction`).
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

    /// Moves the window beside `target`: after it when the target's container runs across
    /// the direction or the move goes left or up, else before it (i3's `tree_move`).
    private mutating func move(_ window: WindowID, beside target: WindowID, _ direction: Direction) {
        let path = root.path(to: window)!
        root[path.dropLast()].children.remove(at: path.last!)
        let targetPath = root.path(to: target)!
        let parent = targetPath.dropLast()
        let after = root[parent].orientation != direction.orientation || !direction.isForward
        root[parent].insert(.window(window), at: targetPath.last! + (after ? 1 : 0))
    }
}
