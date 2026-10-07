import CoreGraphics

/// Why a window waits parked (docs/tree.md).
public enum ParkReason: Equatable, Sendable {
    case fullscreen
    case minimized
    case appHidden
    /// Its app ordered it out and kept it.
    case closedByApp

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
    /// Every parked window has one, except a lifted one.
    var parkReasons: [WindowID: ParkReason] = [:]
    /// The smallest size each window took, as read backs show, until it is seen smaller.
    var learned: [WindowID: CGSize] = [:]
    /// The smallest size WindowServer holds each window to, as its row reads (docs/geometry.md).
    var constrained: [WindowID: CGSize] = [:]
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
    /// Tiled windows that float because their app raised them off level 0 (docs/tree.md).
    public internal(set) var floatedForLevel: Set<WindowID> = []
    /// The window focused when the restored layout was saved, until Kosmos admits it
    /// (docs/tree.md).
    var savedFocus: WindowID?
    /// The workspace the agent workspace's display showed before it, given back when it goes.
    var agentDisplaced: String?

    public init(names: [String], monitors: [Monitor], assigned: [String: DisplayID] = [:]) {
        precondition(!names.isEmpty, "a session needs a workspace")
        precondition(!monitors.isEmpty, "a session needs a display")
        let names = names.contains(Self.agent) ? names : names + [Self.agent]
        self.names = names
        workspaces = Dictionary(uniqueKeysWithValues: names.map { ($0, Workspace()) })
        self.monitors = Monitor.arranged(monitors)
        focusedWorkspace = names[0]
        self.assigned = connected(assigned)
        arrange(focusing: names[0], near: nil)
        check()
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

    /// The display under the frame's center, nil for none.
    public func display(under frame: CGRect) -> DisplayID? {
        monitors.first { $0.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) }?.id
    }

