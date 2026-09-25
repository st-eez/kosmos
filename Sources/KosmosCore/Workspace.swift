import CoreGraphics

/// Parked windows are minimized, hidden with their app or in native fullscreen, out of the
/// layout until they return (docs/tree.md).
struct Workspace: Sendable {
    /// May be empty or hold one window. A root left holding a single container is replaced by
    /// that container.
    var root: Container
    var floating: [WindowID] = []
    /// The tiled window that covers the whole display rectangle.
    var fullscreenWindow: WindowID?
    /// Oldest first.
    var parked: [Parked] = []
    /// For each window that left the tree to float or park, oldest first.
    var hints: [RestoreHint] = []
    /// Counts changes to the tree other than windows leaving, and returning with a fresh
    /// hint. A hint is fresh when no change came after it.
    var edits = 0
    /// Each window's latest focus on `clock`. Parked windows keep theirs.
    var stamps: [WindowID: UInt64] = [:]
    var clock: UInt64 = 0
    var lastContainerID = 0

    init(orientation: Orientation = .horizontal) {
        root = Container(id: 0, orientation: orientation, children: [])
    }
}

struct Parked: Sendable {
    let window: WindowID
    /// It returns to the floating list.
    let floating: Bool
}

/// Where a window stood when it left the tree, as the windows it stood among, which outlive
/// the containers around them (docs/tree.md).
struct RestoreHint: Sendable {
    struct Level: Sendable {
        let orientation: Orientation
        /// The windows under each child of the container, with the child's share.
        let slots: [(windows: Set<WindowID>, weight: Double)]
        /// The child that holds the window.
        let index: Int
    }

    let window: WindowID
    /// The window's container first, then each ancestor up to the root.
    let levels: [Level]
    /// `Workspace.edits` when the hint was taken.
    let edits: Int
}

extension RestoreHint {
    /// With `new` standing where `old` stood, as the hint's window or a neighbour.
    func renaming(_ old: WindowID, to new: WindowID) -> RestoreHint {
        RestoreHint(window: window == old ? new : window, levels: levels.map { level in
            Level(orientation: level.orientation, slots: level.slots.map { slot in
                (slot.windows.contains(old) ? slot.windows.subtracting([old]).union([new]) : slot.windows, slot.weight)
            }, index: level.index)
        }, edits: edits)
    }
}

extension Workspace {
    /// Tiled, floating or parked.
    func contains(_ window: WindowID) -> Bool {
        root.path(to: window) != nil || floating.contains(window) || parked.contains { $0.window == window }
    }

    /// The most recently focused window that is tiled or floating, never a parked one.
    var focusedWindow: WindowID? {
        (root.windows + floating).filter { stamps[$0] != nil }.max { stamps[$0]! < stamps[$1]! }
    }

    /// Focus on another tiled window ends fullscreen, because macOS raises the focused window
    /// over it.
    mutating func focus(_ window: WindowID) {
        let tiled = root.path(to: window) != nil
        guard tiled || floating.contains(window) else { return }
        stamp(window)
        if tiled, fullscreenWindow != window { fullscreenWindow = nil }
        check()
    }

    mutating func insert(_ window: WindowID) {
        precondition(!contains(window), "window \(window) is already in the workspace")
        insertAfterMostRecent(window)
        normalize()
        edits += 1
        check()
    }

    mutating func insert(_ window: WindowID, first: Bool) {
        precondition(!contains(window), "window \(window) is already in the workspace")
        root.insert(.window(window), at: first ? 0 : root.children.count)
        normalize()
        edits += 1
        check()
    }

    /// The two share the target's space equally (docs/displays.md). In a container of
    /// `orientation` they become siblings.
    mutating func insert(_ window: WindowID, beside target: WindowID, _ orientation: Orientation, first: Bool) {
        precondition(!contains(window), "window \(window) is already in the workspace")
        pair(window, with: target, orientation, first: first)
        normalize()
        edits += 1
        check()
    }

    private mutating func pair(_ window: WindowID, with target: WindowID, _ orientation: Orientation, first: Bool) {
        let path = root.path(to: target)!
        let pair = [Node(kind: .window(target), weight: 1), Node(kind: .window(window), weight: 1)]
        root[path.dropLast()].children[path.last!].kind = .container(makeContainer(orientation, first ? pair.reversed() : pair))
    }

    @discardableResult
    mutating func remove(_ window: WindowID) -> Bool {
        if let path = root.path(to: window) {
            root[path.dropLast()].children.remove(at: path.last!)
            edits += 1
        } else if let index = floating.firstIndex(of: window) {
            floating.remove(at: index)
        } else if let index = parked.firstIndex(where: { $0.window == window }) {
            parked.remove(at: index)
        } else {
            return false
        }
        hints.removeAll { $0.window == window }
        stamps[window] = nil
        if fullscreenWindow == window { fullscreenWindow = nil }
        normalize()
        check()
        return true
    }

