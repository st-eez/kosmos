import AppKit
import CKosmos
import KosmosCore
import KosmosRecovery
import Synchronization

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
    func request(_ key: KeyWindow, pid: pid_t, worker: AppWorker?, privately: Bool, generation: UInt64,
                 performing: @escaping @MainActor (_ stamp: ContinuousClock.Instant, _ exact: Bool) -> Void,
                 dropped: @escaping @MainActor (ContinuousClock.Instant) -> Void) {
        queue.async { [self] in
            let isCurrent = { @Sendable [self] in current.load(ordering: .relaxed) == generation }
            guard isCurrent() else { return }
            let front = kosmos_front_pid() == pid
            if privately {
                let record = EchoRecord { stamp in Self.onMain { performing(stamp, true) } }
                switch Self.prepare(key, readFocus: front, worker: worker, isCurrent, record) {
                case .stale?, .alreadyKey?: return
                case .ready?, nil: break
                }
                // The request finishes even if a newer one arrived meanwhile: that one
                // follows in this queue and wins, and the raise's echo finds its record.
                let stamp = record.take()
                let performed = killSwitch.guarded {
                    switch key {
                    case .window(let id): kosmos_make_key(pid, id)
                    case .none: kosmos_front_without_windows(pid)
                    }
                }
                if performed { return }
                Self.onMain { dropped(stamp) }
            }
            if let worker {
                worker.focusPublicly(key, readFocus: front, isCurrent: isCurrent,
                                     performing: { stamp in Self.onMain { performing(stamp, false) } },
                                     dropped: { stamp in Self.onMain { dropped(stamp) } })
            } else if case .none = key {
                let stamp = ContinuousClock.now
                Self.onMain { performing(stamp, false) }
                if NSRunningApplication(processIdentifier: pid)?.activate(options: []) != true { Self.onMain { dropped(stamp) } }
            }
        }
    }

    /// The worker's part of a private request: the focused window read and the raise, as one
    /// job (AppWorker.prepareKey). On macOS 27 the key record alone leaves the key window
    /// unchanged inside the app that is already frontmost, for stacked and side by side
    /// windows alike, while AXRaise and then the record keyed the right window in every case,
    /// same app or not (the hover branch's `kosmos-probe raise`). yabai and alt-tab raise
    /// after the record, which no probe has checked on macOS 27. The queue waits for the job
    /// no longer than the main actor waits on a worker (DESIGN.md, section 4.2), and nil means
    /// no answer in that time: the request goes ahead, a slow app's raise lands after the
    /// record, and a hung app holds only its own worker.
    private static func prepare(_ key: KeyWindow, readFocus: Bool, worker: AppWorker?,
                                _ isCurrent: @escaping @Sendable () -> Bool, _ record: EchoRecord) -> AppWorker.Preparation? {
        guard let worker else { return .ready }
        if case .none = key, !readFocus { return .ready }   // nothing to read or raise
        let answer = Mutex<AppWorker.Preparation?>(nil)
        let finished = DispatchSemaphore(value: 0)
        worker.prepareKey(key, readFocus: readFocus, isCurrent: isCurrent, goAhead: { _ = record.take() }) { preparation in
            answer.withLock { $0 = preparation }
            finished.signal()
        }
        _ = finished.wait(timeout: .now() + .milliseconds(30))
        return answer.withLock { $0 }
    }

    private static func onMain(_ callback: @escaping @MainActor () -> Void) {
        DispatchQueue.main.async { MainActor.assumeIsolated { callback() } }
    }
}

/// A private request's echo, recorded once, before the first call that can change the key
/// window: by the app's worker before it raises, or by the queue when the worker has not
/// answered in time. If the worker then finds the target key already, the record stays and
/// the key record changes nothing; that expectation waits for a later echo to clear it.
private final class EchoRecord: Sendable {
    private let stamp = Mutex<ContinuousClock.Instant?>(nil)
    private let post: @Sendable (ContinuousClock.Instant) -> Void

    init(post: @escaping @Sendable (ContinuousClock.Instant) -> Void) {
        self.post = post
    }

    /// Records the echo unless it is recorded already, and returns its stamp.
    func take() -> ContinuousClock.Instant {
        stamp.withLock { stamp in
            if let stamp { return stamp }
            let now = ContinuousClock.now
            stamp = now
            post(now)
            return now
        }
    }
}
