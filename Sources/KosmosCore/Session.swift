import CoreGraphics

/// Every workspace of one display and which one is shown (DESIGN.md, section 4.3). A change
/// returns a Plan that the app carries out; the Session never talks to macOS.
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

    /// In the order `next` and `prev` walk.
    public let names: [String]
    private(set) var workspaces: [String: Workspace]
    public private(set) var visible: String
    private var previous: String?
    private var home: [WindowID: String] = [:]
    /// Parked windows whose workspace was hidden when they parked, so Kosmos had concealed
    /// them. Switches skip parked windows, so they stay concealed until they return.
    private var parkedConcealed: Set<WindowID> = []
    /// The smallest size each window accepted, as frames read back after writes show.
    private(set) var minimums: [WindowID: CGSize] = [:]
    public var display: CGRect
    public var gaps: Gaps

    public init(names: [String], display: CGRect, gaps: Gaps = Gaps()) {
        precondition(!names.isEmpty, "a session needs a workspace")
        self.names = names
        workspaces = Dictionary(uniqueKeysWithValues: names.map { ($0, Workspace()) })
        visible = names[0]
        self.display = display
        self.gaps = gaps
    }

    public func workspace(of window: WindowID) -> String? { home[window] }

    /// The focused window of the shown workspace.
    public var focused: WindowID? { workspaces[visible]!.focusedWindow }

    /// Tiled and floating windows; parked windows are left to macOS.
    public func windows(of name: String) -> [WindowID] {
        guard let workspace = workspaces[name] else { return [] }
        return workspace.root.windows + workspace.floating
    }

    public func frames(of name: String) -> [WindowID: CGRect] {
        workspaces[name]?.frames(in: display, gaps: gaps, minimums: minimums) ?? [:]
    }

    // MARK: Windows arriving and leaving

    /// A managed window joins a workspace, the shown one unless a rule names another.
    public mutating func add(_ window: WindowID, to name: String? = nil) -> Plan {
        guard home[window] == nil else { return Plan() }
        let target = name.flatMap { workspaces[$0] != nil ? $0 : nil } ?? visible
        workspaces[target]!.insert(window)
        // A workspace with windows always has a focused one, as in i3; reports refine it.
        if workspaces[target]!.focusedWindow == nil { workspaces[target]!.focus(window) }
        home[window] = target
        var plan = Plan()
        plan.frames = frames(of: target)
        if target != visible { plan.hide = [window] }
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
        parkedConcealed.remove(window)
        let wasFocused = name == visible && focused == window
        _ = workspaces[name]!.remove(window)
        var plan = Plan()
        plan.frames = frames(of: name)
        if wasFocused { plan.focus = focused.map(KeyWindow.window) ?? KeyWindow.none }
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
            if name != visible { parkedConcealed.insert(window) }
        }
        var plan = Plan()
        for name in changed { plan.frames.merge(frames(of: name)) { current, _ in current } }
        return plan
    }

    /// Parked windows return to their own workspaces at their saved positions, and Kosmos
    /// follows `follow` there when its workspace is hidden, as it does for Command-Tab
    /// (DESIGN.md, section 5.5). The other returning windows of hidden workspaces are
    /// concealed again, and those Kosmos concealed that return to the shown workspace are
    /// revealed.
    public mutating func unpark(_ windows: [WindowID], follow: WindowID) -> Plan {
        let returning = windows.filter { isParked($0) }
        let changed = Set(returning.map { home[$0]! })
        for name in changed {
            workspaces[name]!.unpark(returning.filter { home[$0] == name }, in: display, gaps: gaps)
        }
        var plan = Plan()
        if returning.contains(follow), let name = home[follow] {
            workspaces[name]!.focus(follow)
            if name != visible { plan = show(name) }
        }
        for name in changed { plan.frames.merge(frames(of: name)) { current, _ in current } }
        plan.hide += returning.filter { home[$0] != visible && !plan.hide.contains($0) }
        plan.show += returning.filter { home[$0] == visible && parkedConcealed.contains($0) && !plan.show.contains($0) }
        parkedConcealed.subtract(returning)
        return plan
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

    /// The user focused a window of the shown workspace.
    public mutating func adopt(_ window: WindowID) {
        guard let name = home[window] else { return }
        workspaces[name]!.focus(window)
    }

    /// The user reached a hidden window with Command-Tab: show its workspace.
    public mutating func follow(_ window: WindowID) -> Plan {
        guard let name = home[window] else { return Plan() }
        workspaces[name]!.focus(window)
        return show(name)
    }

    // MARK: Commands

    /// Carries out a command. Nil when it does not apply, such as a focus at the edge.
    public mutating func perform(_ command: Command) -> Plan? {
        switch command {
        case .workspace(let target):
            guard let name = resolve(target), name != visible else { return nil }
            return show(name)
        case .workspaceBackAndForth:
            guard let previous, previous != visible else { return nil }
            return show(previous)
        case .moveNodeToWorkspace(let target, let follow, let chosen):
            // A minimized or hidden window stays where it will return to.
            guard let window = chosen ?? focused, let source = home[window], !isParked(window),
                  let name = resolve(target), name != source else { return nil }
            return move(window, from: source, to: name, follow: follow)
        case .reloadConfig, .mode:
            return nil   // the app reloads the config or switches hotkeys
        default:
            return performOnFocused(command)
        }
    }

    private mutating func performOnFocused(_ command: Command) -> Plan? {
        guard let window = focused else { return nil }
        var workspace = workspaces[visible]!
        var plan = Plan()
        switch command {
        case .focus(let direction):
            guard let target = workspace.focus(direction, from: window) else { return nil }
            plan.focus = .window(target)
        case .move(let direction):
            guard workspace.move(window, direction) else { return nil }
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
        case .workspace, .workspaceBackAndForth, .moveNodeToWorkspace, .reloadConfig, .mode:
            return nil
        }
        workspaces[visible] = workspace
        plan.frames = frames(of: visible)
        return plan
    }

    private func resolve(_ target: Command.Workspace) -> String? {
        switch target {
        case .named(let name):
            return workspaces[name] != nil ? name : nil
        case .next, .previous:
            let index = names.firstIndex(of: visible)!
            let step = target == .next ? 1 : -1
            return names[(index + step + names.count) % names.count]
        }
    }

    private mutating func show(_ name: String) -> Plan {
        var plan = Plan()
        plan.hide = windows(of: visible)
        plan.show = windows(of: name)
        previous = visible
        visible = name
        // A workspace whose windows were never focused still gets one focused.
        if focused == nil, let first = plan.show.first { workspaces[name]!.focus(first) }
        plan.frames = frames(of: name)
        plan.focus = focused.map(KeyWindow.window) ?? KeyWindow.none
        return plan
    }

    private mutating func move(_ window: WindowID, from source: String, to name: String, follow: Bool) -> Plan {
        let wasFocused = source == visible && focused == window
        let floating = workspaces[source]!.floating.contains(window)
        _ = workspaces[source]!.remove(window)
        workspaces[name]!.insert(window)
        if floating { _ = workspaces[name]!.float(window) }   // it floats there too
        workspaces[name]!.focus(window)
        home[window] = name
        if follow, name != visible {
            let onScreen = source == visible
            var plan = show(name)
            if onScreen {
                // On screen already, it travels with the switch.
                plan.hide.removeAll { $0 == window }
                plan.show.removeAll { $0 == window }
            }
            return plan
        }
        var plan = Plan()
        if source == visible { plan.hide = [window] }
        if name == visible { plan.show = [window] }
        plan.frames = frames(of: source).merging(frames(of: name)) { a, _ in a }
        if wasFocused || name == visible { plan.focus = focused.map(KeyWindow.window) ?? KeyWindow.none }
        return plan
    }
}
