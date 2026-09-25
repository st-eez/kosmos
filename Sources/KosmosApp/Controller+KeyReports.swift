import AppKit
import KosmosCore
import os

extension Controller {
    /// Never the key window, but it can be Kosmos's echo. It leaves the kill switch's count
    /// alone, as a raise says nothing about the key record (tla/README.md, change 17).
    func backgroundFocusChanged(_ id: WindowID?, report: AXReport) {
        guard !sessionLocked else { return }
        _ = reports.consumeEcho(id.map(KeyWindow.window) ?? .noWindow, receivedAt: report.received)
    }

    func focusedWindowChanged(_ id: WindowID?, report: AXReport) {
        let reported: KeyWindow = id.map(KeyWindow.window) ?? .noWindow
        let repeated = key == reported
        let previous: WindowID? = if case .window(let window)? = keyHistory.heard(reported), window != id { window } else { nil }
        if id == nil, report.pid == getpid() { emptyWorkspaceKeyed = .now }
        guard !sessionLocked else { return }   // resync requests the intent again
        admittedUnkeyed = admittedUnkeyed.filter { report.received - $0.value < Self.keyAfterAdmission }
        let keyedAfterAdmission = id.flatMap { admittedUnkeyed.removeValue(forKey: $0) } != nil
        // The report a departure waited for, unless it is Kosmos's echo: a window keyed
        // during a minimize's animation leaves macOS nothing to key when it ends.
        if let previous, awaitingKey?.window == previous, !reports.isEcho(reported, receivedAt: report.received) {
            awaitingKey = nil
        }
        let miss = reports.miss(reported, app: id.flatMap { owner[$0] ?? inventory.windows[$0]?.pid },
                                repeated: repeated, receivedAt: report.received)
        if miss != .none {
            controllerLog.notice("focus request missed: \(String(describing: reported), privacy: .public) again, \(String(describing: miss), privacy: .public)")
        }
        // An unmanaged window's focus is its own, and a parked one is key in its fullscreen
        // Space or just before it returns. A window with no place, or closed and kept, is
        // decided when it takes one.
        if let id, session.workspace(of: id) == nil || session.isParked(id) {
            unplacedKey = session.workspace(of: id) == nil || closedByApp.contains(id)
                ? KeyReport(key: reported, received: report.received, reporter: report.pid, previous: previous,
                            concealed: false, miss: miss) : nil
            // Kosmos keyed a native fullscreen window, as for hover focus: this is its echo.
            if session.isParked(id), reports.consumeEcho(reported, receivedAt: report.received) {
                misses.reported(reported, pid: report.pid, receivedAt: report.received, echo: true)
            }
            return
        }
        unplacedKey = nil
        if held.holds(reported, repeated: repeated) { return }
        // Whether the key window before this report just left the screen is read only when
        // the verdict needs it, as the read can wait on a switch's Space transaction.
        // Concealment is judged at the stamp (docs/focus.md; tla/README.md, change 22).
        let placed = id.flatMap { placedHidden.removeValue(forKey: $0) }
        decidePlaced(KeyReport(key: reported, received: report.received, reporter: report.pid, previous: previous,
                               concealed: placed != nil || id.map { hiding.wasConcealed($0, at: report.received) } ?? false,
                               miss: miss, admitted: keyedAfterAdmission || placed == .admitted),
                     keyLeft: placed != nil ? .stayed : previous.map { inventory.leftScreen($0) ? .left : .unknown } ?? .stayed)
    }

    struct KeyReport {
        let key: KeyWindow
        let received: ContinuousClock.Instant
        let reporter: pid_t
        /// The key window before it, when that was another window.
        let previous: WindowID?
        /// At the report's stamp.
        var concealed: Bool
        let miss: Miss
        /// Its app keyed it as Kosmos admitted it after launch, so following or adopting it
        /// brings the pointer (docs/focus-follows-mouse.md).
        var admitted = false
    }

    /// How long a report waits to learn whether the key window before it left: WindowServer
    /// ordered a hidden app's window out 17 ms after the hide (docs/tree.md). Every follow
    /// of a Command-Tab waits this long.
    private static let grace: Duration = .milliseconds(100)

    func decidePlaced(_ report: KeyReport, keyLeft: @autoclosure () -> Departure) {
        let echo = reports.isEcho(report.key, receivedAt: report.received)
        misses.reported(report.key, pid: report.reporter, receivedAt: report.received, echo: echo)
        if !echo { reports.publicRequestsAnswered(by: report.reporter, receivedAt: report.received) }
        decide(report, keyLeft: keyLeft())
    }

