import CoreGraphics

/// The layout Kosmos writes as it changes and puts back when it starts again: each window's
/// workspace and place in the tree, the workspace each display shows, and the focus
/// (docs/tree.md). WindowServer numbers the windows, so the ids hold across a restart of
/// Kosmos.
public struct SavedLayout: Codable, Equatable, Sendable {
    public struct Shown: Codable, Equatable, Sendable {
        public var display: DisplayID
        public var workspace: String
    }

    public struct Window: Codable, Equatable, Sendable {
        public var window: WindowID
        public var workspace: String
        public var floating: Bool
        /// It waits out of the tree, as minimized or hidden with its app, and holds no tile.
        public var parked: Bool
        /// It covers its workspace's display rectangle (`fullscreen`).
        public var fullscreen: Bool
        /// Its latest focus on its workspace's clock, an order only.
        public var stamp: UInt64?
        /// Its restore hint's levels: where it stands in the tree, or stood before it floated
        /// or parked. A floating window that never tiled has none.
        var levels: [RestoreHint.Level]?
        /// The tree changed after it left, so its hint is stale.
        public var stale: Bool
    }

    public var shown: [Shown]
    public var focusedWorkspace: String
    /// Nil when the focused workspace had no window.
    public var focusedWindow: WindowID?
    /// A window its app closed and kept is left out: shown again, it opens as a new window.
    public var windows: [Window]
}

extension Session {
    /// What `restore` puts back after a restart.
    public func savedLayout() -> SavedLayout {
        var windows: [SavedLayout.Window] = []
        for name in names {
            let workspace = workspaces[name]!
            func saved(_ window: WindowID, floating: Bool, parked: Bool = false, fullscreen: Bool = false, stamp: UInt64?,
                       hint: RestoreHint?) -> SavedLayout.Window {
                SavedLayout.Window(window: window, workspace: name, floating: floating, parked: parked, fullscreen: fullscreen,
                                   stamp: stamp, levels: hint?.levels,
                                   stale: hint.map { $0.edits != workspace.edits } ?? false)
            }
            func hint(_ window: WindowID) -> RestoreHint? { workspace.hints.first { $0.window == window } }
            windows += workspace.pending.map {
                saved($0.window, floating: $0.floating, parked: $0.parked, fullscreen: $0.fullscreen, stamp: $0.stamp, hint: $0.hint)
            }
            windows += workspace.root.windows.map {
                saved($0, floating: false, fullscreen: workspace.fullscreenWindow == $0, stamp: workspace.stamps[$0], hint: workspace.hint(for: $0))
            }
            windows += workspace.floating.map { saved($0, floating: true, stamp: workspace.stamps[$0], hint: hint($0)) }
            windows += workspace.parked.filter { parkReasons[$0.window] != .closedByApp }.map {
                saved($0.window, floating: $0.floating, parked: true, stamp: workspace.stamps[$0.window], hint: hint($0.window))
            }
        }
        return SavedLayout(shown: monitors.compactMap { monitor in shown[monitor.id].map { SavedLayout.Shown(display: monitor.id, workspace: $0) } },
                           focusedWorkspace: focusedWorkspace, focusedWindow: focused, windows: windows)
    }

    /// Takes `layout` back at launch, before any window joins, so each window the layout has
    /// goes back to its place as Kosmos admits it (`add`), and each display shows its
    /// workspace again. Where the profile differs, its workspaces and their displays win
    /// (docs/tree.md).
    public mutating func restore(_ layout: SavedLayout) {
        defer { check() }
        precondition(home.isEmpty, "a layout is restored before any window joins")
        for entry in layout.windows where workspaces[entry.workspace] != nil {
            guard savedWorkspace(of: entry.window) == nil, let pending = entry.pending(edits: workspaces[entry.workspace]!.edits)
            else { continue }
            workspaces[entry.workspace]!.pending.append(pending)
        }
        // Ranks keep the saved focus order, and no number from the file reaches the clock.
        for name in names {
            let pending = workspaces[name]!.pending
            let focused = pending.indices.filter { pending[$0].stamp != nil }.sorted { pending[$0].stamp! < pending[$1].stamp! }
            for (rank, index) in focused.enumerated() {
                workspaces[name]!.pending[index].stamp = UInt64(rank + 1)
            }
            workspaces[name]!.clock = UInt64(focused.count)
        }
        shown = [:]
        for entry in layout.shown where !shown.values.contains(entry.workspace) && shown[entry.display] == nil {
            shown[entry.display] = entry.workspace
        }
        let focus = workspaces[layout.focusedWorkspace] != nil ? layout.focusedWorkspace : focusedWorkspace
        arrange(focusing: focus, near: nil)
        savedFocus = focus == layout.focusedWorkspace ? layout.focusedWindow : nil
    }

    /// The windows the restored layout has that Kosmos has not admitted.
    public var pendingWindows: [WindowID] { names.flatMap { workspaces[$0]!.pending.map(\.window) } }

    /// Where the restored layout puts `window`, until Kosmos admits it.
    public func savedWorkspace(of window: WindowID) -> String? {
        names.first { workspaces[$0]!.pending.contains { $0.window == window } }
    }

    /// Drops the pending windows `gone` names, as windows that closed before Kosmos admitted
    /// them, and lays out their workspaces without them.
    public mutating func forgetPending(where gone: (WindowID) -> Bool) -> Plan {
        var changed: Set<String> = []
        for name in names where workspaces[name]!.pending.contains(where: { gone($0.window) }) {
            workspaces[name]!.pending.removeAll { gone($0.window) }
            changed.insert(name)
        }
        return Plan(frames: frames(of: changed))
    }

    mutating func forgetPending(_ window: WindowID) {
        for name in names { workspaces[name]!.pending.removeAll { $0.window == window } }
        for name in mergedAway.keys { mergedAway[name]!.pending.removeAll { $0.window == window } }
    }

    /// Admits a window the restored layout has on `name`. It returns to its place with no fit,
    /// as a returning window does, and Kosmos asks to focus it again when it was focused.
    mutating func admitSaved(_ window: WindowID, to name: String, minimum: CGSize, parked reason: ParkReason?) -> Plan {
        let monitor = monitor(of: name)
        workspaces[name]!.admit(window, parked: reason != nil, in: monitor.area, gaps: monitor.gaps)
        forgetPending(window)
        home[window] = name
        if minimum != .zero { constrained[window] = minimum }
        if let reason { parkReasons[window] = reason }
        var plan = Plan(frames: frames(of: name))
        if reason == nil, !isShown(name) { plan.hide = [window] }
        if savedFocus == window {
            savedFocus = nil
            if focused == window { plan.focus = intent }
        }
        return plan
    }
}

extension RestoreHint.Level {
    /// A file could hold any numbers, and placing a window divides by its siblings' weights,
    /// which the tree keeps between 0 and 1, summing to 1 (`Workspace.validate`).
    var isSound: Bool {
        slots.indices.contains(index) && slots.allSatisfy { (1e-6...1).contains($0.weight) }
            && abs(slots.reduce(0) { $0 + $1.weight } - 1) < 1e-6
    }
}

extension SavedLayout.Window {
    /// Nil for a tiled window with no sound hint. `edits` is its workspace's.
    func pending(edits: Int) -> Pending? {
        guard levels?.allSatisfy(\.isSound) != false, floating || levels != nil else { return nil }
        let hint = levels.map { RestoreHint(window: window, levels: $0, edits: stale ? edits - 1 : edits) }
        return Pending(window: window, floating: floating, parked: parked, fullscreen: fullscreen, stamp: stamp, hint: hint)
    }
}
