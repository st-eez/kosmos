extension Config {
    /// Parses and checks a whole config file. `config` is nil when any diagnostic is an error,
    /// so a caller applies all of a file or none of it; warnings can come with a config.
    /// Diagnostics are in file order. Binding commands go through `Command.parse`, so a bad
    /// command fails the load instead of the key press.
    public static func load(_ text: String) -> (config: Config?, diagnostics: [Diagnostic]) {
        let root: TOMLTable
        do {
            root = try parseTOML(text)
        } catch {
            return (nil, [error])
        }
        var decoder = ConfigDecoder()
        let config = decoder.config(root)
        // The sort is stable, so problems at one position keep the order they were found in.
        let diagnostics = decoder.diagnostics.sorted { $0.position < $1.position }
        return (diagnostics.contains { $0.severity == .error } ? nil : config, diagnostics)
    }
}

/// Checks the TOML tree against the schema. It reports every problem it finds and returns a
/// config that is complete only when it reported no error.
private struct ConfigDecoder {
    typealias Located = (value: String, position: SourcePosition, path: ValuePath)

    var diagnostics: [Diagnostic] = []
    /// Every name declared under [monitors], including ones whose matcher is invalid, so one
    /// mistake is reported once.
    private var monitorNames: [String] = []

    mutating func config(_ root: TOMLTable) -> Config {
        let path = ValuePath()
        let start = SourcePosition(line: 1, column: 1)
        _ = table(TOMLValue(kind: .table(root), position: start), path, allowed: [
            "config-version", "mouse-follows-focus", "focus-follows-mouse", "focus-follows-mouse-ignore-apps",
            "workspaces", "monitors", "workspace-monitor", "gaps", "mode", "rule", "profile",
        ])
        var config = Config()

        if let entry = root["config-version"] {
            if let version = integer(entry.value, path.key(entry.key)), version != 1 {
                fail("this version of Kosmos reads config-version 1", at: entry.value.position, path.key(entry.key))
            }
        } else {
            fail("missing key 'config-version'; set it to 1", at: start, path)
        }
        if let entry = root["mouse-follows-focus"] {
            config.mouseFollowsFocus = boolean(entry.value, path.key(entry.key)) ?? false
        }
        if let entry = root["focus-follows-mouse"] {
            config.focusFollowsMouse.enabled = boolean(entry.value, path.key(entry.key)) ?? false
        }
        if let entry = root["focus-follows-mouse-ignore-apps"], let items = array(entry.value, path.key(entry.key)) {
            for (index, item) in items.enumerated() {
                if let app = string(item, path.key(entry.key).index(index)) { config.focusFollowsMouse.ignoreApps.append(app) }
            }
        }
        if let entry = root["monitors"] {
            config.monitors = monitors(entry.value, path.key(entry.key))
        }
        if let entry = root["workspaces"] {
            config.workspaces = workspaceList(entry.value, path.key(entry.key)) ?? []
        } else {
            fail("missing key 'workspaces'", at: start, path)
        }
        if let entry = root["workspace-monitor"] {
            config.workspaceMonitors = workspaceMonitors(entry.value, path.key(entry.key),
                                                         workspaces: config.workspaces, scope: "workspaces")
        }
        if let entry = root["gaps"] {
            config.gaps = gaps(entry.value, path.key(entry.key))
        }
        if let entry = root["mode"] {
            config.modes = modes(entry.value, path.key(entry.key))
        }
        var rules: [(rule: WindowRule, position: SourcePosition, path: ValuePath)] = []
        if let entry = root["rule"] {
            rules = self.rules(entry.value, path.key(entry.key), workspaces: config.workspaces, scope: "workspaces")
            config.rules = rules.map(\.rule)
        }
        if let entry = root["profile"] {
            config.profiles = profiles(entry.value, path.key(entry.key), base: config, baseRules: rules)
        }
        return config
    }

    // MARK: Sections

