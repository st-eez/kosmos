import CoreGraphics
import KosmosCore
import Synchronization
import os

let pointerLog = Logger(subsystem: "io.github.st-eez.kosmos", category: "pointer")

/// Pointer movement for focus follows mouse (DESIGN.md, section 5.11), from a listen-only
/// event tap on its own thread. The tap is off while focus follows mouse is, and a pointer
/// at rest sends no events, so neither costs anything.
///
/// The tap sits where WindowServer has annotated each event with the window under the
/// pointer, found by its own hit test, so moving the pointer queries no window list. Each
/// movement goes through a PointerGate, and only a movement into another window or
/// display with Control up goes on to the main actor. Only mouse moved events are tapped: a movement
/// with a button down is a drag, so nothing is focused while a button is down.
///
/// On macOS 27 creating even this mouse-only tap asked a process without Input Monitoring
/// for it, and the tap stayed silent. Whether Kosmos's Accessibility grant is enough is
/// not known yet, so the tap is created only when focus follows mouse is first turned on.
/// The log says whether Input Monitoring is granted, whether the tap is enabled, and when
/// the first event arrives.
final class PointerTap: Sendable {
    private let executor = RunLoopExecutor(name: "kosmos.pointer")
    /// Set once in `init`.
    private nonisolated(unsafe) var port: CFMachPort?
    private let enabled = Atomic<Bool>(false)
    private let gate = Mutex(PointerGate())
    private let heard = Atomic<Bool>(false)
    private let entered: @MainActor (PointerGate.Entered, ContinuousClock.Instant) -> Void

    /// `entered` runs on the main actor with what the pointer moved into and when the tap
    /// saw the movement.
    init(entered: @escaping @MainActor (PointerGate.Entered, ContinuousClock.Instant) -> Void) {
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
            return
        }
        CGEvent.tapEnable(tap: port, enable: false)
        CFRunLoopAddSource(executor.runLoop, CFMachPortCreateRunLoopSource(nil, port, 0), .commonModes)
        pointerLog.notice("pointer tap created; Input Monitoring granted: \(CGPreflightListenEventAccess(), privacy: .public)")
    }

    /// The window the pointer was in at the last movement that counted.
    var window: UInt32? { gate.withLock { $0.window } }

    func setEnabled(_ on: Bool) {
        guard let port, enabled.exchange(on, ordering: .relaxed) != on else { return }
        // The window under the pointer counts as entered on the first movement.
        if on { gate.withLock { $0.reset() } }
        CGEvent.tapEnable(tap: port, enable: on)
        pointerLog.notice("focus follows mouse \(on ? "on" : "off", privacy: .public); tap enabled: \(CGEvent.tapIsEnabled(tap: port), privacy: .public)")
    }

    /// Kosmos moved the pointer (PointerGate.warped).
    func warped() {
        gate.withLock { $0.warped() }
    }

    /// The displays, to tell which one the pointer is on.
    func setMonitors(_ monitors: [Monitor]) {
        gate.withLock { $0.monitors = monitors }
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) {
        guard type == .mouseMoved else {
            // WindowServer turns off a tap whose thread falls behind.
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput, enabled.load(ordering: .relaxed), let port {
                pointerLog.notice("pointer tap turned off by WindowServer (\(type.rawValue)); turning it on again")
                CGEvent.tapEnable(tap: port, enable: true)
            }
            return
        }
        moved(over: UInt32(truncatingIfNeeded: event.getIntegerValueField(.mouseEventWindowUnderMousePointer)),
              at: event.location, control: event.flags.contains(.maskControl))
    }

    /// One movement to `location`, with `window` under the pointer.
    private func moved(over window: UInt32, at location: CGPoint, control: Bool) {
        let stamp = ContinuousClock.now
        if !heard.exchange(true, ordering: .relaxed) { pointerLog.notice("pointer tap receiving events") }
        guard let entered = gate.withLock({ $0.admit(window, at: location, control: control) }) else { return }
        let callback = self.entered
        DispatchQueue.main.async { MainActor.assumeIsolated { callback(entered, stamp) } }
    }
}