    /// A report whose verdict waits on a departure is held until it arrives or the grace ends
    /// (tla/Kosmos.tla, Adopt and Hold).
    private func decide(_ report: KeyReport, keyLeft: @autoclosure () -> Departure) {
        let id: WindowID? = if case .window(let window) = report.key { window } else { nil }
        // After a failed batch, recovery showed the windows of hidden workspaces, so a click
        // reaches them (needsResync).
        let verdict = reports.classify(report.key, receivedAt: report.received,
                                       onShownWorkspace: id.flatMap(session.workspace(of:)).map(session.isShown) ?? false,
                                       concealed: report.concealed, recovered: needsResync, miss: report.miss, keyLeft: keyLeft())
        controllerLog.debug("focus report \(String(describing: report.key), privacy: .public): \(String(describing: verdict), privacy: .public)")
        if id != nil, verdict != .echo, let ended = held.end() {
            controllerLog.notice("""
                held focus report \(String(describing: ended.key), privacy: .public): replaced by \
                \(String(describing: report.key), privacy: .public) after \((ContinuousClock.now - ended.received).milliseconds, format: .fixed(precision: 3)) ms
                """)
        }
        switch verdict {
        case .echo:
            break
        case .ignore:
            // macOS or an app fronted an app with no key window on an empty workspace: the
            // empty workspace keys its window again, so Cmd-Q reaches no app. After a click, a
            // Command-Tab or an app's launch it is the user's choice (docs/focus.md).
            guard report.key == .noWindow, report.reporter != getpid(), session.focused == nil, !UserInput.userPressedJustBefore(),
                  NSRunningApplication(processIdentifier: report.reporter)?.launchDate.map({ $0 > emptyWorkspaceKeyed }) != true
            else { break }
            controllerLog.notice("\(self.inventory.appIdentity(report.reporter).name ?? String(report.reporter), privacy: .public) has no key window on an empty workspace; keying its window again")
            requestFocus(.noWindow)
        case .undecided:
            let number = held.hold(report, of: report.key)
            after(Self.grace) { controller in
                if let report = controller.held.expire(number) { controller.decideHeld(report) }
            }
        case .reassert:
            requestFocus(session.intent, retry: report.miss == .retry)
        case .adopt(let window):
            session.adopt(window)
            touch(window)
            // A new generation, so a request still queued cannot key its window after the
            // user's choice (tla/Kosmos.tla, Adopt).
            requestFocus(.window(window))
            // Command-Tab or a Dock click brings the pointer, and a click on the window leaves
            // it (docs/focus-follows-mouse.md).
            if mouseFollowsFocus, report.admitted ? !UserInput.leftButtonDown : pickedAwayFromPointer() { centerPointer() }
            publishState()
        case .follow(let window):
            touch(window)
            // The pointer goes to a window Command-Tab, a launcher or a Dock click names, on its
            // own display too, and to a new window admitted to a hidden workspace
            // (docs/focus-follows-mouse.md).
            let plan = session.follow(window)
            execute(plan, movePointer: mouseFollowsFocus && (report.admitted ? !UserInput.leftButtonDown : pickedAwayFromPointer()))
        }
    }

    /// Every outcome is logged, to tell whether any report came before the first word of its
    /// departure.
    private func decideHeld(_ report: KeyReport) {
        let after = (ContinuousClock.now - report.received).milliseconds
        if case .window(let id) = report.key, session.workspace(of: id) == nil || session.isParked(id) {
            controllerLog.notice("held focus report \(String(describing: report.key), privacy: .public): dropped, its window left, after \(after, format: .fixed(precision: 3)) ms")
            return
        }
        // A later report moved the key window on, as Kosmos's own echo does when an app it
        // activated keys its last key window first and then the requested one.
        if report.key != key {
            controllerLog.notice("held focus report \(String(describing: report.key), privacy: .public): dropped, \(String(describing: self.key), privacy: .public) is key now, after \(after, format: .fixed(precision: 3)) ms")
            return
        }
        guard let previous = report.previous else { return }
        let left = inventory.leftScreen(previous)
        controllerLog.notice("""
            held focus report \(String(describing: report.key), privacy: .public): \
            \(previous) \(left ? "left" : "stayed", privacy: .public) after \(after, format: .fixed(precision: 3)) ms
            """)
        decide(report, keyLeft: left ? .left : .stayed)
    }
}
