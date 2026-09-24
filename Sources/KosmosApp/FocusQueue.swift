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
    /// The private path for a window follows the split model in tla/Kosmos.tla (KosmosCore's
    /// KeyRequest). `FocusStart`: a stale request, or one whose window was concealed when it
    /// was made, does nothing; otherwise the queue reads whether the target's app is front
    /// (1.6 us) and hands the worker its job. The worker ends a request whose front app
    /// already has the target focused, as it is key already: the key window last reported can
    /// be older than a request still in flight. `FocusDecide`: after the job, or 30 ms, the
    /// queue keys only a background app, since inside the front app the key record does
    /// nothing and only the worker's raise keys a window.
    ///
    /// Each side records the echo right before its own call that changes the key window, and
    /// never for the other's: `performing` runs on the main actor with a stamp and the path,
    /// before any report of the change, which reaches main only after the change starts.
    /// `dropped` gets that stamp when the call fails. Recording when the request is made failed
    /// TLC: a request still queued took a click on its window for its echo.
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
                    let request = SharedKeyRequest(appWasFront: front,
                                                   performing: { stamp in Self.onMain { performing(stamp, .raise) } },
                                                   dropped: { stamp in Self.onMain { dropped(stamp) } })
                    Self.wait(for: worker, id, isCurrent, request)
                    guard let decided = request.queueDecides(isCurrent: isCurrent(), appIsFront: kosmos_front_pid() == pid)
                    else { return }
                    stamp = decided
                case .none:
                    // `FocusStart`: Finder with no window, keyed at once unless it is already.
                    if front, let worker, Self.focusedWindow(on: worker) == .some(nil) { return }
                    stamp = ContinuousClock.now
                }
                Self.onMain { performing(stamp, .keyRecord) }
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
                                      performing: { stamp in Self.onMain { performing(stamp, .activation) } },
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

    /// Runs the worker's job for a private request and waits for it no longer than the main
    /// actor waits on a worker (DESIGN.md, section 4.2). On macOS 27 the key record alone
    /// leaves the key window unchanged inside the app that is already frontmost, while AXRaise
    /// and then the record keyed the right window in every case, same app or not (the hover
    /// branch's `kosmos-probe raise`). A slow app's job finishes on its own, and a hung app
    /// holds only its own worker. With no worker, nothing is raised and the queue decides.
    private static func wait(for worker: AppWorker?, _ id: UInt32, _ isCurrent: @escaping @Sendable () -> Bool,
                             _ request: SharedKeyRequest) {
        guard let worker else { return }
        let finished = DispatchSemaphore(value: 0)
        worker.focusPrivately(id, isCurrent: isCurrent, request: request) { finished.signal() }
        _ = finished.wait(timeout: .now() + .milliseconds(30))
    }

    /// The app's focused window, read on its worker within 30 ms, or nil without an answer.
    private static func focusedWindow(on worker: AppWorker) -> UInt32?? {
        let answer = Mutex<UInt32??>(nil)
        let read = DispatchSemaphore(value: 0)
        worker.readFocusedWindow { window in
            answer.withLock { $0 = window }
            read.signal()
        }
        guard read.wait(timeout: .now() + .milliseconds(30)) == .success else { return nil }
        return answer.withLock { $0 }
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

/// A private request's KeyRequest, shared by the focus queue and the app's worker under one
/// lock. A record is posted to the main actor inside the lock, so the main queue runs it
/// before anything the other side does next.
final class SharedKeyRequest: Sendable {
    let appWasFront: Bool
    private let state: Mutex<KeyRequest<ContinuousClock.Instant>>
    private let performing: @Sendable (ContinuousClock.Instant) -> Void
    let dropped: @Sendable (ContinuousClock.Instant) -> Void

    init(appWasFront: Bool, performing: @escaping @Sendable (ContinuousClock.Instant) -> Void,
         dropped: @escaping @Sendable (ContinuousClock.Instant) -> Void) {
        self.appWasFront = appWasFront
        state = Mutex(KeyRequest(appWasFront: appWasFront))
        self.performing = performing
        self.dropped = dropped
    }

    func workerStarts(isCurrent: Bool) -> Bool {
        state.withLock { $0.workerStarts(isCurrent: isCurrent) }
    }

    func workerRead(isCurrent: Bool, targetFocused: Bool) -> Bool {
        state.withLock { $0.workerRead(isCurrent: isCurrent, targetFocused: targetFocused) }
    }

    /// Records the worker's echo inside the lock when the step says so.
    func workerRaises(isCurrent: Bool, appIsFront: Bool) -> KeyRequest<ContinuousClock.Instant>.RaiseStep {
        state.withLock { request in
            let step = request.workerRaises(isCurrent: isCurrent, appIsFront: appIsFront, now: .now)
            if case .recordAndRaise(let stamp) = step { performing(stamp) }
            return step
        }
    }

    /// The stamp for the queue's key record, or nil when the queue keys nothing. The queue
    /// records it itself, as the key record is its call.
    func queueDecides(isCurrent: Bool, appIsFront: Bool) -> ContinuousClock.Instant? {
        state.withLock { $0.queueDecides(isCurrent: isCurrent, appIsFront: appIsFront, now: .now) }
    }
}
