/// What admitting a window does with the focus (DESIGN.md, sections 5.4 and 5.13). A window
/// its app keyed before Kosmos gave it a place, as a launching app keys its first window,
/// becomes the focus of a shown workspace. Kosmos follows it to a hidden one a rule named,
/// as Hyprland does for a `workspace` window rule without `silent`, only when the user asked
/// for it (UserLaunches): agents launch apps and open windows on the same Mac, and an app
/// they front keys its window too.
public enum AdmissionFocus: Equatable, Sendable {
    case none
    /// The window was key before it had a place, on a shown workspace: it becomes the focus
    /// there.
    case adopt
    /// The user asked for the window, key before it had a place on a hidden workspace: its
    /// report is decided as one of a concealed window whose key window before it stayed,
    /// which Kosmos follows as it follows a Command-Tab.
    case follow

    /// - Parameters:
    ///   - keyed: the window is the key window Kosmos last heard of, which only the front
    ///     app reports: its app keyed it before Kosmos gave it a place.
    ///   - asked: the user asked for it (UserLaunches.asked).
    ///   - shown: its place is on a workspace a display shows.
    ///   - parked: it waits parked, as a window minimized, hidden with its app or in native
    ///     fullscreen when Kosmos admits it, and its return decides the focus.
    ///   - atLaunch: it was there when Kosmos launched. Its report is Kosmos's own read of
    ///     the key window, and a follow during the launch sweep would change the workspace a
    ///     display shows while the sweep still places windows by the display under them.
    ///   - locked: the session is locked, and Kosmos ignores focus reports.
    public static func decide(keyed: Bool, asked: Bool, shown: Bool, parked: Bool, atLaunch: Bool,
                              locked: Bool) -> AdmissionFocus {
        guard keyed, !locked, !parked else { return .none }
        if shown { return .adopt }
        return asked && !atLaunch ? .follow : .none
    }
}

/// Launches the user asked for, until the app's first key window is admitted or the deadline
/// passes (DESIGN.md, section 5.13). The user asked for a launch when a key press or a Dock
/// click came just before it began, by the test that brings the pointer to an activated app
/// (ActivationInput.bringsPointer). A cold launch can take seconds from the launcher's hotkey
/// to the first window, so the input is judged as the launch begins.
public struct UserLaunches: Sendable {
    /// How long after its launch began an app's first key window still counts as asked for.
    /// On 2026-09-25 Raycast asked LaunchServices to launch Chrome at 10:25:26.338, Chrome
    /// checked in 4.1 s after launchd spawned it, and Kosmos admitted its first window at
    /// 10:25:31.865, 5.5 s after the request.
    public static let deadline: Duration = .seconds(10)
    /// Each launch heard of within the deadline, by app: when it began, and whether it still
    /// counts as asked for.
    private var launches: [Int32: (began: ContinuousClock.Instant, asked: Bool)] = [:]

    public init() {}

    /// Kosmos heard `now` that `app` is launching, from NSWorkspace's will-launch or
    /// did-launch notification. The launch began `age` seconds before, as its launch date
    /// says. The first word of a launch judges it, by `input`, read now and taken back to
    /// when the launch began, and `onDock`, whether the last left mouse down landed on the
    /// Dock. Input since then hides what came before, and a launch it hides was not asked
    /// for. Returns whether the user asked for it, or nil for a launch judged already.
    public mutating func launching(_ app: Int32, input: ActivationInput, onDock: Bool, age: Double,
                                   at now: ContinuousClock.Instant) -> Bool? {
        forgetExpired(at: now)
        guard launches[app] == nil else { return nil }
        let age = max(age, 0)
        let asked = input.asOf(secondsAgo: age)?.bringsPointer(onDock: onDock) ?? false
        launches[app] = (now - .seconds(age), asked)
        return asked
    }

    /// Whether the user asked for a window of `app`, admitted `now` as its app's key window:
    /// the first such window of a launch the user asked for, within the deadline, or one
    /// keyed just after a key press in the app itself, as Command-N opens one, by the same
    /// test on `input` read now. `keyBefore` is the app of the key window before it. An app
    /// an agent fronts to open a window was not the app the user typed in.
    public mutating func asked(forKeyOf app: Int32, keyBefore: Int32?, input: ActivationInput, onDock: Bool,
                               at now: ContinuousClock.Instant) -> Bool {
        forgetExpired(at: now)
        if let launch = launches[app] {
            // Kept till the deadline, so a later word of the launch is not judged again.
            launches[app] = (launch.began, false)
            if launch.asked { return true }
        }
        return keyBefore == app && input.bringsPointer(onDock: onDock)
    }

    private mutating func forgetExpired(at now: ContinuousClock.Instant) {
        launches = launches.filter { now - $0.value.began <= Self.deadline }
    }
}
