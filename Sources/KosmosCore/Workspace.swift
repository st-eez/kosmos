/// A workspace: tiled windows in a tree under one root container, floating windows, and
/// parked windows. A parked window is out of the layout while it is minimized, hidden with
/// its app or in native fullscreen, and remembers where to return.
///
/// A value type: the main actor mutates its copy, and a copy sent to another thread is a
/// snapshot.
public struct Workspace: Sendable {
    /// It may be empty or hold a single window. A root left holding a single container is
    /// replaced by that container.
    public internal(set) var root: Container
    public internal(set) var floating: [WindowID] = []
    /// The tiled window that covers the whole display rectangle.
    public internal(set) var fullscreenWindow: WindowID?
    /// Oldest first.
    var parked: [Parked] = []
    /// Where a window that left the tree to float or park returns to.
    var hints: [WindowID: RestoreHint] = [:]
    /// The clock value of each window's latest focus. Parked windows keep theirs.
    var stamps: [WindowID: UInt64] = [:]
    var clock: UInt64 = 0
    var lastContainerID = 0

    public init(orientation: Orientation = .horizontal) {
        root = Container(id: 0, orientation: orientation, children: [])
    }
}

struct Parked: Sendable {
    let window: WindowID
    /// The window was floating, so it returns to the floating list.
    let floating: Bool
}

/// Where a window stood in the tree when it left: its container, its index and share
/// there, and the container's orientation.
struct RestoreHint: Sendable {
    let container: Int
    let index: Int
    let fraction: Double
    let orientation: Orientation
    /// The sibling before the window, or after it when the window came first.
    let neighbor: NodeRef?
}

enum NodeRef: Sendable {
    case window(WindowID)
    case container(Int)
}

extension Workspace {
    /// Whether the window is tiled, floating or parked here.
    public func contains(_ window: WindowID) -> Bool {
        root.path(to: window) != nil || floating.contains(window) || parked.contains { $0.window == window }
    }

    /// The most recently focused window that is tiled or floating.
    public var focusedWindow: WindowID? {
        (root.windows + floating).filter { stamps[$0] != nil }.max { stamps[$0]! < stamps[$1]! }
    }

    /// Records that a tiled or floating window took focus. Focus on another tiled window
    /// ends fullscreen, because macOS raises the focused window over it.
    public mutating func focus(_ window: WindowID) {
        let tiled = root.path(to: window) != nil
        guard tiled || floating.contains(window) else { return }
        stamp(window)
        if tiled, fullscreenWindow != window { fullscreenWindow = nil }
        check()
    }

    /// Tiles a new window after the most recently focused tiled window, in that window's
    /// container, with the mean share of its new siblings (i3's `tree_open_con`).
    public mutating func insert(_ window: WindowID) {
        precondition(!contains(window), "window \(window) is already in the workspace")
        insertAfterMostRecent(window)
        normalize()
        check()
    }

    /// Forgets a window. Call it only when the WindowServer reports the window gone.
    @discardableResult
    public mutating func remove(_ window: WindowID) -> Bool {
        if let path = root.path(to: window) {
            root[path.dropLast()].children.remove(at: path.last!)
        } else if let index = floating.firstIndex(of: window) {
            floating.remove(at: index)
        } else if let index = parked.firstIndex(where: { $0.window == window }) {
            parked.remove(at: index)
        } else {
            return false
        }
        hints[window] = nil
        stamps[window] = nil
        if fullscreenWindow == window { fullscreenWindow = nil }
        normalize()
        check()
        return true
    }

    /// Takes a tiled or floating window out of the layout, keeping where it stood.
    @discardableResult
    public mutating func park(_ window: WindowID) -> Bool {
        if root.path(to: window) != nil {
            detach(window)
            parked.append(Parked(window: window, floating: false))
        } else if let index = floating.firstIndex(of: window) {
            floating.remove(at: index)
            parked.append(Parked(window: window, floating: true))
        } else {
            return false
        }
        normalize()
        check()
        return true
    }

