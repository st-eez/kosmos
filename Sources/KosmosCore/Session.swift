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
        workspaces[name]?.frames(in: display, gaps: gaps) ?? [:]
    }

    // MARK: Windows arriving and leaving

    /// A managed window joins a workspace, the shown one unless a rule names another.
    public mutating func add(_ window: WindowID, to name: String? = nil) -> Plan {
        guard home[window] == nil else { return Plan() }
        let target = name.flatMap { workspaces[$0] != nil ? $0 : nil } ?? visible
        workspaces[target]!.insert(window)
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
        let wasFocused = name == visible && focused == window
        _ = workspaces[name]!.remove(window)
        var plan = Plan()
        plan.frames = frames(of: name)
        if wasFocused { plan.focus = focused.map(KeyWindow.window) ?? KeyWindow.none }
        return plan
    }

    /// Minimized, hidden with its app, or in native fullscreen: out of the layout until it
    /// returns to its place.
    public mutating func park(_ window: WindowID) -> Plan {
        guard let name = home[window], workspaces[name]!.park(window) else { return Plan() }
        var plan = Plan()
        plan.frames = frames(of: name)
        return plan
    }

    /// A parked window returns to its own workspace at its saved position.
    public mutating func unpark(_ window: WindowID) -> Plan {
        guard let name = home[window] else { return Plan() }
        workspaces[name]!.unpark([window])
        var plan = Plan()
        plan.frames = frames(of: name)
        if name != visible { plan.hide = [window] }
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
            guard let window = chosen ?? focused, let source = home[window],
                  !workspaces[source]!.parked.contains(where: { $0.window == window }),
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
            guard floating ? workspace.tile(window) : workspace.float(window) else { return nil }
        case .fullscreen:
            guard workspace.toggleFullscreen(window) else { return nil }
        case .resize(let dimension, let amount):
            guard workspace.resize(window, dimension, by: amount, in: display, gaps: gaps) else { return nil }
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