    private mutating func monitors(_ value: TOMLValue, _ path: ValuePath) -> [String: MonitorMatch] {
        guard let table = table(value, path) else { return [:] }
        let fields = ["name", "serial", "built-in"]
        var monitors: [String: MonitorMatch] = [:]
        for entry in table.entries {
            monitorNames.append(entry.key)
            let monitorPath = path.key(entry.key)
            guard let matcher = self.table(entry.value, monitorPath, allowed: fields) else { continue }
            let given = matcher.entries.filter { fields.contains($0.key) }
            guard given.count == 1, let field = given.first else {
                fail("give exactly one of name, serial or built-in", at: entry.value.position, monitorPath)
                continue
            }
            let fieldPath = monitorPath.key(field.key)
            switch field.key {
            case "name":
                monitors[entry.key] = string(field.value, fieldPath).map(MonitorMatch.name)
            case "serial":
                monitors[entry.key] = string(field.value, fieldPath).map(MonitorMatch.serial)
            default:
                guard let builtIn = boolean(field.value, fieldPath) else { continue }
                if builtIn {
                    monitors[entry.key] = .builtIn
                } else {
                    fail("built-in = false matches nothing; match the display by name or serial", at: field.value.position, fieldPath)
                }
            }
        }
        return monitors
    }

    private mutating func workspaceList(_ value: TOMLValue, _ path: ValuePath) -> [String]? {
        guard let items = array(value, path) else { return nil }
        if items.isEmpty { fail("list at least one workspace", at: value.position, path) }
        var names: [String] = []
        for (index, item) in items.enumerated() {
            let itemPath = path.index(index)
            guard let name = string(item, itemPath) else { continue }
            if let problem = workspaceNameProblem(name) {
                fail(problem, at: item.position, itemPath)
            } else if names.contains(name) {
                fail("workspace '\(name)' is listed twice", at: item.position, itemPath)
            }
            names.append(name)
        }
        return names
    }

    private func workspaceNameProblem(_ name: String) -> String? {
        if name.unicodeScalars.contains(where: \.properties.isWhitespace) {
            return "workspace names cannot contain whitespace"
        }
        if name.hasPrefix("-") {
            return "workspace names cannot start with '-', which starts an option"
        }
        guard case .success(.workspace(.named)) = Command.parse(["workspace", name]) else {
            return "'\(name)' is a command keyword and cannot name a workspace"
        }
        return nil
    }

    /// `scope` names the workspace list the keys must come from, for messages.
    private mutating func workspaceMonitors(_ value: TOMLValue, _ path: ValuePath,
                                            workspaces: [String], scope: String) -> [String: [String]] {
        guard let table = table(value, path) else { return [:] }
        var assignment: [String: [String]] = [:]
        for entry in table.entries {
            let entryPath = path.key(entry.key)
            checkWorkspace((entry.key, entry.keyPosition, entryPath), in: workspaces, scope: scope)
            guard let names = stringOrList(entry.value, entryPath) else { continue }
            for name in names { checkMonitor(name) }
            assignment[entry.key] = names.map(\.value)
        }
        return assignment
    }

    private mutating func gaps(_ value: TOMLValue, _ path: ValuePath) -> GapSettings {
        var gaps = GapSettings()
        guard let table = table(value, path, allowed: ["inner", "outer", "outer-per-monitor"]) else { return gaps }
        if let entry = table["inner"] {
            gaps.inner = gap(entry.value, path.key(entry.key)) ?? 0
        }
        if let entry = table["outer"], let sides = sides(entry.value, path.key(entry.key)) {
            gaps.outer = OuterGaps(top: sides.top ?? 0, left: sides.left ?? 0, bottom: sides.bottom ?? 0, right: sides.right ?? 0)
        }
        if let entry = table["outer-per-monitor"], let perMonitor = self.table(entry.value, path.key(entry.key)) {
            for monitor in perMonitor.entries {
                let monitorPath = path.key(entry.key).key(monitor.key)
                checkMonitor((monitor.key, monitor.keyPosition, monitorPath))
                guard let sides = sides(monitor.value, monitorPath) else { continue }
                gaps.outerPerMonitor.append(MonitorOuterGaps(monitor: monitor.key, top: sides.top, left: sides.left,
                                                             bottom: sides.bottom, right: sides.right))
            }
        }
        return gaps
    }

    private mutating func sides(_ value: TOMLValue, _ path: ValuePath) -> (top: Int?, left: Int?, bottom: Int?, right: Int?)? {
        guard let table = table(value, path, allowed: ["top", "left", "bottom", "right"]) else { return nil }
        func side(_ name: String) -> Int? {
            table[name].flatMap { gap($0.value, path.key(name)) }
        }
        return (side("top"), side("left"), side("bottom"), side("right"))
    }

