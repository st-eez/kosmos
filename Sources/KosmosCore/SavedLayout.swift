import CoreGraphics

/// The layout Kosmos writes as it changes and puts back when it starts again: each window's
/// workspace and place in the tree, the workspace each display shows, and the focus
/// (docs/tree.md). WindowServer numbers the windows, so the ids hold across a restart of
/// Kosmos and name other windows under another WindowServer.
public struct SavedLayout: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    /// A process, whose start time tells it from a later one with its pid.
    public struct Process: Codable, Equatable, Sendable {
        public var pid: Int32
        /// Microseconds since 1970.
        public var start: UInt64

        public init(pid: Int32, start: UInt64) {
            self.pid = pid
            self.start = start
        }
    }

    public struct Shown: Codable, Equatable, Sendable {
        public var display: DisplayID
        public var workspace: String
    }

    public struct Window: Codable, Equatable, Sendable {
        public var id: WindowID
        public var workspace: String
        public var floating: Bool
        /// It waits out of the tree, as minimized or hidden with its app, and holds no tile.
        public var parked: Bool
        /// It covers its workspace's display rectangle (`fullscreen`).
        public var fullscreen: Bool
        /// Its latest focus on its workspace's clock.
        public var focus: UInt64?
        /// Its restore hint: where it stands in the tree, or stood before it floated or
        /// parked, from its container up to the root. A floating window that never tiled has
        /// none.
        public var place: [Level]?
        /// The tree changed after it left.
        public var stale: Bool
    }

    public struct Level: Codable, Equatable, Sendable {
        public var orientation: Orientation
        /// The windows under each child of the container, with the child's share.
        public var slots: [Slot]
        /// The slot that holds the window.
        public var index: Int
    }

    public struct Slot: Codable, Equatable, Sendable {
        public var windows: [WindowID]
        public var weight: Double
    }

    public var version = SavedLayout.currentVersion
    /// The WindowServer that numbered the windows.
    public var windowServer: Process
    public var shown: [Shown]
    public var focusedWorkspace: String
    /// Nil when the focused workspace had no window.
    public var focusedWindow: WindowID?
    /// A window its app closed and kept is left out: shown again, it opens as a new window.
    public var windows: [Window]
}

extension Session {
    /// What `restore` puts back after a restart.
    public func savedLayout(windowServer: SavedLayout.Process) -> SavedLayout {
        var windows: [SavedLayout.Window] = []
        for name in names {
            let workspace = workspaces[name]!
            func saved(_ window: WindowID, floating: Bool, parked: Bool = false, fullscreen: Bool = false, stamp: UInt64?,
                       hint: RestoreHint?) -> SavedLayout.Window {
                SavedLayout.Window(id: window, workspace: name, floating: floating, parked: parked, fullscreen: fullscreen,
                                   focus: stamp, place: hint?.levels.map(SavedLayout.Level.init),
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
        return SavedLayout(windowServer: windowServer,
                           shown: monitors.compactMap { monitor in shown[monitor.id].map { SavedLayout.Shown(display: monitor.id, workspace: $0) } },
                           focusedWorkspace: focusedWorkspace, focusedWindow: focused, windows: windows)
    }

    /// Takes `layout` back at launch, before any window joins, so each window the layout has
    /// goes back to its place as Kosmos admits it (`add`), and each display shows its
    /// workspace again. A layout of another version or WindowServer changes nothing, and
    /// returns false. Where the profile differs, its workspaces and their displays win
    /// (docs/tree.md).
    @discardableResult
    public mutating func restore(_ layout: SavedLayout, windowServer: SavedLayout.Process) -> Bool {
        defer { check() }
        precondition(home.isEmpty, "a layout is restored before any window joins")
        guard layout.version == SavedLayout.currentVersion, layout.windowServer == windowServer else { return false }
        for entry in layout.windows where workspaces[entry.workspace] != nil {
            guard savedWorkspace(of: entry.id) == nil, let pending = entry.pending(edits: workspaces[entry.workspace]!.edits)
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
        return true
    }

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

extension SavedLayout.Level {
    init(_ level: RestoreHint.Level) {
        self.init(orientation: level.orientation,
                  slots: level.slots.map { SavedLayout.Slot(windows: $0.windows.sorted(), weight: $0.weight) },
                  index: level.index)
    }

    /// A file could hold any numbers, and the tree's operations trust a hint's.
    var isSound: Bool {
        slots.indices.contains(index) && slots.allSatisfy { $0.weight > 0 && $0.weight.isFinite }
    }
}

extension SavedLayout.Window {
    /// Nil for a tiled window with no sound place. `edits` is its workspace's.
    func pending(edits: Int) -> Pending? {
        guard place?.allSatisfy(\.isSound) != false, floating || place != nil else { return nil }
        let hint = place.map { levels in
            RestoreHint(window: id, levels: levels.map { level in
                RestoreHint.Level(orientation: level.orientation, slots: level.slots.map { (Set($0.windows), $0.weight) },
                                  index: level.index)
            }, edits: stale ? edits - 1 : edits)
        }
        return Pending(window: id, floating: floating, parked: parked, fullscreen: fullscreen, stamp: focus, hint: hint)
    }
}
