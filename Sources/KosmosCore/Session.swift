import CoreGraphics

/// Why a window Kosmos admits waits parked (docs/tree.md).
public enum ParkReason: Equatable, Sendable {
    case fullscreen
    case minimized
    case appHidden

    /// Fullscreen comes first: a fullscreen window of a hidden app returns when it leaves
    /// fullscreen, and a minimized window stays minimized when its app unhides.
    public static func atAdmission(fullscreen: Bool, minimized: Bool, appHidden: Bool) -> ParkReason? {
        if fullscreen { return .fullscreen }
        if minimized { return .minimized }
        return appHidden ? .appHidden : nil
    }
}

/// A change returns a Plan for the app to carry out, and Session never calls macOS
/// (docs/overview.md, section 4.3, and docs/displays.md).
public struct Session: Sendable {
    public struct Plan: Equatable, Sendable {
        public var show: [WindowID] = []
        public var hide: [WindowID] = []
        /// The frame ledger drops the targets already in place.
        public var frames: [WindowID: CGRect] = [:]
        /// Nil leaves focus alone.
        public var focus: KeyWindow?

        public init() {}

        init(frames: [WindowID: CGRect]) {
            self.frames = frames
        }

        public var isEmpty: Bool { show.isEmpty && hide.isEmpty && frames.isEmpty && focus == nil }
    }

    /// In the order `next` and `prev` walk, as the profile lists them.
    public internal(set) var names: [String]
    var workspaces: [String: Workspace]
    /// Connected displays, left to right, then top to bottom. Never empty.
    public internal(set) var monitors: [Monitor]
    /// A display no workspace can go to has no entry.
    var shown: [DisplayID: String] = [:]
    /// Among the connected displays. A workspace left out is free.
    var assigned: [String: DisplayID] = [:]
    public internal(set) var focusedWorkspace: String
    var previous: String?
    var home: [WindowID: String] = [:]
    /// Parked windows Kosmos concealed, their workspace hidden when they parked. Switches skip
    /// parked windows, so these stay concealed until they return.
    var parkedConcealed: Set<WindowID> = []
    /// The smallest size each window took, as read backs show, until it is seen smaller.
    var minimums: [WindowID: CGSize] = [:]
    /// Workspaces a profile left out, as they were, for a later profile that lists them.
    var mergedAway: [String: Workspace] = [:]
    /// The workspace a profile merged each window out of. A window the user moves or closes
    /// leaves it.
    var mergedFrom: [WindowID: String] = [:]
    /// The workspace a display showed before it left, or before a profile left that
    /// workspace out.
    var shownBefore: [DisplayID: String] = [:]
    /// Tiled windows dragged by the title bar, parked where they stood (docs/displays.md).
    public internal(set) var lifted: Set<WindowID> = []

    public init(names: [String], monitors: [Monitor], assigned: [String: DisplayID] = [:]) {
        precondition(!names.isEmpty, "a session needs a workspace")
        precondition(!monitors.isEmpty, "a session needs a display")
        self.names = names
        workspaces = Dictionary(uniqueKeysWithValues: names.map { ($0, Workspace()) })
        self.monitors = Monitor.arranged(monitors)
        focusedWorkspace = names[0]
        self.assigned = connected(assigned)
        arrange(focusing: names[0], near: nil)
        check()
    }

    public init(names: [String], display: CGRect, gaps: Gaps = Gaps()) {
        self.init(names: names, monitors: [Monitor(id: 1, frame: display, gaps: gaps)])
    }

    public func workspace(of window: WindowID) -> String? { home[window] }

    public var focused: WindowID? { workspaces[focusedWorkspace]!.focusedWindow }

    public var intent: KeyWindow { focused.map(KeyWindow.window) ?? .noWindow }

    // MARK: Displays

    public func isShown(_ name: String) -> Bool { shown.values.contains(name) }

    /// In display order.
    public var shownWorkspaces: [String] { monitors.compactMap { shown[$0.id] } }

    /// Nil for a display that no workspace can go to.
    public func workspace(shownOn display: DisplayID) -> String? { shown[display] }

