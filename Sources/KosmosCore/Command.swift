import CoreGraphics

/// A command from a hotkey or the CLI. Names follow AeroSpace's, so existing bindings
/// carry over; flags AeroSpace needs for several monitors are left out.
public enum Command: Equatable, Sendable {
    public enum Workspace: Equatable, Sendable {
        case named(String)
        case next
        case previous
    }

    public enum Layout: Equatable, Sendable {
        case orientation(Orientation)
        case toggleOrientation
        case toggleFloating
    }

    public enum Toggle: Equatable, Sendable {
        case on
        case off
        case toggle
    }

    case workspace(Workspace)
    case workspaceBackAndForth
    case focus(Direction)
    case move(Direction)
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
    /// Turns focus follows mouse on or off until the next config load.
    case focusFollowsMouse(Toggle)

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
        case "focus", "move", "swap", "join-with":
            guard rest.count == 1 else { return usage }
            guard let direction = direction(rest[0]) else { return fail("\(name): unknown direction \(rest[0])") }
            switch name {
            case "focus": return .success(.focus(direction))
            case "move": return .success(.move(direction))
            case "swap": return .success(.swap(direction))
            default: return .success(.joinWith(direction))
            }
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
        case "focus-follows-mouse":
            switch rest {
            case ["on"]: return .success(.focusFollowsMouse(.on))
            case ["off"]: return .success(.focusFollowsMouse(.off))
            case ["toggle"]: return .success(.focusFollowsMouse(.toggle))
            default: return fail("usage: focus-follows-mouse on|off|toggle")
            }
        default: return usage
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
