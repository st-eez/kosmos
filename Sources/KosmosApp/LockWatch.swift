import AppKit
import KosmosCore
import os

private let lockLog = Logger(subsystem: "io.github.st-eez.kosmos", category: "lock")

/// Follows the screen lock, fast user switching and wake (docs/inventory.md).
/// loginwindow posts com.apple.screenIsLocked and com.apple.screenIsUnlocked; the macOS 27
/// (26A428) loginwindow binary still names both, and alt-tab and rift listen for them.
/// NSWorkspace reports session switches. The session dictionary gives the state at launch,
/// as alt-tab seeds it, and is read every 5 s while locked, so a missed unlock cannot stop
/// Kosmos for good.
@MainActor
final class LockWatch: NSObject {
    private var state = LockState()
    private var check: Timer?
    /// The resync after a wake, held until the wake's other notifications are in.
    private var wakeResync: DispatchWorkItem?

    /// Called with true when the session locks, and with false when it unlocks or the Mac or
    /// its displays wake while it is unlocked.
    var onChange: (@MainActor (_ locked: Bool) -> Void)?

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
            wakeResync?.cancel()   // the unlock resyncs
            wakeResync = nil
            onChange?(false)
        case nil:
            break
        }
    }

    /// A wake can post both didWake and screensDidWake. Each one restarts a 0.5 s wait, so a
    /// burst gets one resync. The wait is a guess; the log gives the gap between the two. A
    /// wake while locked waits for the unlock.
    private func woke(_ name: Notification.Name) {
        lockLog.notice("\(name.rawValue, privacy: .public)")
        wakeResync?.cancel()
        let resync = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.wakeResync = nil
                if !self.state.isLocked { self.onChange?(false) }
            }
        }
        wakeResync = resync
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: resync)
    }

    /// Whether the screen is locked and whether this session has the console. Unlocked, the
    /// dictionary on this Mac has no lock key at all, and a missing key reads as unlocked.
    /// Whether the key is there while locked is open (docs/inventory.md): each read logs
    /// the lock and console keys, so a lock test settles it.
    private static func read() -> LockState.Signal {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any] ?? [:]
        let keys = session.filter { $0.key.localizedCaseInsensitiveContains("lock") || $0.key == "kCGSSessionOnConsoleKey" }
            .map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " ")
        lockLog.notice("session dictionary: \(keys, privacy: .public)")
        return .read(screenLocked: session["CGSSessionScreenIsLocked"] as? Bool ?? false,
                     onConsole: session["kCGSSessionOnConsoleKey"] as? Bool ?? true)
    }
}
