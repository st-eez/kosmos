/// The WindowServer id of a window.
public typealias WindowID = UInt32

public enum Orientation: Sendable {
    case horizontal
    case vertical

    var opposite: Orientation { self == .horizontal ? .vertical : .horizontal }
}

public enum Direction: Sendable {
    case left, right, up, down

    var orientation: Orientation { self == .left || self == .right ? .horizontal : .vertical }
    /// Right and down point toward later children.
    var isForward: Bool { self == .right || self == .down }
    var step: Int { isForward ? 1 : -1 }
}

/// A window or a container in a workspace tree, with its share of the parent.
struct Node: Sendable {
    enum Kind: Sendable {
        case window(WindowID)
        case container(Container)
    }

    var kind: Kind
    /// The share of the parent's length along the parent's orientation. Siblings sum to 1.
    var weight: Double
}

/// An i3 `tiles` container: its children side by side along its orientation.
struct Container: Sendable {
    /// Unique within a workspace, so a restore hint can find the container again.
    let id: Int
    var orientation: Orientation
    var children: [Node]
}

extension Node {
    /// The windows in depth first order.
    var windows: [WindowID] {
        switch kind {
        case .window(let id): [id]
        case .container(let container): container.windows
        }
    }
}

extension Container: CustomStringConvertible {
    /// The arrangement without weights, for example `h[1 v[2 3]]`.
    var description: String {
        let items = children.map { child in
            switch child.kind {
            case .window(let id): "\(id)"
            case .container(let container): container.description
            }
        }
        return (orientation == .horizontal ? "h[" : "v[") + items.joined(separator: " ") + "]"
    }
}

extension Container {
    /// The container reached by following child indexes down from this one.
    subscript(path: ArraySlice<Int>) -> Container {
        get {
            guard let index = path.first else { return self }
            guard case .container(let child) = children[index].kind else { preconditionFailure("the path ends at a window") }
            return child[path.dropFirst()]
        }
        set {
            guard let index = path.first else {
                self = newValue
                return
            }
            guard case .container(var child) = children[index].kind else { preconditionFailure("the path ends at a window") }
            child[path.dropFirst()] = newValue
            children[index].kind = .container(child)
        }
    }

    /// The node at a path of at least one index.
    func node(at path: [Int]) -> Node {
        self[path.dropLast()].children[path.last!]
    }

    func path(to window: WindowID) -> [Int]? {
        for (index, child) in children.enumerated() {
            switch child.kind {
            case .window(let id):
                if id == window { return [index] }
            case .container(let container):
                if let rest = container.path(to: window) { return [index] + rest }
            }
        }
        return nil
    }

    func path(toContainer id: Int) -> [Int]? {
        if self.id == id { return [] }
        for (index, child) in children.enumerated() {
            if case .container(let container) = child.kind, let rest = container.path(toContainer: id) {
                return [index] + rest
            }
        }
        return nil
    }

    /// The windows in depth first order.
    var windows: [WindowID] { children.flatMap(\.windows) }

    /// Inserts a child with the mean share of its siblings.
    mutating func insert(_ kind: Node.Kind, at index: Int) {
        let weight = children.isEmpty ? 1 : children.reduce(0) { $0 + $1.weight } / Double(children.count)
        children.insert(Node(kind: kind, weight: weight), at: index)
    }

    /// Restores the invariants below this container and scales its weights to sum to 1.
    /// A container left empty is dropped. One left with a single child is replaced by that
    /// child, which takes its weight. A child container with this container's orientation
    /// is spliced in, and its children keep their sizes on screen.
    mutating func normalize() {
        var normalized: [Node] = []
        for var child in children {
            if case .container(var container) = child.kind {
                container.normalize()
                switch container.children.count {
                case 0: continue
                case 1: child.kind = container.children[0].kind
                default: child.kind = .container(container)
                }
            }
            if case .container(let container) = child.kind, container.orientation == orientation {
                normalized += container.children.map { Node(kind: $0.kind, weight: child.weight * $0.weight) }
            } else {
                normalized.append(child)
            }
        }
        children = normalized
        let total = children.reduce(0) { $0 + $1.weight }
        for index in children.indices {
            children[index].weight /= total
        }
    }

    mutating func balance() {
        for index in children.indices {
            children[index].weight = 1 / Double(children.count)
            if case .container(var container) = children[index].kind {
                container.balance()
                children[index].kind = .container(container)
            }
        }
    }
}
