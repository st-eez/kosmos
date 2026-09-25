import CoreGraphics
import KosmosCore
import Synchronization
import os

let dragLog = Logger(subsystem: "io.github.st-eez.kosmos", category: "drag")

/// Mouse button events for modifier drags (DESIGN.md, section 5.14), from an active event
/// tap on its own thread. It sits at the annotated session location, where WindowServer has
/// named the window under the pointer with its own hit test, so deciding a press queries no
/// window list. A DragGate decides each event under a lock that the main actor holds only
/// to hand it the modifiers and the windows, and the tap never waits on the main actor: a
/// press it takes, the drag's movements and the mouse up go to the main actor afterwards,
/// and never reach the app under the pointer. Every other event passes untouched.
///
/// An active tap needs Accessibility, which Kosmos has before it makes one.
final class DragTap: Sendable {
    private let executor = RunLoopExecutor(name: "kosmos.drag")
    /// Set once in `init`.
    private nonisolated(unsafe) var port: CFMachPort?
    private let gate = Mutex(DragGate())
    private let heard = Atomic<Bool>(false)
    private let began: @MainActor (DragGate.Grab, ContinuousClock.Instant) -> Void
    private let moved: @MainActor (Int) -> Void
    private let ended: @MainActor (DragGate.End) -> Void

    /// `began` runs on the main actor with a drag's press and when the tap saw it, `moved`
    /// with the number of a drag whose latest movement waits in `takeMovement`, and `ended`
    /// with a drag that ended. Nil when WindowServer refuses the tap.
    init?(began: @escaping @MainActor (DragGate.Grab, ContinuousClock.Instant) -> Void,
          moved: @escaping @MainActor (Int) -> Void,
          ended: @escaping @MainActor (DragGate.End) -> Void) {
        (self.began, self.moved, self.ended) = (began, moved, ended)
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

    /// Where the pointer last moved during drag `number` (DragGate.takeMovement).
    func takeMovement(of number: Int) -> CGPoint? {
        gate.withLock { $0.takeMovement(of: number) }
    }

    /// Whether Kosmos takes the event, so the app under the pointer never gets it.
    private func takes(_ type: CGEventType, _ event: CGEvent) -> Bool {
        let outcome: DragGate.Outcome
        switch type {
        case .leftMouseDown, .rightMouseDown:
            let window = WindowID(truncatingIfNeeded: event.getIntegerValueField(.mouseEventWindowUnderMousePointer))
            outcome = gate.withLock { $0.pressed(type == .leftMouseDown ? .left : .right, over: window, flags: event.flags, at: event.location) }
        case .leftMouseDragged, .rightMouseDragged:
            outcome = gate.withLock { $0.dragged(type == .leftMouseDragged ? .left : .right, to: event.location) }
        case .leftMouseUp, .rightMouseUp:
            outcome = gate.withLock { $0.released(type == .leftMouseUp ? .left : .right, at: event.location) }
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

    /// WindowServer turns off a tap whose thread falls behind, and events pass untouched
    /// until it is on again. A button whose mouse up passed meanwhile is up by then, and its
    /// drag ends where the pointer is. A mouse up missed otherwise ends its drag at the
    /// button's next press (DragGate.pressed).
    private func turnOnAgain(_ type: CGEventType) {
        dragLog.notice("drag tap turned off by WindowServer (\(type.rawValue)); turning it on again")
        guard let port else { return }
        CGEvent.tapEnable(tap: port, enable: true)
        let point = CGEvent(source: nil)?.location ?? .zero
        for button in gate.withLock({ $0.held }) {
            guard !CGEventSource.buttonState(.combinedSessionState, button: button == .left ? .left : .right) else { continue }
            post(gate.withLock { $0.released(button, at: point) })
        }
    }

    private func post(_ outcome: DragGate.Outcome) {
        let stamp = ContinuousClock.now
        let (began, moved, ended) = (self.began, self.moved, self.ended)
        // In this order: a press can end one drag and begin the next.
        if let end = outcome.ended { DispatchQueue.main.async { MainActor.assumeIsolated { ended(end) } } }
        if let grab = outcome.began { DispatchQueue.main.async { MainActor.assumeIsolated { began(grab, stamp) } } }
        if let number = outcome.moved { DispatchQueue.main.async { MainActor.assumeIsolated { moved(number) } } }
    }
}
