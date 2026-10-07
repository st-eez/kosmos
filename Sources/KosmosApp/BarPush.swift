import CKosmos
import Foundation
import os
import Synchronization

private let barLog = Logger(subsystem: "io.github.st-eez.kosmos", category: "bar")

/// Pushes each snapshot to Zenith's Mach port as the JSON alone (docs/ipc.md).
final class BarPush: Sendable {
    static let name = "io.github.st-eez.zenith"

    private let queue = DispatchQueue(label: "kosmos.bar", qos: .utility)
    /// Zenith's send right, touched only on `queue`.
    nonisolated(unsafe) private var port = mach_port_t(MACH_PORT_NULL)
    /// The snapshot Zenith has yet to take.
    private let pending = Mutex<Data?>(nil)
    /// The log names the first failed send of a streak and its end, so a Mac without
    /// Zenith logs once.
    private let failures = Mutex(0)

    func publish(_ snapshot: Data) {
        pending.withLock { $0 = snapshot }
        queue.async { self.flush(retrying: false) }
    }

    private func flush(retrying: Bool) {
        guard let snapshot = pending.withLock({ $0 }) else { return }
        let payload = snapshot.map { CChar(bitPattern: $0) }
        let result = payload.withUnsafeBufferPointer { kosmos_bar_send(&port, Self.name, $0.baseAddress, UInt32($0.count)) }
        if result == KERN_SUCCESS {
            pending.withLock { if $0 == snapshot { $0 = nil } }
            let streak = failures.withLock { count in defer { count = 0 }; return count }
            if streak > 0 {
                barLog.notice("Zenith took a snapshot after \(streak) failed sends, \(retrying ? "on a retry 250 ms after one" : "at a later change", privacy: .public)")
            }
            return
        }
        if failures.withLock({ count in count += 1; return count }) == 1 {
            barLog.notice("Zenith send failed: \(result); more failures are logged when a send goes again")
        }
        // The zero send timeout fails while the bar's queue is full, and a restarting bar has
        // no port yet, so a busy or restarting bar gets one more try.
        if !retrying { queue.asyncAfter(deadline: .now() + .milliseconds(250)) { self.flush(retrying: true) } }
    }
}