    /// Where the workspace is laid out, and where the `workspace` command shows it.
    public func monitor(of name: String) -> Monitor {
        let id = displayShowing(name) ?? assigned[name] ?? focusedDisplay
        return monitors.first { $0.id == id }!
    }

    public var focusedDisplay: DisplayID { displayShowing(focusedWorkspace)! }

    func displayShowing(_ name: String) -> DisplayID? { shown.first { $0.value == name }?.key }

    func workspace(at point: CGPoint) -> String? {
        monitors.first { $0.frame.contains(point) }.flatMap { shown[$0.id] }
    }

    /// The broken invariants of the per-window state, empty when the session is sound.
    func validate() -> [String] {
        var problems: [String] = []
        if Set(names) != Set(workspaces.keys) { problems.append("names \(names) are not the workspaces \(workspaces.keys.sorted())") }
        if !isShown(focusedWorkspace) { problems.append("the focused workspace \(focusedWorkspace) is not shown") }
        for (window, name) in home where workspaces[name]?.contains(window) != true {
            problems.append("window \(window) of \(name) is not in its workspace")
        }
        for name in names {
            for window in allWindows(of: name) where home[window] != name {
                problems.append("window \(window) in \(name) belongs to \(home[window] ?? "no workspace")")
            }
        }
        for window in lifted where !isParked(window) { problems.append("lifted window \(window) is not parked") }
        for window in parkedConcealed where !isParked(window) { problems.append("concealed window \(window) is not parked") }
        for (window, origin) in mergedFrom {
            if home[window] == nil { problems.append("merged window \(window) belongs to no workspace") }
            if mergedAway[origin]?.contains(window) != true { problems.append("merged window \(window) is not in \(origin)") }
        }
        for window in minimums.keys where home[window] == nil { problems.append("window \(window) with a minimum belongs to no workspace") }
        return problems
    }

    func check() {
        assert(validate().isEmpty, "\(validate())")
    }

    /// Tiled and floating. Parked windows are left to macOS.
    public func windows(of name: String) -> [WindowID] {
        guard let workspace = workspaces[name] else { return [] }
        return workspace.root.windows + workspace.floating
    }

    /// Tiled, floating and parked, in that order.
    func allWindows(of name: String) -> [WindowID] {
        let workspace = workspaces[name]!
        return workspace.root.windows + workspace.floating + workspace.parked.map(\.window)
    }

    public func isVisible(_ window: WindowID) -> Bool {
        home[window].map(isShown) == true && !isParked(window)
    }

    public func focusIsOnAnotherDisplay(than point: CGPoint) -> Bool {
        !monitor(of: focusedWorkspace).frame.contains(point)
    }

    public func frames(of name: String) -> [WindowID: CGRect] {
        guard let workspace = workspaces[name] else { return [:] }
        let monitor = monitor(of: name)
        return workspace.frames(in: monitor.area, gaps: monitor.gaps, minimums: minimums)
    }

    func frames(of names: some Sequence<String>) -> [WindowID: CGRect] {
        names.reduce(into: [:]) { frames, name in frames.merge(self.frames(of: name)) { current, _ in current } }
    }

    public func resyncPlan(layingOutHidden: Bool) -> Plan {
        var plan = Plan(frames: frames(of: names.filter { layingOutHidden || isShown($0) }))
        plan.show = shownWorkspaces.flatMap(windows(of:))
        plan.hide = names.filter { !isShown($0) }.flatMap(windows(of:))
        return plan
    }

    // MARK: Windows arriving and leaving

    /// `point` is the window's center (docs/displays.md).
    public mutating func add(_ window: WindowID, to name: String? = nil, at point: CGPoint? = nil,
                             floating: Bool = false) -> Plan {
        defer { check() }
        guard home[window] == nil else { return Plan() }
        let target = name.flatMap { workspaces[$0] != nil ? $0 : nil } ?? point.flatMap(workspace(at:)) ?? focusedWorkspace
        if floating { workspaces[target]!.floating.append(window) } else { workspaces[target]!.insert(window) }
        if workspaces[target]!.focusedWindow == nil { workspaces[target]!.focus(window) }
        home[window] = target
        var plan = Plan(frames: frames(of: target))
        if !isShown(target) { plan.hide = [window] }
        return plan
    }