    private mutating func gap(_ value: TOMLValue, _ path: ValuePath) -> Int? {
        guard let points = integer(value, path) else { return nil }
        guard points >= 0 else {
            fail("gaps cannot be negative", at: value.position, path)
            return nil
        }
        return points
    }

    private mutating func modes(_ value: TOMLValue, _ path: ValuePath) -> [String: [Binding]] {
        guard let table = table(value, path) else { return [:] }
        var modes: [String: [Binding]] = [:]
        // Modes that `mode` commands name, checked once every mode is known.
        var targets: [Located] = []
        for mode in table.entries {
            let modePath = path.key(mode.key)
            if mode.key.isEmpty || mode.key.unicodeScalars.contains(where: \.properties.isWhitespace) {
                fail("mode names cannot be empty or contain whitespace", at: mode.keyPosition, modePath)
            }
            var bindings: [Binding] = []
            let bindingsPath = modePath.key("binding")
            if let fields = self.table(mode.value, modePath, allowed: ["binding"]),
               let entry = fields["binding"], let table = self.table(entry.value, bindingsPath) {
                var seen: [KeyCombo: TOMLTable.Entry] = [:]
                for binding in table.entries {
                    let bindingPath = bindingsPath.key(binding.key)
                    let combo: KeyCombo
                    do {
                        combo = try KeyCombo(binding.key)
                    } catch {
                        fail(error.message, at: binding.keyPosition, bindingPath)
                        continue
                    }
                    if let first = seen[combo] {
                        fail("'\(binding.key)' is the same combination as '\(first.key)' on line \(first.keyPosition.line)",
                             at: binding.keyPosition, bindingPath)
                        continue
                    }
                    seen[combo] = binding
                    guard let parsed = command(binding.value, bindingPath) else { continue }
                    if case .mode(let target) = parsed.command {
                        targets.append((target, binding.value.position, bindingPath))
                    }
                    bindings.append(Binding(key: binding.key, combo: combo, arguments: parsed.arguments))
                }
            }
            modes[mode.key] = bindings
        }
        // Mode main always exists, with no bindings when the config gives it none.
        for target in targets where target.value != "main" && modes[target.value] == nil {
            fail("no mode named '\(target.value)'" + suggestion(for: target.value, from: modes.keys),
                 at: target.position, target.path)
        }
        return modes
    }

    /// A command and its arguments, after `Command.parse` accepts them. The string splits at
    /// whitespace with no quoting; no command takes an argument that contains a space.
    private mutating func command(_ value: TOMLValue, _ path: ValuePath) -> (arguments: [String], command: Command)? {
        guard case .string = value.kind else {
            fail("expected a command as a string, found \(kindName(value))", at: value.position, path)
            return nil
        }
        guard let line = string(value, path) else { return nil }
        let arguments = line.split(whereSeparator: \.isWhitespace).map(String.init)
        switch Command.parse(arguments) {
        case .success(let command):
            return (arguments, command)
        case .failure(let error):
            fail(error.message, at: value.position, path)
            return nil
        }
    }

    /// Rules in file order, with a warning for each rule an earlier one shadows.
    private mutating func rules(_ value: TOMLValue, _ path: ValuePath, workspaces: [String], scope: String)
        -> [(rule: WindowRule, position: SourcePosition, path: ValuePath)]
    {
        guard let items = array(value, path) else { return [] }
        var rules: [(rule: WindowRule, position: SourcePosition, path: ValuePath)] = []
        for (index, item) in items.enumerated() {
            let rulePath = path.index(index)
            guard let fields = table(item, rulePath, allowed: ["app-id", "app-name", "float", "workspace"]) else { continue }
            var rule = WindowRule()
            if let entry = fields["app-id"] { rule.appID = string(entry.value, rulePath.key(entry.key)) }
            if let entry = fields["app-name"] { rule.appName = string(entry.value, rulePath.key(entry.key)) }
            if let entry = fields["float"] { rule.float = boolean(entry.value, rulePath.key(entry.key)) }
            if let entry = fields["workspace"], let name = string(entry.value, rulePath.key(entry.key)) {
                rule.workspace = name
                checkWorkspace((name, entry.value.position, rulePath.key(entry.key)), in: workspaces, scope: scope)
            }
            guard fields["app-id"] != nil || fields["app-name"] != nil else {
                fail("a rule needs app-id or app-name", at: item.position, rulePath)
                continue
            }
            guard fields["float"] != nil || fields["workspace"] != nil else {
                fail("a rule needs float or workspace", at: item.position, rulePath)
                continue
            }
            rules.append((rule, item.position, rulePath))
        }
        for (index, later) in rules.enumerated() {
            if let earlier = rules[..<index].first(where: { $0.rule.covers(later.rule) }) {
                warn("this rule never applies: \(earlier.path) on line \(earlier.position.line) matches every window it matches",
                     at: later.position, later.path)
            }
        }
        return rules
    }

