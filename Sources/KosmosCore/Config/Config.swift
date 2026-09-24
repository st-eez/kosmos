/// A checked config file. `Config.load` builds one, and every monitor and workspace name in
/// it is defined. docs/sample-config.toml is Steve's AeroSpace setup in this schema.
public struct Config: Equatable, Sendable {
    public var startAtLogin = false
    /// Move the mouse pointer into the focused window after a keyboard focus change.
    public var mouseFollowsFocus = false
    public var workspaces: [String] = []
    /// Display matchers by the name the rest of the config uses for them.
    public var monitors: [String: MonitorMatch] = [:]
    /// The monitors each workspace belongs on, in order of preference.
    public var workspaceMonitors: [String: [String]] = [:]
    public var gaps = GapSettings()
    /// Each mode's bindings in file order. Kosmos starts in mode `main`.
    public var modes: [String: [Binding]] = [:]
    /// Window rules in file order. The first rule that matches a window applies.
    public var rules: [WindowRule] = []
    /// Display profiles in file order. The first whose monitors are all connected applies.
    public var profiles: [Profile] = []
}

/// A connected display, as the app reads it.
public struct Display: Equatable, Sendable {
    /// The name `NSScreen.localizedName` reports.
    public var name: String
    /// The EDID alphanumeric serial number, when the app can read one.
    public var serial: String?
    public var isBuiltIn: Bool

    public init(name: String, serial: String? = nil, isBuiltIn: Bool = false) {
        self.name = name
        self.serial = serial
        self.isBuiltIn = isBuiltIn
    }
}

public enum MonitorMatch: Equatable, Sendable {
    /// Displays whose name contains this text, ignoring case. macOS appends " (1)" and " (2)"
    /// to the names of identical displays, and this matches both.
    case name(String)
    /// The display with this EDID alphanumeric serial number. Identical displays share a name
    /// and differ only here.
    case serial(String)
    case builtIn

    public func matches(_ display: Display) -> Bool {
        switch self {
        case .name(let text): display.name.lowercased().contains(text.lowercased())
        case .serial(let serial): display.serial == serial
        case .builtIn: display.isBuiltIn
        }
    }
}

public struct GapSettings: Equatable, Sendable {
    /// Points between neighboring windows.
    public var inner = 0
    /// Points between the windows and each edge of a display.
    public var outer = OuterGaps()
    /// Changes to `outer` on displays a named monitor matches. The first entry that matches a
    /// display applies.
    public var outerPerMonitor: [MonitorOuterGaps] = []
}

public struct OuterGaps: Equatable, Sendable {
    public var top = 0
    public var left = 0
    public var bottom = 0
    public var right = 0
}

public struct MonitorOuterGaps: Equatable, Sendable {
    public var monitor: String
    public var top: Int?
    public var left: Int?
    public var bottom: Int?
    public var right: Int?
}

public struct Binding: Equatable, Sendable {
    /// The combination as written in the config, such as `alt-shift-h`.
    public var key: String
    public var combo: KeyCombo
    /// The command's arguments, as the CLI passes them. `Command.parse` accepted them when the
    /// config loaded.
    public var arguments: [String]
}

public struct WindowRule: Equatable, Sendable {
    /// Matches this bundle identifier exactly.
    public var appID: String?
    /// Matches app names that contain this text, ignoring case.
    public var appName: String?
    /// Float the window, or tile it when false.
    public var float: Bool?
    /// Put the window on this workspace.
    public var workspace: String?

    /// Whether the rule matches a window of the app with this bundle identifier and name.
    public func matches(appID: String?, appName: String?) -> Bool {
        if let id = self.appID, id != appID { return false }
        if let text = self.appName {
            guard let appName, appName.lowercased().contains(text.lowercased()) else { return false }
        }
        return true
    }

    /// Whether this rule matches every window `other` matches, so `other` never applies after
    /// it. Every such window has `other`'s bundle identifier, when `other` names one, and a name
    /// containing `other`'s text, so matching those two values proves it. A rule on the app
    /// name never covers a rule on the bundle identifier alone, whose app name is unknown.
    func covers(_ other: WindowRule) -> Bool {
        matches(appID: other.appID, appName: other.appName)
    }
}

/// Settings for one set of connected displays. A key the profile leaves out keeps the base
/// config's value.
public struct Profile: Equatable, Sendable {
    public var name: String
    /// Monitor names that must all be connected. Empty matches any set of displays.
    public var when: [String] = []
    public var workspaces: [String]?
    public var workspaceMonitors: [String: [String]]?
    /// Where the windows of a workspace this profile leaves out go, by workspace name.
    public var mergeWorkspaces: [String: String] = [:]
    /// Rules checked before the base config's rules.
    public var rules: [WindowRule] = []
}

/// What the config says for one set of connected displays.
public struct Setup: Equatable, Sendable {
    /// The profile that applies, or nil when none matches and the base config applies alone.
    public var profile: String?
    public var workspaces: [String]
    /// The display each workspace belongs on, as an index into the displays given to
    /// `setup(for:)`: the first display that the first connected monitor in the workspace's
    /// list matches. A workspace with no connected monitor is absent, and the app places it.
    public var workspaceDisplays: [String: Int]
    /// Windows on a workspace missing from `workspaces` move to the workspace named here.
    public var mergeWorkspaces: [String: String]
    /// The profile's rules, then the base rules with `mergeWorkspaces` applied to their
    /// workspaces.
    public var rules: [WindowRule]
}

extension Config {
    public func setup(for displays: [Display]) -> Setup {
        func firstDisplay(_ monitor: String) -> Int? {
            monitors[monitor].flatMap { match in displays.firstIndex(where: match.matches) }
        }
        let profile = profiles.first { $0.when.allSatisfy { firstDisplay($0) != nil } }
        let workspaces = profile?.workspaces ?? workspaces
        let assignment = profile?.workspaceMonitors ?? workspaceMonitors
        var workspaceDisplays: [String: Int] = [:]
        for workspace in workspaces {
            workspaceDisplays[workspace] = assignment[workspace]?.lazy.compactMap(firstDisplay).first
        }
        let merge = profile?.mergeWorkspaces ?? [:]
        let baseRules = rules.map { rule in
            var rule = rule
            if let workspace = rule.workspace, let target = merge[workspace] { rule.workspace = target }
            return rule
        }
        return Setup(profile: profile?.name, workspaces: workspaces, workspaceDisplays: workspaceDisplays,
                     mergeWorkspaces: merge, rules: (profile?.rules ?? []) + baseRules)
    }

    public func outerGaps(on display: Display) -> OuterGaps {
        var gaps = self.gaps.outer
        if let change = self.gaps.outerPerMonitor.first(where: { monitors[$0.monitor]?.matches(display) == true }) {
            gaps.top = change.top ?? gaps.top
            gaps.left = change.left ?? gaps.left
            gaps.bottom = change.bottom ?? gaps.bottom
            gaps.right = change.right ?? gaps.right
        }
        return gaps
    }
}