    /// Returns parked windows to where they stood. They return in the reverse of the order
    /// they parked, which undoes the parking exactly when nothing else changed, as when an
    /// app hides and unhides its windows together.
    public mutating func unpark(_ windows: [WindowID]) {
        for entry in parked.reversed() where windows.contains(entry.window) {
            parked.removeAll { $0.window == entry.window }
            if entry.floating {
                floating.append(entry.window)
            } else {
                restore(entry.window)
            }
            normalize()
        }
        check()
    }

    /// Moves a tiled window to the floating list, keeping where it stood.
    @discardableResult
    public mutating func float(_ window: WindowID) -> Bool {
        guard root.path(to: window) != nil else { return false }
        detach(window)
        floating.append(window)
        normalize()
        check()
        return true
    }

    /// Tiles a floating window where it stood before it floated, or after the most recently
    /// focused tiled window if it never was tiled.
    @discardableResult
    public mutating func tile(_ window: WindowID) -> Bool {
        guard let index = floating.firstIndex(of: window) else { return false }
        floating.remove(at: index)
        restore(window)
        normalize()
        check()
        return true
    }

    /// The broken invariants: those of DESIGN 5.5, plus consistent focus stamps,
    /// fullscreen window and restore hints. Empty when the workspace is sound. Every
    /// mutation checks it in debug builds.
    public func validate() -> [String] {
        var problems: [String] = []
        var places: [WindowID: Int] = [:]
        var ids: Set<Int> = []
        func visit(_ container: Container, isRoot: Bool) {
            if !ids.insert(container.id).inserted { problems.append("container \(container.id) appears twice") }
            if !isRoot, container.children.count < 2 { problems.append("\(container) has fewer than two children") }
            let total = container.children.reduce(0) { $0 + $1.weight }
            if !container.children.isEmpty, abs(total - 1) > 1e-9 { problems.append("weights in \(container) sum to \(total)") }
            for child in container.children {
                if !(child.weight > 0 && child.weight.isFinite) { problems.append("weight \(child.weight) in \(container)") }
                switch child.kind {
                case .window(let id):
                    places[id, default: 0] += 1
                case .container(let nested):
                    if nested.orientation == container.orientation { problems.append("\(nested) nests in \(container)") }
                    visit(nested, isRoot: false)
                }
            }
        }
        visit(root, isRoot: true)
        if root.children.count == 1, case .container = root.children[0].kind { problems.append("the root holds a single container") }
        for window in floating + parked.map(\.window) {
            places[window, default: 0] += 1
        }
        for (window, count) in places where count > 1 {
            problems.append("window \(window) is in \(count) places")
        }
        if let fullscreenWindow, root.path(to: fullscreenWindow) == nil {
            problems.append("fullscreen window \(fullscreenWindow) is not tiled")
        }
        for window in hints.keys where places[window] == nil || root.path(to: window) != nil {
            problems.append("window \(window) has a restore hint but is tiled or unknown")
        }
        for entry in parked where !entry.floating && hints[entry.window] == nil {
            problems.append("parked window \(entry.window) has no restore hint")
        }
        for window in stamps.keys where places[window] == nil {
            problems.append("unknown window \(window) has a focus stamp")
        }
        return problems
    }
}

// MARK: Helpers for the operations

extension Workspace {
    func check() {
        assert(validate().isEmpty, "\(validate())")
    }

    /// Restores the invariants after a mutation. A root left holding a single container is
    /// replaced by that container, as in AeroSpace, so the root's orientation is the one on
    /// screen.
    mutating func normalize() {
        root.normalize()
        if root.children.count == 1, case .container(let only) = root.children[0].kind {
            root = only
        }
    }

    mutating func makeContainer(_ orientation: Orientation, _ children: [Node]) -> Container {
        lastContainerID += 1
        return Container(id: lastContainerID, orientation: orientation, children: children)
    }

