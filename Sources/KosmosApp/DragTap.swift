import CoreGraphics
import KosmosCore
import Synchronization
import os

let dragLog = Logger(subsystem: "io.github.st-eez.kosmos", category: "drag")

/// Modifier drags' button events from an active tap at the annotated session location, where
/// WindowServer names the window under the pointer, so the tap never waits on the main actor
/// or reads a window list (docs/modifier-drags.md).
final class DragTap: Sendable {
    private let executor = RunLoopExecutor(name: "kosmos.drag")
    /// Set once in `init`.
    private nonisolated(unsafe) var port: CFMachPort?
    private let gate = Mutex(DragGate())
    private let heard = Atomic<Bool>(false)
    private let handle: @MainActor (DragGate.Outcome, ContinuousClock.Instant) -> Void

    init?(handle: @escaping @MainActor (DragGate.Outcome, ContinuousClock.Instant) -> Void) {
        self.handle = handle
        let types: [CGEventType] = [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseDown, .rightMouseDragged, .rightMouseUp]
        port = CGEvent.tapCreate(
            tap: .cgAnnotatedSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: types.reduce(0) { $0 | CGEventMask(1) << $1.rawValue },
            callback: { _, type, event, refcon in
                Unmanaged<DragTap>.fromOpaque(refcon!).takeUnretainedValue().takes(type, event) ? nil : Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque())
        let access = "Input Monitoring granted: \(CGPreflightListenEventAccess()), posting granted: \(CGPreflightPostEventAccess())"
        guard let port else {
            dragLog.error("drag tap not created; \(access, privacy: .public)")
            executor.stop()
            return nil
        }
        // Off until its thread's run loop serves it, so no event waits on a tap nobody reads.
        CGEvent.tapEnable(tap: port, enable: false)
        CFRunLoopAddSource(executor.runLoop, CFMachPortCreateRunLoopSource(nil, port, 0), .commonModes)
        executor.perform { [self] in
            if let port = self.port { CGEvent.tapEnable(tap: port, enable: true) }
        }
        dragLog.notice("drag tap created; \(access, privacy: .public)")
    }

    func setModifiers(_ modifiers: KeyCombo.Modifiers?) {
        gate.withLock { $0.modifiers = modifiers }
    }

    func setWindows(_ windows: Set<WindowID>) {
        gate.withLock { $0.windows = windows }
    }

    func setMonitors(_ monitors: [Monitor]) {
        gate.withLock { $0.monitors = monitors }
    }

    func endIfReleased() {
        let pointer = CGEvent(source: nil)?.location
        post(gate.withLock { $0.endIfReleased(hid: Self.hid, at: pointer) })
    }

    /// HID's state, as the combined session state also counts presses other processes post
    /// (docs/modifier-drags.md).
    private static func hid(_ button: DragButton) -> DragGate.ButtonState {
        let (mouse, down): (CGMouseButton, CGEventType) = button == .left ? (.left, .leftMouseDown) : (.right, .rightMouseDown)
        return DragGate.ButtonState(down: CGEventSource.buttonState(.hidSystemState, button: mouse),
                                    presses: CGEventSource.counterForEventType(.hidSystemState, eventType: down))
    }

    private func takes(_ type: CGEventType, _ event: CGEvent) -> Bool {
        let outcome: DragGate.Outcome
        switch type {
        case .leftMouseDown, .rightMouseDown:
            let window = WindowID(truncatingIfNeeded: event.getIntegerValueField(.mouseEventWindowUnderMousePointer))
            let number = event.getIntegerValueField(.mouseEventNumber)
            outcome = gate.withLock {
                $0.pressed(type == .leftMouseDown ? .left : .right, number: number, over: window, flags: event.flags,
                           at: event.location, hid: Self.hid)
            }
            // The live test reads this line: the gate is safe only if presses carry distinct
            // numbers and each up carries its press's (docs/modifier-drags.md).
            if outcome.began != nil { dragLog.info("modifier drag's press has event number \(number)") }
        case .leftMouseDragged, .rightMouseDragged:
            outcome = gate.withLock { $0.dragged(to: event.location) }
        case .leftMouseUp, .rightMouseUp:
            let number = event.getIntegerValueField(.mouseEventNumber)
            outcome = gate.withLock { $0.released(type == .leftMouseUp ? .left : .right, number: number, at: event.location) }
            if outcome.ended != nil, !outcome.take {
                dragLog.notice("mouse up \(number) is not the modifier drag's own: it ends the drag and passes on")
            }
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            turnOnAgain(type)
            return false
        default:
            return false
        }
        if !heard.exchange(true, ordering: .relaxed) { dragLog.notice("drag tap receiving events") }
        if let window = outcome.passedOver { dragLog.info("modifier press over \(window), which Kosmos does not manage: passed on") }
        post(outcome)
        return outcome.take
    }

    /// WindowServer turns off a tap that falls behind and passes every event, the one it
    /// waited for included, until the tap is on again (docs/modifier-drags.md).
    private func turnOnAgain(_ type: CGEventType) {
        dragLog.notice("drag tap turned off by WindowServer (\(type.rawValue)); turning it on again")
        guard let port else { return }
        if type == .tapDisabledByTimeout { post(gate.withLock { $0.timedOut() }) }
        CGEvent.tapEnable(tap: port, enable: true)
        endIfReleased()
    }

    /// In one main actor turn, as a press can end one drag and begin the next.
    private func post(_ outcome: DragGate.Outcome) {
        guard outcome.ended != nil || outcome.began != nil || outcome.moved != nil else { return }
        let stamp = ContinuousClock.now
        let handle = self.handle
        onMain { handle(outcome, stamp) }
    }
}
