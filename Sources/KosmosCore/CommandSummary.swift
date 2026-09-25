import CoreGraphics

// What `kosmos list-bindings` says about a command (docs/integrations.md).

extension Command {
    /// A group for launchers, by what the command acts on.
    public var category: String {
        switch self {
        case .focus: "Focus"
        case .move, .swap: "Move"
        case .workspace, .workspaceBackAndForth, .moveNodeToWorkspace: "Workspace"
        case .focusMonitor, .moveNodeToMonitor: "Monitor"
        case .layout, .fullscreen, .joinWith, .flattenWorkspaceTree: "Layout"
        case .resize, .balanceSizes: "Resize"
        case .profile: "Profile"
        case .reloadConfig, .mode, .focusFollowsMouse: "Other"
        }
    }

    /// It leaves out a window given with `--window-id`, which no binding names.
    public var summary: String {
        switch self {
        case .workspace(let target):
            "Switch to \(Self.name(target))"
        case .workspaceBackAndForth:
            "Switch back and forth between the last two workspaces"
        case .focus(let direction, let boundaries):
            "Focus \(direction)\(Self.across(boundaries))"
        case .move(let direction, let boundaries):
            "Move window \(direction)\(Self.across(boundaries))"
        case .swap(let direction):
            "Swap window with the window \(Self.beside(direction))"
        case .joinWith(let direction):
            "Join window with the window \(Self.beside(direction))"
        case .moveNodeToWorkspace(let target, let follow, _):
            "Move window to \(Self.name(target))\(follow ? " and follow" : "")"
        case .layout(.orientation(let orientation)):
            "Set the layout to \(orientation == .horizontal ? "horizontal" : "vertical")"
        case .layout(.toggleOrientation):
            "Toggle the layout between horizontal and vertical"
        case .layout(.toggleFloating):
            "Toggle floating and tiling"
        case .fullscreen:
            "Toggle fullscreen"
        case .resize(let dimension, let amount):
            "\(amount > 0 ? "Grow" : "Shrink") window\(Self.name(dimension)) by \(Self.points(abs(amount)))"
        case .balanceSizes:
            "Balance window sizes"
        case .flattenWorkspaceTree:
            "Flatten the workspace tree"
        case .reloadConfig:
            "Reload the config"
        case .mode(let name):
            "Switch to mode \(name)"
        case .focusMonitor(let target, let wrap):
            "Focus \(Self.name(target))\(wrap ? ", wrapping around" : "")"
        case .moveNodeToMonitor(let target, let follow, let wrap, _):
            "Move window to \(Self.name(target))\(follow ? " and follow" : "")\(wrap ? ", wrapping around" : "")"
        case .profile(let name):
            "Switch to profile \(name)"
        case .focusFollowsMouse(.on):
            "Turn focus follows mouse on"
        case .focusFollowsMouse(.off):
            "Turn focus follows mouse off"
        case .focusFollowsMouse(.toggle):
            "Toggle focus follows mouse"
        }
    }

    private static func name(_ target: Workspace) -> String {
        switch target {
        case .named(let name): "workspace \(name)"
        case .next: "the next workspace on the focused monitor"
        case .previous: "the previous workspace on the focused monitor"
        }
    }

    private static func name(_ target: MonitorTarget) -> String {
        switch target {
        case .direction(let direction): "the monitor \(beside(direction))"
        case .next: "the next monitor"
        case .previous: "the previous monitor"
        case .number(let number): "monitor \(number)"
        }
    }

    private static func name(_ dimension: ResizeDimension) -> String {
        switch dimension {
        case .width: " width"
        case .height: " height"
        case .smart: ""
        }
    }

    private static func across(_ boundaries: Boundaries) -> String {
        switch boundaries {
        case .workspace: ""
        case .allMonitors: ", across monitors"
        case .allMonitorsWrapping: ", across monitors, wrapping around"
        }
    }

    private static func beside(_ direction: Direction) -> String {
        switch direction {
        case .left: "to the left"
        case .right: "to the right"
        case .up: "above"
        case .down: "below"
        }
    }

    private static func points(_ amount: CGFloat) -> String {
        let number = amount == amount.rounded() ? String(Int(amount)) : String(Double(amount))
        return number + (amount == 1 ? " point" : " points")
    }
}
