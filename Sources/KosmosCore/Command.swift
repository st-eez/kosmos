import CoreGraphics

/// A command from a hotkey or the CLI. Names follow AeroSpace's, so existing bindings
/// carry over.
public enum Command: Equatable, Sendable {
    public enum Workspace: Equatable, Sendable {
        case named(String)
        case next
        case previous
    }

    /// Where `focus` and `move` stop, AeroSpace's `--boundaries` and `--boundaries-action`.
    public enum Boundaries: Equatable, Sendable {
        /// The edge of the workspace.
        case workspace
        /// The edge of the outermost display in the direction: at the edge of the
        /// workspace, go on to the next display.
        case allMonitors
        /// As `allMonitors`, and from the outermost display on to the one at the other end.
        case allMonitorsWrapping
    }

    /// A display, as the monitor commands name one (DESIGN.md, section 5.13).
    public enum MonitorTarget: Equatable, Sendable {
        case direction(Direction)
        case next
        case previous
        /// Counted from 1, left to right, then top to bottom.
        case number(Int)
    }

    public enum Layout: Equatable, Sendable {
        case orientation(Orientation)
        case toggleOrientation
        case toggleFloating
    }

    case workspace(Workspace)
    case workspaceBackAndForth
    case focus(Direction, boundaries: Boundaries = .workspace)
    case move(Direction, boundaries: Boundaries = .workspace)
    case swap(Direction)
    case joinWith(Direction)
    /// Moves the focused window, or the window given with `--window-id`.
    case moveNodeToWorkspace(Workspace, focusFollowsWindow: Bool, window: WindowID? = nil)
    case layout(Layout)
    case fullscreen
    case resize(ResizeDimension, by: CGFloat)
    case balanceSizes
    case flattenWorkspaceTree
    case reloadConfig
    /// Switches the hotkeys to another binding mode from the config.
    case mode(String)
    case focusMonitor(MonitorTarget, wrapAround: Bool)
    /// Moves the focused window, or the window given with `--window-id`, to the workspace
    /// the display shows.
    case moveNodeToMonitor(MonitorTarget, focusFollowsWindow: Bool, wrapAround: Bool, window: WindowID? = nil)
    /// Applies a display profile from the config until the displays change.
    case profile(String)

    public struct ParseError: Error, Equatable, Sendable {
        public let message: String
    }

