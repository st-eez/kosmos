import CoreGraphics
import Synchronization
import os

private let pointerLog = Logger(subsystem: "io.github.st-eez.kosmos", category: "pointer")

/// Pointer movement for focus follows mouse (DESIGN.md, section 5.11), from a listen-only
/// event tap on its own thread. The tap is off while focus follows mouse is, and a pointer
/// at rest sends no events, so neither costs anything.
///
/// The tap sits where WindowServer has annotated each event with the window under the
/// pointer, found by its own hit test, so moving the pointer queries no window list. Only
/// a movement into another window with Control up goes on to the main actor. Only mouse
/// moved events are tapped: a movement with a button down is a drag, so nothing is focused
/// while a button is down.
///
/// On macOS 27 creating even this mouse-only tap asked a process without Input Monitoring
/// for it, and the tap stayed silent. Whether Kosmos's Accessibility grant is enough is
/// not known yet, so the tap is created only when focus follows mouse is first turned on.
/// The log says whether Input Monitoring is granted and when the first event arrives.
final class PointerTap: Sendable {
    private let executor = RunLoopExecutor(name: "kosmos.pointer")
    /// Set once in `init`.
    private nonisolated(unsafe) var port: CFMachPort?
    private let enabled = Atomic<Bool>(false)
    /// The window the last movement passed on entered, or 0 since the tap turned on.
    private let lastWindow = Atomic<UInt32>(0)
    /// Whether Control was held at the latest movement.
    private let controlAtLastMovement = Atomic<Bool>(false)
    private let heard = Atomic<Bool>(false)
    private let entered: @MainActor (UInt32) -> Void

    /// `entered` runs on the main actor with the window the pointer moved into.
    init(entered: @escaping @MainActor (UInt32) -> Void) {
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
            pointerLog.error("pointer tap not created")
            return
        }
        CGEvent.tapEnable(tap: port, enable: false)
        CFRunLoopAddSource(executor.runLoop, CFMachPortCreateRunLoopSource(nil, port, 0), .commonModes)
        pointerLog.notice("pointer tap created; Input Monitoring granted: \(CGPreflightListenEventAccess())")
    }

    /// Whether Control, which pauses focus follows mouse, was held at the latest movement.
    var paused: Bool { controlAtLastMovement.load(ordering: .relaxed) }

    func setEnabled(_ on: Bool) {
        guard let port, enabled.exchange(on, ordering: .relaxed) != on else { return }
        // The window under the pointer counts as entered on the first movement.
        if on { lastWindow.store(0, ordering: .relaxed) }
        CGEvent.tapEnable(tap: port, enable: on)
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) {
        guard type == .mouseMoved else {
            // WindowServer turns off a tap whose thread falls behind.
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput, enabled.load(ordering: .relaxed), let port {
                CGEvent.tapEnable(tap: port, enable: true)
            }
            return
        }
        if !heard.exchange(true, ordering: .relaxed) { pointerLog.notice("pointer tap receiving events") }
        let window = UInt32(truncatingIfNeeded: event.getIntegerValueField(.mouseEventWindowUnderMousePointer))
        // A movement with Control held still moves the pointer, so after Control is released
        // the next movement enters the window under it.
        let control = event.flags.contains(.maskControl)
        controlAtLastMovement.store(control, ordering: .relaxed)
        guard !control, lastWindow.exchange(window, ordering: .relaxed) != window else { return }
        let entered = self.entered
        DispatchQueue.main.async { MainActor.assumeIsolated { entered(window) } }
    }
}
