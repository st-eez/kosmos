import CoreGraphics

/// A checked config file. `Config.load` builds one, and every monitor, workspace and mode
/// name in it is defined. docs/sample-config.toml is Steve's AeroSpace setup in this schema.
public struct Config: Equatable, Sendable {
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
    /// Display profiles in file order. The first whose `when` holds applies (`setup(for:)`).
    public var profiles: [Profile] = []

    /// No workspaces, bindings, rules or profiles, for when there is no config file.
    public init() {}
}

/// A connected display, as the app reads it.
public struct Display: Equatable, Sendable {
    public var id: DisplayID
    /// The name `NSScreen.localizedName` reports.
    public var name: String
    /// The EDID alphanumeric serial number, when the app can read one.
    public var serial: String?
    public var isBuiltIn: Bool
    /// The whole display, in the top left origin coordinates Accessibility uses.
    public var frame: CGRect
    /// The visible frame, without the menu bar and the Dock.
    public var area: CGRect

    public init(id: DisplayID = 0, name: String, serial: String? = nil, isBuiltIn: Bool = false,
                frame: CGRect = .zero, area: CGRect? = nil) {
        self.id = id
        self.name = name
        self.serial = serial
        self.isBuiltIn = isBuiltIn
        self.frame = frame
        self.area = area ?? frame
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
    /// Monitor names that must all be connected. A profile without any applies only when no
    /// profile with them does, at launch (`Config.setup(for:)`).
    public var when: [String] = []
    /// No display other than the `when` monitors may be connected.
    public var only = false
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
    /// The display each workspace belongs on: the first display, left to right, then top to
    /// bottom, that the first connected monitor in the workspace's list matches. A workspace
    /// with no connected monitor is absent, and free (DESIGN.md, section 5.13).
    public var workspaceDisplays: [String: DisplayID]
    /// Windows on a workspace missing from `workspaces` move to the workspace named here.
    public var mergeWorkspaces: [String: String]
    /// The profile's rules, then the base rules with `mergeWorkspaces` applied to their
    /// workspaces.
    public var rules: [WindowRule]
    /// The displays as the session tiles them, in the order above, each with its gaps and
    /// the monitor names that match it.
    public var monitors: [Monitor]
}

extension Config {
    /// The profile that applies (DESIGN.md, sections 5.8 and 5.13): the one `forced` names,
    /// as the `profile` command asks for, else the first whose `when` holds. Displays that no
    /// profile's `when` fits keep `active`, the profile that applies now, as Steve's
    /// `apply-profile.sh` kept its profile for displays it did not know. With no active
    /// profile, as at launch, the first profile without `when` applies, else the base config.
    public func setup(for displays: [Display], profile forced: String? = nil, keeping active: String? = nil) -> Setup {
        let displays = displays.sorted { ($0.frame.minX, $0.frame.minY, $0.id) < ($1.frame.minX, $1.frame.minY, $1.id) }
        func firstDisplay(_ monitor: String) -> DisplayID? {
            monitors[monitor].flatMap { match in displays.first(where: match.matches)?.id }
        }
        func holds(_ profile: Profile) -> Bool {
            guard !profile.when.isEmpty, profile.when.allSatisfy({ firstDisplay($0) != nil }) else { return false }
            return !profile.only || displays.allSatisfy { display in
                profile.when.contains { monitors[$0]?.matches(display) == true }
            }
        }
        func named(_ name: String?) -> Profile? { name.flatMap { name in profiles.first { $0.name == name } } }
        let profile = named(forced) ?? profiles.first(where: holds)
            ?? (active != nil ? named(active) : profiles.first { $0.when.isEmpty })
        let workspaces = profile?.workspaces ?? workspaces
        let assignment = profile?.workspaceMonitors ?? workspaceMonitors
        var workspaceDisplays: [String: DisplayID] = [:]
        for workspace in workspaces {
            workspaceDisplays[workspace] = assignment[workspace]?.lazy.compactMap(firstDisplay).first
        }
        let merge = profile?.mergeWorkspaces ?? [:]
        let baseRules = rules.map { rule in
            var rule = rule
            if let workspace = rule.workspace, let target = merge[workspace] { rule.workspace = target }
            return rule
        }
        let tiled = displays.map { display in
            Monitor(id: display.id, frame: display.frame, area: display.area, gaps: gaps(on: display),
                    names: monitors.filter { $0.value.matches(display) }.keys.sorted())
        }
        return Setup(profile: profile?.name, workspaces: workspaces, workspaceDisplays: workspaceDisplays,
                     mergeWorkspaces: merge, rules: (profile?.rules ?? []) + baseRules, monitors: tiled)
    }

    public func gaps(on display: Display) -> Gaps {
        let outer = outerGaps(on: display)
        return Gaps(inner: CGFloat(gaps.inner), outer: Insets(top: CGFloat(outer.top), left: CGFloat(outer.left),
                                                              bottom: CGFloat(outer.bottom), right: CGFloat(outer.right)))
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
