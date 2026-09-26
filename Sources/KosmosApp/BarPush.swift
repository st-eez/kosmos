import CKosmos
import Foundation
import os
import Synchronization

private let barLog = Logger(subsystem: "io.github.st-eez.kosmos", category: "bar")

/// Pushes each snapshot to SketchyBar as one `--trigger` event over its Mach port (docs/ipc.md).
final class BarPush: Sendable {
    static let barName = "git.felix.sketchybar"
    static let event = "kosmos_state"

    private let queue = DispatchQueue(label: "kosmos.bar", qos: .utility)
    private let pending = Mutex<Data?>(nil)

    func publish(_ snapshot: Data) {
        pending.withLock { $0 = snapshot }
        queue.async { self.flush(failed: nil) }
    }

    /// `failed`: the result of the send this one tries again.
    private func flush(failed: kern_return_t?) {
        guard let snapshot = pending.withLock({ $0 }) else {
            if let failed { barLog.notice("SketchyBar send failed: \(failed); a later send went before the retry") }
            return
        }
        let payload = Self.payload(["--trigger", Self.event, "STATE=" + String(decoding: snapshot, as: UTF8.self)])
        let result = payload.withUnsafeBufferPointer { kosmos_bar_send(Self.barName, $0.baseAddress, UInt32($0.count)) }
        if result == KERN_SUCCESS { pending.withLock { if $0 == snapshot { $0 = nil } } }
        if let failed {
            barLog.notice("SketchyBar send failed: \(failed); 250 ms later \(result == KERN_SUCCESS ? "it went" : "it failed again: \(result)", privacy: .public)")
        } else if result != KERN_SUCCESS {
            // The zero send timeout fails while the bar's queue is full, and a restarting bar has
            // no port yet, so a busy or restarting bar gets one more try.
            queue.asyncAfter(deadline: .now() + .milliseconds(250)) { self.flush(failed: result) }
        }
    }

    static func payload(_ arguments: [String]) -> [CChar] {
        arguments.flatMap { $0.utf8CString } + [0]
    }
}
