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
    /// the public path otherwise or when a SkyLight call fails. `worker` belongs to the window's app: it raises the window
    /// before the private path keys it, and runs the public path. `dropped` runs on the main
    /// actor when the request is not performed, so the caller can forget the echo it expected.
    func request(_ key: KeyWindow, pid: pid_t, worker: AppWorker?, privately: Bool, generation: UInt64,
                 dropped: @escaping @MainActor () -> Void) {
        queue.async { [self] in
            let isCurrent = { @Sendable [self] in current.load(ordering: .relaxed) == generation }
            guard isCurrent() else { return Self.onMain(dropped) }
            if privately {
                if case .window(let id) = key, let worker {
                    Self.raise(id, on: worker, isCurrent)
                    guard isCurrent() else { return Self.onMain(dropped) }
                }
                let performed = killSwitch.guarded {
                    switch key {
                    case .window(let id): kosmos_make_key(pid, id)
                    case .none: kosmos_front_without_windows(pid)
                    }
                }
                if performed { return }
            }
            switch key {
            case .window(let id):
                guard let worker else { return Self.onMain(dropped) }
                worker.focusPublicly(id, isCurrent: isCurrent) { Self.onMain(dropped) }
            case .none:
                NSRunningApplication(processIdentifier: pid)?.activate(options: [])
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

    private static func onMain(_ dropped: @escaping @MainActor () -> Void) {
        DispatchQueue.main.async { MainActor.assumeIsolated { dropped() } }
    }
}
