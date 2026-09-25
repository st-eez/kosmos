import Foundation
import os

private let switchLog = Logger(subsystem: "io.github.st-eez.kosmos", category: "focus")

/// Turns the private focus path off (docs/focus.md). Two bytes in a file mapped
/// shared outlive the process, as the recovery record does: the first is set while a private
/// call runs, so a crash inside it is found at the next launch, and the second keeps the path
/// off, across restarts, until `kosmos reload-config`. Setting and clearing the first is two
/// stores into memory with no system call, about 1.4 ns in all.
///
/// A kill during the call also leaves the first byte set and turns the path off; a reload
/// turns it back on. The second byte is read and written on the main actor only, and the
/// focus queue is told with each request which path to take.
final class FocusKillSwitch: @unchecked Sendable {
    enum Reason: UInt8 {
        case crashed = 1
        case wrongWindows = 2
    }

    /// The byte set during a private call, and the reason the path is off (0 while on).
    private let bytes: UnsafeMutablePointer<UInt8>

    init(url: URL) {
        let size = 2
        let fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        defer { if fd >= 0 { close(fd) } }
        let mapped = fd >= 0 && ftruncate(fd, off_t(size)) == 0
            ? mmap(nil, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0) : MAP_FAILED
        if let mapped, mapped != MAP_FAILED {
            bytes = mapped.bindMemory(to: UInt8.self, capacity: size)
        } else {
            // Without the file the switch still works, but a crash is forgotten.
            switchLog.error("\(url.path, privacy: .public) not mapped (\(errno)); a crash in private focus will not be remembered")
            bytes = .allocate(capacity: size)
            bytes.initialize(repeating: 0, count: size)
        }
        if bytes[0] != 0 {
            bytes[0] = 0
            bytes[1] = Reason.crashed.rawValue
            switchLog.fault("the last run stopped inside a private focus call; focus uses the public path")
        }
        if let reason = Reason(rawValue: bytes[1]) {
            switchLog.notice("private focus is off (\(String(describing: reason), privacy: .public)) until a config reload")
        } else {
            bytes[1] = 0
        }
    }

    /// Main actor only, like `offReason`, `turnOff` and `turnOn`.
    var isOn: Bool { bytes[1] == 0 }

    /// Why the path is off, or nil.
    var offReason: Reason? { Reason(rawValue: bytes[1]) }

    /// Runs a private call with the first byte set. Focus queue only.
    func guarded(_ call: () -> Bool) -> Bool {
        bytes[0] = 1
        defer { bytes[0] = 0 }
        return call()
    }

    func turnOff(_ reason: Reason) {
        bytes[1] = reason.rawValue
    }

    func turnOn() {
        bytes[1] = 0
    }
}
