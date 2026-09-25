import CoreGraphics

/// Why a window waits parked when Kosmos admits it, as at launch (DESIGN.md, section 5.5).
public enum ParkReason: Equatable, Sendable {
    case fullscreen
    case minimized
    case appHidden

    /// Fullscreen comes first: a fullscreen window of a hidden app returns when it leaves
    /// fullscreen. A minimized window stays minimized when its app unhides, so it is not
    /// hidden with the app.
    public static func atAdmission(fullscreen: Bool, minimized: Bool, appHidden: Bool) -> ParkReason? {
        if fullscreen { return .fullscreen }
        if minimized { return .minimized }
        return appHidden ? .appHidden : nil
    }
}

/// Every workspace, the displays that show them, and the one with the focus (DESIGN.md,
/// sections 4.3 and 5.13). A change returns a Plan that the app carries out; the Session
/// never talks to macOS.
public struct Session: Sendable {
    /// What the app does after a change.
    public struct Plan: Equatable, Sendable {
        /// Windows to reveal and to conceal.
        public var show: [WindowID] = []
        public var hide: [WindowID] = []
        /// Targets for the shown workspace, and for a hidden one laid out while hidden.
        /// The frame ledger drops the ones already in place.
        public var frames: [WindowID: CGRect] = [:]
        /// The window to make key, or nil to leave focus alone.
        public var focus: KeyWindow?

        public init() {}

        public var isEmpty: Bool { show.isEmpty && hide.isEmpty && frames.isEmpty && focus == nil }
    }

    /// In the order `next` and `prev` walk, as the profile lists them.
    public private(set) var names: [String]
    private(set) var workspaces: [String: Workspace]
    /// Connected displays, left to right, then top to bottom. Never empty.
    public private(set) var monitors: [Monitor]
    /// The workspace each display shows. A display that no workspace can go to shows none.
    private var shown: [DisplayID: String] = [:]
    /// The display the profile assigns each workspace to, among the connected ones. A
    /// workspace left out is free.
    private var assigned: [String: DisplayID] = [:]
    /// The workspace of the focused display, which holds the focus. A display always shows
    /// it.
    public private(set) var focusedWorkspace: String
    private var previous: String?
    private var home: [WindowID: String] = [:]
    /// Parked windows whose workspace was hidden when they parked, so Kosmos had concealed
    /// them. Switches skip parked windows, so they stay concealed until they return.
    private var parkedConcealed: Set<WindowID> = []
    /// The smallest size each window accepted, as frames read back after writes show.
    private(set) var minimums: [WindowID: CGSize] = [:]
    /// Workspaces a profile left out, as they were: their trees, shares and focus order. A
    /// profile that lists one again gets it back with its windows still merged.
    private var mergedAway: [String: Workspace] = [:]
    /// Windows a profile moved out of a workspace it left out, by that workspace. A window
    /// the user moves or closes leaves it, and its workspace comes back without it.
    private var merged: [WindowID: String] = [:]
    /// The workspace a display showed before it left, or before a profile left that
    /// workspace out, for when it shows one again.
    private var shownBefore: [DisplayID: String] = [:]

    /// `assigned` maps workspaces to the ids of `monitors`. The first workspace has the focus.
    public init(names: [String], monitors: [Monitor], assigned: [String: DisplayID] = [:]) {
        precondition(!names.isEmpty, "a session needs a workspace")
        precondition(!monitors.isEmpty, "a session needs a display")
        self.names = names
        workspaces = Dictionary(uniqueKeysWithValues: names.map { ($0, Workspace()) })
        self.monitors = Monitor.arranged(monitors)
        focusedWorkspace = names[0]
        self.assigned = connected(assigned)
        arrange(focusing: names[0], near: nil)
    }

    /// One display, whose whole rectangle tiles.
    public init(names: [String], display: CGRect, gaps: Gaps = Gaps()) {
        self.init(names: names, monitors: [Monitor(id: 1, frame: display, gaps: gaps)])
    }

    public func workspace(of window: WindowID) -> String? { home[window] }

