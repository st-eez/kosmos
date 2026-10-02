import CoreGraphics

/// New windows whose app can still retitle them into a rule on the title, as Chrome titles
/// the Bitwarden extension's pop-out only after it shows (docs/config.md).
public struct TitleWatch: Sendable {
    /// Chrome's pop-out took its title within 0.6 s of showing, and Kosmos admits a window 0.1
    /// to 0.3 s after it shows. The log names each late rule with its delay, to tune this by
    /// (docs/config.md).
    public static let bound: Duration = .seconds(2)

    public struct Watch: Equatable, Sendable {
        public let admitted: ContinuousClock.Instant
        /// The rule that placed the window, nil for none.
        public let rule: WindowRule?
        /// Where its app showed it, where it floats when a rule on its title floats it later.
        public let frame: CGRect?
    }

    private var watches: [WindowID: Watch] = [:]

    public init() {}

    /// Whether a rule on the title names the app, so its new windows' titles are watched.
    public static func watches(_ rules: [WindowRule], appID: String?, appName: String?) -> Bool {
        rules.contains { $0.title != nil && $0.matchesApp(appID: appID, appName: appName) }
    }

    public mutating func admitted(_ window: WindowID, rule: WindowRule?, frame: CGRect?, at now: ContinuousClock.Instant) {
        watches[window] = Watch(admitted: now, rule: rule, frame: frame)
    }

    /// The user placed the window, it left, or the bound passed.
    public mutating func end(_ window: WindowID) {
        watches[window] = nil
    }

    /// A command that moves, resizes, floats or tiles a window places it: the focused one, or
    /// the one it names.
    public mutating func ran(_ command: Command, focused: WindowID?) {
        switch command {
        case .moveNodeToWorkspace(_, _, let window), .moveNodeToMonitor(_, _, _, let window):
            if let window = window ?? focused { end(window) }
        case .move, .swap, .joinWith, .layout, .fullscreen, .resize, .balanceSizes, .flattenWorkspaceTree:
            if let focused { end(focused) }
        case .workspace, .workspaceBackAndForth, .focus, .focusMonitor, .reloadConfig, .profile, .focusFollowsMouse:
            break
        }
    }

    /// `rule` is the first rule that matches the window under its new title. It applies, once,
    /// when it is a rule on the title other than the one that placed the window.
    public mutating func retitled(_ window: WindowID, rule: WindowRule?,
                                  at now: ContinuousClock.Instant) -> (rule: WindowRule, watch: Watch)? {
        guard let watch = watches[window] else { return nil }
        guard now - watch.admitted <= Self.bound else {
            end(window)
            return nil
        }
        guard let rule, rule.title != nil, rule != watch.rule else { return nil }
        end(window)
        return (rule, watch)
    }
}

extension Session {
    /// A window a rule on its title reaches after its admission floats or tiles as the rule
    /// says, and goes to the rule's workspace, as at its admission. Floated, it goes back to
    /// `frame`, where its app showed it. A window with the focus is followed to the workspace.
    /// Nil for a parked window, or when nothing changes (docs/config.md).
    public mutating func retitled(_ window: WindowID, floating: Bool, frame: CGRect?, to target: String?) -> Plan? {
        defer { check() }
        guard let source = home[window], !isParked(window) else { return nil }
        var plan: Plan?
        if floating != isFloating(window) {
            let monitor = monitor(of: source)
            if floating {
                workspaces[source]!.float(window)
            } else {
                workspaces[source]!.tile(window, in: monitor.area, gaps: monitor.gaps)
            }
            var changed = Plan(frames: frames(of: source))
            if floating, let frame { changed.frames[window] = frame }
            plan = changed
        }
        if let target, target != source, workspaces[target] != nil {
            let moved = move(window, from: source, to: target, follow: focused == window)
            var changed = plan ?? Plan()
            changed.frames.merge(moved.frames) { $1 }
            (changed.show, changed.hide, changed.focus) = (moved.show, moved.hide, moved.focus)
            plan = changed
        }
        return plan
    }
}
