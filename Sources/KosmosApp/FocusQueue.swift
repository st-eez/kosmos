import AppKit
import CSkyLight
import KosmosCore
import Synchronization

/// Makes windows key off the main thread (DESIGN.md, sections 4.2 and 5.4). Each request
/// carries the focus generation it was made for, and is dropped when a newer intent exists
/// by the time the queue reaches it.
final class FocusQueue: Sendable {
    private let queue = DispatchQueue(label: "kosmos.focus", qos: .userInteractive)
    private let current = Atomic<UInt64>(0)

    /// Starts a new focus intent; requests from older intents are dropped.
    func newGeneration() -> UInt64 {
        current.add(1, ordering: .relaxed).newValue
    }

    /// `dropped` runs on the main actor when the request is not performed, so the caller can
    /// forget the echo it expected.
    func request(_ key: KeyWindow, pid: pid_t, generation: UInt64, dropped: @escaping @MainActor () -> Void) {
        queue.async { [self] in
            guard current.load(ordering: .relaxed) == generation else {
                return DispatchQueue.main.async { MainActor.assumeIsolated { dropped() } }
            }
            let performed = switch key {
            case .window(let id): kosmos_make_key(pid, id)
            case .none: kosmos_front_without_windows(pid)
            }
            if !performed { DispatchQueue.main.async { MainActor.assumeIsolated { dropped() } } }
        }
    }
}