    /// The focused window of the focused workspace.
    public var focused: WindowID? { workspaces[focusedWorkspace]!.focusedWindow }

    // MARK: Displays

    /// Whether a display shows the workspace.
    public func isShown(_ name: String) -> Bool { shown.values.contains(name) }

    /// The workspaces the displays show, in display order.
    public var shownWorkspaces: [String] { monitors.compactMap { shown[$0.id] } }

    /// Nil for a display that no workspace can go to.
    public func workspace(shownOn display: DisplayID) -> String? { shown[display] }

    /// The display that shows the workspace, else the one it is assigned to, else the
    /// focused display: where it is laid out, and where `workspace` shows it.
    public func monitor(of name: String) -> Monitor {
        let id = displayShowing(name) ?? assigned[name] ?? focusedDisplay
        return monitors.first { $0.id == id }!
    }

    public var focusedDisplay: DisplayID { displayShowing(focusedWorkspace)! }

    private func displayShowing(_ name: String) -> DisplayID? { shown.first { $0.value == name }?.key }

    /// The workspace shown on the display under `point`.
    private func workspace(at point: CGPoint) -> String? {
        monitors.first { $0.frame.contains(point) }.flatMap { shown[$0.id] }
    }

    private func connected(_ assigned: [String: DisplayID]) -> [String: DisplayID] {
        assigned.filter { name, id in workspaces[name] != nil && monitors.contains { $0.id == id } }
    }

