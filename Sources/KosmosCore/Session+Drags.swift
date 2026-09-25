import CoreGraphics

/// A tiled window the user drags by its title bar (docs/displays.md).
public enum TitleBarDrag {
    /// How far, in points, a drag goes before it lifts a tiled window, and before a
    /// modifier drag moves or resizes anything, so a click that jitters changes nothing
    /// (docs/displays.md and docs/modifier-drags.md).
    public static let liftDistance: CGFloat = 10

    /// Whether the pointer is where macOS resizes a window at `frame`: within 6 pt of its
    /// left, right or bottom edge, or just above its top edge, outside the title bar. A
    /// drag by the title bar keeps the pointer inside the frame, away from the side edges.
    public static func onResizeBorder(_ pointer: CGPoint, of frame: CGRect) -> Bool {
        let reach: CGFloat = 6
        guard frame.insetBy(dx: -reach, dy: -reach).contains(pointer) else { return false }
        return pointer.x <= frame.minX + reach || pointer.x >= frame.maxX - reach
            || pointer.y >= frame.maxY - reach || pointer.y < frame.minY
    }
}

extension Session {
    /// The user dragged a floating window of a shown workspace to `frame`. With its center on
    /// a display showing another workspace, it joins that workspace, and the focus goes with
    /// it if it had it, as AeroSpace's moveWithMouse binds it. The plan asks for no focus:
    /// the window is key. Nil when it stays, its center on its own workspace's display or on
    /// none (docs/displays.md).
    public mutating func dragged(_ window: WindowID, to frame: CGRect) -> Plan? {
        defer { check() }
        guard let source = home[window], isShown(source), workspaces[source]!.floating.contains(window),
              let name = workspace(at: CGPoint(x: frame.midX, y: frame.midY)), name != source else { return nil }
        var plan = move(window, from: source, to: name, follow: focused == window)
        plan.focus = nil
        return plan
    }

    /// The user started to drag a tiled window of a shown workspace by its title bar: it
    /// parks where it stood until `drop`. The plan has no frame for it. Nil when the window
    /// is not tiled on a shown workspace (docs/displays.md).
    public mutating func lift(_ window: WindowID) -> Plan? {
        defer { check() }
        guard let name = home[window], isShown(name), workspaces[name]!.root.path(to: window) != nil else { return nil }
        workspaces[name]!.park(window)
        lifted.insert(window)
        return Plan(frames: frames(of: name))
    }

    /// The left button came up at `point` with windows lifted. Each tiles on the workspace
    /// shown on the display under the pointer, beside the tile under it or the closest one,
    /// and takes the focus; off every display, or over one showing no workspace, it goes
    /// back to where it stood (docs/displays.md).
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
            if name != source { merged[window] = nil }
            workspaces[name]!.focus(window)
            focusShown(name)
            plan.focus = .window(window)
            changed.insert(name)
        }
        lifted = []
        plan.frames = frames(of: changed)
        return plan
    }

    /// A lifted window returns to where it stood, ending its drag.
    mutating func putBack(_ window: WindowID) {
        let name = home[window]!, monitor = monitor(of: name)
        workspaces[name]!.unpark([window], in: monitor.area, gaps: monitor.gaps)
    }

    /// The user let go of the left button after moving or resizing tiled windows of shown
    /// workspaces without lifting them, as by their edges. Each goes back to its tile, as
    /// Omarchy leaves Hyprland's `resize_on_border` off so a tile's edge resizes nothing. The
    /// plan has their workspaces' frames (docs/geometry.md).
    public func released(_ windows: Set<WindowID>) -> Plan {
        var changed: Set<String> = []
        for window in windows {
            guard let name = home[window], isShown(name), workspaces[name]!.root.path(to: window) != nil else { continue }
            changed.insert(name)
        }
        return Plan(frames: frames(of: changed))
    }

    /// A modifier drag of `grab.window`, a tiled or floating window of a shown workspace
    /// that WindowServer has at `frame`, or nil for any other window (docs/modifier-drags.md).
    /// A resize moves the edges on the sides of the window's center the press was on,
    /// left or right and top or bottom, as Hyprland's DragController picks the corner. A tile
    /// with no neighbour on that side moves its edge on the other side, as Hyprland's dwindle
    /// layout does for a window at the display's edge, and one with neighbours on neither
    /// side moves no edge on that axis.
    public func beginDrag(_ grab: DragGate.Grab, frame: CGRect) -> ModifierDrag? {
        guard isVisible(grab.window), let name = home[grab.window] else { return nil }
        let workspace = workspaces[name]!
        let sides: [Direction] = [grab.start.x < frame.midX ? .left : .right, grab.start.y < frame.midY ? .up : .down]
        if workspace.floating.contains(grab.window) {
            return ModifierDrag(grab: grab, frame: frame, floating: true, edges: sides, tile: nil)
        }
        let edges = sides.compactMap { side in [side, side.opposite].first { workspace.neighbor(of: grab.window, $0) != nil } }
        return ModifierDrag(grab: grab, frame: frame, floating: false, edges: edges, tile: frames(of: name)[grab.window])
    }

    /// Moves the edges of a modifier drag's tiled window where the pointer takes them,
    /// `delta` from where the button went down, as far as `Workspace.moveEdge` can: each
    /// goes from the tile's edge then to that edge carried by `delta`, so one stopped at a
    /// limit follows the pointer again as it comes back. The plan has the workspace's frames.
    /// Nil when nothing changed, and while the window's workspace is hidden or in fullscreen.
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

    /// The frame of a modifier drag's floating window resized `delta` from where the button
    /// went down: the drag's edges follow the pointer and the others stay, as Hyprland's
    /// DragController resizes a floating window. Neither side goes below the window's
    /// recorded minimum, nor below 20 pt, Hyprland's MIN_WINDOW_SIZE.
    public func resized(_ drag: ModifierDrag, by delta: CGSize) -> CGRect {
        let start = drag.frame, least = minimums[drag.grab.window] ?? .zero
        let (width, height) = (max(least.width, 20), max(least.height, 20))
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