    private mutating func profiles(_ value: TOMLValue, _ path: ValuePath, base: Config,
                                   baseRules: [(rule: WindowRule, position: SourcePosition, path: ValuePath)]) -> [Profile] {
        guard let items = array(value, path) else { return [] }
        var profiles: [(profile: Profile, position: SourcePosition, path: ValuePath)] = []
        var nameLines: [String: Int] = [:]
        for (index, item) in items.enumerated() {
            let profilePath = path.index(index)
            guard let fields = table(item, profilePath, allowed: [
                "name", "when", "workspaces", "workspace-monitor", "merge-workspaces", "rule",
            ]) else { continue }
            var profile = Profile(name: "")

            if let entry = fields["name"] {
                let namePath = profilePath.key(entry.key)
                if let name = string(entry.value, namePath) {
                    if let line = nameLines[name] {
                        fail("profile '\(name)' is already defined at line \(line)", at: entry.value.position, namePath)
                    }
                    nameLines[name] = entry.value.position.line
                    profile.name = name
                }
            } else {
                fail("missing key 'name'", at: item.position, profilePath)
            }
            if let entry = fields["when"], let monitors = array(entry.value, profilePath.key(entry.key)) {
                for (index, monitor) in monitors.enumerated() {
                    let monitorPath = profilePath.key(entry.key).index(index)
                    guard let name = string(monitor, monitorPath) else { continue }
                    checkMonitor((name, monitor.position, monitorPath))
                    profile.when.append(name)
                }
            }
            if let entry = fields["workspaces"] {
                profile.workspaces = workspaceList(entry.value, profilePath.key(entry.key))
            }
            let workspaces = profile.workspaces ?? base.workspaces
            let scope = profile.workspaces == nil ? "workspaces" : "this profile's workspaces"
            if let entry = fields["workspace-monitor"] {
                profile.workspaceMonitors = workspaceMonitors(entry.value, profilePath.key(entry.key),
                                                              workspaces: workspaces, scope: scope)
            }
            if let entry = fields["merge-workspaces"], let merges = table(entry.value, profilePath.key(entry.key)) {
                for merge in merges.entries {
                    let mergePath = profilePath.key(entry.key).key(merge.key)
                    if workspaces.contains(merge.key) {
                        fail("workspace '\(merge.key)' is in \(scope), so there is nothing to merge", at: merge.keyPosition, mergePath)
                    } else {
                        checkWorkspace((merge.key, merge.keyPosition, mergePath), in: base.workspaces, scope: "workspaces")
                    }
                    guard let target = string(merge.value, mergePath) else { continue }
                    checkWorkspace((target, merge.value.position, mergePath), in: workspaces, scope: scope)
                    profile.mergeWorkspaces[merge.key] = target
                }
            }
            if let entry = fields["rule"] {
                profile.rules = rules(entry.value, profilePath.key(entry.key), workspaces: workspaces, scope: scope).map(\.rule)
            }
            for base in baseRules {
                guard let target = base.rule.workspace, !workspaces.contains(target), profile.mergeWorkspaces[target] == nil,
                      !profile.rules.contains(where: { $0.covers(base.rule) })
                else { continue }
                warn("\(base.path) on line \(base.position.line) sends windows to workspace '\(target)', which this profile "
                     + "leaves out; add '\(target)' to merge-workspaces or give the profile a rule of its own",
                     at: item.position, profilePath)
            }
            profiles.append((profile, item.position, profilePath))
        }
        for (index, later) in profiles.enumerated() {
            if let earlier = profiles[..<index].first(where: { Set($0.profile.when).isSubset(of: later.profile.when) }) {
                warn("this profile never applies: profile '\(earlier.profile.name)' on line \(earlier.position.line) "
                     + "comes first and matches whenever it does", at: later.position, later.path)
            }
        }
        return profiles.map(\.profile)
    }

