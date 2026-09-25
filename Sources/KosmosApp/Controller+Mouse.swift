import AppKit
import KosmosCore
import os

extension Controller {
    /// Judged as of `changedAt`, as the inventory applies a change after an off main read.
    /// The key tiled window lifts only once it moved whole past TitleBarDrag.dragThreshold, so
    /// a click that jitters the title bar does not lift it (docs/geometry.md, docs/displays.md).
    func frameChanged(_ id: WindowID, from old: CGRect, to frame: CGRect, changedAt: ContinuousClock.Instant?) {
        guard managing, !sessionLocked, !ledger.isWriting(id), !hiding.isConcealed(id),
              let name = session.workspace(of: id), session.isShown(name), !session.isParked(id) else { return }
        if let changedAt, ledger.isWriting(id, at: changedAt) {
            ledger.observeAfterConfirm(id, frame: frame)
            return
        }
        let button = changedAt.map { leftButton.state(at: $0) } ?? .up
        // The user moves or resizes it, unless the change is its own write landing after the
        // read back, as the other tiles' reflow at a lift lands while the user drags.
        if button != .up { slides?.changedInPress(id, to: frame) }
        ledger.observe(id, frame: frame)
        // Seen smaller than its minimum, the window loses it. During a press, the mouse up
        // lays its workspace out.
        let smaller = session.sizeObserved(id, frame.size)
        if !smaller.isEmpty { controllerLog.notice("\(id) seen at \(Int(frame.width))x\(Int(frame.height)), below its minimum") }
        guard button != .up else {
            if !smaller.isEmpty { execute(smaller) }
            return
        }
        if session.shownFloatingWindows.contains(id) {
            guard key == .window(id), let plan = session.dragged(id, to: frame) else { return }
            controllerLog.info("\(id) dragged to workspace \(self.session.workspace(of: id) ?? "?", privacy: .public)")
            execute(plan)
            return
        }
        guard button == .down else {
            // The mouse up sent back what the press had moved by then, each with a write this
            // change would count as, so this window was not among them.
            controllerLog.info("\(id) changed during a press that has ended goes back to its tile")
            ledger.forget(id)
            execute(session.released([id]))
            return
        }
        let press = mouseMoved[id]
        let before = press?.before ?? old
        // WindowServer can apply a resize by the left or top edge as a move first, so the
        // pointer on a resize border marks one too. Read here, as reading it as each event
        // came would read it at every change event a switch posts.
        let onBorder = press == nil && CGEvent(source: nil).map { TitleBarDrag.onResizeBorder($0.location, of: frame) } == true
        let resized = press?.resized == true || onBorder || frame.size != before.size
        if !resized, key == .window(id), hypot(frame.minX - before.minX, frame.minY - before.minY) > TitleBarDrag.dragThreshold,
           let plan = session.lift(id) {
            mouseMoved[id] = nil
            controllerLog.info("\(id) lifted from workspace \(name, privacy: .public)")
            execute(plan)
        } else {
            mouseMoved[id] = (before, resized)
        }
    }

    /// A hotkey ends a drag where the pointer is before its command runs, as Hyprland does
    /// (docs/displays.md and docs/modifier-drags.md).
    func endDrag() {
        dragTap?.endIfReleased()
        if modifierDrag != nil {
            controllerLog.info("hotkey during a modifier drag: it ends where the pointer is")
            return finishDrag(at: nil)
        }
        guard dragging else { return }
        controllerLog.info("hotkey during a drag: the window drops where the pointer is")
        leftMouseUp(at: nil)
    }

