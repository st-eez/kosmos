import CKosmos
import Foundation
import os
import Synchronization

private let barLog = Logger(subsystem: "io.github.st-eez.kosmos", category: "bar")

/// Pushes each snapshot to the bars over their Mach ports: SketchyBar as one `--trigger`
/// event, Zenith as the snapshot alone (docs/ipc.md).
final class BarPush: Sendable {
    struct Bar: Sendable {
        let label: String
        let name: String
        let payload: @Sendable (Data) -> [CChar]
    }

    static let event = "kosmos_state"
    static let bars = [
        Bar(label: "SketchyBar", name: "git.felix.sketchybar") {
            payload(["--trigger", event, "STATE=" + String(decoding: $0, as: UTF8.self)])
        },
        Bar(label: "Zenith", name: "io.github.st-eez.zenith") { $0.map { CChar(bitPattern: $0) } },
    ]

    private let queue = DispatchQueue(label: "kosmos.bar", qos: .utility)
    /// Each bar's send right, touched only on `queue`.
    nonisolated(unsafe) private var ports = Array(repeating: mach_port_t(MACH_PORT_NULL), count: bars.count)
    /// The snapshot each bar has yet to take.
    private let pending = Mutex<[Data?]>(Array(repeating: nil, count: bars.count))
    /// The log names the first failed send of each bar's streak and its end, so a Mac
    /// without one of the bars logs once.
    private let failures = Mutex(Array(repeating: 0, count: bars.count))

    func publish(_ snapshot: Data) {
        pending.withLock { $0 = $0.map { _ in snapshot } }
        queue.async { for bar in Self.bars.indices { self.flush(bar, retrying: false) } }
    }

    private func flush(_ index: Int, retrying: Bool) {
        let bar = Self.bars[index]
        guard let snapshot = pending.withLock({ $0[index] }) else { return }
        let payload = bar.payload(snapshot)
        let result = payload.withUnsafeBufferPointer { kosmos_bar_send(&ports[index], bar.name, $0.baseAddress, UInt32($0.count)) }
        if result == KERN_SUCCESS {
            pending.withLock { if $0[index] == snapshot { $0[index] = nil } }
            let streak = failures.withLock { counts in defer { counts[index] = 0 }; return counts[index] }
            if streak > 0 {
                barLog.notice("\(bar.label, privacy: .public) took a snapshot after \(streak) failed sends, \(retrying ? "on a retry 250 ms after one" : "at a later change", privacy: .public)")
            }
            return
        }
        if failures.withLock({ counts in counts[index] += 1; return counts[index] }) == 1 {
            barLog.notice("\(bar.label, privacy: .public) send failed: \(result); more failures are logged when a send goes again")
        }
        // The zero send timeout fails while the bar's queue is full, and a restarting bar has
        // no port yet, so a busy or restarting bar gets one more try.
        if !retrying { queue.asyncAfter(deadline: .now() + .milliseconds(250)) { self.flush(index, retrying: true) } }
    }

    static func payload(_ arguments: [String]) -> [CChar] {
        arguments.flatMap { $0.utf8CString } + [0]
    }
}