    /// Moves the root into a new root with `orientation` (i3's `ws_force_orientation`).
    mutating func wrapRoot(_ orientation: Orientation) {
        let old = root
        root = makeContainer(orientation, [Node(kind: .container(old), weight: 1)])
    }

    mutating func stamp(_ window: WindowID) {
        clock += 1
        stamps[window] = clock
    }

    func stamp(of node: Node) -> UInt64 {
        switch node.kind {
        case .window(let id): stamps[id] ?? 0
        case .container(let container): container.children.map(stamp(of:)).max() ?? 0
        }
    }

    /// The child holding the most recently focused window, the last one on a tie
    /// (AeroSpace's `mostRecentChild`).
    func mostRecentChild(of container: Container) -> Node? {
        var best: (node: Node, stamp: UInt64)?
        for child in container.children {
            let stamp = stamp(of: child)
            if best == nil || stamp >= best!.stamp { best = (child, stamp) }
        }
        return best?.node
    }

    func mostRecentWindow(in node: Node) -> WindowID {
        switch node.kind {
        case .window(let id): id
        case .container(let container): mostRecentWindow(in: mostRecentChild(of: container)!)
        }
    }

    mutating func insertAfterMostRecent(_ window: WindowID) {
        guard let child = mostRecentChild(of: root) else {
            root.insert(.window(window), at: 0)
            return
        }
        let path = root.path(to: mostRecentWindow(in: child))!
        root[path.dropLast()].insert(.window(window), at: path.last! + 1)
    }

    /// Takes a tiled window out of the tree and records where it stood.
    mutating func detach(_ window: WindowID) {
        let path = root.path(to: window)!
        let parentPath = path.dropLast(), index = path.last!
        let parent = root[parentPath]
        let neighborIndex = index > 0 ? index - 1 : index + 1
        var neighbor: NodeRef?
        if parent.children.indices.contains(neighborIndex) {
            switch parent.children[neighborIndex].kind {
            case .window(let id): neighbor = .window(id)
            case .container(let container): neighbor = .container(container.id)
            }
        }
        hints[window] = RestoreHint(
            container: parent.id,
            index: index,
            fraction: parent.children[index].weight,
            orientation: parent.orientation,
            neighbor: neighbor
        )
        root[parentPath].children.remove(at: index)
        if fullscreenWindow == window { fullscreenWindow = nil }
    }

    /// Puts a window back where its hint says. If its old container still exists, the
    /// window returns there at its old index and share. If the container collapsed into
    /// the old neighbor, the neighbor is wrapped in a new container with the old
    /// orientation, which rebuilds the old container. Without either, the window goes
    /// after the most recently focused tiled window.
    mutating func restore(_ window: WindowID) {
        guard let hint = hints.removeValue(forKey: window) else {
            insertAfterMostRecent(window)
            return
        }
        if let path = root.path(toContainer: hint.container) {
            let count = root[path[...]].children.count
            root[path[...]].insert(.window(window), at: min(hint.index, count), fraction: hint.fraction)
            return
        }
        let found: [Int]? = switch hint.neighbor {
            case .window(let id): root.path(to: id)
            case .container(let id): root.path(toContainer: id)
            case nil: nil
        }
        guard var path = found else {
            insertAfterMostRecent(window)
            return
        }
        if path.isEmpty {
            wrapRoot(hint.orientation)
            path = [0]
        } else if root[path.dropLast()].orientation != hint.orientation {
            let parent = path.dropLast(), index = path.last!
            let wrapper = makeContainer(hint.orientation, [Node(kind: root[parent].children[index].kind, weight: 1)])
            root[parent].children[index].kind = .container(wrapper)
            path.append(0)
        }
        // A window with an index past 0 came after its neighbor.
        let index = path.last! + (hint.index > 0 ? 1 : 0)
        root[path.dropLast()].insert(.window(window), at: index, fraction: hint.fraction)
    }
}
