import AppKit
import CKosmos
import KosmosCore
import KosmosRecovery
import Synchronization
import os

private let focusLog = Logger(subsystem: "io.github.st-eez.kosmos", category: "focus")

/// Makes windows key off the main thread (docs/overview.md, section 4.2, and docs/focus.md). Each
/// request starts a focus generation and is dropped when a newer one exists as the queue runs it.
final class FocusQueue: Sendable {
    private let queue = DispatchQueue(label: "kosmos.focus", qos: .userInteractive)
    private let current = Atomic<UInt64>(0)
    let killSwitch = FocusKillSwitch(url: KosmosFiles.support.appending(path: "private-focus"))

    /// The private path for a window runs the split model's `FocusStart`, `FocusDecide` and
    /// `WorkerPost` (tla/Kosmos.tla; KosmosCore's KeyRequest). Each side records the echo
    /// through `performing` right before its own call that changes the key window; recording
    /// at the request failed TLC (docs/focus.md). `emptyWorkspace` is the window `.noWindow` keys.
    func request(_ key: KeyWindow, pid: pid_t, worker: AppWorker?, privately: Bool, concealed: Bool,
                 emptyWorkspace: EmptyWorkspaceWindow.Target?,
                 performing: @escaping @MainActor (_ stamp: ContinuousClock.Instant, _ path: FocusPath) -> Void,
                 forgetRecord: @escaping @MainActor (ContinuousClock.Instant) -> Void) {
        let generation = current.add(1, ordering: .relaxed).newValue
        queue.async { [self] in
            let isCurrent = { @Sendable [self] in current.load(ordering: .relaxed) == generation }
            guard isCurrent(), !concealed else { return }
            let raising: @Sendable (ContinuousClock.Instant) -> Void = { stamp in onMain { performing(stamp, .raise) } }
            let forgettingRecord: @Sendable (ContinuousClock.Instant) -> Void = { stamp in onMain { forgetRecord(stamp) } }
            let front = kosmos_front_pid() == pid
            if privately {
                let keyed: WindowID
                switch key {
                case .window(let id):
                    let request = KeyRequest(appWasFront: front)
                    Self.wait(for: worker, id, isCurrent, request, performing: raising, forgetRecord: forgettingRecord)
                    guard request.queueKeys(isCurrent: isCurrent(), appIsFront: kosmos_front_pid() == pid) else { return }
                    keyed = id
                case .noWindow:
                    // `FocusStart` for Kosmos's own window.
                    guard let emptyWorkspace else { return }
                    if front {
                        // Inside the front app the key record keys nothing (docs/overview.md,
                        // section 2), so AppKit keys it, as when another display's window is key.
                        onMain {
                            guard isCurrent(), !emptyWorkspace.isKey.load(ordering: .relaxed) else { return }
                            performing(.now, .raise)
                            emptyWorkspace.makeKey()
                        }
                        return
                    }
                    keyed = emptyWorkspace.window
                }
                let stamp = ContinuousClock.now
                onMain { performing(stamp, .keyRecord) }
                let performed = killSwitch.guarded { kosmos_make_key(pid, keyed) }
                if performed {
                    // `WorkerPost`: the key record leaves the window where it sits in its app's
                    // stacking order.
                    if case .window(let id) = key {
                        worker?.raiseAfterKeyRecord(id, performing: raising, raised: forgettingRecord)
                    }
                    return
                }
                // A failed key record takes the public path (docs/focus.md).
                forgettingRecord(stamp)
            }
            switch key {
            case .window(let id):
                worker?.focusPublicly(id, readFocus: front, isCurrent: isCurrent,
                                      performing: { stamp in onMain { performing(stamp, .activation) } },
                                      forgetRecord: forgettingRecord)
            case .noWindow:
                // No public call keys Kosmos's own window (docs/focus.md).
                focusLog.notice("the empty workspace keys nothing: the private path is off after a crash, or its call failed")
            }
        }
    }

    /// Waits no longer than the main actor waits on a worker (docs/overview.md, section 4.2);
    /// a slow app's job finishes on its own.
    private static func wait(for worker: AppWorker?, _ id: WindowID, _ isCurrent: @escaping @Sendable () -> Bool,
                             _ request: KeyRequest,
                             performing: @escaping @Sendable (ContinuousClock.Instant) -> Void,
                             forgetRecord: @escaping @Sendable (ContinuousClock.Instant) -> Void) {
        guard let worker else { return }
        let finished = DispatchSemaphore(value: 0)
        worker.focusPrivately(id, isCurrent: isCurrent, request: request, performing: performing, forgetRecord: forgetRecord) {
            finished.signal()
        }
        _ = finished.wait(timeout: .now() + .milliseconds(30))
    }
}

/// The call a recorded echo waits for.
enum FocusPath: Sendable {
    /// Activates a background app with the named window. Only these count toward the kill switch.
    case keyRecord
    /// Inside the front app, where it keys the window: AXRaise, or AppKit for Kosmos's own.
    case raise
    /// The public activation, which lets the app choose its key window.
    case activation
}
