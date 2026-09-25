import AppKit
import KosmosCore
import KosmosSkyLight
import os

extension Controller {
    /// The tap is made again after a refusal, or when it predates an Input Monitoring grant
    /// (docs/focus-follows-mouse.md).
    func updatePointerTap() {
        let listening = CGPreflightListenEventAccess()
        if !listening { pointerListens = false }
        if wantsPointer, pointer == nil || (listening && !pointerListens) { makePointerTap(listening: listening) }
        pointer?.setEnabled(focusFollowsMouse.enabled)
        if wantsPointer, !listening { onInputMonitoringMissing?() }
    }

    func renewPointerTapAfterGrant() {
        guard CGPreflightListenEventAccess() else { pointerListens = false; return }
        guard wantsPointer, !pointerListens else { return }
        makePointerTap(listening: true)
        pointer?.setEnabled(true)
    }

    private func makePointerTap(listening: Bool) {
        pointer?.stop()
        pointer = PointerTap { [weak self] entered, stamp in self?.pointerEntered(entered, at: stamp) }
        pointer?.setMonitors(session.monitors)
        pointerListens = listening
    }

    /// Focuses at once, through the same path as a focus command (docs/focus-follows-mouse.md).
    private func pointerEntered(_ entered: PointerGate.Entered, at stamp: ContinuousClock.Instant) {
        // The pointer moved on before this ran. While a window is lifted the pointer is the user's.
        guard !sessionLocked, !dragging, pointer?.window == entered.window else { return }
        let window = entered.window
        let fullscreen = session.parkReason(of: window) == .fullscreen
        let skip = focusFollowsMouse.skip(window, in: session, fullscreen: fullscreen, key: key,
                                          app: owner[window].map(inventory.appIdentity), stale: reports.isStale(stamp))
        // Onto the desktop of a display whose workspace is empty, that workspace takes the
        // focus. Only then is the window's level read from WindowServer.
        let emptyWorkspace = skip == .notTiled ? entered.display.flatMap { display in
            focusFollowsMouse.emptyWorkspace(entered: display, overDesktop: window == 0 || SkyLight.rows([window]).first
                .map { FocusFollowsMouse.isDesktop(level: $0.level) } == true, in: session)
        } : nil
        if let skip, emptyWorkspace == nil {
            pointerLog.debug("pointer in \(window): \(String(describing: skip), privacy: .public)")
            return
        }
        if let holder = UserInput.keyHolderApartFromFront() {
            pointerLog.debug("""
                pointer in \(window): \(NSRunningApplication(processIdentifier: holder)?.localizedName ?? String(holder), privacy: .public) \
                holds the key window apart from the front app
                """)
            return
        }
        if let emptyWorkspace {
            guard let plan = session.perform(.workspace(.named(emptyWorkspace))) else { return }
            pointerLog.info("pointer focuses empty workspace \(emptyWorkspace, privacy: .public)")
            reports.commandExecuted(receivedAt: stamp)
            execute(plan, fromCommand: true)
            return
        }
        pointerLog.info("pointer focuses \(window)")
        // A command for the window, stamped when the pointer entered it, so the reports of
        // activations before it are stale.
        reports.commandExecuted(receivedAt: stamp)
        // A native fullscreen window stays parked, and the session's focus stays where it
        // was, as when the user clicks the window.
        if !fullscreen { session.adopt(window) }
        // The window is on screen under the pointer, so keying it takes no display out of a
        // native fullscreen Space.
        requestFocus(.window(window), fromCommand: true)
        publishState()
    }

    /// Only when the pointer is outside, as AeroSpace's `window-lazy-center`. The frame is the
    /// layout's or the inventory's, read from no other process (docs/focus-follows-mouse.md).
    func centerPointer() {
        guard !dragging else { return }
        let frame: CGRect? = if let window = session.focused {
            session.frames(of: session.focusedWorkspace)[window] ?? inventory.windows[window]?.frame
        } else {
            session.monitor(of: session.focusedWorkspace).frame
        }
        guard let frame, !frame.isEmpty, let location = CGEvent(source: nil)?.location, !frame.contains(location) else { return }
        CGWarpMouseCursorPosition(CGPoint(x: frame.midX, y: frame.midY))
        pointer?.warped()
    }

    func movesPointer(after change: FocusChange) -> Bool {
        change.movesPointer(mouseFollowsFocus: mouseFollowsFocus, reading: pointerReadings)
    }

    var pointerReadings: PointerReadings {
        PointerReadings(
            focusOnAnotherDisplay: { CGEvent(source: nil).map { self.session.focusIsOnAnotherDisplay(than: $0.location) } ?? false },
            leftButtonDown: { UserInput.leftButtonDown }, activation: { self.activation() })
    }

    private func activation() -> (input: ActivationInput, onDock: Bool) {
        let input = ActivationInput(key: UserInput.secondsSince(.keyDown), leftClick: UserInput.secondsSince(.leftMouseDown),
                                    rightClick: UserInput.secondsSince(.rightMouseDown), moved: UserInput.secondsSince(.mouseMoved))
        let dock = UserInput.isDock(clickedWindow)
        pointerLog.debug("""
            activation: key \(input.key, format: .fixed(precision: 3)) s ago, left click \(input.leftClick, format: .fixed(precision: 3)) s ago \
            \(dock ? "on" : "off", privacy: .public) the Dock, right click \(input.rightClick, format: .fixed(precision: 3)) s ago, \
            pointer moved \(input.moved, format: .fixed(precision: 3)) s ago
            """)
        return (input, dock)
    }
}
