import CoreGraphics

/// A checked config file (docs/config.md): `Config.load` builds one, and every monitor,
/// workspace and mode name in it is defined. docs/sample-config.toml shows the schema.
public struct Config: Equatable, Sendable {
    /// Move the mouse pointer to the focus the keyboard moved (Command.movesPointer).
    public var mouseFollowsFocus = false
    public var focusFollowsMouse = FocusFollowsMouse()
    /// The modifiers that start a modifier drag, or nil when modifier drags are off
    /// (docs/modifier-drags.md).
    public var mouseModifier: KeyCombo.Modifiers? = .alt
    /// Slide windows to the frames a relayout gives them, and pop new windows in
    /// (docs/geometry.md).
    public var animations = true
    public var workspaces: [String] = []
    /// Display matchers by the name the rest of the config uses for them.
    public var monitors: [String: MonitorMatch] = [:]
    /// The monitors each workspace belongs on, in order of preference.
    public var workspaceMonitors: [String: [String]] = [:]
    public var gaps = GapSettings()
    /// Borders around the windows on screen, or nil while `borders = false` turns them off
    /// (docs/borders.md).
    public var borders: BorderSettings? = BorderSettings()
    /// Each mode's bindings in file order. Kosmos starts in mode `main`.
    public var modes: [String: [Binding]] = [:]
    /// Window rules in file order. The first rule that matches a window applies.
    public var rules: [WindowRule] = []
    /// Display profiles in file order. The first whose `when` holds applies (`setup(for:)`).
    public var profiles: [Profile] = []

    public init() {}

    /// What applies with no config file.
    public static let defaults: Config = {
        var config = Config()
        config.workspaces = (1...9).map(String.init)
        return config
    }()
}

/// Focus moves to the window the pointer enters (docs/focus-follows-mouse.md).
public struct FocusFollowsMouse: Equatable, Sendable {
    public var enabled = false
    /// Apps whose windows the pointer never focuses, each named by its bundle identifier or
    /// its name.
    public var ignoreApps: [String] = []

    public init() {}

    /// Names match whole, ignoring case.
    public func ignores(appID: String?, appName: String?) -> Bool {
        let names = [appID, appName].compactMap { $0?.lowercased() }
        return ignoreApps.contains { names.contains($0.lowercased()) }
    }
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
    public var inner: CGFloat = 0
    /// Points between the windows and each edge of a display.
    public var outer = Insets()
    /// Changes to `outer` on displays a named monitor matches. The first entry that matches a
    /// display applies.
    public var outerPerMonitor: [MonitorOuterGaps] = []
}

public struct MonitorOuterGaps: Equatable, Sendable {
    public var monitor: String
    public var top: CGFloat?
    public var left: CGFloat?
    public var bottom: CGFloat?
    public var right: CGFloat?
}

public struct Binding: Equatable, Sendable {
    /// The combination as written in the config, such as `alt-shift-h`.
    public var key: String
    public var combo: KeyCombo
    /// The command's arguments, as the CLI passes them.
    public var arguments: [String]
    /// What `Command.parse` made of `arguments` when the config loaded.
    public var command: Command
}

public struct WindowRule: Equatable, Sendable {
    public var appID: String?
    /// Matches app names that contain this text, ignoring case.
    public var appName: String?
    /// Float the window, or tile it when false.
    public var float: Bool?
    /// Put the window on this workspace, which Kosmos shows when the window's app keyed it
    /// (AdmissionFocus).
    public var workspace: String?

    public func matches(appID: String?, appName: String?) -> Bool {
        if let id = self.appID, id != appID { return false }
        if let text = self.appName {
            guard let appName, appName.lowercased().contains(text.lowercased()) else { return false }
        }
        return true
    }

    /// Whether this rule matches every window `other` matches, so `other` never applies after
    /// it (docs/config.md).
    func covers(_ other: WindowRule) -> Bool {
        matches(appID: other.appID, appName: other.appName)
    }
}

/// Settings for one set of connected displays. A key the profile leaves out keeps the base
/// config's value.
public struct Profile: Equatable, Sendable {
    public var name: String
    /// Monitor names that must all be connected (`Config.setup(for:)`).
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
    /// A workspace with no connected monitor in its list is absent, and free (docs/displays.md).
    public var workspaceDisplays: [String: DisplayID]
    /// Windows on a workspace missing from `workspaces` move to the workspace named here.
    public var mergeWorkspaces: [String: String]
    public var rules: [WindowRule]
    public var monitors: [Monitor]
}

extension Config {
    /// What applies to `displays` (docs/config.md): `forced` is the profile the `profile`
    /// command names, and `active` the one that applies now, which displays no `when` fits keep.
    public func setup(for displays: [Display], profile forced: String? = nil, keeping active: String? = nil) -> Setup {
        let tiled = Monitor.arranged(displays.map { Monitor(id: $0.id, frame: $0.frame, area: $0.area, gaps: gaps(on: $0)) })
        let byID = Dictionary(displays.map { ($0.id, $0) }) { first, _ in first }
        let displays = tiled.map { byID[$0.id]! }
        func firstDisplay(_ monitor: String) -> DisplayID? {
            monitors[monitor].flatMap { match in displays.first(where: match.matches)?.id }
        }
        func named(_ name: String?) -> Profile? { name.flatMap { name in profiles.first { $0.name == name } } }
        let fallback = profiles.first { $0.when.isEmpty }
        let builtInAlone = displays.count == 1 && displays[0].isBuiltIn
        let profile = named(forced)
            ?? profiles.first { !$0.when.isEmpty && $0.when.allSatisfy { firstDisplay($0) != nil } }
            ?? (builtInAlone ? fallback : nil) ?? named(active) ?? fallback
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
        return Setup(profile: profile?.name, workspaces: workspaces, workspaceDisplays: workspaceDisplays,
                     mergeWorkspaces: merge, rules: (profile?.rules ?? []) + baseRules, monitors: tiled)
    }

    public func gaps(on display: Display) -> Gaps {
        var outer = gaps.outer
        if let change = gaps.outerPerMonitor.first(where: { monitors[$0.monitor]?.matches(display) == true }) {
            outer.top = change.top ?? outer.top
            outer.left = change.left ?? outer.left
            outer.bottom = change.bottom ?? outer.bottom
            outer.right = change.right ?? outer.right
        }
        return Gaps(inner: gaps.inner, outer: outer)
    }
}