    public static func parse(_ arguments: [String]) -> Result<Command, ParseError> {
        func fail(_ message: String) -> Result<Command, ParseError> { .failure(ParseError(message: message)) }
        guard let name = arguments.first else { return fail("no command") }
        let rest = Array(arguments.dropFirst())
        let usage = fail("unknown command or arguments: \(arguments.joined(separator: " "))")
        switch name {
        case "workspace":
            guard rest.count == 1 else { return usage }
            return .success(.workspace(workspace(rest[0])))
        case "workspace-back-and-forth":
            return rest.isEmpty ? .success(.workspaceBackAndForth) : usage
        case "focus", "move":
            // AeroSpace's --boundaries, whose default is the workspace, and its
            // --boundaries-action, before or after the direction. AeroSpace wraps only focus;
            // Kosmos wraps a move too, as Steve's `move || move-node-to-monitor --wrap-around`
            // binding did. A move takes only the wrap; no binding needs AeroSpace's `stop` or
            // `fail` for one.
            var across = false, wraps = false, directions: [String] = []
            var words = rest[...]
            while let word = words.popFirst() {
                switch word {
                case "--boundaries":
                    switch words.popFirst() {
                    case "workspace": across = false
                    case "all-monitors-outer-frame": across = true
                    default: return fail("\(name): --boundaries takes workspace or all-monitors-outer-frame")
                    }
                case "--boundaries-action":
                    switch words.popFirst() {
                    case "stop" where name == "focus": wraps = false
                    case "wrap-around-all-monitors": wraps = true
                    default:
                        return fail("\(name): --boundaries-action takes \(name == "focus" ? "stop or " : "")wrap-around-all-monitors")
                    }
                default:
                    directions.append(word)
                }
            }
            guard directions.count == 1 else { return usage }
            guard let direction = direction(directions[0]) else { return fail("\(name): unknown direction \(directions[0])") }
            if wraps, !across { return fail("\(name): wrap-around-all-monitors needs --boundaries all-monitors-outer-frame") }
            let boundaries: Boundaries = wraps ? .allMonitorsWrapping : across ? .allMonitors : .workspace
            return .success(name == "focus" ? .focus(direction, boundaries: boundaries) : .move(direction, boundaries: boundaries))
        case "swap", "join-with":
            guard rest.count == 1 else { return usage }
            guard let direction = direction(rest[0]) else { return fail("\(name): unknown direction \(rest[0])") }
            return .success(name == "swap" ? .swap(direction) : .joinWith(direction))
        case "move-node-to-workspace":
            let usageText = "usage: move-node-to-workspace [--focus-follows-window] [--window-id <id>] <name|next|prev>"
            var follow = false, window: WindowID?, targets: [String] = []
            var words = rest[...]
            while let word = words.popFirst() {
                switch word {
                case "--focus-follows-window": follow = true
                case "--window-id":
                    guard let id = words.popFirst().flatMap(WindowID.init) else { return fail(usageText) }
                    window = id
                default: targets.append(word)
                }
            }
            guard targets.count == 1, !targets[0].hasPrefix("--") else { return fail(usageText) }
            return .success(.moveNodeToWorkspace(workspace(targets[0]), focusFollowsWindow: follow, window: window))
        case "layout":
            switch rest {
            case ["horizontal"], ["tiles", "horizontal"]: return .success(.layout(.orientation(.horizontal)))
            case ["vertical"], ["tiles", "vertical"]: return .success(.layout(.orientation(.vertical)))
            case ["tiles", "horizontal", "vertical"], ["horizontal", "vertical"]: return .success(.layout(.toggleOrientation))
            case ["floating", "tiling"], ["tiling", "floating"]: return .success(.layout(.toggleFloating))
            default: return usage
            }
        case "fullscreen":
            return rest.isEmpty ? .success(.fullscreen) : usage
        case "resize":
            guard rest.count == 2 else { return usage }
            let dimension: ResizeDimension? = switch rest[0] {
            case "width": .width
            case "height": .height
            case "smart": .smart
            default: nil
            }
            guard let dimension else { return fail("resize: unknown dimension \(rest[0])") }
            let amount = rest[1]
            guard amount.first == "+" || amount.first == "-", let value = Double(amount), value != 0 else {
                return fail("resize: amount must be +N or -N points, got \(amount)")
            }
            return .success(.resize(dimension, by: CGFloat(value)))
        case "balance-sizes": return rest.isEmpty ? .success(.balanceSizes) : usage
        case "flatten-workspace-tree": return rest.isEmpty ? .success(.flattenWorkspaceTree) : usage
        case "reload-config": return rest.isEmpty ? .success(.reloadConfig) : usage
        case "mode": return rest.count == 1 ? .success(.mode(rest[0])) : usage
        case "profile": return rest.count == 1 && !rest[0].hasPrefix("-") ? .success(.profile(rest[0])) : usage
        case "focus-monitor", "move-node-to-monitor":
            let movesNode = name == "move-node-to-monitor"
            let usageText = "usage: \(name) " + (movesNode ? "[--focus-follows-window] [--window-id <id>] " : "")
                + "[--wrap-around] <left|right|up|down|next|prev|number>"
            var follow = false, wrap = false, window: WindowID?, targets: [String] = []
            var words = rest[...]
            while let word = words.popFirst() {
                switch word {
                case "--wrap-around": wrap = true
                case "--focus-follows-window" where movesNode: follow = true
                case "--window-id" where movesNode:
                    guard let id = words.popFirst().flatMap(WindowID.init) else { return fail(usageText) }
                    window = id
                default: targets.append(word)
                }
            }
            guard targets.count == 1, let target = monitor(targets[0]) else { return fail(usageText) }
            // As in AeroSpace, wrapping needs an order to wrap in.
            if wrap, case .number = target { return fail("\(name): --wrap-around needs a direction, next or prev") }
            return .success(movesNode ? .moveNodeToMonitor(target, focusFollowsWindow: follow, wrapAround: wrap, window: window)
                                      : .focusMonitor(target, wrapAround: wrap))
        default: return usage
        }
    }

    private static func monitor(_ target: String) -> MonitorTarget? {
        if let direction = direction(target) { return .direction(direction) }
        switch target {
        case "next": return .next
        case "prev": return .previous
        default: return Int(target).flatMap { $0 > 0 ? MonitorTarget.number($0) : nil }
        }
    }

    private static func workspace(_ target: String) -> Workspace {
        switch target {
        case "next": .next
        case "prev": .previous
        default: .named(target)
        }
    }

    private static func direction(_ word: String) -> Direction? {
        switch word {
        case "left": .left
        case "right": .right
        case "up": .up
        case "down": .down
        default: nil
        }
    }
}
