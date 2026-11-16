/// The user's own presses, as the input tap saw them, and what makes a key window change his
/// (docs/focus.md). His keys and clicks carry source pid 0, and input another process posts
/// carries that process's pid, Kosmos's own focus records included.
public struct OwnInput: Sendable {
    public enum Press: Equatable, Sendable {
        /// A key down or a modifier change. The Command-Tab switcher activates its app as
        /// Command comes up, and that change goes to the Dock.
        case key(target: Int32)
        case click(target: Int32)
        /// A key down of the user's that reached the session and no app: a hotkey took it, as
        /// a launcher's or one of Kosmos's.
        case hotkey
    }

    /// Where a press went, seen from the app whose change is judged.
    public enum Target: Sendable {
        /// The app, or a process inside its .app bundle, as Teams' notification service.
        case app
        /// A process that is not a regular app: the Dock's Command-Tab switcher, Raycast,
        /// Spotlight's Siri, Notification Center.
        case notRegular
        case otherApp
    }

    public enum Cause: Equatable, Sendable {
        /// A press that went to the app or a process in its bundle.
        case inApp(Press, ago: Duration)
        /// A press that opens other apps: a click anywhere, a key to a process that is not a
        /// regular app, or a hotkey. `ago` counts from the app's launch when `beforeLaunch`.
        case opener(Press, ago: Duration, beforeLaunch: Bool)
        /// The tap is missing or hears nothing, so every change counts as the user's, as
        /// before the tap.
        case unheard
    }

    /// A press into the app counts this long. No measurement chose it. Chrome keyed its first
    /// window 5.2 s after the launcher's hotkey (docs/focus-follows-mouse.md), and the log
    /// gives each follow's press and its age.
    public static let inAppBound: Duration = .seconds(10)
    /// Command-Tab, a Dock click or a launcher's key comes this close before the activation it
    /// makes, as the Command-Tab test of mouse-follows-focus takes it.
    public static let openerBound: Duration = .seconds(ActivationInput.maxAge)
    /// Long enough for a launch whose first window comes seconds after it.
    static let kept: Duration = .seconds(30)
    /// A probe's annotated tap heard each of 319 key downs of Steve's from 4.1 ms before to the
    /// same moment as its session tap, on one run loop, on 2026-11-16. Raycast activated
    /// Spotify about 100 ms after its key, so a hotkey's key is judged at the read, not at
    /// the activation's stamp (docs/focus.md).
    static let twinWait: Duration = .milliseconds(10)

    private var presses: [(at: ContinuousClock.Instant, press: Press)] = []
    /// The user's key downs by event time, which a key's copies at both taps share
    /// (docs/focus.md).
    private var keys: [UInt64: (at: ContinuousClock.Instant, reachedApp: Bool)] = [:]
    private var heard = false

    public init() {}

    /// A key down the annotated tap saw, which went to an app.
    public mutating func heardKey(from source: Int32, target: Int32, event: UInt64, at stamp: ContinuousClock.Instant) {
        heard = true
        guard source == 0 else { return }
        add(.key(target: target), at: stamp)
        note(event, at: stamp, reachedApp: true)
    }

    /// A key down the session tap saw, before macOS gives it to a hotkey or an app.
    public mutating func heardSessionKey(from source: Int32, event: UInt64, at stamp: ContinuousClock.Instant) {
        heard = true
        guard source == 0 else { return }
        note(event, at: stamp, reachedApp: false)
    }

    public mutating func heardClick(from source: Int32, target: Int32, at stamp: ContinuousClock.Instant) {
        heard = true
        guard source == 0 else { return }
        add(.click(target: target), at: stamp)
    }

    public mutating func heardModifiers(from source: Int32, target: Int32, at stamp: ContinuousClock.Instant) {
        heard = true
        guard source == 0 else { return }
        add(.key(target: target), at: stamp)
    }

    /// The user's last key down, a hotkey's included, for the Command-Tab test
    /// (docs/focus-follows-mouse.md).
    public var lastKey: ContinuousClock.Instant? { keys.values.map(\.at).max() }

    private mutating func add(_ press: Press, at stamp: ContinuousClock.Instant) {
        presses.removeAll { stamp - $0.at > Self.kept }
        presses.append((stamp, press))
    }

    private mutating func note(_ event: UInt64, at stamp: ContinuousClock.Instant, reachedApp: Bool) {
        keys = keys.filter { stamp - $0.value.at <= Self.kept }
        if keys[event] == nil { keys[event] = (stamp, reachedApp) } else if reachedApp { keys[event]?.reachedApp = true }
    }

    private func pressesWithHotkeys(by now: ContinuousClock.Instant) -> [(at: ContinuousClock.Instant, press: Press)] {
        let hotkeys = keys.values.filter { !$0.reachedApp && now - $0.at >= Self.twinWait }
        return (presses + hotkeys.map { ($0.at, Press.hotkey) }).sorted { $0.at < $1.at }
    }

    /// Why a change of an app's, stamped at `stamp`, is the user's, or nil when no press of his
    /// could have made it (docs/focus.md). `launched`: when the app launched, for a window that
    /// comes seconds after. `listening`: the tap is made with Input Monitoring granted. `now`:
    /// the read, by which a key that reached an app has reached the annotated tap.
    public func cause(at stamp: ContinuousClock.Instant, launched: ContinuousClock.Instant?, listening: Bool,
                      now: ContinuousClock.Instant, target: (Int32) -> Target) -> Cause? {
        guard listening, heard else { return .unheard }
        var targets: [Int32: Target] = [:]
        func place(_ pid: Int32) -> Target {
            if let known = targets[pid] { return known }
            let found = target(pid)
            targets[pid] = found
            return found
        }
        func opens(_ press: Press) -> Bool {
            switch press {
            case .click, .hotkey: true
            case .key(let pid): place(pid) == .notRegular
            }
        }
        let presses = pressesWithHotkeys(by: now)
        for (at, press) in presses.reversed() where at <= stamp && stamp - at <= Self.inAppBound {
            switch press {
            case .key(let pid), .click(let pid):
                if place(pid) == .app { return .inApp(press, ago: stamp - at) }
            case .hotkey:
                break
            }
            if stamp - at <= Self.openerBound, opens(press) { return .opener(press, ago: stamp - at, beforeLaunch: false) }
        }
        guard let launched, launched <= stamp,
              let made = presses.last(where: { $0.at <= launched && launched - $0.at <= Self.openerBound && opens($0.press) })
        else { return nil }
        return .opener(made.press, ago: launched - made.at, beforeLaunch: true)
    }
}
