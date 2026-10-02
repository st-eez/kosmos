/// The user's own presses, as the input tap saw them, and what makes a key window change his
/// (docs/focus.md). His keys and clicks carry source pid 0, and input another process posts
/// carries that process's pid, Kosmos's own focus records included.
public struct OwnInput: Sendable {
    public enum Press: Equatable, Sendable {
        /// A key down or a modifier change. The Command-Tab switcher activates its app as
        /// Command comes up, and that change goes to the Dock.
        case key(target: Int32)
        case click(target: Int32)
        /// A key down HID counted that the tap never saw: another app's hotkey, as a
        /// launcher's, or a key typed under Secure Input.
        case unseenKey
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
        /// regular app, or a key the tap never saw. `ago` counts from the app's launch when
        /// `beforeLaunch`.
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

    private var presses: [(at: ContinuousClock.Instant, press: Press)] = []
    /// HID's count of key downs when the tap last saw a key down or a modifier change.
    private var hidKeys: UInt32?
    private var heard = false

    public init() {}

    /// A key down the tap saw, from any process. HID counts a key down before the tap sees it
    /// (docs/modifier-drags.md), so a count past this one's says the tap missed others.
    public mutating func heardKey(from source: Int32, target: Int32, hidKeys count: UInt32, at stamp: ContinuousClock.Instant) {
        heard = true
        if let seen = hidKeys, count > seen &+ 1 { add(.unseenKey, at: stamp) }
        hidKeys = count
        if source == 0 { add(.key(target: target), at: stamp) }
    }

    public mutating func heardClick(from source: Int32, target: Int32, at stamp: ContinuousClock.Instant) {
        heard = true
        if source == 0 { add(.click(target: target), at: stamp) }
    }

    /// A modifier change the tap saw, from any process. A hotkey's modifiers come up after its
    /// key, so the key the tap missed is noted with its time while it is HID's last.
    public mutating func heardModifiers(from source: Int32, target: Int32, hidKeys count: UInt32,
                                        lastKeyAt: ContinuousClock.Instant, at stamp: ContinuousClock.Instant) {
        heard = true
        noteUnseenKeys(hidKeys: count, lastKeyAt: lastKeyAt)
        if source == 0 { add(.key(target: target), at: stamp) }
    }

    /// Notes a key down HID counted that the tap never saw, at HID's last key down.
    public mutating func noteUnseenKeys(hidKeys count: UInt32, lastKeyAt: ContinuousClock.Instant) {
        if let seen = hidKeys, count != seen { add(.unseenKey, at: lastKeyAt) }
        hidKeys = count
    }

    private mutating func add(_ press: Press, at stamp: ContinuousClock.Instant) {
        presses.removeAll { stamp - $0.at > Self.kept }
        presses.append((stamp, press))
    }

    /// Why a change of an app's, stamped at `stamp`, is the user's, or nil when no press of his
    /// could have made it (docs/focus.md). `launched`: when the app launched, for a window that
    /// comes seconds after. `listening`: the tap is made with Input Monitoring granted.
    public func cause(at stamp: ContinuousClock.Instant, launched: ContinuousClock.Instant?, listening: Bool,
                      target: (Int32) -> Target) -> Cause? {
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
            case .click, .unseenKey: true
            case .key(let pid): place(pid) == .notRegular
            }
        }
        for (at, press) in presses.reversed() where at <= stamp && stamp - at <= Self.inAppBound {
            switch press {
            case .key(let pid), .click(let pid):
                if place(pid) == .app { return .inApp(press, ago: stamp - at) }
            case .unseenKey:
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
