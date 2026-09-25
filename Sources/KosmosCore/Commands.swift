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
        edits += 1
        check()
        return true
    }

    /// Moves a tiled window one step in the direction, with i3's `tree_move` (src/move.c).
    /// In a container along the direction, it swaps with a sibling window or enters a
    /// sibling container beside the window it borders. Otherwise it leaves for the nearest
    /// ancestor along the direction, entering the container past its old branch if there is
    /// one. With no such ancestor the window is at the edge of the workspace, where
    /// `implicitContainer` first wraps the root in a new root along the direction, as i3
    /// and AeroSpace do. Returns false at the edge otherwise, and at the end of a root
    /// along the direction, where a move across displays goes on to the next display.
    @discardableResult
    mutating func move(_ window: WindowID, _ direction: Direction, implicitContainer: Bool = true) -> Bool {
        // A lone window has nowhere to go. Wrapping the root would only flip its orientation.
        guard root.path(to: window) != nil, root.children.count > 1,
              moveTiled(window, direction, implicitContainer: implicitContainer) else { return false }
        normalize()
        edits += 1
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
        // Joining a sibling keeps the pair's combined space for the new container, so the
        // other siblings keep their sizes and joining back out restores them exactly. Taking
        // only the target's share gave the window's share to every sibling, and each join
        // and unjoin grew the others.
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

    /// Sets the orientation of the window's container. A container that ends up with its
    /// parent's orientation is spliced into the parent, and so is a child container that
    /// ends up with its orientation.
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
    ///
    /// The change stops where it would take a window along the dimension below its entry
    /// in `minimums`, or below one point without one, counting windows nested in a squeezed
    /// sibling. A window already under its limit may stay there. i3 refuses a resize past
    /// such a limit. Stopping at the limit does as much as the key press can, so repeated
    /// presses reach the limit exactly, and the weights never ask for less than a window
    /// takes. Returns false when nothing could change.
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

    /// Moves the window's edge on the `direction` side by `amount` points, outward when
    /// positive, as a modifier drag with the right button does (docs/modifier-drags.md).
    /// The neighbour `focus` finds in the direction (`neighbor(of:)`), the node next to the
    /// window's branch in the nearest container along the direction, gives the branch the
    /// space alone, as i3's resize with the mouse moves only the border between two
    /// neighbours (resize_find_tiling_participants) and Hyprland's dwindle splits hold two
    /// nodes each. Every other edge stays. Each container along the direction between that
    /// one and the window gives the space to the window's branch alone, and its other
    /// children keep their lengths. It stops at the limits `resize` keeps. False with no
    /// neighbour, as at the workspace's edge, or when nothing could change.
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

    /// Makes the change `apply` makes for `amount` points along `orientation`, else the most
    /// whole points toward `amount` that keep every window along the orientation at its
    /// entry in `minimums`, or at one point without one. A window already under its limit
    /// may stay there. `apply` returns false when the points leave a share at or below zero.
    /// False when nothing could change.
    private mutating func change(by amount: CGFloat, along orientation: Orientation, in rect: CGRect, gaps: Gaps,
                                 minimums: [WindowID: CGSize], _ apply: (inout Workspace, CGFloat) -> Bool) -> Bool {
        let length: (CGRect) -> CGFloat = orientation == .horizontal ? \.width : \.height
        func limit(_ id: WindowID) -> CGFloat {
            let minimum = minimums[id].map { orientation == .horizontal ? $0.width : $0.height } ?? 0
            return max(1, minimum.rounded(.up))
        }
        let before = tileFrames(in: rect, gaps: gaps)
        // The workspace after a change of `points`, or nil when that takes a window below
        // its limit.
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

    /// Gives every child of every container an equal share.
    mutating func balanceSizes() {
        root.balance()
        edits += 1
        check()
    }

    /// Puts every tiled window directly under the root in depth first order, with equal
    /// shares.
    mutating func flattenWorkspaceTree() {
        let windows = root.windows
        root.children = windows.map { Node(kind: .window($0), weight: 1 / Double(windows.count)) }
        edits += 1
        check()
    }
}

extension Workspace {
    /// The path of the node `focus` reaches in the direction: the sibling on that side of
    /// the window, or of its nearest ancestor, in the nearest container along the direction
    /// (i3's `get_tree_next`, AeroSpace's `closestParent(hasChildrenInDirection:)`).
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
        // Leave for the nearest ancestor along the direction above the window's container.
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
