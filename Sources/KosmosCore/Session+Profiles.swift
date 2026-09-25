import CoreGraphics

extension Session {
    /// Takes the displays and the profile's workspaces after a display or profile change
    /// (docs/displays.md). The windows of a workspace that `names` leaves out move to
    /// the end of the workspace `merge` names for it, else of the first, and come back when a
    /// later profile lists their workspace, unless they moved since. The focused workspace
    /// keeps the focus, on its display, and every other display keeps its workspace if it may
    /// still show it. A drag that the change, a lock or a wake cut short ends with the
    /// lifted windows back where they stood. It plans nothing: the app resyncs every window
    /// after it.
    public mutating func reconfigure(names newNames: [String], monitors newMonitors: [Monitor],
                                     assigned newAssigned: [String: DisplayID], merge: [String: String]) {
        defer { check() }
        precondition(!newNames.isEmpty, "a session needs a workspace")
        precondition(!newMonitors.isEmpty, "a session needs a display")
        for window in lifted { putBack(window) }
        lifted = []
        let focusedBefore = focusedDisplay
        for name in newNames where workspaces[name] == nil {
            let monitor = newMonitors.first { $0.id == newAssigned[name] } ?? newMonitors[0]
            workspaces[name] = mergedAway.removeValue(forKey: name).map { restored($0, as: name, on: monitor) } ?? Workspace()
        }
        for name in names where !newNames.contains(name) {
            let target = merge[name].flatMap { newNames.contains($0) ? $0 : nil } ?? newNames[0]
            mergedAway[name] = workspaces[name]
            for window in allWindows(of: name) {
                carry(window, to: target)
                if merged[window] == nil { merged[window] = name }
            }
            workspaces[name] = nil
            if focusedWorkspace == name { focusedWorkspace = target }
            if previous == name { previous = nil }
        }
        names = newNames
        monitors = Monitor.arranged(newMonitors)
        assigned = connected(newAssigned)
        arrange(focusing: focusedWorkspace, near: focusedBefore)
    }

    /// A workspace a profile left out, `saved` as it was, back with the windows still merged
    /// out of it. Each takes the state it has now: parked or not, tiled or floating. The
    /// others, which the user moved or closed meanwhile, leave it. `monitor` is where it is
    /// laid out, for windows returning to a tree that changed. The windows return in the
    /// saved order: a return to a changed tree depends on the ones before it.
    private mutating func restored(_ saved: Workspace, as name: String, on monitor: Monitor) -> Workspace {
        var workspace = saved
        let windows = saved.root.windows + saved.floating + saved.parked.map(\.window)
        for window in windows where merged[window] != name {
            workspace.remove(window)
        }
        for window in windows where merged[window] == name {
            let current = workspaces[home[window]!]!
            let parked = current.parked.first { $0.window == window }
            let floating = parked?.floating ?? current.floating.contains(window)
            _ = workspaces[home[window]!]!.remove(window)
            if workspace.parked.contains(where: { $0.window == window }) {
                workspace.unpark([window], in: monitor.area, gaps: monitor.gaps)
            }
            if floating, !workspace.floating.contains(window) { workspace.float(window) }
            if !floating, workspace.floating.contains(window) { workspace.tile(window, in: monitor.area, gaps: monitor.gaps) }
            if parked != nil { workspace.park(window) }
            home[window] = name
            merged[window] = nil
        }
        return workspace
    }

    /// Moves a window to the end of another workspace, tiled, floating or parked as it was.
    private mutating func carry(_ window: WindowID, to name: String) {
        let source = home[window]!
        let floating = workspaces[source]!.floating.contains(window)
        let parked = workspaces[source]!.parked.first { $0.window == window }
        _ = workspaces[source]!.remove(window)
        if floating || parked?.floating == true {
            workspaces[name]!.floating.append(window)
        } else {
            workspaces[name]!.insert(window, first: false)
        }
        if parked != nil { workspaces[name]!.park(window) }
        home[window] = name
    }

    /// Shows `focus` on its display and focuses it. Every other display keeps its workspace
    /// where that may stay, and a display left with none shows the workspace it showed
    /// before, if that may show there, else the first workspace assigned to it, else the
    /// first free hidden one. A free `focus` that no display shows goes to `near`, else to
    /// the main display.
    mutating func arrange(focusing focus: String, near: DisplayID?) {
        let ids = Set(monitors.map(\.id))
        for (id, name) in shown where !ids.contains(id) || workspaces[name] == nil { shownBefore[id] = name }
        shown = shown.filter { id, name in ids.contains(id) && workspaces[name] != nil && (assigned[name] ?? id) == id }
        let main = monitors.first { $0.frame.origin == .zero } ?? monitors[0]
        let display = assigned[focus] ?? displayShowing(focus) ?? near.flatMap { ids.contains($0) ? $0 : nil } ?? main.id
        shown = shown.filter { $0.value != focus }
        shown[display] = focus
        for monitor in monitors where shown[monitor.id] == nil {
            let hidden = names.filter { !isShown($0) }
            // What it showed before, once that may show here again.
            let before = shownBefore[monitor.id].flatMap { name in
                hidden.contains(name) && (assigned[name] ?? monitor.id) == monitor.id ? name : nil
            }
            if before != nil { shownBefore[monitor.id] = nil }
            shown[monitor.id] = before ?? hidden.first { assigned[$0] == monitor.id } ?? hidden.first { assigned[$0] == nil }
        }
        focusedWorkspace = focus
    }

    func connected(_ assigned: [String: DisplayID]) -> [String: DisplayID] {
        assigned.filter { name, id in workspaces[name] != nil && monitors.contains { $0.id == id } }
    }
}
