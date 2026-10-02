import CoreGraphics
import KosmosCore
import Synchronization
import os

let pointerLog = Logger(subsystem: "io.github.st-eez.kosmos", category: "pointer")

/// Focus follows mouse's pointer movement from a listen-only tap at the annotated session
/// location, where WindowServer names the window under the pointer, so a movement reads no
/// window list (docs/focus-follows-mouse.md).
final class PointerTap: Sendable {
    private let executor = RunLoopExecutor(name: "kosmos.pointer")
    /// Set once in `init`.
    private nonisolated(unsafe) var port: CFMachPort?
    private let enabled = Atomic<Bool>(false)
    private let gate = Mutex(PointerGate())
    private let heard = Atomic<Bool>(false)
    /// Each process whose posted movement was logged.
    private let posters = Mutex<Set<pid_t>>([])
    private let entered: @MainActor (PointerGate.Entered, ContinuousClock.Instant) -> Void

    init?(entered: @escaping @MainActor (PointerGate.Entered, ContinuousClock.Instant) -> Void) {
        self.entered = entered
        port = CGEvent.tapCreate(
            tap: .cgAnnotatedSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
            eventsOfInterest: CGEventMask(1 << CGEventType.mouseMoved.rawValue),
            callback: { _, type, event, refcon in
                Unmanaged<PointerTap>.fromOpaque(refcon!).takeUnretainedValue().handle(type, event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let port else {
            pointerLog.error("pointer tap not created; Input Monitoring granted: \(CGPreflightListenEventAccess(), privacy: .public)")
            executor.stop()
            return nil
        }
        CGEvent.tapEnable(tap: port, enable: false)
        CFRunLoopAddSource(executor.runLoop, CFMachPortCreateRunLoopSource(nil, port, 0), .commonModes)
        pointerLog.notice("pointer tap created; Input Monitoring granted: \(CGPreflightListenEventAccess(), privacy: .public)")
    }

    /// The port is invalidated on the tap's thread, and the block holds this object until
    /// then, so no callback outlives it.
    func stop() {
        guard let port else { return }
        enabled.store(false, ordering: .relaxed)
        CGEvent.tapEnable(tap: port, enable: false)
        executor.perform { [self] in
            if let port = self.port { CFMachPortInvalidate(port) }
            executor.stop()
        }
        pointerLog.notice("pointer tap stopped")
    }

    var window: WindowID? { gate.withLock { $0.window } }

    func setEnabled(_ on: Bool) {
        guard let port, enabled.exchange(on, ordering: .relaxed) != on else { return }
        // The window under the pointer counts as entered on the first movement.
        if on { gate.withLock { $0.reset() } }
        CGEvent.tapEnable(tap: port, enable: on)
        pointerLog.notice("focus follows mouse \(on ? "on" : "off", privacy: .public); tap enabled: \(CGEvent.tapIsEnabled(tap: port), privacy: .public)")
    }

    func warped() {
        gate.withLock { $0.warped() }
    }

    func setMonitors(_ monitors: [Monitor]) {
        gate.withLock { $0.monitors = monitors }
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) {
        guard type == .mouseMoved else {
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput, enabled.load(ordering: .relaxed), let port {
                pointerLog.notice("pointer tap turned off by WindowServer (\(type.rawValue)); turning it on again")
                CGEvent.tapEnable(tap: port, enable: true)
            }
            return
        }
        // The user's hand showed source pid 0, and a posted movement its poster's pid
        // (docs/focus-follows-mouse.md).
        let poster = pid_t(truncatingIfNeeded: event.getIntegerValueField(.eventSourceUnixProcessID))
        moved(over: WindowID(truncatingIfNeeded: event.getIntegerValueField(.mouseEventWindowUnderMousePointer)),
              at: event.location, control: event.flags.contains(.maskControl), poster: poster)
    }

    private func moved(over window: WindowID, at location: CGPoint, control: Bool, poster: pid_t) {
        let stamp = ContinuousClock.now
        if !heard.exchange(true, ordering: .relaxed) { pointerLog.notice("pointer tap receiving events") }
        if poster != 0, posters.withLock({ $0.insert(poster).inserted }) {
            pointerLog.notice("pointer movement posted by pid \(poster) (\(processName(poster), privacy: .public)) focuses nothing")
        }
        guard let entered = gate.withLock({ $0.admit(window, at: location, control: control, posted: poster != 0) }) else { return }
        let callback = self.entered
        onMain { callback(entered, stamp) }
    }
}

private func processName(_ pid: pid_t) -> String {
    var name = [CChar](repeating: 0, count: 256)
    guard proc_name(pid, &name, UInt32(name.count)) > 0 else { return "?" }
    return name.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
}