    public mutating func remove(_ window: WindowID) -> Plan {
        defer { check() }
        guard let name = home.removeValue(forKey: window) else { return Plan() }
        minimums[window] = nil
        mergedFrom[window] = nil
        parkedConcealed.remove(window)
        lifted.remove(window)
        let wasFocused = name == focusedWorkspace && focused == window
        _ = workspaces[name]!.remove(window)
        var plan = Plan(frames: frames(of: name))
        if wasFocused { plan.focus = intent }
        return plan
    }

    /// `new`, the tab just selected, takes `old`'s place and a tiled `old`'s minimum
    /// (docs/tree.md). Nil when `old` holds no place.
    public mutating func replace(_ old: WindowID, with new: WindowID) -> Plan? {
        defer { check() }
        guard old != new, let name = home[old] else { return nil }
        let parked = isParked(old)
        var changed: Set<String> = [name]
        if let current = home.removeValue(forKey: new) {
            _ = workspaces[current]!.remove(new)
            parkedConcealed.remove(new)
            lifted.remove(new)
            changed.insert(current)
        }
        if lifted.remove(old) != nil { lifted.insert(new) }
        workspaces[name]!.replace(old, with: new)
        home[old] = nil
        home[new] = name
        if let minimum = minimums.removeValue(forKey: old), !parked { minimums[new] = minimum }
        mergedFrom[new] = mergedFrom.removeValue(forKey: old)
        if let origin = mergedFrom[new] {
            mergedAway[origin]?.remove(new)
            mergedAway[origin]?.replace(old, with: new)
        }
        parkedConcealed.remove(old)
        var plan = Plan(frames: frames(of: changed))
        if !isShown(name), !isParked(new) { plan.hide = [new] }
        return plan
    }

    /// The plan asks for no focus: macOS keys another window itself, and a request would pull
    /// the screen out of a native fullscreen Space (docs/tree.md).
    public mutating func park(_ windows: [WindowID]) -> Plan {
        defer { check() }
        var changed: Set<String> = []
        for window in windows {
            guard let name = home[window], lifted.remove(window) != nil || workspaces[name]!.park(window) else { continue }
            changed.insert(name)
            if !isShown(name) { parkedConcealed.insert(window) }
        }
        return Plan(frames: frames(of: changed))
    }

    /// Kosmos follows `follow` to its workspace, as it follows a Command-Tab (docs/tree.md).
    public mutating func unpark(_ windows: [WindowID], follow: WindowID?) -> Plan {
        defer { check() }
        let returning = windows.filter { isParked($0) && !lifted.contains($0) }
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
        plan.frames = frames(of: changed)
        plan.hide += returning.filter { !isShown(home[$0]!) && !plan.hide.contains($0) }
        plan.show += returning.filter { isShown(home[$0]!) && parkedConcealed.contains($0) && !plan.show.contains($0) }
        parkedConcealed.subtract(returning)
        return plan
    }

    /// A parked window its app closed and kept, then ordered in again, opens as a new window
    /// does and keeps its minimum (docs/tree.md). Nil for a window that is not parked.
    public mutating func reopen(_ window: WindowID, to name: String?, floating: Bool) -> Plan? {
        defer { check() }
        guard isParked(window) else { return nil }
        let concealed = parkedConcealed.contains(window), minimum = minimums[window]
        _ = remove(window)
        minimums[window] = minimum
        var plan = add(window, to: name, floating: floating)
        if concealed, plan.hide.isEmpty { plan.show = [window] }
        return plan
    }

    /// Nil for a managed `keyed` window that did not hide with the app: a minimized one follows
    /// by its own return, and a fullscreen one keeps macOS on its Space (docs/tree.md).
    public func followOnUnhide(_ windows: [WindowID], keyed: WindowID?, fallback: WindowID?) -> WindowID? {
        guard let keyed, home[keyed] != nil else { return fallback }
        return windows.contains(keyed) ? keyed : nil
    }

