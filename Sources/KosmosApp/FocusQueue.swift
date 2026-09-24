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

    /// Starts a new focus intent; requests from older intents are dropped.
    func newGeneration() -> UInt64 {
        current.add(1, ordering: .relaxed).newValue
    }

    /// Uses the private path when `privately`, as the kill switch said on the main actor, and
    /// the public path otherwise or when a SkyLight call fails. `worker` belongs to the
    /// target's app: it reads the app's focused window, raises the window and runs the public
    /// path.
    ///
    /// The request is checked when it runs (tla/Kosmos.tla, ExecFocus). A stale one does
    /// nothing. A target that is key already, as its app is the front process (1.6 us to
    /// read) and the app's focused window is the target, is skipped: the key window last
    /// reported can be older than a request still in flight. Only a request for the front app
    /// pays that AX read, and a read with no answer lets the request go ahead.
    ///
    /// Otherwise `performing` runs on the main actor with a stamp, before any call that can
    /// change the key window, so the caller records the echo it expects before any report of
    /// the change, which reaches main only after the change starts. It says whether the path
    /// keys the exact window: the private path does, and the public path, which a failed
    /// private call falls back to with a record of its own, lets the app choose. `dropped`
    /// gets the stamp when the calls fail. Recording when the request is made failed TLC: a
    /// request still queued took a click on its window for its echo.
    ///
    /// `concealed` says the target window was concealed when the request was made: the queue
    /// never names a concealed window, and the switch that reveals it requests focus once its
    /// barrier confirms the reveal.
    func request(_ key: KeyWindow, pid: pid_t, worker: AppWorker?, privately: Bool, concealed: Bool,
                 generation: UInt64,
                 performing: @escaping @MainActor (_ stamp: ContinuousClock.Instant, _ exact: Bool) -> Void,
                 dropped: @escaping @MainActor (ContinuousClock.Instant) -> Void) {
        queue.async { [self] in
            let isCurrent = { @Sendable [self] in current.load(ordering: .relaxed) == generation }
            guard isCurrent(), !concealed else { return }
            let front = kosmos_front_pid() == pid
            if privately {
                let request = SharedKeyRequest(performing: { stamp in Self.onMain { performing(stamp, true) } },
                                               dropped: { stamp in Self.onMain { dropped(stamp) } })
                Self.prepare(key, readFocus: front, worker: worker, isCurrent, request)
                // Once recorded, the request finishes even if a newer one arrived meanwhile:
                // that one follows in this queue and wins, and the raise's echo finds its record.
                guard let stamp = request.queueDecides() else { return }
                let performed = killSwitch.guarded {
                    switch key {
                    case .window(let id): kosmos_make_key(pid, id)
                    case .none: kosmos_front_without_windows(pid)
                    }
                }
                if performed { return }
                Self.onMain { dropped(stamp) }
            }
            switch key {
            case .window(let id):
                worker?.focusPublicly(id, readFocus: front, isCurrent: isCurrent,
                                      performing: { stamp in Self.onMain { performing(stamp, false) } },
                                      dropped: { stamp in Self.onMain { dropped(stamp) } })
            case .none:
                // No public call fronts Finder with no key window. Activating Finder can key a
                // hidden Finder window that keeps its ordinary Space for Command-Tab, and
                // Kosmos would follow it off the empty workspace. Kosmos itself has no window
                // a workspace holds, and nothing reports its activation, so nothing is
                // recorded. Whether macOS 27 lets a background agent activate itself is
                // unmeasured (`kosmos-probe keying`), so a refusal is logged.
                guard kosmos_front_pid() != getpid() else { return }
                if !NSRunningApplication.current.activate(options: []) {
                    focusLog.notice("activating Kosmos for an empty workspace returned false")
                }
                queue.asyncAfter(deadline: .now() + .milliseconds(200)) {
                    guard isCurrent(), kosmos_front_pid() != getpid() else { return }
                    focusLog.notice("Kosmos is not the front process 0.2 s after activating itself for an empty workspace")
                }
            }
        }
    }

    /// The worker's part of a private request: the focused window read and the raise, as one
    /// job (AppWorker.prepareKey). On macOS 27 the key record alone leaves the key window
    /// unchanged inside the app that is already frontmost, for stacked and side by side
    /// windows alike, while AXRaise and then the record keyed the right window in every case,
    /// same app or not (the hover branch's `kosmos-probe raise`). yabai and alt-tab raise
    /// after the record, which no probe has checked on macOS 27. The queue waits for the job
    /// no longer than the main actor waits on a worker (DESIGN.md, section 4.2); after that
    /// `queueDecides` goes ahead, a slow app's raise lands after the record, and a hung app
    /// holds only its own worker.
    private static func prepare(_ key: KeyWindow, readFocus: Bool, worker: AppWorker?,
                                _ isCurrent: @escaping @Sendable () -> Bool, _ request: SharedKeyRequest) {
        guard let worker else { return }
        if case .none = key, !readFocus { return }   // nothing to read or raise
        let finished = DispatchSemaphore(value: 0)
        worker.prepareKey(key, readFocus: readFocus, isCurrent: isCurrent, request: request) { finished.signal() }
        _ = finished.wait(timeout: .now() + .milliseconds(30))
    }

    private static func onMain(_ callback: @escaping @MainActor () -> Void) {
        DispatchQueue.main.async { MainActor.assumeIsolated { callback() } }
    }
}

/// A private request's KeyRequest, shared by the focus queue and the app's worker under one
/// lock. A record or a drop is posted to the main actor inside the lock, so the main queue
/// runs it before anything the other side does next.
final class SharedKeyRequest: Sendable {
    private let state = Mutex(KeyRequest<ContinuousClock.Instant>())
    private let performing: @Sendable (ContinuousClock.Instant) -> Void
    private let dropped: @Sendable (ContinuousClock.Instant) -> Void

    init(performing: @escaping @Sendable (ContinuousClock.Instant) -> Void,
         dropped: @escaping @Sendable (ContinuousClock.Instant) -> Void) {
        self.performing = performing
        self.dropped = dropped
    }

    func workerStarts(isCurrent: Bool) -> Bool {
        state.withLock { $0.workerStarts(isCurrent: isCurrent) }
    }

    /// Returns whether the worker raises.
    func workerDecides(isCurrent: Bool, alreadyKey: Bool, appWasFront: Bool) -> Bool {
        state.withLock { request in
            switch request.workerDecides(isCurrent: isCurrent, alreadyKey: alreadyKey, appWasFront: appWasFront, now: .now) {
            case .stop: return false
            case .record(let stamp):
                performing(stamp)
                return true
            case .raise: return true
            case .drop(let stamp):
                dropped(stamp)
                return false
            }
        }
    }

    /// The stamp to key with, or nil when the worker skipped the request.
    func queueDecides() -> ContinuousClock.Instant? {
        state.withLock { request in
            guard let decision = request.queueDecides(now: .now) else { return nil }
            if decision.recordsItself { performing(decision.stamp) }
            return decision.stamp
        }
    }
}
