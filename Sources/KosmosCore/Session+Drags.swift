import CoreGraphics

/// A tiled window the user drags by its title bar (docs/displays.md).
public enum TitleBarDrag {
    public static let dragThreshold: CGFloat = 10

    /// Where macOS resizes a window at `frame`. A title-bar drag keeps the pointer inside the
    /// frame, away from the side edges.
    public static func onResizeBorder(_ pointer: CGPoint, of frame: CGRect) -> Bool {
        let reach: CGFloat = 6
        guard frame.insetBy(dx: -reach, dy: -reach).contains(pointer) else { return false }
        return pointer.x <= frame.minX + reach || pointer.x >= frame.maxX - reach
            || pointer.y >= frame.maxY - reach || pointer.y < frame.minY
    }
}

extension Session {
    /// A floating window whose center lands on a display showing another workspace joins it
    /// (docs/displays.md). The plan asks for no focus: the window is key.
    public mutating func dragged(_ window: WindowID, to frame: CGRect) -> Plan? {
        defer { check() }
        guard let source = home[window], isShown(source), workspaces[source]!.floating.contains(window),
              let name = workspace(at: CGPoint(x: frame.midX, y: frame.midY)), name != source else { return nil }
        var plan = move(window, from: source, to: name, follow: focused == window)
        plan.focus = nil
        return plan
    }

    /// The window parks where it stood until `drop`, so the plan has no frame for it
    /// (docs/displays.md).
    public mutating func lift(_ window: WindowID) -> Plan? {
        defer { check() }
        guard let name = home[window], isShown(name), workspaces[name]!.root.path(to: window) != nil else { return nil }
        workspaces[name]!.park(window)
        lifted.insert(window)
        return Plan(frames: frames(of: name))
    }

    public mutating func drop(at point: CGPoint) -> Plan {
        defer { check() }
        var plan = Plan()
        var changed: Set<String> = []
        let name = workspace(at: point)
        for window in lifted.sorted() {
            let source = home[window]!
            changed.insert(source)
            guard let name else {
                putBack(window)
                if !isShown(source) { plan.hide.append(window) }
                continue
            }
            let tiles = frames(of: name).sorted { $0.key < $1.key }
            func distance(_ frame: CGRect) -> CGFloat { hypot(frame.midX - point.x, frame.midY - point.y) }
            let target = tiles.first { $0.value.contains(point) } ?? tiles.min { distance($0.value) < distance($1.value) }
            _ = workspaces[source]!.remove(window)
            if let target {
                let tile = target.value, across = tile.width > tile.height
                workspaces[name]!.insert(window, beside: target.key, across ? .horizontal : .vertical,
                                         first: across ? point.x < tile.midX : point.y < tile.midY)
            } else {
                workspaces[name]!.insert(window, first: false)
            }
            home[window] = name
            if name != source { mergedFrom[window] = nil }
            workspaces[name]!.focus(window)
            focusShown(name)
            plan.focus = .window(window)
            changed.insert(name)
        }
        lifted = []
        plan.frames = frames(of: changed)
        return plan
    }

    mutating func putBack(_ window: WindowID) {
        let name = home[window]!, monitor = monitor(of: name)
        workspaces[name]!.unpark([window], in: monitor.area, gaps: monitor.gaps)
    }

    /// Tiles the user moved or resized without a lift go back (docs/geometry.md).
    public func released(_ windows: Set<WindowID>) -> Plan {
        var changed: Set<String> = []
        for window in windows {
            guard let name = home[window], isShown(name), workspaces[name]!.root.path(to: window) != nil else { continue }
            changed.insert(name)
        }
        return Plan(frames: frames(of: changed))
    }

    /// A resize moves the edges on the press's side of the center, and a tile with no neighbour
    /// there moves the other edge (docs/modifier-drags.md).
    public func beginDrag(_ grab: DragGate.Grab, frame: CGRect) -> ModifierDrag? {
        guard isVisible(grab.window), let name = home[grab.window] else { return nil }
        let workspace = workspaces[name]!
        let sides: [Direction] = [grab.start.x < frame.midX ? .left : .right, grab.start.y < frame.midY ? .up : .down]
        if workspace.floating.contains(grab.window) {
            return ModifierDrag(grab: grab, frame: frame, edges: sides, tile: nil)
        }
        let edges = sides.compactMap { side in [side, side.opposite].first { workspace.neighbor(of: grab.window, $0) != nil } }
        return ModifierDrag(grab: grab, frame: frame, edges: edges, tile: frames(of: name)[grab.window])
    }

    /// Each edge goes to the tile's edge at the press carried by `delta`, so one stopped at a
    /// limit follows the pointer again as it comes back.
    public mutating func dragEdges(_ drag: ModifierDrag, by delta: CGSize) -> Plan? {
        defer { check() }
        let window = drag.grab.window
        guard let tile = drag.tile, let name = home[window], isShown(name), workspaces[name]!.fullscreenWindow == nil
        else { return nil }
        let monitor = monitor(of: name)
        var changed = false
        for edge in drag.edges {
            guard let now = frames(of: name)[window] else { return nil }
            let amount = switch edge {
            case .left: now.minX - (tile.minX + delta.width)
            case .right: tile.maxX + delta.width - now.maxX
            case .up: now.minY - (tile.minY + delta.height)
            case .down: tile.maxY + delta.height - now.maxY
            }
            if amount != 0,
               workspaces[name]!.moveEdge(window, edge, by: amount, in: monitor.area, gaps: monitor.gaps, minimums: minimums) {
                changed = true
            }
        }
        guard changed else { return nil }
        return Plan(frames: frames(of: name))
    }

    public func resized(_ drag: ModifierDrag, by delta: CGSize) -> CGRect {
        let start = drag.frame, least = minimums[drag.grab.window] ?? .zero, side = ModifierDrag.smallestSide
        let (width, height) = (max(least.width, side), max(least.height, side))
        var frame = start
        for edge in drag.edges {
            switch edge {
            case .left:
                frame.size.width = max(start.width - delta.width, width)
                frame.origin.x = start.maxX - frame.width
            case .right:
                frame.size.width = max(start.width + delta.width, width)
            case .up:
                frame.size.height = max(start.height - delta.height, height)
                frame.origin.y = start.maxY - frame.height
            case .down:
                frame.size.height = max(start.height + delta.height, height)
            }
        }
        return frame
    }
}
