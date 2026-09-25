import CKosmos
import Foundation
import os
import Synchronization

private let barLog = Logger(subsystem: "io.github.st-eez.kosmos", category: "bar")

/// Pushes each state snapshot to SketchyBar as one `--trigger` event, so the bar never
/// queries Kosmos and a switch launches no process (docs/ipc.md).
final class BarPush: Sendable {
    static let barName = "git.felix.sketchybar"
    static let event = "kosmos_state"

    private let queue = DispatchQueue(label: "kosmos.bar", qos: .utility)
    /// The newest snapshot not yet delivered; a newer one replaces it.
    private let pending = Mutex<Data?>(nil)

    func publish(_ snapshot: Data) {
        pending.withLock { $0 = snapshot }
        queue.async { self.flush(retry: true) }
    }

    /// Sends `--query bar` and waits for the reply, which fails if SketchyBar changed its
    /// wire format. Returns false when no bar answers.
    func checkFormat() -> Bool {
        let payload = Self.payload(["--query", "bar"])
        var reply = [CChar](repeating: 0, count: 4096)
        let count = payload.withUnsafeBufferPointer {
            kosmos_bar_query(Self.barName, $0.baseAddress, UInt32($0.count), &reply, UInt32(reply.count), 500)
        }
        if count <= 0 { barLog.error("SketchyBar did not answer --query bar") }
        return count > 0
    }

    private func flush(retry: Bool) {
        guard let snapshot = pending.withLock({ $0 }) else { return }
        let payload = Self.payload(["--trigger", Self.event, "STATE=" + String(decoding: snapshot, as: UTF8.self)])
        let result = payload.withUnsafeBufferPointer { kosmos_bar_send(Self.barName, $0.baseAddress, UInt32($0.count)) }
        if result == KERN_SUCCESS {
            pending.withLock { if $0 == snapshot { $0 = nil } }
        } else if retry {
            // A busy or restarting bar gets one more try; a newer snapshot replaces this one.
            queue.asyncAfter(deadline: .now() + .milliseconds(250)) { self.flush(retry: false) }
        } else {
            barLog.debug("SketchyBar send failed: \(result)")
        }
    }

    /// Arguments joined by NUL, with one more NUL at the end.
    static func payload(_ arguments: [String]) -> [CChar] {
        arguments.flatMap { $0.utf8CString } + [0]
    }
}
