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
        queue.async { self.flush(retry: true) }
    }

    private func flush(retry: Bool) {
        guard let snapshot = pending.withLock({ $0 }) else { return }
        let payload = Self.payload(["--trigger", Self.event, "STATE=" + String(decoding: snapshot, as: UTF8.self)])
        let result = payload.withUnsafeBufferPointer { kosmos_bar_send(Self.barName, $0.baseAddress, UInt32($0.count)) }
        if result == KERN_SUCCESS {
            pending.withLock { if $0 == snapshot { $0 = nil } }
        } else if retry {
            // A busy or restarting bar gets one more try.
            queue.asyncAfter(deadline: .now() + .milliseconds(250)) { self.flush(retry: false) }
        } else {
            barLog.debug("SketchyBar send failed: \(result)")
        }
    }

    static func payload(_ arguments: [String]) -> [CChar] {
        arguments.flatMap { $0.utf8CString } + [0]
    }
}
