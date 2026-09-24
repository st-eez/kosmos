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

    /// Uses the private path while the kill switch allows it, and the public path when it is
    /// off or a SkyLight call fails. `worker` belongs to the window's app and runs the public
    /// path. `dropped` runs on the main actor when the request is not performed, so the
    /// caller can forget the echo it expected.
    func request(_ key: KeyWindow, pid: pid_t, worker: AppWorker?, generation: UInt64,
                 dropped: @escaping @MainActor () -> Void) {
        queue.async { [self] in
            let isCurrent = { @Sendable [self] in current.load(ordering: .relaxed) == generation }
            guard isCurrent() else { return Self.onMain(dropped) }
            if killSwitch.isOn {
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

    private static func onMain(_ dropped: @escaping @MainActor () -> Void) {
        DispatchQueue.main.async { MainActor.assumeIsolated { dropped() } }
    }
}
