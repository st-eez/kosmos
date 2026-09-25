import CoreGraphics
import Testing
@testable import KosmosCore

private let header = "config-version = 1\nworkspaces = ['1', '2', '3']\n"

/// Loads `header` followed by `body`, so line 3 is the first line of `body`.
private func load(_ body: String) -> (config: Config?, diagnostics: [String]) {
    let result = Config.load(header + body)
    return (result.config, result.diagnostics.map(\.description))
}

@Suite struct ConfigLoaderTests {
    @Test func minimalConfigTakesDefaults() throws {
        let result = load("")
        #expect(result.diagnostics.isEmpty)
        let config = try #require(result.config)
        #expect(config.workspaces == ["1", "2", "3"])
        #expect(!config.mouseFollowsFocus)
        #expect(config.gaps == GapSettings())
        #expect(config.modes.isEmpty && config.rules.isEmpty && config.profiles.isEmpty)
    }

    @Test func requiredKeys() {
        let result = Config.load("")
        #expect(result.config == nil)
        #expect(result.diagnostics.map(\.description) == [
            "1:1: error: missing key 'config-version'; set it to 1",
            "1:1: error: missing key 'workspaces'",
        ])
        #expect(Config.load("config-version = 2\nworkspaces = ['1']").diagnostics.map(\.description) == [
            "1:18: error: config-version: this version of Kosmos reads config-version 1",
        ])
    }

    @Test func syntaxErrorsComeBackAsDiagnostics() {
        let result = load("[gaps]\ninner = 'ten")
        #expect(result.config == nil)
        #expect(result.diagnostics == ["4:9: error: gaps.inner: the string is not closed on this line"])
    }

    @Test func focusFollowsMouse() throws {
        let config = try #require(load("""
            focus-follows-mouse = true
            focus-follows-mouse-ignore-apps = ['Google Chrome for Testing', 'com.apple.Notes']
            """).config)
        var expected = FocusFollowsMouse()
        expected.enabled = true
        expected.ignoreApps = ["Google Chrome for Testing", "com.apple.Notes"]
        #expect(config.focusFollowsMouse == expected)
        // Off by default.
        #expect(try #require(load("").config).focusFollowsMouse == FocusFollowsMouse())
    }

    @Test func borders() throws {
        let steve = try #require(load("borders = { width = 4.0, active = '#7aa2f7', inactive = '#00000000' }").config)
        #expect(steve.borders == BorderSettings(width: 4, active: BorderColor(hex: "#7aa2f7")!, inactive: .clear))
        // Width 4 and no inactive border unless the table says otherwise, and off with no table.
        let table = try #require(load("[borders]\nactive = '#7aa2f7'\nwidth = 2").config)
        #expect(table.borders == BorderSettings(width: 2, active: BorderColor(hex: "#7aa2f7")!))
        #expect(try #require(load("[borders]\nactive = '#7aa2f7'").config).borders?.width == 4)
        #expect(try #require(load("").config).borders == nil)
    }

    @Test func borderMistakes() {
        #expect(load("borders = { width = 0, inactive = '#414868' }").diagnostics == [
            "3:11: error: borders: missing key 'active', the focused window's color, such as '#7aa2f7'",
            "3:21: error: borders.width: the width must be above 0",
        ])
        #expect(load("borders = { width = '4', active = '7aa2f7', inactive = '#4148', style = 'round' }").diagnostics == [
            "3:21: error: borders.width: expected a number, found a string",
            "3:35: error: borders.active: expected a color as '#rrggbb' or '#rrggbbaa', found '7aa2f7'",
            "3:56: error: borders.inactive: expected a color as '#rrggbb' or '#rrggbbaa', found '#4148'",
            "3:65: error: borders.style: unknown key",
        ])
    }

    /// A theme file sets the borders, as the dotfiles' theme-set links one per theme.
    @Test func includedFilesAddTheirKeys() throws {
        let files = ["theme.toml": "[borders]\nwidth = 4.0\nactive = '#7aa2f7'\n", "more/gaps.toml": "gaps = { inner = 10 }"]
        let result = Config.load(header + "include = ['theme.toml', 'more/gaps.toml']", including: { files[$0] })
        #expect(result.diagnostics.isEmpty)
        let config = try #require(result.config)
        #expect(config.borders == BorderSettings(width: 4, active: BorderColor(hex: "#7aa2f7")!))
        #expect(config.gaps.inner == 10)
        #expect(try #require(Config.load(header + "include = 'theme.toml'", including: { files[$0] }).config).borders != nil)
    }

    /// Each problem names its file, the main file's first, and each file in include order.
    @Test func includeMistakes() {
        let files = [
            "theme.toml": "gaps = { inner = 5 }\nborders = { active = 'blue' }\ninclude = ['other.toml']",
            "broken.toml": "[borders\n",
            "second.toml": "borders = { active = '#7aa2f7' }",
        ]
        let result = Config.load(header + "include = ['theme.toml', 'missing.toml', '../up.toml', '/abs.toml', 'broken.toml', 'second.toml']\ngaps = { inner = 'x' }",
                                 including: { files[$0] })
        #expect(result.config == nil)
        #expect(result.diagnostics.map { "\($0.file ?? "main"): \($0)" } == [
            "main: 3:26: error: include[1]: cannot read 'missing.toml' in the config's directory",
            "main: 3:42: error: include[2]: name a file in the config's directory, such as 'theme.toml'",
            "main: 3:56: error: include[3]: name a file in the config's directory, such as 'theme.toml'",
            "main: 4:18: error: gaps.inner: expected an integer, found a string",
            "theme.toml: 1:1: error: gaps: set in the main config file too",
            "theme.toml: 2:22: error: borders.active: expected a color as '#rrggbb' or '#rrggbbaa', found 'blue'",
            "theme.toml: 3:1: error: include: 'include' belongs in the main config file",
            "broken.toml: 1:9: error: borders: expected ']' to close the table header",
            "second.toml: 1:1: error: borders: set in 'theme.toml' too",
        ])
        // With no reader, as for docs/sample-config.toml, every include is unreadable.
        #expect(load("include = ['theme.toml']").diagnostics == ["3:12: error: include[0]: cannot read 'theme.toml' in the config's directory"])
    }

    @Test func focusFollowsMouseMistakes() {
        #expect(load("""
            focus-follows-mouse = 'on'
            focus-follows-mouse-ignore-apps = ['Numi', '', 3]
            focus-follow-mouse = true
            """).diagnostics == [
            "3:23: error: focus-follows-mouse: expected true or false, found a string",
            "4:44: error: focus-follows-mouse-ignore-apps[1]: the string is empty",
            "4:48: error: focus-follows-mouse-ignore-apps[2]: expected a string, found an integer",
            "5:1: error: focus-follow-mouse: unknown key; did you mean 'focus-follows-mouse'?",
        ])
    }

    @Test func mouseModifier() throws {
        #expect(try #require(load("").config).mouseModifier == .alt)
        #expect(try #require(load("mouse-modifier = 'shift-ctrl'").config).mouseModifier == [.ctrl, .shift])
        let off = try #require(load("mouse-modifier = 'off'").config)
        #expect(off.mouseModifier == nil)
        #expect(load("mouse-modifier = 'option'").diagnostics == [
            "3:18: error: mouse-modifier: 'option' is not a modifier; use cmd, ctrl, alt or shift",
        ])
        #expect(load("mouse-modifier = 'alt-'").diagnostics == [
            "3:18: error: mouse-modifier: expected modifiers joined by '-', such as ctrl-alt",
        ])
        #expect(load("mouse-modifier = true").diagnostics == ["3:18: error: mouse-modifier: expected a string, found a boolean"])
    }

    @Test func unknownKeysSuggestTheNearestKey() {
        #expect(load("mouse-follow-focus = true\n[gaps]\ninnr = 1\n[[rules]]").diagnostics == [
            "3:1: error: mouse-follow-focus: unknown key; did you mean 'mouse-follows-focus'?",
            "5:1: error: gaps.innr: unknown key; did you mean 'inner'?",
            "6:3: error: rules: unknown key; did you mean 'rule'?",
        ])
        #expect(load("colour = 1").diagnostics == ["3:1: error: colour: unknown key"])
    }

    @Test func wrongTypesNameTheKeyPath() {
        #expect(load("mouse-follows-focus = 'yes'\n[gaps]\ninner = '10'\nouter = { top = true }").diagnostics == [
            "3:23: error: mouse-follows-focus: expected true or false, found a string",
            "5:9: error: gaps.inner: expected an integer, found a string",
            "6:17: error: gaps.outer.top: expected an integer, found a boolean",
        ])
        #expect(load("gaps = 10").diagnostics == ["3:8: error: gaps: expected a table, found an integer"])
    }

    @Test func gapsCannotBeNegative() {
        #expect(load("[gaps]\ninner = -1").diagnostics == ["4:9: error: gaps.inner: gaps cannot be negative"])
    }

    @Test func workspaceNames() {
        let diagnostics = Config.load("config-version = 1\nworkspaces = ['a b', '-x', 'next', 'w', 'w', '']").diagnostics
        #expect(diagnostics.map(\.description) == [
            "2:15: error: workspaces[0]: workspace names cannot contain whitespace",
            "2:22: error: workspaces[1]: workspace names cannot start with '-', which starts an option",
            "2:28: error: workspaces[2]: 'next' is a command keyword and cannot name a workspace",
            "2:41: error: workspaces[4]: workspace 'w' is listed twice",
            "2:46: error: workspaces[5]: the string is empty",
        ])
        #expect(Config.load("config-version = 1\nworkspaces = []").diagnostics.map(\.description) == [
            "2:14: error: workspaces: list at least one workspace",
        ])
    }

    @Test func monitorMatchers() {
        let body = """
        [monitors]
        both = { name = 'A', serial = 'B' }
        none = {}
        off = { built-in = false }
        typo = { nmae = 'A' }
        """
        #expect(load(body).diagnostics == [
            "4:8: error: monitors.both: give exactly one of name, serial or built-in",
            "5:8: error: monitors.none: give exactly one of name, serial or built-in",
            "6:20: error: monitors.off.built-in: built-in = false matches nothing; match the display by name or serial",
            "7:8: error: monitors.typo: give exactly one of name, serial or built-in",
            "7:10: error: monitors.typo.nmae: unknown key; did you mean 'name'?",
        ])
    }

    @Test func referencesMustBeDefined() {
        let body = """
        [monitors]
        main = { name = 'Studio' }
        [workspace-monitor]
        1 = 'mian'
        4 = 'main'
        [gaps]
        outer-per-monitor = { side = { top = 1 } }
        [[rule]]
        app-id = 'x'
        workspace = '9'
        """
        #expect(load(body).diagnostics == [
            "6:5: error: workspace-monitor.1: no monitor named 'mian' under [monitors]; did you mean 'main'?",
            "7:1: error: workspace-monitor.4: workspace '4' is not in workspaces",
            "9:23: error: gaps.outer-per-monitor.side: no monitor named 'side' under [monitors]",
            "12:13: error: rule[0].workspace: workspace '9' is not in workspaces",
        ])
    }

    @Test func bindings() throws {
        let body = """
        [mode.main.binding]
        alt-h = 'focus left'
        alt-shift-1 = 'move-node-to-workspace --focus-follows-window 1'
        alt-equal = "  resize\tsmart   +100 "
        alt-r = 'mode resize'
        [mode.resize.binding]
        esc = 'mode main'
        """
        let config = try #require(load(body).config)
        let main = try #require(config.modes["main"])
        #expect(main.map(\.key) == ["alt-h", "alt-shift-1", "alt-equal", "alt-r"])
        #expect(main[0].arguments == ["focus", "left"])
        #expect(main[1].arguments == ["move-node-to-workspace", "--focus-follows-window", "1"])
        // A string splits at any run of whitespace.
        #expect(main[2].arguments == ["resize", "smart", "+100"])
        #expect(try main[1].combo == KeyCombo("shift-alt-1"))
        #expect(config.modes["resize"]?.first?.combo.modifiers == [])
    }

    @Test func badBindings() {
        let body = """
        [mode.main.binding]
        alt-hh = 'fullscreen'
        opt-h = 'fullscreen'
        alt-shift-j = 'fullscreen'
        shift-alt-j = 'fullscreen'
        alt-k = ''
        alt-l = []
        alt-m = 3
        alt-n = '   '
        [mode.'two words'.binding]
        [mode.x]
        bindings = {}
        """
        #expect(load(body).diagnostics == [
            "4:1: error: mode.main.binding.alt-hh: 'hh' is not a key name; did you mean 'h'?",
            "5:1: error: mode.main.binding.opt-h: 'opt' is not a modifier; use cmd, ctrl, alt or shift; did you mean 'alt'?",
            "7:1: error: mode.main.binding.shift-alt-j: 'shift-alt-j' is the same combination as 'alt-shift-j' on line 6",
            "8:9: error: mode.main.binding.alt-k: the string is empty",
            "9:9: error: mode.main.binding.alt-l: expected a command as a string, found an array",
            "10:9: error: mode.main.binding.alt-m: expected a command as a string, found an integer",
            "11:9: error: mode.main.binding.alt-n: no command",
            "12:7: error: mode.\"two words\": mode names cannot be empty or contain whitespace",
            "14:1: error: mode.x.bindings: unknown key; did you mean 'binding'?",
        ])
    }

    @Test func invalidCommandsFailTheLoad() {
        let body = """
        [mode.main.binding]
        alt-h = 'focus left'
        alt-j = 'fcous down'
        alt-k = 'resize smart 100'
        """
        let result = load(body)
        #expect(result.config == nil)
        #expect(result.diagnostics == [
            "5:9: error: mode.main.binding.alt-j: unknown command or arguments: fcous down",
            "6:9: error: mode.main.binding.alt-k: resize: amount must be +N or -N points, up to 100000, got 100",
        ])
    }

    @Test func modeCommandsNameDefinedModes() {
        let body = """
        [mode.main.binding]
        alt-r = 'mode resize'
        alt-s = 'mode resise'
        [mode.resize.binding]
        esc = 'mode main'
        """
        #expect(load(body).diagnostics == ["5:9: error: mode.main.binding.alt-s: no mode named 'resise'; did you mean 'resize'?"])
        // Mode main exists even when the config gives it no bindings.
        #expect(load("[mode.resize.binding]\nesc = 'mode main'").diagnostics.isEmpty)
    }

    @Test func rulesNeedAMatcherAndAnAction() {
        let body = """
        [[rule]]
        float = true
        [[rule]]
        app-id = 'x'
        [[rule]]
        app-id = 'x'
        app-name = 'X'
        float = true
        workspace = '2'
        """
        #expect(load(body).diagnostics == [
            "3:3: error: rule[0]: a rule needs app-id or app-name",
            "5:3: error: rule[1]: a rule needs float or workspace",
        ])
    }

    @Test func shadowedRulesAreWarnings() throws {
        // AeroSpace's Ghostty floating rule never fired: a rule for the same bundle id came first.
        let body = """
        [[rule]]
        app-id = 'com.mitchellh.ghostty'
        workspace = '1'

        [[rule]]
        app-name = 'you'
        float = true

        [[rule]]
        app-id = 'com.mitchellh.ghostty'
        float = true

        [[rule]]
        app-name = 'YouTube'
        workspace = '2'

        [[rule]]
        app-id = 'com.google.youtube'
        workspace = '3'

        [[rule]]
        app-id = 'com.google.youtube'
        app-name = 'YouTube Music'
        workspace = '3'
        """
        let result = load(body)
        // A warning alone leaves the config usable.
        #expect(result.config?.rules.count == 6)
        #expect(result.diagnostics == [
            "11:3: warning: rule[2]: this rule never applies: rule[0] on line 3 matches every window it matches",
            "15:3: warning: rule[3]: this rule never applies: rule[1] on line 7 matches every window it matches",
            "23:3: warning: rule[5]: this rule never applies: rule[1] on line 7 matches every window it matches",
        ])
    }

    @Test func ruleMatching() {
        let rule = WindowRule(appID: "com.google.Chrome", appName: "chrome")
        #expect(rule.matches(appID: "com.google.Chrome", appName: "Google Chrome"))
        #expect(!rule.matches(appID: "com.google.Chrome", appName: "Brave Browser"))
        #expect(!rule.matches(appID: "com.google.chrome", appName: "Google Chrome"))
        #expect(!rule.matches(appID: nil, appName: "Google Chrome"))
        #expect(WindowRule(appName: "youtube").matches(appID: "com.apple.Safari.WebApp.1234", appName: "YouTube"))
    }

    @Test func diagnosticsAreInFileOrder() {
        // The loader checks [monitors] before workspaces, but reports in file order.
        let result = Config.load("config-version = 1\nworkspaces = [1]\n[monitors]\nx = {}")
        #expect(result.diagnostics.map(\.position.line) == [2, 4])
    }
}

@Suite struct ProfileTests {
    private static let text = """
    config-version = 1
    workspaces = ['1', '2', '3', '4']

    [monitors]
    builtin = { built-in = true }
    left = { serial = 'L' }
    main = { serial = 'M' }
    asus = { name = 'VG279QE5A' }

    [workspace-monitor]
    1 = 'main'
    2 = 'left'
    3 = ['builtin', 'main']

    [gaps]
    outer = { top = 35, left = 10, bottom = 10, right = 10 }
    outer-per-monitor = { builtin = { top = 5 } }

    [[rule]]
    app-id = 'spotify'
    workspace = '4'

    [[rule]]
    app-id = 'chrome'
    workspace = '3'

    [[profile]]
    name = 'home'
    when = ['left', 'main']

    [[profile]]
    name = 'single'
    when = ['asus']
    workspace-monitor = { 1 = 'asus', 2 = 'asus', 3 = ['builtin', 'asus'], 4 = 'asus' }

    [[profile]]
    name = 'laptop'
    workspaces = ['1', '2']
    workspace-monitor = { 1 = 'builtin', 2 = 'builtin' }
    merge-workspaces = { 3 = '1', 4 = '2' }

    [[profile.rule]]
    app-id = 'spotify'
    workspace = '2'
    """

    // Steve's desk: the left panel, the main panel at the origin, and the built-in display
    // below.
    private let builtIn = Display(id: 3, name: "Color LCD", isBuiltIn: true, frame: CGRect(x: 200, y: 1080, width: 1512, height: 982))
    private let left = Display(id: 1, name: "VG279QE5A (2)", serial: "L", frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080))
    private let main = Display(id: 2, name: "VG279QE5A (1)", serial: "M", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))

    private func config() throws -> Config {
        let result = Config.load(Self.text)
        #expect(result.diagnostics.isEmpty)
        return try #require(result.config)
    }

    @Test func firstProfileWhoseMonitorsAreConnectedApplies() throws {
        let config = try config()
        #expect(config.setup(for: [builtIn, left, main]).profile == "home")
        // With the lid closed at home the built-in display is gone, and home still applies.
        #expect(config.setup(for: [main, left]).profile == "home")
        // One panel: its name matches 'asus', and home needs both serials.
        #expect(config.setup(for: [builtIn, main]).profile == "single")
        // With no profile that applies yet, as at launch, a profile without `when` takes
        // every other set of displays.
        #expect(config.setup(for: [builtIn]).profile == "laptop")
        #expect(config.setup(for: [builtIn, Display(name: "Projector")]).profile == "laptop")
        // Once one applies, displays no `when` fits keep it.
        #expect(config.setup(for: [builtIn, Display(name: "Projector")], keeping: "home").profile == "home")
        // The built-in display alone gives the profile without `when`, whatever applied.
        #expect(config.setup(for: [builtIn], keeping: "home").profile == "laptop")
        // A profile the config no longer has gives way to the one without `when`.
        #expect(config.setup(for: [Display(name: "Projector")], keeping: "gone").profile == "laptop")
    }

    @Test func workspacesGoToTheFirstConnectedMonitorInTheirList() throws {
        let config = try config()
        #expect(config.setup(for: [builtIn, left, main]).workspaceDisplays == ["1": 2, "2": 1, "3": 3])
        // Lid closed: 3 falls back to the main panel, and 4 has no monitor, so it is free.
        #expect(config.setup(for: [left, main]).workspaceDisplays == ["1": 2, "2": 1, "3": 2])
        #expect(config.setup(for: [builtIn, main]).workspaceDisplays == ["1": 2, "2": 2, "3": 3, "4": 2])
    }

    @Test func aNameMatchingTwoDisplaysTakesTheLeftOne() throws {
        var config = try config()
        config.profiles.removeFirst()   // home
        let setup = config.setup(for: [main, builtIn, left])
        #expect(setup.profile == "single")
        #expect(setup.workspaceDisplays == ["1": 1, "2": 1, "3": 3, "4": 1])
    }

    @Test func aForcedProfileAppliesWhateverIsConnected() throws {
        let config = try config()
        #expect(config.setup(for: [builtIn], profile: "home").profile == "home")
        // Its monitors are not connected, so its workspaces are free.
        #expect(config.setup(for: [builtIn], profile: "home").workspaceDisplays == ["3": 3])
        #expect(config.setup(for: [builtIn, left, main], profile: "laptop").workspaces == ["1", "2"])
        // An unknown name leaves the choice to the displays.
        #expect(config.setup(for: [builtIn], profile: "nowhere").profile == "laptop")
    }

    @Test func monitorsCarryTheirGapsInDisplayOrder() throws {
        let setup = try config().setup(for: [builtIn, main, left])
        #expect(setup.monitors.map(\.id) == [1, 2, 3])
        #expect(setup.monitors.map(\.gaps.outer.top) == [35, 35, 5])
        #expect(setup.monitors[2].area == builtIn.frame)
    }

    @Test func profileReplacesWorkspacesAndPutsItsRulesFirst() throws {
        let setup = try config().setup(for: [builtIn])
        #expect(setup.workspaces == ["1", "2"])
        #expect(setup.workspaceDisplays == ["1": 3, "2": 3])
        #expect(setup.mergeWorkspaces == ["3": "1", "4": "2"])
        // The profile's Spotify rule wins, and the base Chrome rule's workspace 3 merges into 1.
        #expect(setup.rules.map(\.appID) == ["spotify", "spotify", "chrome"])
        #expect(setup.rules.first { $0.matches(appID: "spotify", appName: nil) }?.workspace == "2")
        #expect(setup.rules.first { $0.matches(appID: "chrome", appName: nil) }?.workspace == "1")
    }

    @Test func noMatchingProfileLeavesTheBaseConfig() throws {
        var config = try config()
        config.profiles.removeLast()
        let setup = config.setup(for: [builtIn])
        #expect(setup.profile == nil)
        #expect(setup.workspaces == ["1", "2", "3", "4"])
        #expect(setup.rules == config.rules)
    }

    @Test func outerGapsPerMonitor() throws {
        let config = try config()
        #expect(config.outerGaps(on: builtIn) == OuterGaps(top: 5, left: 10, bottom: 10, right: 10))
        #expect(config.outerGaps(on: main) == OuterGaps(top: 35, left: 10, bottom: 10, right: 10))
    }

    @Test func monitorNamesMatchIgnoringCase() {
        #expect(MonitorMatch.name("lg ultrawide").matches(Display(name: "LG ULTRAWIDE")))
        #expect(!MonitorMatch.serial("L").matches(Display(name: "VG279QE5A")))
    }

    @Test func profileErrors() {
        let body = """
        [monitors]
        a = { name = 'A' }
        [[profile]]
        when = ['b']
        [[profile]]
        name = 'p'
        workspaces = ['1']
        workspace-monitor = { 2 = 'a' }
        merge-workspaces = { 1 = '1', 3 = '9' }
        [[profile]]
        name = 'p'
        """
        #expect(load(body).diagnostics == [
            "5:3: error: profile[0]: missing key 'name'",
            "6:9: error: profile[0].when[0]: no monitor named 'b' under [monitors]",
            "10:23: error: profile[1].workspace-monitor.2: workspace '2' is not in this profile's workspaces",
            "11:22: error: profile[1].merge-workspaces.1: workspace '1' is in this profile's workspaces, so there is nothing to merge",
            "11:35: error: profile[1].merge-workspaces.3: workspace '9' is not in this profile's workspaces",
            "12:3: warning: profile[2]: this profile never applies: profile 'p' on line 7 comes first and matches whenever it does",
            "13:8: error: profile[2].name: profile 'p' is already defined at line 8",
        ])
    }

    @Test func aProfileWithoutWhenShadowsOnlyALaterOneWithout() {
        let body = """
        [monitors]
        a = { name = 'A' }
        b = { name = 'B' }
        [[profile]]
        name = 'laptop'
        [[profile]]
        name = 'a-and-b'
        when = ['a', 'b']
        [[profile]]
        name = 'a'
        when = ['a']
        [[profile]]
        name = 'b-and-a'
        when = ['b', 'a']
        [[profile]]
        name = 'fallback'
        """
        #expect(load(body).diagnostics == [
            "14:3: warning: profile[3]: this profile never applies: profile 'a-and-b' on line 8 comes first and matches whenever it does",
            "17:3: warning: profile[4]: this profile never applies: profile 'laptop' on line 6 comes first and matches whenever it does",
        ])
    }

    @Test func mergedWorkspacesMustBeWorkspaces() {
        let text = """
        config-version = 1
        workspaces = ['web', 'code', 'chat']
        [[profile]]
        name = 'small'
        workspaces = ['web']
        merge-workspaces = { code = 'web', caht = 'web', o = 'web' }
        """
        #expect(Config.load(text).diagnostics.map(\.description) == [
            "6:36: error: profile[0].merge-workspaces.caht: workspace 'caht' is not in workspaces; did you mean 'chat'?",
            "6:50: error: profile[0].merge-workspaces.o: workspace 'o' is not in workspaces",
        ])
    }

    @Test func baseRuleForAMissingWorkspaceIsAWarning() {
        let body = """
        [[rule]]
        app-id = 'spotify'
        workspace = '3'
        [[profile]]
        name = 'small'
        workspaces = ['1']
        """
        #expect(load(body).diagnostics == [
            "6:3: warning: profile[0]: rule[0] on line 3 sends windows to workspace '3', which this profile leaves out; "
                + "add '3' to merge-workspaces or give the profile a rule of its own",
        ])
    }
}