    /// Whether a write to `target` moves a window WindowServer has at `frame` onto another
    /// display, where AppKit holds it to the old display's edge for a while
    /// (FrameLedger.displayMoveBound). False with no frame known.
    public func movesDisplay(from frame: CGRect?, to target: CGRect) -> Bool {
        guard let frame else { return false }
        return display(under: frame) != display(under: target)
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
        for window in floatedForLevel where home[window].map({ workspaces[$0]!.root.path(to: window) != nil }) ?? true {
            problems.append("window \(window) floated for its level is tiled or belongs to no workspace")
        }
        for window in parkReasons.keys where !isParked(window) { problems.append("window \(window) with a park reason is not parked") }
        for name in names {
            for entry in workspaces[name]!.parked where (parkReasons[entry.window] == nil) != lifted.contains(entry.window) {
                problems.append("parked window \(entry.window) must have a park reason exactly when it is not lifted")
            }
        }
        for (window, origin) in mergedFrom {
            if home[window] == nil { problems.append("merged window \(window) belongs to no workspace") }
            if mergedAway[origin]?.contains(window) != true { problems.append("merged window \(window) is not in \(origin)") }
        }
        for window in Set(learned.keys).union(constrained.keys) where home[window] == nil {
            problems.append("window \(window) with a minimum belongs to no workspace")
        }
        let pending = pendingWindows
        for window in pending where home[window] != nil { problems.append("pending window \(window) belongs to a workspace") }
        if Set(pending).count != pending.count { problems.append("a window is pending on two workspaces") }
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

    public func isFloating(_ window: WindowID) -> Bool {
        home[window].map { workspaces[$0]!.floating.contains(window) } ?? false
    }

    public func isVisible(_ window: WindowID) -> Bool {
        home[window].map(isShown) == true && !isParked(window)
    }

    /// The tile of a tiled window of a shown workspace; nil for a floating, parked or hidden one.
    public func tile(of window: WindowID) -> CGRect? {
        guard let name = home[window], isShown(name), !isParked(window), !isFloating(window) else { return nil }
        return frames(of: name)[window]
    }

    public func focusIsOnAnotherDisplay(than point: CGPoint) -> Bool {
        !monitor(of: focusedWorkspace).frame.contains(point)
    }

    /// Each window's minimum: on each axis the larger of WindowServer's and the one learned.
    var minimums: [WindowID: CGSize] {
        learned.merging(constrained) { CGSize(width: max($0.width, $1.width), height: max($0.height, $1.height)) }
    }

    /// The windows a restored layout still has pending hold their tiles (docs/tree.md).
    public func frames(of name: String) -> [WindowID: CGRect] {
        guard let workspace = workspaces[name] else { return [:] }
        let monitor = monitor(of: name)
        return workspace.shownFrames(in: monitor.area, gaps: monitor.gaps, minimums: minimums)
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

    /// `point` is the window's center (docs/displays.md), and `minimum` the one WindowServer
    /// reads for it. A window the restored layout has goes back to its place there, whatever
    /// `name` and `floating` say (docs/tree.md). With a `reason`, the window waits parked. A
    /// `concealed` window, as one taken over at launch, is revealed unless the plan hides it:
    /// its workspace is shown, or it parks (docs/hiding.md).
    public mutating func add(_ window: WindowID, to name: String? = nil, at point: CGPoint? = nil,
                             floating: Bool = false, minimum: CGSize = .zero, parked reason: ParkReason? = nil,
                             concealed: Bool = false) -> Plan {
        defer { check() }
        guard home[window] == nil else { return Plan() }
        if let saved = savedWorkspace(of: window) {
            return admitSaved(window, to: saved, minimum: minimum, parked: reason, concealed: concealed)
        }
        let target = name.flatMap { workspaces[$0] != nil ? $0 : nil } ?? point.flatMap(workspace(at:)) ?? focusedWorkspace
        if minimum != .zero { constrained[window] = minimum }
        if floating || target == Self.agent { workspaces[target]!.floating.append(window) } else { workspaces[target]!.insert(window) }
        fit(window, in: target)
        if workspaces[target]!.focusedWindow == nil { workspaces[target]!.focus(window) }
        home[window] = target
        var plan = Plan(frames: frames(of: target))
        if let reason { plan.frames = park([window], because: reason).frames }
        if reason == nil, !isShown(target) { plan.hide = [window] } else if concealed { plan.show = [window] }
        return plan
    }

    public mutating func remove(_ window: WindowID) -> Plan {
        defer { check() }
        guard let name = home.removeValue(forKey: window) else { return Plan() }
        learned[window] = nil
        constrained[window] = nil
        mergedFrom[window] = nil
        parkedConcealed.remove(window)
        parkReasons[window] = nil
        lifted.remove(window)
        floatedForLevel.remove(window)
        let wasFocused = name == focusedWorkspace && focused == window
        _ = workspaces[name]!.remove(window)
        var plan = Plan(frames: frames(of: name))
        if wasFocused { plan.focus = intent }
        return plan
    }

    /// `new`, the tab just selected, takes `old`'s place with its park reason, and the minimum
    /// Kosmos learned for a tiled `old` (docs/tree.md). `minimum` is WindowServer's for `new`.
    /// Nil when `old` holds no place.
    public mutating func replace(_ old: WindowID, with new: WindowID, minimum: CGSize = .zero) -> Plan? {
        defer { check() }
        guard old != new, let name = home[old] else { return nil }
        if let saved = savedWorkspace(of: new) { workspaces[saved]!.pending.removeAll { $0.window == new } }
        let parked = isParked(old)
        var changed: Set<String> = [name]
        if let current = home.removeValue(forKey: new) {
            _ = workspaces[current]!.remove(new)
            parkedConcealed.remove(new)
            lifted.remove(new)
            floatedForLevel.remove(new)
            changed.insert(current)
        }
        if lifted.remove(old) != nil { lifted.insert(new) }
        if floatedForLevel.remove(old) != nil { floatedForLevel.insert(new) }
        parkReasons[new] = parkReasons.removeValue(forKey: old)
        workspaces[name]!.replace(old, with: new)
        home[old] = nil
        home[new] = name
        if let minimum = learned.removeValue(forKey: old), !parked { learned[new] = minimum }
        constrained[old] = nil
        constrained[new] = minimum == .zero ? nil : minimum
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

    /// A tiled window its app raises off level 0, as IINA's Float on Top does, floats at the
    /// frame it has, and tiles again when its level returns to 0, unless the user toggled it in
    /// the meantime (docs/tree.md). Nil when nothing changes, as for a window floating already.
    public mutating func leveled(_ window: WindowID, raised: Bool) -> Plan? {
        defer { check() }
        guard let name = home[window] else { return nil }
        // On the agent workspace every window floats already; one its app raises tiles only
        // once it leaves and its level returns (docs/displays.md).
        if name == Self.agent {
            if raised { floatedForLevel.insert(window) } else { floatedForLevel.remove(window) }
            return nil
        }
        if raised {
            guard workspaces[name]!.float(window) else { return nil }
            floatedForLevel.insert(window)
        } else {
            let monitor = monitor(of: name)
            guard floatedForLevel.contains(window), workspaces[name]!.tile(window, in: monitor.area, gaps: monitor.gaps)
            else { return nil }
            floatedForLevel.remove(window)
        }
        return Plan(frames: frames(of: name))
    }

    /// A parked window keeps its reason unless a minimize or native fullscreen replaces closed
    /// and kept, and the plan asks for no focus (docs/tree.md).
    public mutating func park(_ windows: [WindowID], because reason: ParkReason) -> Plan {
        defer { check() }
        var changed: Set<String> = []
        for window in windows {
            guard let name = home[window] else { continue }
            if lifted.remove(window) != nil || workspaces[name]!.park(window) {
                changed.insert(name)
                if !isShown(name) { parkedConcealed.insert(window) }
            } else if parkReasons[window] != .closedByApp || reason == .appHidden {
                continue
            }
            parkReasons[window] = reason
        }
        return Plan(frames: frames(of: changed))
    }

    /// Kosmos follows `follow` to its workspace, as it follows a Command-Tab (docs/tree.md).
    public mutating func unpark(_ windows: [WindowID], follow: WindowID?) -> Plan {
        defer { check() }
        let before = framesBeforeFullscreen
        let returning = windows.filter { isParked($0) && !lifted.contains($0) }
        let focused = self.focused
        let changed = Set(returning.map { home[$0]! })
        for name in changed {
            let monitor = monitor(of: name)
            workspaces[name]!.unpark(returning.filter { home[$0] == name }, in: monitor.area, gaps: monitor.gaps)
        }
        var plan = Plan()
        var ended: [WindowID: CGRect] = [:]
        if let follow, returning.contains(follow), let name = home[follow] {
            workspaces[name]!.focus(follow)
            if name != focusedWorkspace { plan = reach(name) }
        } else if let focused {
            // A returning window focused more recently would take the focus back.
            ended = focusEndingFullscreen(focused, on: focusedWorkspace)
        } else if let window = returning.first(where: { home[$0] == focusedWorkspace }) {
            workspaces[focusedWorkspace]!.focus(window)
            plan.focus = .window(window)
        }
        plan.frames = frames(of: changed).merging(ended) { $1 }.merging(backFromFullscreen(since: before)) { $1 }
        plan.hide += returning.filter { !isShown(home[$0]!) && !plan.hide.contains($0) }
        plan.show += returning.filter { isShown(home[$0]!) && parkedConcealed.contains($0) && !plan.show.contains($0) }
        parkedConcealed.subtract(returning)
        for window in returning { parkReasons[window] = nil }
        return plan
    }

    /// A parked window its app closed and kept, then ordered in again, opens as a new window
    /// does and keeps the minimum Kosmos learned (docs/tree.md). Nil for a window that is not
    /// parked.
    public mutating func reopen(_ window: WindowID, to name: String?, floating: Bool, minimum: CGSize = .zero,
                                parked reason: ParkReason? = nil) -> Plan? {
        defer { check() }
        guard isParked(window) else { return nil }
        let concealed = parkedConcealed.contains(window), kept = learned[window]
        _ = remove(window)
        learned[window] = kept
        return add(window, to: name, floating: floating, minimum: minimum, parked: reason, concealed: concealed)
    }

    /// Where the focus goes when an app unhides (docs/tree.md).
    public enum UnhideFocus: Equatable, Sendable {
        case stays
        case follow(WindowID)
        /// No input of the user's fronted the app, and its window returns to a hidden
        /// workspace: Kosmos requests its intent again, so no key goes to a concealed window.
        case reassert
    }

    /// The focus stays for a managed `keyed` window that did not hide with the app: a minimized
    /// one follows by its own return, and a fullscreen one keeps macOS on its Space. It stays
    /// too when the app is not the front process: an unhide that fronts nothing, as a
    /// script's or computer use's, or Show All. An unhide no input of the user's fronted, as
    /// `open -a` on a hidden app, is followed only onto a shown workspace (docs/tree.md).
    public func focusOnUnhide(_ windows: [WindowID], keyed: WindowID?, fallback: WindowID?, front: Bool,
                              byUser: Bool) -> UnhideFocus {
        guard front else { return .stays }
        let window: WindowID? = if let keyed, home[keyed] != nil { windows.contains(keyed) ? keyed : nil } else { fallback }
        guard let window else { return .stays }
        return byUser || home[window].map(isShown) == true ? .follow(window) : .reassert
    }

    public func isParked(_ window: WindowID) -> Bool {
        guard let name = home[window] else { return false }
        return workspaces[name]!.parked.contains { $0.window == window }
    }

    public func parkReason(of window: WindowID) -> ParkReason? { parkReasons[window] }

    public func parked(because reason: ParkReason) -> [WindowID] {
        names.flatMap { workspaces[$0]!.parked.map(\.window) }.filter { parkReasons[$0] == reason }
    }

    public mutating func setMinimum(_ window: WindowID, _ size: CGSize) -> Plan {
        defer { check() }
        guard let name = home[window] else { return Plan() }
        let old = learned[window] ?? .zero
        let new = CGSize(width: max(old.width, size.width), height: max(old.height, size.height))
        guard new != old else { return Plan() }
        learned[window] = new
        return Plan(frames: frames(of: name))
    }

    /// WindowServer's minimum for the window changed. The split stays, and the window spills
    /// where its tile is too small (docs/tree.md).
    public mutating func constrain(_ window: WindowID, to minimum: CGSize) -> Plan {
        defer { check() }
        guard let name = home[window], constrained[window] ?? .zero != minimum else { return Plan() }
        constrained[window] = minimum == .zero ? nil : minimum
        return Plan(frames: frames(of: name))
    }

    /// `size` came with no write of Kosmos's. Smaller than the minimum on an axis, past the
    /// slack, it shows the refusals that recorded it were no limit of the app's (docs/geometry.md).
    public mutating func sizeObserved(_ window: WindowID, _ size: CGSize) -> Plan {
        defer { check() }
        guard let name = home[window], let old = learned[window] else { return Plan() }
        let new = CGSize(width: size.width + FrameLedger.slack < old.width ? 0 : old.width,
                         height: size.height + FrameLedger.slack < old.height ? 0 : old.height)
        guard new != old else { return Plan() }
        learned[window] = new == .zero ? nil : new
        return Plan(frames: frames(of: name))
    }

    // MARK: Focus reports

    /// The plan has frames only when the focus ended a fullscreen.
    public mutating func adopt(_ window: WindowID) -> Plan {
        defer { check() }
        guard let name = home[window] else { return Plan() }
        let frames = focusEndingFullscreen(window, on: name)
        if isShown(name) { focusShown(name) }
        return Plan(frames: frames)
    }

    public mutating func follow(_ window: WindowID) -> Plan {
        defer { check() }
        guard let name = home[window] else { return Plan() }
        let frames = focusEndingFullscreen(window, on: name)
        var plan = reach(name)
        plan.frames.merge(frames) { $1 }
        return plan
    }

    private mutating func focusEndingFullscreen(_ window: WindowID, on name: String) -> [WindowID: CGRect] {
        let before = framesBeforeFullscreen, fullscreen = workspaces[name]!.fullscreenWindow
        workspaces[name]!.focus(window)
        guard workspaces[name]!.fullscreenWindow != fullscreen else { return [:] }
        return frames(of: name).merging(backFromFullscreen(since: before)) { $1 }
    }

    // MARK: Commands

    /// Nil when the command does not apply, such as a focus at the edge. `frame` gives where
    /// a window is now, for a focus in a direction and a floating window's fullscreen and
    /// resize (docs/tree.md).
    public mutating func perform(_ command: Command, frame: (WindowID) -> CGRect? = { _ in nil }) -> Plan? {
        defer { check() }
        switch command {
        case .workspace(let target):
            guard let name = resolve(target) else { return nil }
            if name == Self.agent { return toggleAgent() }
            guard name != focusedWorkspace else { return nil }
            return reach(name)
        case .workspaceBackAndForth:
            guard let previous, previous != focusedWorkspace else { return nil }
            return reach(previous)
        case .moveNodeToWorkspace(let target, let follow, let chosen):
            guard let window = chosen ?? focused, let source = home[window], !isParked(window),
                  let name = resolve(target), name != source else { return nil }
            return move(window, from: source, to: name, follow: follow)
        case .focus(let direction, let boundaries) where boundaries != .workspace:
            if let plan = performOnFocused(command, frame: frame) { return plan }
            guard let name = workspace(on: .direction(direction), wrapAround: boundaries == .allMonitorsWrapping) else { return nil }
            let here = monitor(of: focusedWorkspace), there = monitor(of: name)
            let source = focused.flatMap {
                workspaces[focusedWorkspace]!.onScreen(frame, in: here.area, gaps: here.gaps, minimums: minimums)[$0]
            }
            workspaces[name]!.enter(direction, from: source, frame: frame, in: there.area, gaps: there.gaps, minimums: minimums)
            return focusShown(name)
        case .move(let direction, let boundaries) where boundaries != .workspace:
            if let plan = performOnFocused(command) { return plan }
            return perform(.moveNodeToMonitor(.direction(direction), focusFollowsWindow: true,
                                              wrapAround: boundaries == .allMonitorsWrapping))
        case .focusMonitor(let target, let wrap):
            guard let name = workspace(on: target, wrapAround: wrap) else { return nil }
            return focusShown(name)
        case .moveNodeToMonitor(let target, let follow, let wrap, let chosen):
            guard let window = chosen ?? focused, let source = home[window], !isParked(window),
                  let monitor = Monitor.resolve(target, from: monitor(of: source), in: monitors, wrapAround: wrap),
                  let name = shown[monitor.id], name != source else { return nil }
            let entering: Direction? = if case .direction(let direction) = target { direction } else { nil }
            return move(window, from: source, to: name, follow: follow, entering: entering)
        default:
            return performOnFocused(command, frame: frame)
        }
    }

    private mutating func performOnFocused(_ command: Command, frame: (WindowID) -> CGRect? = { _ in nil }) -> Plan? {
        guard let window = focused else { return nil }
        let before = framesBeforeFullscreen
        var workspace = workspaces[focusedWorkspace]!
        let monitor = monitor(of: focusedWorkspace), minimums = minimums
        let (display, gaps) = (monitor.area, monitor.gaps)
        // Where Kosmos chooses a split, minimums that fit bind (docs/tree.md).
        func fitMinimums(_ window: WindowID?) { workspace.fit(window, in: display, gaps: gaps, minimums: minimums) }
        var plan = Plan()
        switch command {
        case .focus(let direction, _):
            guard let target = workspace.focus(direction, from: window, frame: frame, in: display, gaps: gaps,
                                               minimums: minimums) else { return nil }
            plan.focus = .window(target)
        case .move(let direction, let boundaries):
            let container = { (workspace: Workspace) in workspace.root.path(to: window).map { workspace.root[$0.dropLast()].id } }
            let from = container(workspace)
            guard workspace.move(window, direction, implicitContainer: boundaries == .workspace) else { return nil }
            // Within its container a move swaps places and keeps the weights (docs/tree.md).
            if container(workspace) != from { fitMinimums(window) }
        case .swap(let direction):
            guard workspace.swap(window, direction, in: display, gaps: gaps, minimums: minimums) else { return nil }
        case .joinWith(let direction):
            guard workspace.joinWith(window, direction) else { return nil }
            fitMinimums(window)
        case .layout(.orientation(let orientation)):
            guard workspace.layout(window, orientation) else { return nil }
        case .layout(.toggleOrientation):
            guard workspace.toggleLayout(window) else { return nil }
        case .layout(.toggleFloating):
            let floating = workspace.floating.contains(window)
            guard floating ? workspace.tile(window, in: display, gaps: gaps) : workspace.float(window) else { return nil }
            floatedForLevel.remove(window)
        case .fullscreen:
            guard workspace.toggleFullscreen(window, frame: frame(window)) else { return nil }
        case .resize(let dimension, let amount) where workspace.floating.contains(window):
            // Hyprland's resize refuses a fullscreen window (docs/tree.md).
            guard workspace.fullscreenWindow != window, let old = frame(window) else { return nil }
            let new = resizedFloating(old, dimension, by: amount, least: leastSize(of: window), in: display)
            return new == old ? nil : Plan(frames: [window: new])
        case .resize(let dimension, let amount):
            guard workspace.resize(window, dimension, by: amount, in: display, gaps: gaps) else { return nil }
        case .balanceSizes:
            workspace.balanceSizes()
            fitMinimums(nil)
        case .flattenWorkspaceTree:
            workspace.flattenWorkspaceTree()
            fitMinimums(nil)
        case .workspace, .workspaceBackAndForth, .moveNodeToWorkspace, .reloadConfig, .focusMonitor,
             .moveNodeToMonitor, .profile, .focusFollowsMouse:
            return nil
        }
        workspaces[focusedWorkspace] = workspace
        plan.frames = frames(of: focusedWorkspace).merging(backFromFullscreen(since: before)) { $1 }
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
            let cycle = names.filter { $0 != Self.agent && monitor(of: $0).id == focusedDisplay }
            guard let index = cycle.firstIndex(of: focusedWorkspace) else { return cycle.first }
            let step = target == .next ? 1 : -1
            return cycle[(index + step + cycle.count) % cycle.count]
        }
    }

    /// The workspace shown on the display `target` names from the focused one. Nil for the
    /// focused workspace.
    private func workspace(on target: Command.MonitorTarget, wrapAround: Bool) -> String? {
        guard let monitor = Monitor.resolve(target, from: monitor(of: focusedWorkspace), in: monitors, wrapAround: wrapAround),
              let name = shown[monitor.id], name != focusedWorkspace else { return nil }
        return name
    }

    /// Kosmos chose the split of the container the window joined, so the minimums there bind
    /// where they fit (docs/tree.md).
    mutating func fit(_ window: WindowID, in name: String) {
        let monitor = monitor(of: name)
        workspaces[name]!.fit(window, in: monitor.area, gaps: monitor.gaps, minimums: minimums)
    }

    /// A click the user released on the desktop of a display whose workspace does not have the
    /// focus focuses that workspace, as AeroSpace's mouse up does (docs/displays.md). Nil when
    /// that workspace has it, or the point is on no display.
    public mutating func clickedDesktop(at point: CGPoint) -> Plan? {
        defer { check() }
        guard let name = workspace(at: point), name != focusedWorkspace else { return nil }
        return focusShown(name)
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

    mutating func show(_ name: String) -> Plan {
        let display = monitor(of: name).id
        var plan = Plan()
        if let old = shown[display] { plan.hide = windows(of: old) }
        if name == Self.agent { agentDisplaced = shown[display] } else if shown[display] == Self.agent { agentDisplaced = nil }
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
        let before = framesBeforeFullscreen
        let wasFocused = source == focusedWorkspace && focused == window
        let onScreen = isShown(source)
        // A window floats on the agent workspace and tiles once it leaves, unless its app holds
        // it off level 0 (docs/displays.md).
        let floating = name == Self.agent
            || workspaces[source]!.floating.contains(window) && (source != Self.agent || floatedForLevel.contains(window))
        _ = workspaces[source]!.remove(window)
        mergedFrom[window] = nil
        if let entering, !floating {
            let orientation = workspaces[name]!.root.orientation
            workspaces[name]!.insert(window, first: entering.isForward && orientation == entering.orientation)
        } else {
            workspaces[name]!.insert(window)
        }
        if floating { _ = workspaces[name]!.float(window) }
        fit(window, in: name)
        workspaces[name]!.focus(window)
        home[window] = name
        let following = follow && name != focusedWorkspace
        var plan = following ? reach(name) : Plan()
        // Its own reveal or conceal replaces the switch's.
        plan.hide.removeAll { $0 == window }
        plan.show.removeAll { $0 == window }
        if onScreen, !isShown(name) { plan.hide.append(window) }
        if !onScreen, isShown(name) { plan.show.append(window) }
        // Concealed again, as the agent workspace's windows stay drawn in a Space of their own
        // (docs/hiding.md).
        if !onScreen, !isShown(name), (source == Self.agent) != (name == Self.agent) { plan.hide.append(window) }
        if !following, wasFocused || name == focusedWorkspace {
            plan.focus = intent
        }
        plan.frames = frames(of: [source, name]).merging(backFromFullscreen(since: before)) { $1 }
        return plan
    }

    /// The windows on screen that a batch's reveal takes in, as the one
    /// move-node-to-workspace --focus-follows-window moves or a followed rule window. Each that
    /// does not slide would land at its tile while the batch waits for the revealed windows'
    /// writes, so a batch of its own conceals it first. One that
    /// `display` does not show on its workspace's display is left out: concealed, it keeps the
    /// ordinary Space of the display it leaves, and whether its reveal shows it on the other is
    /// open (docs/hiding.md). `concealed`: Hiding has or is sending the window's conceal.
    public func entering(show: [WindowID], hide: [WindowID], frames: some Collection<WindowID>,
                         concealed: (WindowID) -> Bool, display: (WindowID) -> DisplayID?) -> [WindowID] {
        let revealed = Set(show.filter(concealed).compactMap { home[$0] })
        guard !revealed.isEmpty else { return [] }
        return frames.filter { id in
            guard let name = home[id], revealed.contains(name), !hide.contains(id), !concealed(id), isVisible(id)
            else { return false }
            return display(id) == monitor(of: name).id
        }
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
    /// (docs/displays.md). Each goes from `written`, a write of Kosmos's no row shows yet, as
    /// the row can still show where the window was, else from its row in `frames`. A window
    /// whose center is on no display stays.
    public func floatingFrames(at frames: [WindowID: CGRect],
                               written: (WindowID) -> CGRect?) -> [WindowID: CGRect] {
        var targets: [WindowID: CGRect] = [:]
        for name in shownWorkspaces {
            let own = monitor(of: name)
            for window in workspaces[name]!.floating {
                guard let frame = written(window) ?? frames[window] else { continue }
                let center = CGPoint(x: frame.midX, y: frame.midY)
                guard let under = monitors.first(where: { $0.frame.contains(center) }) else {
                    // On no display, as where an app restores a window off the displays there
                    // are now, it comes inside its own (docs/displays.md).
                    targets[window] = fitted(frame, in: own.area).integral
                    continue
                }
                guard under.id != own.id else { continue }
                targets[window] = floatingFrame(frame, from: under.area, movingTo: own.area)
            }
        }
        return targets
    }

    /// Where the pointer centers for the focus: the focused window's tile, a floating window
    /// where the floating check puts it from `frame`, or an empty workspace's display
    /// (docs/focus-follows-mouse.md). Nil for a floating window with no frame.
    public func pointerFrame(frame: (WindowID) -> CGRect?) -> CGRect? {
        guard let window = focused else { return monitor(of: focusedWorkspace).frame }
        if let tile = frames(of: focusedWorkspace)[window] { return tile }
        return frame(window).map { floatingFrames(at: [window: $0], written: { _ in nil })[window] ?? $0 }
    }

    /// Whether a shown floating window, at `frame`, overlaps the tile of `window`, so the focus
    /// keys the tile without bringing it forward (docs/focus.md). False for a floating window,
    /// and for a window of a hidden workspace.
    public func floatingOverlaps(_ window: WindowID, frame: (WindowID) -> CGRect?) -> Bool {
        guard let name = home[window], isShown(name), !isFloating(window),
              let tile = frames(of: name)[window] else { return false }
        return shownFloatingWindows.contains { frame($0).map { !$0.intersection(tile).isEmpty } ?? false }
    }

    var framesBeforeFullscreen: [WindowID: CGRect] {
        var frames: [WindowID: CGRect] = [:]
        for workspace in workspaces.values {
            if let window = workspace.fullscreenWindow, let frame = workspace.frameBeforeFullscreen { frames[window] = frame }
            for entry in workspace.parked { frames[entry.window] = entry.frameBeforeFullscreen }
        }
        return frames
    }

    /// The windows of `before` that float out of fullscreen now, at their frames from before
    /// (docs/tree.md).
    func backFromFullscreen(since before: [WindowID: CGRect]) -> [WindowID: CGRect] {
        var frames: [WindowID: CGRect] = [:]
        for (window, frame) in before {
            guard let name = home[window], workspaces[name]!.floating.contains(window),
                  workspaces[name]!.fullscreenWindow != window else { continue }
            let own = monitor(of: name), center = CGPoint(x: frame.midX, y: frame.midY)
            let under = monitors.first { $0.frame.contains(center) }
            frames[window] = under?.id == own.id ? frame : floatingFrame(frame, from: (under ?? own).area, movingTo: own.area)
        }
        return frames
    }
}

private func floatingFrame(_ frame: CGRect, from: CGRect, movingTo area: CGRect) -> CGRect {
    guard from.width > 0, from.height > 0 else { return frame }
    let x = area.minX + (frame.minX - from.minX) * area.width / from.width
    let y = area.minY + (frame.minY - from.minY) * area.height / from.height
    return fitted(CGRect(origin: CGPoint(x: x, y: y), size: frame.size), in: area).integral
}

/// Ceiling: an app that keeps another size keeps the target's top left corner, so the center
/// moves by half the change (docs/tree.md). Upgrade: at a read back of another size, write
/// the position again around the target's center.
private func resizedFloating(_ frame: CGRect, _ dimension: ResizeDimension, by amount: CGFloat, least: CGSize,
                             in area: CGRect) -> CGRect {
    var size = frame.size
    if dimension == .height {
        size.height = max(size.height + amount, least.height)
    } else {
        size.width = max(size.width + amount, least.width)
    }
    return fitted(CGRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2,
                         width: size.width, height: size.height), in: area)
}

/// No larger than `area`, and moved inside it.
private func fitted(_ frame: CGRect, in area: CGRect) -> CGRect {
    let size = CGSize(width: min(frame.width, area.width), height: min(frame.height, area.height))
    return CGRect(x: min(max(frame.minX, area.minX), area.maxX - size.width),
                  y: min(max(frame.minY, area.minY), area.maxY - size.height), width: size.width, height: size.height)
}
