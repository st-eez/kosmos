import AppKit
import KosmosCore
import os

private let lockLog = Logger(subsystem: "io.github.st-eez.kosmos", category: "lock")

/// Follows the screen lock, fast user switching and wake (DESIGN.md, section 5.1).
/// loginwindow posts com.apple.screenIsLocked and com.apple.screenIsUnlocked; the macOS 27
/// (26A428) loginwindow binary still names both, and alt-tab and rift listen for them.
/// NSWorkspace reports session switches. The session dictionary gives the state at launch,
/// as alt-tab seeds it, and is read every 5 s while locked, so a missed unlock cannot stop
/// Kosmos for good.
@MainActor
final class LockWatch: NSObject {
    private var state = LockState()
    private var check: Timer?

    /// Called with true when the session locks, and with false when it unlocks or the Mac or
    /// its displays wake while it is unlocked.
    var onChange: (@MainActor (_ locked: Bool) -> Void)?
    var isLocked: Bool { state.isLocked }

    func start() {
        apply(Self.read())
        // AppKit holds distributed notifications for an app that is not active unless they
        // are delivered immediately. Kosmos is active only while onboarding shows.
        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(self, selector: #selector(screenLocked), name: Notification.Name("com.apple.screenIsLocked"),
                                object: nil, suspensionBehavior: .deliverImmediately)
        distributed.addObserver(self, selector: #selector(screenUnlocked), name: Notification.Name("com.apple.screenIsUnlocked"),
                                object: nil, suspensionBehavior: .deliverImmediately)
        let workspace = NSWorkspace.shared.notificationCenter
        let sessionSignals: [(Notification.Name, LockState.Signal)] = [(NSWorkspace.sessionDidResignActiveNotification, .switchedOut),
                                                                       (NSWorkspace.sessionDidBecomeActiveNotification, .switchedIn)]
        for (name, signal) in sessionSignals {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.apply(signal) }
            }
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.woke(name) }
            }
        }
    }

    @objc private func screenLocked() { apply(.screenLocked) }
    @objc private func screenUnlocked() { apply(.screenUnlocked) }

    private func apply(_ signal: LockState.Signal) {
        switch state.apply(signal) {
        case .locked?:
            lockLog.notice("session locked (\(String(describing: signal), privacy: .public)); windows wait")
            check = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.apply(Self.read()) }
            }
            onChange?(true)
        case .unlocked?:
            lockLog.notice("session unlocked (\(String(describing: signal), privacy: .public))")
            check?.invalidate()
            check = nil
            onChange?(false)
        case nil:
            break
        }
    }

    /// A wake while locked waits for the unlock.
    private func woke(_ name: Notification.Name) {
        guard !state.isLocked else { return }
        lockLog.notice("\(name.rawValue, privacy: .public)")
        onChange?(false)
    }

    /// Whether the screen is locked and whether this session has the console. Unlocked, the
    /// dictionary on this Mac has no lock key at all.
    private static func read() -> LockState.Signal {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any] ?? [:]
        return .read(screenLocked: session["CGSSessionScreenIsLocked"] as? Bool ?? false,
                     onConsole: session["kCGSSessionOnConsoleKey"] as? Bool ?? true)
    }
}