    func watchLeftButton() {
        // AppKit calls a global monitor's handler on the main thread.
        _ = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let point = event.cgEvent?.location else { return }
            // A global event has no window, so its location is on the screen.
            let location = event.locationInWindow
            MainActor.assumeIsolated { self?.leftMouseDown(at: point, location: location) }
        }
        _ = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            let point = event.cgEvent?.location
            MainActor.assumeIsolated { self?.leftMouseUpHeard(at: point) }
        }
    }

    /// `location` is `point` in AppKit's coordinates. kosmos_make_key posts a mouse down far
    /// past every display with no mouse up, so a press off every display is left out. The
    /// window clicked is found as the press lands: an autohiding Dock can hide before its app
    /// reports a key window (docs/focus-follows-mouse.md).
    private func leftMouseDown(at point: CGPoint, location: NSPoint) {
        // The live test reads whether the monitor hears a press the drag tap took. During a
        // right drag the left button's presses reach the app and count here.
        guard modifierDrag?.grab.button != .left else {
            controllerLog.info("left mouse down heard during a left modifier drag: left out")
            return
        }
        var display: CGDirectDisplayID = 0, count: UInt32 = 0
        let onDisplay = CGGetDisplaysWithPoint(point, 1, &display, &count) == .success && count > 0
        controllerLog.debug("left mouse down at \(point.x), \(point.y)\(onDisplay ? "" : ", off every display: left out", privacy: .public)")
        clickedWindow = 0
        guard onDisplay else { return }
        leftButton.pressed(at: .now)
        if mouseFollowsFocus { clickedWindow = NSWindow.windowNumber(at: location, belowWindowWithWindowNumber: 0) }
    }

    /// At a lock and a resync: a press whose mouse up Kosmos never heard would count as on
    /// until the next click. The resync lays out the windows the presses moved.
    func forgetPresses() {
        leftButton = LeftButton()
        mouseMoved = [:]
        modifierDrag = nil
        dragTap?.endIfReleased()
    }

    /// During a left modifier drag its own end drops the window (finishDrag), so a mouse up
    /// heard here drops nothing twice.
    private func leftMouseUpHeard(at point: CGPoint?) {
        leftButton.released(at: .now)
        guard modifierDrag?.grab.button != .left else {
            controllerLog.info("left mouse up heard during a left modifier drag: left out")
            return
        }
        leftMouseUp(at: point)
    }

    /// `point`: nil for where the pointer is.
    private func leftMouseUp(at point: CGPoint?) {
        guard managing, !sessionLocked else { return }
        let moved = Set(mouseMoved.keys)
        let released = session.lifted.union(moved)
        guard !released.isEmpty else { return }
        mouseMoved = [:]
        // Whole frame writes: the ledger holds a lifted window's frame from before the drag,
        // and a resize can have gone on past the last frame it heard of.
        for id in released { ledger.forget(id) }
        if !session.lifted.isEmpty, let point = point ?? CGEvent(source: nil)?.location {
            let dropped = session.lifted
            let plan = session.drop(at: point)
            controllerLog.info("dropped \(dropped.sorted().map(String.init).joined(separator: " "), privacy: .public) at \(Int(point.x)), \(Int(point.y))")
            execute(plan)
        }
        if !moved.isEmpty {
            controllerLog.info("left mouse up: \(moved.count) tiled windows moved or resized with the button down go back to their tiles")
            execute(session.released(moved))
        }
    }

    // MARK: Modifier drags

    /// Turned off at a reload, the tap stays and begins no drag (docs/modifier-drags.md).
    func updateDragTap() {
        if dragTap == nil, managing, mouseModifier != nil {
            dragTap = DragTap { [weak self] outcome, stamp in self?.dragHeard(outcome, at: stamp) }
            dragTap?.setWindows(draggable)
            dragTap?.setMonitors(session.monitors)
        }
        dragTap?.setModifiers(mouseModifier)
    }

    var draggable: Set<WindowID> { Set(session.shownWorkspaces.flatMap { session.windows(of: $0) }) }

    /// Each movement is carried as it comes, and AppWorker merges the writes a busy app has not
    /// taken yet (docs/modifier-drags.md).
    private func dragHeard(_ outcome: DragGate.Outcome, at stamp: ContinuousClock.Instant) {
        if let end = outcome.ended { dragEnded(end) }
        if let grab = outcome.began { dragBegan(grab, at: stamp) }
        if let point = outcome.moved, modifierDrag != nil {
            dragLog.debug("movement carried \((ContinuousClock.now - stamp).milliseconds, format: .fixed(precision: 3)) ms after the tap saw it")
            carryDrag(to: point)
        }
    }

    /// The window takes the focus, as Hyprland's dragBegin does, through a command stamped when
    /// the tap saw the press. A press on a window no longer tiled or floating on a shown
    /// workspace is taken all the same.
    private func dragBegan(_ grab: DragGate.Grab, at stamp: ContinuousClock.Instant) {
        guard let frame = inventory.windows[grab.window]?.frame, let drag = session.beginDrag(grab, frame: frame) else {
            dragLog.info("modifier press on \(grab.window): no tiled or floating window of a shown workspace, nothing to drag")
            return
        }
        modifierDrag = drag
        slides?.end(grab.window, "as a modifier drag took it")
        // A Dock click before this press no longer brings the pointer (ActivationInput.bringsPointer).
        clickedWindow = 0
        dragLog.info("""
            modifier drag of \(grab.window) with the \(grab.button == .left ? "left" : "right", privacy: .public) button, \
            \(drag.floating ? "floating" : "tiled", privacy: .public), edges \(String(describing: drag.edges), privacy: .public)
            """)
        reports.commandExecuted(receivedAt: stamp)
        session.adopt(grab.window)
        requestFocus(.window(grab.window), fromCommand: true)
        publishState()
    }

    /// Each movement writes frames and nothing else, as a plan would read the floating
    /// windows' frames from WindowServer each time (bringFloatingHome).
    private func carryDrag(to point: CGPoint) {
        guard var drag = modifierDrag else { return }
        let window = drag.grab.window
        // Gone from the screen since, it is no longer the user's to drag.
        guard session.lifted.contains(window) || session.isVisible(window) else {
            dragLog.info("\(window) left during its modifier drag")
            modifierDrag = nil
            return
        }
        guard let delta = drag.delta(to: point) else { return }
        modifierDrag = drag
        switch drag.grab.button {
        case .left:
            if !drag.floating, !session.lifted.contains(window) {
                guard let plan = session.lift(window) else {
                    modifierDrag = nil
                    return
                }
                dragLog.info("\(window) lifted from workspace \(self.session.workspace(of: window) ?? "?", privacy: .public)")
                execute(plan)
            }
            writeDragFrame(drag, drag.moved(by: delta))
        case .right:
            if drag.floating {
                writeDragFrame(drag, session.resized(drag, by: delta))
            } else if let plan = session.dragEdges(drag, by: delta) {
                writeFrames(plan.frames)
            }
        }
    }

    private func writeDragFrame(_ drag: ModifierDrag, _ frame: CGRect) {
        writeFrames([drag.grab.window: frame])
        guard drag.floating, let plan = session.dragged(drag.grab.window, to: frame) else { return }
        dragLog.info("\(drag.grab.window) dragged to workspace \(self.session.workspace(of: drag.grab.window) ?? "?", privacy: .public)")
        execute(plan)
    }

    /// Also for a mouse up the tap missed, or a press WindowServer passed on (DragGate.timedOut).
    private func dragEnded(_ end: DragGate.End) {
        guard modifierDrag?.grab == end.grab else { return }
        carryDrag(to: end.point)
        finishDrag(at: end.point)
    }

    private func finishDrag(at point: CGPoint?) {
        guard let drag = modifierDrag else { return }
        modifierDrag = nil
        if session.lifted.contains(drag.grab.window) { leftMouseUp(at: point) }
        publishState()
    }
}
