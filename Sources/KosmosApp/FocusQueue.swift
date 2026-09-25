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
    private let emptyWorkspace: EmptyWorkspaceWindow.Target

    init(emptyWorkspace: EmptyWorkspaceWindow.Target) {
        self.emptyWorkspace = emptyWorkspace
    }

    /// The private path for a window runs the split model's `FocusStart`, `FocusDecide` and
    /// `WorkerPost` (tla/Kosmos.tla; KosmosCore's KeyRequest). Each side records the echo
    /// through `performing` right before its own call that changes the key window; recording
    /// at the request failed TLC (docs/focus.md).
    func request(_ key: KeyWindow, pid: pid_t, worker: AppWorker?, privately: Bool, concealed: Bool,
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
                let stamp: ContinuousClock.Instant
                switch key {
                case .window(let id):
                    let request = KeyRequest(appWasFront: front)
                    Self.wait(for: worker, id, isCurrent, request, performing: raising, forgetRecord: forgettingRecord)
                    guard request.queueKeys(isCurrent: isCurrent(), appIsFront: kosmos_front_pid() == pid) else { return }
                    stamp = ContinuousClock.now
                case .emptyWorkspace:
                    // `FocusStart` for Kosmos's own window.
                    if front, emptyWorkspace.isKey.load(ordering: .relaxed) { return }
                    stamp = ContinuousClock.now
                }
                onMain { performing(stamp, .keyRecord) }
                let performed = killSwitch.guarded {
                    switch key {
                    case .window(let id): kosmos_make_key(pid, id)
                    case .emptyWorkspace: kosmos_make_key(pid, emptyWorkspace.window)
                    }
                }
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
            case .emptyWorkspace:
                // No public call keys Kosmos's own window (docs/focus.md).
                focusLog.notice("the empty workspace keys nothing: the private path is off after a crash, or its call failed")
            }
        }
    }

    /// Waits no longer than the main actor waits on a worker (docs/overview.md, section 4.2);
    /// a slow app's job finishes on its own.
    private static func wait(for worker: AppWorker?, _ id: UInt32, _ isCurrent: @escaping @Sendable () -> Bool,
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
    /// AXRaise inside the front app, where it keys the window.
    case raise
    /// The public activation, which lets the app choose its key window.
    case activation
}