    public func isParked(_ window: WindowID) -> Bool {
        guard let name = home[window] else { return false }
        return workspaces[name]!.parked.contains { $0.window == window }
    }

    public mutating func setMinimum(_ window: WindowID, _ size: CGSize) -> Plan {
        defer { check() }
        guard let name = home[window] else { return Plan() }
        let old = minimums[window] ?? .zero
        let new = CGSize(width: max(old.width, size.width), height: max(old.height, size.height))
        guard new != old else { return Plan() }
        minimums[window] = new
        return Plan(frames: frames(of: name))
    }

    /// `size` came with no write of Kosmos's. Smaller than the minimum on an axis, past the
    /// slack, it shows the refusals that recorded it were no limit of the app's (docs/geometry.md).
    public mutating func sizeObserved(_ window: WindowID, _ size: CGSize) -> Plan {
        defer { check() }
        guard let name = home[window], let old = minimums[window] else { return Plan() }
        let new = CGSize(width: size.width + FrameLedger.slack < old.width ? 0 : old.width,
                         height: size.height + FrameLedger.slack < old.height ? 0 : old.height)
        guard new != old else { return Plan() }
        minimums[window] = new == .zero ? nil : new
        return Plan(frames: frames(of: name))
    }

    // MARK: Focus reports

    public mutating func adopt(_ window: WindowID) {
        defer { check() }
        guard let name = home[window] else { return }
        workspaces[name]!.focus(window)
        if isShown(name) { focusShown(name) }
    }

    public mutating func follow(_ window: WindowID) -> Plan {
        defer { check() }
        guard let name = home[window] else { return Plan() }
        workspaces[name]!.focus(window)
        return reach(name)
    }

    // MARK: Commands

    /// Nil when the command does not apply, such as a focus at the edge. `frame` gives where
    /// a window is now, for a focus in a direction (docs/tree.md).
    public mutating func perform(_ command: Command, frame: (WindowID) -> CGRect? = { _ in nil }) -> Plan? {
        defer { check() }
        switch command {
        case .workspace(let target):
            guard let name = resolve(target), name != focusedWorkspace else { return nil }
            return reach(name)
        case .workspaceBackAndForth:
            guard let previous, previous != focusedWorkspace else { return nil }
            return reach(previous)
        case .moveNodeToWorkspace(let target, let follow, let chosen):
            guard let window = chosen ?? focused, let source = home[window], !isParked(window),
                  let name = resolve(target), name != source else { return nil }
            return move(window, from: source, to: name, follow: follow)
        case .focus(let direction, let boundaries) where boundaries != .workspace:
            return performOnFocused(command, frame: frame)
                ?? perform(.focusMonitor(.direction(direction), wrapAround: boundaries == .allMonitorsWrapping))
        case .move(let direction, let boundaries) where boundaries != .workspace:
            if let plan = performOnFocused(command) { return plan }
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
        case .reloadConfig, .mode, .profile, .focusFollowsMouse:
            return nil   // the app reloads the config, switches hotkeys, applies the profile
                         // or turns focus follows mouse on or off
        default:
            return performOnFocused(command, frame: frame)
        }
    }

    private mutating func performOnFocused(_ command: Command, frame: (WindowID) -> CGRect? = { _ in nil }) -> Plan? {
        guard let window = focused else { return nil }
        var workspace = workspaces[focusedWorkspace]!
        let monitor = monitor(of: focusedWorkspace)
        let (display, gaps) = (monitor.area, monitor.gaps)
        var plan = Plan()
        switch command {
        case .focus(let direction, _):
            guard let target = workspace.focus(direction, from: window, frame: frame, in: display, gaps: gaps,
                                               minimums: minimums) else { return nil }
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
             .moveNodeToMonitor, .profile, .focusFollowsMouse:
            return nil
        }
        workspaces[focusedWorkspace] = workspace
        plan.frames = frames(of: focusedWorkspace)
        return plan
    }