    /// Takes the displays and the profile's workspaces after a display or profile change
    /// (DESIGN.md, section 5.13). The windows of a workspace that `names` leaves out move to
    /// the end of the workspace `merge` names for it, else of the first, and come back when a
    /// later profile lists their workspace, unless they moved since. The focused workspace
    /// keeps the focus, on its display, and every other display keeps its workspace if it may
    /// still show it. It plans nothing: the app resyncs every window after it.
    public mutating func reconfigure(names newNames: [String], monitors newMonitors: [Monitor],
                                     assigned newAssigned: [String: DisplayID], merge: [String: String]) {
        precondition(!newNames.isEmpty, "a session needs a workspace")
        precondition(!newMonitors.isEmpty, "a session needs a display")
        let focusedBefore = focusedDisplay
        for name in newNames where workspaces[name] == nil {
            let area = newMonitors.first { $0.id == newAssigned[name] }?.area ?? newMonitors[0].area
            workspaces[name] = mergedAway.removeValue(forKey: name).map { restored($0, as: name, in: area) } ?? Workspace()
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

    /// Tiled, floating and parked, in that order.
    private func allWindows(of name: String) -> [WindowID] {
        let workspace = workspaces[name]!
        return workspace.root.windows + workspace.floating + workspace.parked.map(\.window)
    }

    /// A workspace a profile left out, `saved` as it was, back with the windows still merged
    /// out of it. Each takes the state it has now: parked or not, tiled or floating. The
    /// others, which the user moved or closed meanwhile, leave it. `area` is where it is
    /// laid out, for windows returning to a tree that changed.
    private mutating func restored(_ saved: Workspace, as name: String, in area: CGRect) -> Workspace {
        var workspace = saved
        let returning = Set(merged.filter { $0.value == name }.keys)
        for window in saved.root.windows + saved.floating + saved.parked.map(\.window) where !returning.contains(window) {
            workspace.remove(window)
        }
        for window in returning {
            let current = workspaces[home[window]!]!
            let parked = current.parked.first { $0.window == window }
            let floating = parked?.floating ?? current.floating.contains(window)
            _ = workspaces[home[window]!]!.remove(window)
            if workspace.parked.contains(where: { $0.window == window }) { workspace.unpark([window], in: area, gaps: Gaps()) }
            if floating, !workspace.floating.contains(window) { workspace.float(window) }
            if !floating, workspace.floating.contains(window) { workspace.tile(window, in: area, gaps: Gaps()) }
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
    private mutating func arrange(focusing focus: String, near: DisplayID?) {
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

    /// Tiled and floating windows; parked windows are left to macOS.
    public func windows(of name: String) -> [WindowID] {
        guard let workspace = workspaces[name] else { return [] }
        return workspace.root.windows + workspace.floating
    }

    public func frames(of name: String) -> [WindowID: CGRect] {
        guard let workspace = workspaces[name] else { return [:] }
        let monitor = monitor(of: name)
        return workspace.frames(in: monitor.area, gaps: monitor.gaps, minimums: minimums)
    }

    // MARK: Windows arriving and leaving

    /// A managed window joins a workspace: the one a rule names, else the one shown on the
    /// display under `point`, the window's center, else the focused one (DESIGN.md, section
    /// 5.13).
    public mutating func add(_ window: WindowID, to name: String? = nil, at point: CGPoint? = nil) -> Plan {
        guard home[window] == nil else { return Plan() }
        let target = name.flatMap { workspaces[$0] != nil ? $0 : nil } ?? point.flatMap(workspace(at:)) ?? focusedWorkspace
        workspaces[target]!.insert(window)
        // A workspace with windows always has a focused one, as in i3; reports refine it.
        if workspaces[target]!.focusedWindow == nil { workspaces[target]!.focus(window) }
        home[window] = target
        var plan = Plan()
        plan.frames = frames(of: target)
        if !isShown(target) { plan.hide = [window] }
        return plan
    }

    /// Takes a window out of the tiling, as a window rule asks.
    public mutating func float(_ window: WindowID) -> Plan {
        guard let name = home[window], workspaces[name]!.float(window) else { return Plan() }
        var plan = Plan()
        plan.frames = frames(of: name)
        return plan
    }

    public mutating func remove(_ window: WindowID) -> Plan {
        guard let name = home.removeValue(forKey: window) else { return Plan() }
        minimums[window] = nil
        merged[window] = nil
        parkedConcealed.remove(window)
        let wasFocused = name == focusedWorkspace && focused == window
        _ = workspaces[name]!.remove(window)
        var plan = Plan()
        plan.frames = frames(of: name)
        if wasFocused { plan.focus = focused.map(KeyWindow.window) ?? KeyWindow.none }
        return plan
    }

    /// Native tabs share one place. `new`, the tab just selected, takes the place of `old`,
    /// the tab it replaces, with its share, focus and workspace, and `old` leaves the
    /// session (DESIGN.md, section 5.5). A tab Kosmos already placed as a window of its
    /// own, tiled or parked, as after Merge All Windows, leaves that place. A parked `old`,
    /// as the tab in native fullscreen, leaves `new` parked in its stead. `new` inherits the
    /// minimum of a tiled `old`, as tabs share a size, so a switch does not reflow to learn
    /// it again; a fullscreen tab's would fill the display. The plan has the frames, and
    /// conceals a tiled `new` when its place is on a hidden workspace. Nil, and nothing
    /// changes, when `old` holds no place.
    public mutating func replace(_ old: WindowID, with new: WindowID) -> Plan? {
        guard old != new, let name = home[old] else { return nil }
        let parked = isParked(old)
        var changed: Set<String> = [name]
        if let current = home.removeValue(forKey: new) {
            _ = workspaces[current]!.remove(new)
            parkedConcealed.remove(new)
            changed.insert(current)
        }
        workspaces[name]!.replace(old, with: new)
        home[old] = nil
        home[new] = name
        if let minimum = minimums.removeValue(forKey: old), !parked { minimums[new] = minimum }
        merged[new] = merged.removeValue(forKey: old)
        // Selected while its workspace is merged away, the tab returns in the place of `old`.
        if let origin = merged[new] {
            mergedAway[origin]?.remove(new)
            mergedAway[origin]?.replace(old, with: new)
        }
        parkedConcealed.remove(old)
        var plan = Plan()
        for name in changed { plan.frames.merge(frames(of: name)) { current, _ in current } }
        if !isShown(name), !isParked(new) { plan.hide = [new] }
        return plan
    }

    /// Minimized, hidden with their app, or in native fullscreen: out of the layout until
    /// they return to their places. Parked windows take no part in switches, so Kosmos
    /// neither conceals nor reveals them, and they get no frames. Focus is left to macOS,
    /// which keys another window itself; asking for one here would pull the screen out of
    /// a native fullscreen Space.
    public mutating func park(_ windows: [WindowID]) -> Plan {
        var changed: Set<String> = []
        for window in windows {
            guard let name = home[window], workspaces[name]!.park(window) else { continue }
            changed.insert(name)
            if !isShown(name) { parkedConcealed.insert(window) }
        }
        var plan = Plan()
        for name in changed { plan.frames.merge(frames(of: name)) { current, _ in current } }
        return plan
    }

    /// Parked windows return to their own workspaces at their saved positions, and Kosmos
    /// follows `follow` there when its workspace is not the focused one, as it does for
    /// Command-Tab (DESIGN.md, section 5.5). Following nothing, the focused workspace keeps
    /// its focus, and an empty one focuses a window returning to it. The other returning
    /// windows of hidden workspaces are concealed again, and those Kosmos concealed that
    /// return to a shown workspace are revealed.
    public mutating func unpark(_ windows: [WindowID], follow: WindowID?) -> Plan {
        let returning = windows.filter { isParked($0) }
        let focused = self.focused
        let changed = Set(returning.map { home[$0]! })
        for name in changed {
            let monitor = monitor(of: name)
            workspaces[name]!.unpark(returning.filter { home[$0] == name }, in: monitor.area, gaps: monitor.gaps)
        }
        var plan = Plan()
        if let follow, returning.contains(follow), let name = home[follow] {
            workspaces[name]!.focus(follow)
            if name != focusedWorkspace { plan = reach(name) }
        } else if let focused {
            // A returning window focused more recently would take the focus back.
            workspaces[focusedWorkspace]!.focus(focused)
        } else if let window = returning.first(where: { home[$0] == focusedWorkspace }) {
            workspaces[focusedWorkspace]!.focus(window)
            plan.focus = .window(window)
        }
        for name in changed { plan.frames.merge(frames(of: name)) { current, _ in current } }
        plan.hide += returning.filter { !isShown(home[$0]!) && !plan.hide.contains($0) }
        plan.show += returning.filter { isShown(home[$0]!) && parkedConcealed.contains($0) && !plan.show.contains($0) }
        parkedConcealed.subtract(returning)
        return plan
    }

    /// The window Kosmos follows when an app unhides: the window the app keys, if it hid with
    /// the app, else the one focused most recently (`fallback`). A managed keyed window that
    /// did not hide with the app is not followed from the unhide: a minimized one whose Dock
    /// thumbnail unhid the app follows by its own return, and a fullscreen one keeps macOS
    /// on its Space (DESIGN.md, section 5.5).
    public func followOnUnhide(_ windows: [WindowID], keyed: WindowID?, fallback: WindowID?) -> WindowID? {
        guard let keyed, home[keyed] != nil else { return fallback }
        return windows.contains(keyed) ? keyed : nil
    }

    public func isParked(_ window: WindowID) -> Bool {
        guard let name = home[window] else { return false }
        return workspaces[name]!.parked.contains { $0.window == window }
    }

    /// Records a size the window would not go below, from a frame read back after a
    /// write. The layout keeps the window at least that large, on each axis the largest
    /// size recorded. Returns the frames of the window's workspace when the minimum grew,
    /// else an empty plan.
    public mutating func setMinimum(_ window: WindowID, _ size: CGSize) -> Plan {
        guard let name = home[window] else { return Plan() }
        let old = minimums[window] ?? .zero
        let new = CGSize(width: max(old.width, size.width), height: max(old.height, size.height))
        guard new != old else { return Plan() }
        minimums[window] = new
        var plan = Plan()
        plan.frames = frames(of: name)
        return plan
    }

    // MARK: Focus reports

    /// The user focused a window a display shows: that display becomes the focused one
    /// (DESIGN.md, section 5.13).
    public mutating func adopt(_ window: WindowID) {
        guard let name = home[window] else { return }
        workspaces[name]!.focus(window)
        if isShown(name) { focusShown(name) }
    }

    /// The user reached a hidden window with Command-Tab: show its workspace.
    public mutating func follow(_ window: WindowID) -> Plan {
        guard let name = home[window] else { return Plan() }
        workspaces[name]!.focus(window)
        return reach(name)
    }

    // MARK: Commands

    /// Carries out a command. Nil when it does not apply, such as a focus at the edge.
    public mutating func perform(_ command: Command) -> Plan? {
        switch command {
        case .workspace(let target):
            guard let name = resolve(target), name != focusedWorkspace else { return nil }
            return reach(name)
        case .workspaceBackAndForth:
            guard let previous, previous != focusedWorkspace else { return nil }
            return reach(previous)
        case .moveNodeToWorkspace(let target, let follow, let chosen):
            // A minimized or hidden window stays where it will return to.
            guard let window = chosen ?? focused, let source = home[window], !isParked(window),
                  let name = resolve(target), name != source else { return nil }
            return move(window, from: source, to: name, follow: follow)
        case .focus(let direction, let boundaries) where boundaries != .workspace:
            return performOnFocused(command)
                ?? perform(.focusMonitor(.direction(direction), wrapAround: boundaries == .allMonitorsWrapping))
        case .move(let direction, let boundaries) where boundaries != .workspace:
            // At the edge of the workspace the window crosses to the next display, as in
            // AeroSpace.
            if let plan = performOnFocused(command) { return plan }
            // A floating window has no edge to cross, as in AeroSpace.
            guard let window = focused, !workspaces[focusedWorkspace]!.floating.contains(window) else { return nil }
            return perform(.moveNodeToMonitor(.direction(direction), focusFollowsWindow: true,
                                              wrapAround: boundaries == .allMonitorsWrapping))
        case .focusMonitor(let target, let wrap):
            guard let monitor = Monitor.resolve(target, from: monitor(of: focusedWorkspace), in: monitors, wrapAround: wrap),
                  let name = shown[monitor.id], name != focusedWorkspace else { return nil }
            return focusShown(name)
        case .moveNodeToMonitor(let target, let follow, let wrap, let chosen):
            guard let window = chosen ?? focused, let source = home[window], !isParked(window),
                  let monitor = Monitor.resolve(target, from: monitor(of: source), in: monitors, wrapAround: wrap),
                  let name = shown[monitor.id], name != source else { return nil }
            let entering: Direction? = if case .direction(let direction) = target { direction } else { nil }
            return move(window, from: source, to: name, follow: follow, entering: entering)
        case .reloadConfig, .mode, .profile:
            return nil   // the app reloads the config, switches hotkeys or applies the profile
        default:
            return performOnFocused(command)
        }
    }

    private mutating func performOnFocused(_ command: Command) -> Plan? {
        guard let window = focused else { return nil }
        var workspace = workspaces[focusedWorkspace]!
        let monitor = monitor(of: focusedWorkspace)
        let (display, gaps) = (monitor.area, monitor.gaps)
        var plan = Plan()
        switch command {
        case .focus(let direction, _):
            guard let target = workspace.focus(direction, from: window) else { return nil }
            plan.focus = .window(target)
        case .move(let direction, let boundaries):
            guard workspace.move(window, direction, implicitContainer: boundaries == .workspace) else { return nil }
        case .swap(let direction):
            guard workspace.swap(window, direction) else { return nil }
        case .joinWith(let direction):
            guard workspace.joinWith(window, direction) else { return nil }
        case .layout(.orientation(let orientation)):
            guard workspace.layout(window, orientation) else { return nil }
        case .layout(.toggleOrientation):
            guard workspace.toggleLayout(window) else { return nil }
        case .layout(.toggleFloating):
            let floating = workspace.floating.contains(window)
            guard floating ? workspace.tile(window, in: display, gaps: gaps) : workspace.float(window) else { return nil }
        case .fullscreen:
            guard workspace.toggleFullscreen(window) else { return nil }
        case .resize(let dimension, let amount):
            guard workspace.resize(window, dimension, by: amount, in: display, gaps: gaps, minimums: minimums) else { return nil }
        case .balanceSizes:
            workspace.balanceSizes()
        case .flattenWorkspaceTree:
            workspace.flattenWorkspaceTree()
        case .workspace, .workspaceBackAndForth, .moveNodeToWorkspace, .reloadConfig, .mode, .focusMonitor,
             .moveNodeToMonitor, .profile:
            return nil
        }
        workspaces[focusedWorkspace] = workspace
        plan.frames = frames(of: focusedWorkspace)
        return plan
    }

    /// The workspace a command names that the session does not have, as one the active
    /// profile leaves out, or nil. AeroSpace creates a workspace on demand; Kosmos's list is
    /// fixed by the profile, whose `merge-workspaces` puts the windows of the others on its
    /// own, so such a command fails.
    public func missingWorkspace(in command: Command) -> String? {
        switch command {
        case .workspace(.named(let name)), .moveNodeToWorkspace(.named(let name), _, _):
            workspaces[name] == nil ? name : nil
        default:
            nil
        }
    }

    private func resolve(_ target: Command.Workspace) -> String? {
        switch target {
        case .named(let name):
            return workspaces[name] != nil ? name : nil
        case .next, .previous:
            // The focused display's workspaces, as AeroSpace walks them.
            let cycle = names.filter { monitor(of: $0).id == focusedDisplay }
            let index = cycle.firstIndex(of: focusedWorkspace)!
            let step = target == .next ? 1 : -1
            return cycle[(index + step + cycle.count) % cycle.count]
        }
    }

    /// Focuses a workspace: where a display shows it, with nothing concealed or revealed,
    /// else on its display.
    private mutating func reach(_ name: String) -> Plan {
        isShown(name) ? focusShown(name) : show(name)
    }

    /// Moves the focus to a workspace a display shows.
    @discardableResult
    private mutating func focusShown(_ name: String) -> Plan {
        if name != focusedWorkspace { previous = focusedWorkspace }
        focusedWorkspace = name
        if focused == nil, let first = windows(of: name).first { workspaces[name]!.focus(first) }
        var plan = Plan()
        plan.focus = focused.map(KeyWindow.window) ?? KeyWindow.none
        return plan
    }

    /// Shows a hidden workspace on its display, concealing the one there, and focuses it.
    private mutating func show(_ name: String) -> Plan {
        let display = monitor(of: name).id
        var plan = Plan()
        if let old = shown[display] { plan.hide = windows(of: old) }
        plan.show = windows(of: name)
        shown[display] = name
        previous = focusedWorkspace
        focusedWorkspace = name
        // A workspace whose windows were never focused still gets one focused.
        if focused == nil, let first = plan.show.first { workspaces[name]!.focus(first) }
        plan.frames = frames(of: name)
        plan.focus = focused.map(KeyWindow.window) ?? KeyWindow.none
        return plan
    }

    /// `entering`: the window crosses to another display in this direction, and tiles at
    /// the edge it enters by.
    private mutating func move(_ window: WindowID, from source: String, to name: String, follow: Bool,
                               entering: Direction? = nil) -> Plan {
        let wasFocused = source == focusedWorkspace && focused == window
        let onScreen = isShown(source)
        let floating = workspaces[source]!.floating.contains(window)
        _ = workspaces[source]!.remove(window)
        merged[window] = nil
        if let entering, !floating {
            let orientation = workspaces[name]!.root.orientation
            workspaces[name]!.insert(window, first: entering.isForward && orientation == entering.orientation)
        } else {
            workspaces[name]!.insert(window)
        }
        if floating { _ = workspaces[name]!.float(window) }   // it floats there too
        workspaces[name]!.focus(window)
        home[window] = name
        let following = follow && name != focusedWorkspace
        var plan = following ? reach(name) : Plan()
        // The window is revealed or concealed as its new workspace is shown or not. On
        // screen already, it travels with a switch.
        plan.hide.removeAll { $0 == window }
        plan.show.removeAll { $0 == window }
        if onScreen, !isShown(name) { plan.hide.append(window) }
        if !onScreen, isShown(name) { plan.show.append(window) }
        if !following, wasFocused || name == focusedWorkspace {
            plan.focus = focused.map(KeyWindow.window) ?? KeyWindow.none
        }
        plan.frames.merge(frames(of: source)) { current, _ in current }
        plan.frames.merge(frames(of: name)) { current, _ in current }
        return plan
    }

    /// The windows of `hide` that lose their ordinary Space as they are concealed: with
    /// several displays, those whose app's most recently used window, as `latest` gives it,
    /// is on a shown workspace of another display. macOS would key such a window on the
    /// current display over that one, the AeroSpace fork's np3 failure. Every other window
    /// keeps its ordinary Space, as on one display (DESIGN.md, sections 5.3 and 5.13).
    public func stripped(_ hide: [WindowID], latest: (WindowID) -> WindowID?) -> Set<WindowID> {
        guard monitors.count > 1 else { return [] }
        return Set(hide.filter { window in
            guard let recent = latest(window), let shown = home[recent], isShown(shown),
                  !isParked(recent), let own = home[window] else { return false }
            return monitor(of: own).id != monitor(of: shown).id
        })
    }

    /// The user dragged a floating window of a shown workspace to `frame`. With its center on
    /// a display showing another workspace, it joins that workspace, and the focus goes with
    /// it if it had it, as AeroSpace's moveWithMouse binds it. The plan asks for no focus:
    /// the window is key. Nil when it stays, its center on its own workspace's display or on
    /// none (DESIGN.md, section 5.13).
    public mutating func dragged(_ window: WindowID, to frame: CGRect) -> Plan? {
        guard let source = home[window], isShown(source), workspaces[source]!.floating.contains(window),
              let name = workspace(at: CGPoint(x: frame.midX, y: frame.midY)), name != source else { return nil }
        var plan = move(window, from: source, to: name, follow: focused == window)
        plan.focus = nil
        return plan
    }

    /// The floating windows of the shown workspaces, which `floatingFrames` checks.
    public var shownFloatingWindows: [WindowID] { shownWorkspaces.flatMap { workspaces[$0]!.floating } }

    /// Where the floating windows of shown workspaces go that sit on a display showing
    /// another workspace: onto their workspace's display, at the same place relative to the
    /// display areas, as AeroSpace's layoutFloatingWindow moves them. Any change can leave a
    /// floating window there: a move to another display, a rule, a display change. A window
    /// whose center is on no display, as a concealed one, is left where it is (DESIGN.md,
    /// section 5.13).
    /// - Parameter frames: where the windows are now.
    public func floatingFrames(at frames: [WindowID: CGRect]) -> [WindowID: CGRect] {
        var targets: [WindowID: CGRect] = [:]
        for name in shownWorkspaces {
            let own = monitor(of: name)
            for window in workspaces[name]!.floating {
                guard let frame = frames[window] else { continue }
                let center = CGPoint(x: frame.midX, y: frame.midY)
                guard let under = monitors.first(where: { $0.frame.contains(center) }), under.id != own.id else { continue }
                targets[window] = floatingFrame(frame, from: under.area, movingTo: own.area)
            }
        }
        return targets
    }

    /// Where a floating window at `frame` in the area `from` goes in `area`: at the same
    /// place relative to the areas, scaled with them, and kept inside `area`.
    func floatingFrame(_ frame: CGRect, from: CGRect, movingTo area: CGRect) -> CGRect {
        guard from.width > 0, from.height > 0 else { return frame }
        let size = CGSize(width: min(frame.width, area.width), height: min(frame.height, area.height))
        let x = area.minX + (frame.minX - from.minX) * area.width / from.width
        let y = area.minY + (frame.minY - from.minY) * area.height / from.height
        return CGRect(x: min(max(x, area.minX), area.maxX - size.width), y: min(max(y, area.minY), area.maxY - size.height),
                      width: size.width, height: size.height).integral
    }
}
