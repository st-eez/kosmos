/// Whether the login session is locked or switched out (docs/inventory.md).
public struct LockState: Equatable, Sendable {
    public enum Signal: Equatable, Sendable {
        /// loginwindow's com.apple.screenIsLocked and com.apple.screenIsUnlocked.
        case screenLocked, screenUnlocked
        /// NSWorkspace's session resign and become active, for fast user switching.
        case switchedOut, switchedIn
        /// A read of the session dictionary, which replaces both.
        case read(screenLocked: Bool, onConsole: Bool)
    }

    public enum Change: Equatable, Sendable {
        case locked, unlocked
    }

    public private(set) var screenLocked = false
    public private(set) var switchedOut = false
    public var isLocked: Bool { screenLocked || switchedOut }

    public init() {}

    public mutating func apply(_ signal: Signal) -> Change? {
        let wasLocked = isLocked
        switch signal {
        case .screenLocked: screenLocked = true
        case .screenUnlocked: screenLocked = false
        case .switchedOut: switchedOut = true
        case .switchedIn: switchedOut = false
        case .read(let locked, let onConsole):
            screenLocked = locked
            switchedOut = !onConsole
        }
        guard isLocked != wasLocked else { return nil }
        return isLocked ? .locked : .unlocked
    }
}