    // MARK: Values

    private mutating func fail(_ message: String, at position: SourcePosition, _ path: ValuePath) {
        diagnostics.append(Diagnostic(.error, at: position, path: path.description, message))
    }

    private mutating func warn(_ message: String, at position: SourcePosition, _ path: ValuePath) {
        diagnostics.append(Diagnostic(.warning, at: position, path: path.description, message))
    }

    /// `scope` names the workspace list `name` must be in, for the message.
    private mutating func checkWorkspace(_ name: Located, in workspaces: [String], scope: String) {
        if !workspaces.contains(name.value) {
            fail("workspace '\(name.value)' is not in \(scope)" + suggestion(for: name.value, from: workspaces),
                 at: name.position, name.path)
        }
    }

    private mutating func checkMonitor(_ name: Located) {
        if !monitorNames.contains(name.value) {
            fail("no monitor named '\(name.value)' under [monitors]" + suggestion(for: name.value, from: monitorNames),
                 at: name.position, name.path)
        }
    }

    /// A table, after reporting each key outside `allowed`. Tables keyed by names the user
    /// chooses, such as [monitors], pass no `allowed` list.
    private mutating func table(_ value: TOMLValue, _ path: ValuePath, allowed: [String]? = nil) -> TOMLTable? {
        guard case .table(let table) = value.kind else {
            fail("expected a table, found \(kindName(value))", at: value.position, path)
            return nil
        }
        if let allowed {
            for entry in table.entries where !allowed.contains(entry.key) {
                fail("unknown key" + suggestion(for: entry.key, from: allowed), at: entry.keyPosition, path.key(entry.key))
            }
        }
        return table
    }

    private mutating func array(_ value: TOMLValue, _ path: ValuePath) -> [TOMLValue]? {
        guard case .array(let items) = value.kind else {
            fail("expected an array, found \(kindName(value))", at: value.position, path)
            return nil
        }
        return items
    }

    /// A non-empty string. No key accepts an empty one.
    private mutating func string(_ value: TOMLValue, _ path: ValuePath) -> String? {
        guard case .string(let string) = value.kind else {
            fail("expected a string, found \(kindName(value))", at: value.position, path)
            return nil
        }
        guard !string.isEmpty else {
            fail("the string is empty", at: value.position, path)
            return nil
        }
        return string
    }

    private mutating func integer(_ value: TOMLValue, _ path: ValuePath) -> Int? {
        guard case .integer(let integer) = value.kind else {
            fail("expected an integer, found \(kindName(value))", at: value.position, path)
            return nil
        }
        return integer
    }

    private mutating func boolean(_ value: TOMLValue, _ path: ValuePath) -> Bool? {
        guard case .boolean(let boolean) = value.kind else {
            fail("expected true or false, found \(kindName(value))", at: value.position, path)
            return nil
        }
        return boolean
    }

    /// One string, or a non-empty array of them.
    private mutating func stringOrList(_ value: TOMLValue, _ path: ValuePath) -> [Located]? {
        switch value.kind {
        case .string:
            return string(value, path).map { [($0, value.position, path)] }
        case .array(let items):
            guard !items.isEmpty else {
                fail("the list is empty", at: value.position, path)
                return nil
            }
            var strings: [Located] = []
            for (index, item) in items.enumerated() {
                if let string = string(item, path.index(index)) { strings.append((string, item.position, path.index(index))) }
            }
            return strings.count == items.count ? strings : nil
        default:
            fail("expected a string or an array of strings, found \(kindName(value))", at: value.position, path)
            return nil
        }
    }
}

private func kindName(_ value: TOMLValue) -> String {
    switch value.kind {
    case .string: "a string"
    case .integer: "an integer"
    case .boolean: "a boolean"
    case .array: "an array"
    case .table: "a table"
    }
}
