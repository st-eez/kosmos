import AppKit
import KosmosCore
import Synchronization
import os

let pointerLog = Logger(subsystem: "io.github.st-eez.kosmos", category: "pointer")

/// Pointer movement for focus follows mouse (DESIGN.md, section 5.11), from an NSEvent
/// global monitor for mouse moved events, which asks for no Input Monitoring. The monitor
/// is removed while focus follows mouse is off, and a pointer at rest sends no events, so
/// neither costs anything.
///
/// The monitor delivers on the main thread. Each movement goes through a PointerGate, and
/// only a movement into another window or display with Control up goes on. The window under the
/// pointer is the one WindowServer annotated the event with, when the monitor's event
/// carries it, and otherwise WindowServer's hit test at the pointer. Only mouse moved
/// events are monitored: a movement with a button down is a drag, so nothing is focused
/// while a button is down.
final class PointerTap: Sendable {
    /// Used on the main actor only.
    private nonisolated(unsafe) var monitor: Any?
    private let gate = Mutex(PointerGate())
    private let heard = Atomic<Bool>(false)
    private let entered: @MainActor (PointerGate.Entered, ContinuousClock.Instant) -> Void

    /// `entered` runs on the main actor with what the pointer moved into and when the
    /// monitor saw the movement.
    init(entered: @escaping @MainActor (PointerGate.Entered, ContinuousClock.Instant) -> Void) {
        self.entered = entered
        pointerLog.notice("pointer monitor created; Input Monitoring granted: \(CGPreflightListenEventAccess(), privacy: .public)")
    }

    /// The window the pointer was in at the last movement that counted.
    var window: UInt32? { gate.withLock { $0.window } }

    @MainActor func setEnabled(_ on: Bool) {
        guard on != (monitor != nil) else { return }
        if on {
            // The window under the pointer counts as entered on the first movement.
            gate.withLock { $0.reset() }
            monitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
                MainActor.assumeIsolated { self?.moved(event) }
            }
        } else if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        if on, monitor == nil {
            pointerLog.error("focus follows mouse on; monitor not added")
        } else {
            pointerLog.notice("focus follows mouse \(on ? "on" : "off", privacy: .public); monitor added: \(self.monitor != nil, privacy: .public)")
        }
    }

    /// Kosmos moved the pointer (PointerGate.warped).
    func warped() {
        gate.withLock { $0.warped() }
    }

    /// The displays, to tell which one the pointer is on.
    func setMonitors(_ monitors: [Monitor]) {
        gate.withLock { $0.monitors = monitors }
    }

    @MainActor private func moved(_ event: NSEvent) {
        let annotated = event.cgEvent.map { UInt32(truncatingIfNeeded: $0.getIntegerValueField(.mouseEventWindowUnderMousePointer)) } ?? 0
        if !heard.exchange(true, ordering: .relaxed) {
            pointerLog.notice("pointer monitor receiving events; events name the window under the pointer: \(annotated != 0, privacy: .public)")
        }
        // A global event has no window, so its location is in screen coordinates, which the
        // hit test takes.
        let window = annotated != 0 ? annotated
            : UInt32(truncatingIfNeeded: NSWindow.windowNumber(at: event.locationInWindow, belowWindowWithWindowNumber: 0))
        // The event's CoreGraphics location has the top left origin the session's displays use.
        let location = event.cgEvent?.location ?? CGPoint(x: event.locationInWindow.x,
                                                           y: (NSScreen.screens.first?.frame.height ?? 0) - event.locationInWindow.y)
        moved(over: window, at: location, control: event.modifierFlags.contains(.control))
    }

    /// One movement to `location`, with `window` under the pointer.
    private func moved(over window: UInt32, at location: CGPoint, control: Bool) {
        let stamp = ContinuousClock.now
        guard let entered = gate.withLock({ $0.admit(window, at: location, control: control) }) else { return }
        let callback = self.entered
        DispatchQueue.main.async { MainActor.assumeIsolated { callback(entered, stamp) } }
    }
}
