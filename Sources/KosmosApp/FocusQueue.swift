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
    /// target's app: it reads the app's focused window, raises the window before the private
    /// path keys it, and runs the public path.
    ///
    /// A request that is stale, or whose target is already key, makes no call and records
    /// nothing. Otherwise `performing` runs on the main actor with a stamp taken just before
    /// the calls, so the caller records the echo it expects, and `dropped` runs with that
    /// stamp when the calls fail, so the caller forgets it (tla/Kosmos.tla, ExecFocus).
    /// `performing` says whether the path keys the exact window: the private path does, and
    /// the public path, which a failed private call falls back to with a record of its own,
    /// lets the app choose. The
    /// main queue runs `performing` before any report of the change, which reaches main only
    /// after the change starts. Recording when the request is made instead failed TLC: a
    /// request still queued took a click on its window for its echo.
    func request(_ key: KeyWindow, pid: pid_t, worker: AppWorker?, privately: Bool, generation: UInt64,
                 performing: @escaping @MainActor (_ stamp: ContinuousClock.Instant, _ exact: Bool) -> Void,
                 dropped: @escaping @MainActor (ContinuousClock.Instant) -> Void) {
        queue.async { [self] in
            let isCurrent = { @Sendable [self] in current.load(ordering: .relaxed) == generation }
            guard isCurrent(), !Self.isKey(key, pid: pid, worker: worker) else { return }
            if privately {
                let stamp = ContinuousClock.now
                Self.onMain { performing(stamp, true) }
                if case .window(let id) = key, let worker {
                    Self.raise(id, on: worker, isCurrent)
                    guard isCurrent() else { return Self.onMain { dropped(stamp) } }
                }
                let performed = killSwitch.guarded {
                    switch key {
                    case .window(let id): kosmos_make_key(pid, id)
                    case .none: kosmos_front_without_windows(pid)
                    }
                }
                if performed { return }
                Self.onMain { dropped(stamp) }
            }
            let stamp = ContinuousClock.now
            Self.onMain { performing(stamp, false) }
            switch key {
            case .window(let id):
                guard let worker else { return Self.onMain { dropped(stamp) } }
                worker.focusPublicly(id, isCurrent: isCurrent) { Self.onMain { dropped(stamp) } }
            case .none:
                if NSRunningApplication(processIdentifier: pid)?.activate(options: []) != true { Self.onMain { dropped(stamp) } }
            }
        }
    }

    /// On macOS 27 the key record alone leaves the key window unchanged inside the app that
    /// is already frontmost, for stacked and side by side windows alike, while AXRaise and
    /// then the record keyed the right window in every case, same app or not (the hover
    /// branch's `kosmos-probe raise`). yabai and alt-tab raise after the record, which no
    /// probe has checked on macOS 27. The raise runs on the app's worker, and the queue waits
    /// for it no longer than the main actor waits on a worker (DESIGN.md, section 4.2): a
    /// slow app's raise lands after the record, and a hung app holds only its own worker.
    private static func raise(_ id: UInt32, on worker: AppWorker, _ isCurrent: @escaping @Sendable () -> Bool) {
        let raised = DispatchSemaphore(value: 0)
        worker.raise(id, isCurrent: isCurrent) { raised.signal() }
        _ = raised.wait(timeout: .now() + .milliseconds(30))
    }

    /// Whether the target is already key, checked when the request runs rather than against
    /// the key window last reported, which can be older than a request still in flight
    /// (tla/Kosmos.tla, ExecFocus). The app's focused window is read on its worker only when
    /// the app is the front process, so a request for another app costs one 1.6 us front
    /// process lookup and no AX read. The queue waits for the read no longer than for a raise,
    /// and an unanswered read lets the request go ahead.
    private static func isKey(_ key: KeyWindow, pid: pid_t, worker: AppWorker?) -> Bool {
        let front = kosmos_front_pid() == pid
        var focused: UInt32?? = nil
        if front, let worker {
            let answer = Mutex<UInt32??>(nil)
            let read = DispatchSemaphore(value: 0)
            worker.readFocusedWindow { window in
                answer.withLock { $0 = window }
                read.signal()
            }
            if read.wait(timeout: .now() + .milliseconds(30)) == .success { focused = answer.withLock { $0 } }
        }
        return key.isAlreadyKey(appIsFront: front, focused: focused)
    }

    private static func onMain(_ callback: @escaping @MainActor () -> Void) {
        DispatchQueue.main.async { MainActor.assumeIsolated { callback() } }
    }
}
