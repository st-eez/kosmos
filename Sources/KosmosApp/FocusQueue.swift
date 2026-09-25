import AppKit
import CKosmos
import KosmosCore
import KosmosRecovery
import Synchronization
import os

private let focusLog = Logger(subsystem: "io.github.st-eez.kosmos", category: "focus")

/// Makes windows key off the main thread (DESIGN.md, sections 4.2 and 5.4). Each request
/// carries the focus generation it was made for, and is dropped when a newer intent exists
/// by the time the queue reaches it.
final class FocusQueue: Sendable {
    private let queue = DispatchQueue(label: "kosmos.focus", qos: .userInteractive)
    private let current = Atomic<UInt64>(0)
    let killSwitch = FocusKillSwitch(url: KosmosFiles.support.appending(path: "private-focus"))
    /// Kosmos's own window, which an empty workspace keys.
    private let emptyWorkspace: EmptyWorkspaceWindow.Target

    init(emptyWorkspace: EmptyWorkspaceWindow.Target) {
        self.emptyWorkspace = emptyWorkspace
    }

    /// Starts a new focus intent; requests from older intents are dropped.
    func newGeneration() -> UInt64 {
        current.add(1, ordering: .relaxed).newValue
    }

    /// Uses the private path when `privately`, as the kill switch said on the main actor, and
    /// the public path otherwise or when a SkyLight call fails. `worker` belongs to the
    /// target's app: it reads the app's focused window, raises the window and runs the public
    /// path. For `.none`, `pid` is Kosmos's own, and the private key record keys Kosmos's
    /// empty workspace window, which no public call can.
    ///
    /// The private path for a window follows the split model in tla/Kosmos.tla (KosmosCore's
    /// KeyRequest). `FocusStart`: a stale request, or one whose window was concealed when it
    /// was made, does nothing; otherwise the queue reads whether the target's app is front
    /// (1.6 us) and hands the worker its job. For the front app the worker ends a request
    /// whose target is focused already, as it is key already: the key window last reported
    /// can be older than a request still in flight. Otherwise it raises, which keys the
    /// window there. `FocusDecide`: after the job, or 30 ms, the queue keys only a
    /// background app, whose job did nothing but order the key record after the app's queued
    /// activation reads. `WorkerPost`: then the app's worker raises the window.
    ///
    /// Each side records the echo right before its own call that changes the key window, and
    /// never for the other's: `performing` runs on the main actor with a stamp and the path,
    /// before any report of the change, which reaches main only after the change starts. The
    /// key record's echo is an activation's (`act` in tla/Kosmos.tla) and a raise's a change
    /// inside the front app (`note`). `dropped` gets that stamp when the call fails, and when
    /// the raise after a key record is done, which forgets its record unless a report used it.
    /// Recording when the request is made failed TLC: a request still queued took a click on
    /// its window for its echo.
    func request(_ key: KeyWindow, pid: pid_t, worker: AppWorker?, privately: Bool, concealed: Bool,
                 generation: UInt64,
                 performing: @escaping @MainActor (_ stamp: ContinuousClock.Instant, _ path: FocusPath) -> Void,
                 dropped: @escaping @MainActor (ContinuousClock.Instant) -> Void) {
        queue.async { [self] in
            let isCurrent = { @Sendable [self] in current.load(ordering: .relaxed) == generation }
            guard isCurrent(), !concealed else { return }
            let front = kosmos_front_pid() == pid
            if privately {
                let stamp: ContinuousClock.Instant
                switch key {
                case .window(let id):
                    let request = KeyRequest(appWasFront: front)
                    Self.wait(for: worker, id, isCurrent, request,
                              performing: { stamp in Self.onMain { performing(stamp, .raise) } },
                              dropped: { stamp in Self.onMain { dropped(stamp) } })
                    guard request.queueKeys(isCurrent: isCurrent(), appIsFront: kosmos_front_pid() == pid) else { return }
                    stamp = ContinuousClock.now
                case .none:
                    // `FocusStart`: Kosmos's own window, keyed at once unless it is key already.
                    if front, emptyWorkspace.isKey.load(ordering: .relaxed) { return }
                    stamp = ContinuousClock.now
                }
                Self.onMain { performing(stamp, .keyRecord) }
                let performed = killSwitch.guarded {
                    switch key {
                    case .window(let id): kosmos_make_key(pid, id)
                    case .none: kosmos_make_key(pid, emptyWorkspace.window)
                    }
                }
                guard performed else { return Self.onMain { dropped(stamp) } }
                // `WorkerPost`: the key record left the window where it sits in its app's
                // stacking order, and the app's worker raises it next.
                if case .window(let id) = key {
                    worker?.raiseAfterKeyRecord(id, performing: { stamp in Self.onMain { performing(stamp, .raise) } },
                                                raised: { stamp in Self.onMain { dropped(stamp) } })
                }
                return
            }
            switch key {
            case .window(let id):
                worker?.focusPublicly(id, readFocus: front, isCurrent: isCurrent,
                                      performing: { stamp in Self.onMain { performing(stamp, .activation) } },
                                      dropped: { stamp in Self.onMain { dropped(stamp) } })
            case .none:
                // Only the private path keys Kosmos's own window: an accessory app that
                // activated itself became front in 0 of 10 trials. With that path off after a
                // crash, or its call failing, the previous window stays key.
                focusLog.notice("the empty workspace keys nothing: the private path is off after a crash, or its call failed")
            }
        }
    }

    /// Runs the worker's job for a private request and waits for it no longer than the main
    /// actor waits on a worker (DESIGN.md, section 4.2). On macOS 27 the key record alone
    /// leaves the key window unchanged inside the app that is already frontmost, 0 times in 20,
    /// while AXRaise keyed the right window 20 times in 20 (`kosmos-probe keying`). A slow app's job
    /// finishes on its own, and a hung app holds only its own worker. With no worker, nothing
    /// is raised and the queue decides.
    private static func wait(for worker: AppWorker?, _ id: UInt32, _ isCurrent: @escaping @Sendable () -> Bool,
                             _ request: KeyRequest,
                             performing: @escaping @Sendable (ContinuousClock.Instant) -> Void,
                             dropped: @escaping @Sendable (ContinuousClock.Instant) -> Void) {
        guard let worker else { return }
        let finished = DispatchSemaphore(value: 0)
        worker.focusPrivately(id, isCurrent: isCurrent, request: request, performing: performing, dropped: dropped) {
            finished.signal()
        }
        _ = finished.wait(timeout: .now() + .milliseconds(30))
    }

    private static func onMain(_ callback: @escaping @MainActor () -> Void) {
        DispatchQueue.main.async { MainActor.assumeIsolated { callback() } }
    }
}

/// The call a recorded echo waits for.
enum FocusPath: Sendable {
    /// The private key record, which activates a background app with the named window. Only
    /// these count toward the kill switch.
    case keyRecord
    /// AXRaise inside the front app, where it keys the window.
    case raise
    /// The public activation, which lets the app choose its key window.
    case activation
}