    /// The workspaces are the profile's, so a command that names another fails
    /// (docs/config.md).
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
            let cycle = names.filter { monitor(of: $0).id == focusedDisplay }
            let index = cycle.firstIndex(of: focusedWorkspace)!
            let step = target == .next ? 1 : -1
            return cycle[(index + step + cycle.count) % cycle.count]
        }
    }

    mutating func reach(_ name: String) -> Plan {
        isShown(name) ? focusShown(name) : show(name)
    }

    @discardableResult
    mutating func focusShown(_ name: String) -> Plan {
        if name != focusedWorkspace { previous = focusedWorkspace }
        focusedWorkspace = name
        if focused == nil, let first = windows(of: name).first { workspaces[name]!.focus(first) }
        var plan = Plan()
        plan.focus = intent
        return plan
    }

    private mutating func show(_ name: String) -> Plan {
        let display = monitor(of: name).id
        var plan = Plan()
        if let old = shown[display] { plan.hide = windows(of: old) }
        plan.show = windows(of: name)
        shown[display] = name
        previous = focusedWorkspace
        focusedWorkspace = name
        if focused == nil, let first = plan.show.first { workspaces[name]!.focus(first) }
        plan.frames = frames(of: name)
        plan.focus = intent
        return plan
    }

    /// `entering`: the window crosses to another display in this direction, and tiles at the
    /// edge it enters by.
    mutating func move(_ window: WindowID, from source: String, to name: String, follow: Bool,
                       entering: Direction? = nil) -> Plan {
        let wasFocused = source == focusedWorkspace && focused == window
        let onScreen = isShown(source)
        let floating = workspaces[source]!.floating.contains(window)
        _ = workspaces[source]!.remove(window)
        mergedFrom[window] = nil
        if let entering, !floating {
            let orientation = workspaces[name]!.root.orientation
            workspaces[name]!.insert(window, first: entering.isForward && orientation == entering.orientation)
        } else {
            workspaces[name]!.insert(window)
        }
        if floating { _ = workspaces[name]!.float(window) }
        workspaces[name]!.focus(window)
        home[window] = name
        let following = follow && name != focusedWorkspace
        var plan = following ? reach(name) : Plan()
        // Its own reveal or conceal replaces the switch's.
        plan.hide.removeAll { $0 == window }
        plan.show.removeAll { $0 == window }
        if onScreen, !isShown(name) { plan.hide.append(window) }
        if !onScreen, isShown(name) { plan.show.append(window) }
        if !following, wasFocused || name == focusedWorkspace {
            plan.focus = intent
        }
        plan.frames = frames(of: [source, name])
        return plan
    }

    /// The windows of `hide` that lose their ordinary Space as they are concealed
    /// (docs/displays.md).
    public func stripped(_ hide: [WindowID], latest: (WindowID) -> WindowID?) -> Set<WindowID> {
        guard monitors.count > 1 else { return [] }
        return Set(hide.filter { window in
            guard let recent = latest(window), let shown = home[recent], isShown(shown),
                  !isParked(recent), let own = home[window] else { return false }
            return monitor(of: own).id != monitor(of: shown).id
        })
    }

    public var shownFloatingWindows: [WindowID] { shownWorkspaces.flatMap { workspaces[$0]!.floating } }

    /// Targets for the shown workspaces' floating windows on a display showing another workspace
    /// (docs/displays.md). A concealed window's center is on no display, so it stays.
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
}

private func floatingFrame(_ frame: CGRect, from: CGRect, movingTo area: CGRect) -> CGRect {
    guard from.width > 0, from.height > 0 else { return frame }
    let size = CGSize(width: min(frame.width, area.width), height: min(frame.height, area.height))
    let x = area.minX + (frame.minX - from.minX) * area.width / from.width
    let y = area.minY + (frame.minY - from.minY) * area.height / from.height
    return CGRect(x: min(max(x, area.minX), area.maxX - size.width), y: min(max(y, area.minY), area.maxY - size.height),
                  width: size.width, height: size.height).integral
}