    /// Native tabs share one place, so `new` takes `old`'s place, share, focus stamp,
    /// fullscreen state and restore hints. False when `old` is not here, or `new` is.
    @discardableResult
    mutating func replace(_ old: WindowID, with new: WindowID) -> Bool {
        guard !contains(new) else { return false }
        if let path = root.path(to: old) {
            root[path.dropLast()].children[path.last!].kind = .window(new)
        } else if let index = floating.firstIndex(of: old) {
            floating[index] = new
        } else if let index = parked.firstIndex(where: { $0.window == old }) {
            parked[index] = Parked(window: new, floating: parked[index].floating)
        } else {
            return false
        }
        if let stamp = stamps.removeValue(forKey: old) { stamps[new] = stamp }
        if fullscreenWindow == old { fullscreenWindow = new }
        hints = hints.map { $0.renaming(old, to: new) }
        check()
        return true
    }

    @discardableResult
    mutating func park(_ window: WindowID) -> Bool {
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

    /// The windows return in the reverse of the order they parked, which undoes the parking
    /// exactly when nothing else changed. `rect` and `gaps` are the ones `frames` gets, for a
    /// stale hint.
    mutating func unpark(_ windows: [WindowID], in rect: CGRect, gaps: Gaps) {
        for entry in parked.reversed() where windows.contains(entry.window) {
            parked.removeAll { $0.window == entry.window }
            if entry.floating {
                floating.append(entry.window)
            } else {
                restore(entry.window, in: rect, gaps: gaps)
            }
            normalize()
        }
        check()
    }

    @discardableResult
    mutating func float(_ window: WindowID) -> Bool {
        guard root.path(to: window) != nil else { return false }
        detach(window)
        floating.append(window)
        normalize()
        check()
        return true
    }

    /// `rect` and `gaps` are as for `unpark`.
    @discardableResult
    mutating func tile(_ window: WindowID, in rect: CGRect, gaps: Gaps) -> Bool {
        guard let index = floating.firstIndex(of: window) else { return false }
        floating.remove(at: index)
        restore(window, in: rect, gaps: gaps)
        normalize()
        check()
        return true
    }

    /// The broken invariants of docs/tree.md, and of the stamps, the fullscreen window and the
    /// hints. Empty when the workspace is sound.
    func validate() -> [String] {
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
        for window in hints.map(\.window) where places[window] == nil || root.path(to: window) != nil {
            problems.append("window \(window) has a restore hint but is tiled or unknown")
        }
        for window in Set(hints.map(\.window)) where hints.count(where: { $0.window == window }) > 1 {
            problems.append("window \(window) has more than one restore hint")
        }
        for entry in parked where !entry.floating && !hints.contains(where: { $0.window == entry.window }) {
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

    /// The child holding the most recently focused window, the last one on a tie.
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

    /// Its space goes to the children that hold its nearest recorded siblings, which give it
    /// back when it returns.
    mutating func detach(_ window: WindowID) {
        let hint = hint(for: window)
        hints.append(hint)
        let path = root.path(to: window)!
        let parent = path.dropLast(), index = path.last!
        let tiled = Set(root.windows).subtracting([window])
        if let level = hint.levels.first(where: { !present($0, tiled).isEmpty }) {
            let siblings = present(level, tiled).reduce(into: Set<WindowID>()) { $0.formUnion(level.slots[$1].windows) }
            let holders = root[parent].children.indices.filter { $0 != index && !siblings.isDisjoint(with: root[parent].children[$0].windows) }
            let held = holders.reduce(0) { $0 + root[parent].children[$1].weight }
            let space = root[parent].children[index].weight
            for holder in holders {
                root[parent].children[holder].weight *= (held + space) / held
            }
        }
        root[parent].children.remove(at: index)
        if fullscreenWindow == window { fullscreenWindow = nil }
    }

    /// A return with a stale hint, or none, changes the tree like an insert, and leaves every
    /// window that had a point with one (docs/tree.md).
    mutating func restore(_ window: WindowID, in rect: CGRect, gaps: Gaps) {
        guard let index = hints.firstIndex(where: { $0.window == window }) else {
            insertAfterMostRecent(window)
            edits += 1
            return
        }
        let hint = hints.remove(at: index)
        guard hint.edits != edits else {
            place(hint)
            return
        }
        edits += 1
        let before = tileFrames(in: rect, gaps: gaps)
        let tiled = Set(root.windows)
        let bySiblings = hint.levels.contains { !present($0, tiled).isEmpty }
        var scale = 1.0
        while true {
            var attempt = self
            attempt.place(hint, scale: scale)
            attempt.normalize()
            let frames = attempt.tileFrames(in: rect, gaps: gaps)
            let own = frames[window]!, fits = own.width >= 1 && own.height >= 1
            let kept = frames.allSatisfy { id, frame in
                id == window || (frame.width >= min(1, before[id]!.width) && frame.height >= min(1, before[id]!.height))
            }
            if fits, kept {
                self = attempt
                return
            }
            // A smaller share helps only beside the siblings, while the window gets a point.
            guard bySiblings, fits else { break }
            scale /= 2
        }
        split(roomiest: window, in: rect, gaps: gaps)
    }

    /// In a new container across the roomiest window's container, so no other window moves.
    private mutating func split(roomiest window: WindowID, in rect: CGRect, gaps: Gaps) {
        let frames = tileFrames(in: rect, gaps: gaps)
        // The shorter side of each half, the length along the container or half the length
        // across it.
        func room(_ id: WindowID) -> CGFloat {
            let frame = frames[id]!
            return root[root.path(to: id)!.dropLast()].orientation == .horizontal
                ? min(frame.width, frame.height / 2) : min(frame.height, frame.width / 2)
        }
        guard let roomiest = root.windows.max(by: { room($0) < room($1) }) else {
            root.insert(.window(window), at: 0)
            return
        }
        pair(window, with: roomiest, root[root.path(to: roomiest)!.dropLast()].orientation.opposite, first: false)
    }

    /// Taken with every window that has a fresh hint put back, newest first, so hints taken
    /// in any order agree on where each window goes.
    private func hint(for window: WindowID) -> RestoreHint {
        var whole = self
        for hint in hints.reversed() where hint.edits == edits {
            whole.place(hint)
            whole.normalize()
        }
        var path = whole.root.path(to: window)!
        var levels: [RestoreHint.Level] = []
        while let index = path.popLast() {
            let container = whole.root[path[...]]
            let slots = container.children.map { (windows: Set($0.windows), weight: $0.weight) }
            levels.append(RestoreHint.Level(orientation: container.orientation, slots: slots, index: index))
        }
        return RestoreHint(window: window, levels: levels, edits: edits)
    }

    /// The slots of `level`, other than the window's own, with windows in `tiled`.
    private func present(_ level: RestoreHint.Level, _ tiled: Set<WindowID>) -> [Int] {
        level.slots.indices.filter { $0 != level.index && !level.slots[$0].windows.isDisjoint(with: tiled) }
    }

    /// At the lowest level of the hint with old siblings tiled, with the recorded share times
    /// `scale`.
    private mutating func place(_ hint: RestoreHint, scale: Double = 1) {
        let tiled = Set(root.windows)
        guard let level = hint.levels.first(where: { !present($0, tiled).isEmpty }) else {
            insertAfterMostRecent(hint.window)
            return
        }
        let present = present(level, tiled)
        let paths = present.flatMap { level.slots[$0].windows.intersection(tiled).map { root.path(to: $0)! } }
        // The lowest container holding the siblings' windows, and its children that do.
        var depth = 0
        while paths.allSatisfy({ $0.count > depth + 1 && $0[depth] == paths[0][depth] }) {
            depth += 1
        }
        let parent = paths[0].prefix(depth), container = root[parent]
        let holders = Set(paths.map { $0[depth] })
        let share = scale * level.slots[level.index].weight / present.reduce(0) { $0 + level.slots[$1].weight }
        let earlier = present.last { $0 < level.index }

        func children(_ slot: Int) -> [Int] {
            level.slots[slot].windows.intersection(tiled).map { root.path(to: $0)![depth] }
        }
        // The child holding the nearest earlier sibling, else the nearest later one.
        let anchor = earlier.map { children($0).max()! } ?? children(present.first { $0 > level.index }!).min()!

        if container.orientation == level.orientation {
            let index = earlier == nil ? anchor : anchor + 1
            let held = holders.reduce(0) { $0 + container.children[$1].weight }
            for holder in holders {
                root[parent].children[holder].weight /= 1 + share
            }
            root[parent].children.insert(Node(kind: .window(hint.window), weight: held * share / (1 + share)), at: index)
        } else {
            // The old container collapsed into the siblings, so rebuild it around them. After other
            // commands moved windows between them, only the run next to the nearest one goes in.
            var run = anchor...anchor
            while holders.contains(run.lowerBound - 1) { run = (run.lowerBound - 1)...run.upperBound }
            while holders.contains(run.upperBound + 1) { run = run.lowerBound...(run.upperBound + 1) }
            let siblings = run.count == 1 ? container.children[run.lowerBound].kind
                : .container(makeContainer(container.orientation, Array(container.children[run])))
            var nodes = [Node(kind: siblings, weight: 1)]
            nodes.insert(Node(kind: .window(hint.window), weight: share), at: earlier == nil ? 0 : 1)
            let rebuilt = makeContainer(level.orientation, nodes)
            let space = container.children[run].reduce(0) { $0 + $1.weight }
            root[parent].children.replaceSubrange(run, with: [Node(kind: .container(rebuilt), weight: space)])
        }
    }
}
