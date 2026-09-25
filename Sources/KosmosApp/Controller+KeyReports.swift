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
        if id == nil, report.pid == getpid() { emptyWorkspaceKeyed = .now }
        run(intake.heard(id.map(KeyWindow.window) ?? .noWindow, from: report.pid, receivedAt: report.received,
                         facts: reportFacts, reports: &reports, misses: &misses))
    }

    func windowPlaced(_ id: WindowID) {
        run(intake.placed(id, facts: reportFacts, reports: &reports, misses: &misses))
    }

    /// The intake holds `intake`, `reports` and `misses` while it runs these closures, so none
    /// of them may touch those.
    var reportFacts: KeyReportIntake.Facts {
        KeyReportIntake.Facts(
            workspace: { self.session.workspace(of: $0) }, isShown: { self.session.isShown($0) },
            isParked: { self.session.isParked($0) }, closedByApp: { self.closedByApp.contains($0) },
            wasConcealed: { self.hiding.wasConcealed($0, at: $1) }, leftScreen: { self.inventory.leftScreen($0) },
            app: { self.owner[$0] ?? self.inventory.windows[$0]?.pid },
            intent: session.intent, locked: sessionLocked, recovered: needsResync, mouseFollowsFocus: mouseFollowsFocus,
            leftButtonDown: { UserInput.leftButtonDown }, pickedAwayFromPointer: { self.pickedAwayFromPointer() },
            userPressedJustBefore: { UserInput.userPressedJustBefore() },
            launchedSinceEmptyWorkspaceKeyed: {
                NSRunningApplication(processIdentifier: $0)?.launchDate.map { $0 > self.emptyWorkspaceKeyed } == true
            },
            note: { self.log($0) })
    }

    private func run(_ action: KeyReportIntake.Action) {
        switch action {
        case .none:
            break
        case .requestFocus(let retry):
            requestFocus(session.intent, retry: retry)
        case .adopt(let window, let bringsPointer):
            session.adopt(window)
            touch(window)
            // A new generation, so a request still queued cannot key its window after the
            // user's choice (tla/Kosmos.tla, Adopt).
            requestFocus(.window(window))
            if bringsPointer { centerPointer() }
            publishState()
        case .follow(let window, let bringsPointer):
            touch(window)
            execute(session.follow(window), movePointer: bringsPointer)
        case .hold(let number):
            after(KeyReportIntake.grace) { controller in
                controller.run(controller.intake.expire(number, facts: controller.reportFacts, reports: &controller.reports))
            }
        case .keyEmptyWorkspaceAgain(let app):
            controllerLog.notice("\(self.inventory.appIdentity(app).name ?? String(app), privacy: .public) has no key window on an empty workspace; keying its window again")
            requestFocus(.noWindow)
        }
    }

    /// Every held report logs its outcome, to tell whether any report came before the first
    /// word of its departure.
    private func log(_ note: KeyReportIntake.Note) {
        func since(_ held: KeyReportIntake.Report) -> Double { (ContinuousClock.now - held.received).milliseconds }
        switch note {
        case .missed(let key, let miss):
            controllerLog.notice("focus request missed: \(String(describing: key), privacy: .public) again, \(String(describing: miss), privacy: .public)")
        case .verdict(let key, let verdict):
            controllerLog.debug("focus report \(String(describing: key), privacy: .public): \(String(describing: verdict), privacy: .public)")
        case .replaced(let held, let key):
            controllerLog.notice("""
                held focus report \(String(describing: held.key), privacy: .public): replaced by \
                \(String(describing: key), privacy: .public) after \(since(held), format: .fixed(precision: 3)) ms
                """)
        case .heldWindowLeft(let held):
            controllerLog.notice("held focus report \(String(describing: held.key), privacy: .public): dropped, its window left, after \(since(held), format: .fixed(precision: 3)) ms")
        case .heldMovedOn(let held, let key):
            controllerLog.notice("held focus report \(String(describing: held.key), privacy: .public): dropped, \(String(describing: key), privacy: .public) is key now, after \(since(held), format: .fixed(precision: 3)) ms")
        case .heldDecided(let held, let previous, let left, let at):
            controllerLog.notice("""
                held focus report \(String(describing: held.key), privacy: .public): \
                \(previous) \(left ? "left" : "stayed", privacy: .public) after \((at - held.received).milliseconds, format: .fixed(precision: 3)) ms
                """)
        }
    }
}
