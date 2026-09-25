import CoreGraphics
import KosmosCore
import Synchronization
import os

let dragLog = Logger(subsystem: "io.github.st-eez.kosmos", category: "drag")

/// Mouse button events for modifier drags (docs/modifier-drags.md), from an active event
/// tap on its own thread. It sits at the annotated session location, where WindowServer has
/// named the window under the pointer with its own hit test, so deciding a press reads no
/// window list. A DragGate decides each event under a lock that the main actor holds only
/// to hand it the modifiers, windows and displays and to end a drag whose press is over,
/// and the tap never waits on the main actor: what a taken event means goes to the main
/// actor afterwards, and the event never reaches the app under the pointer. Every other
/// event passes untouched.
///
/// An active tap needs Accessibility, which Kosmos has before it makes one.
final class DragTap: Sendable {
    private let executor = RunLoopExecutor(name: "kosmos.drag")
    /// Set once in `init`.
    private nonisolated(unsafe) var port: CFMachPort?
    private let gate = Mutex(DragGate())
    private let heard = Atomic<Bool>(false)
    private let handle: @MainActor (DragGate.Outcome, ContinuousClock.Instant) -> Void

    /// `handle` runs on the main actor with each outcome that ends, begins or moves a drag,
    /// and when the tap saw its event. Nil when WindowServer refuses the tap.
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

    /// The modifiers that begin a drag, or nil to begin none.
    func setModifiers(_ modifiers: KeyCombo.Modifiers?) {
        gate.withLock { $0.modifiers = modifiers }
    }

    /// The windows a press may take: the tiled and floating windows of the shown workspaces.
    func setWindows(_ windows: Set<WindowID>) {
        gate.withLock { $0.windows = windows }
    }

    func setMonitors(_ monitors: [Monitor]) {
        gate.withLock { $0.monitors = monitors }
    }

    /// Ends the gate's drag if its press is over by now, where the pointer is
    /// (DragGate.endIfReleased). A drag whose press is still held goes on to its mouse up,
    /// which the tap takes.
    func endIfReleased() {
        let pointer = CGEvent(source: nil)?.location
        post(gate.withLock { $0.endIfReleased(hid: Self.hid, at: pointer) })
    }

    /// A mouse button as HID reads it now. HID's state holds the presses of the mouse and
    /// trackpad; the combined session state holds those other processes post as well, which
    /// would read as presses newer than the drag's (docs/modifier-drags.md).
    private static func hid(_ button: DragButton) -> DragGate.ButtonState {
        let (mouse, down): (CGMouseButton, CGEventType) = button == .left ? (.left, .leftMouseDown) : (.right, .rightMouseDown)
        return DragGate.ButtonState(down: CGEventSource.buttonState(.hidSystemState, button: mouse),
                                    presses: CGEventSource.counterForEventType(.hidSystemState, eventType: down))
    }

    /// Whether Kosmos takes the event, so the app under the pointer never gets it.
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
            // The live test reads these: the gate is safe only if presses carry distinct
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

    /// WindowServer turns off a tap whose thread falls behind, passes on the event it waited
    /// for, and passes every event until the tap is on again. A drag whose press it passed
    /// ends, so the app gets the rest of that press (DragGate.timedOut), and a drag whose
    /// press is over by now ends where the pointer is.
    private func turnOnAgain(_ type: CGEventType) {
        dragLog.notice("drag tap turned off by WindowServer (\(type.rawValue)); turning it on again")
        guard let port else { return }
        if type == .tapDisabledByTimeout { post(gate.withLock { $0.timedOut() }) }
        CGEvent.tapEnable(tap: port, enable: true)
        endIfReleased()
    }

    /// Hands the main actor what an outcome ends, begins and moves, in one turn and in that
    /// order: a press can end one drag and begin the next.
    private func post(_ outcome: DragGate.Outcome) {
        guard outcome.ended != nil || outcome.began != nil || outcome.moved != nil else { return }
        let stamp = ContinuousClock.now
        let handle = self.handle
        onMain { handle(outcome, stamp) }
    }
}
