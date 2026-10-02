import AppKit
import KosmosCore
import os

extension Controller {
    /// Never the key window, but it can be Kosmos's echo. It leaves the kill switch's count
    /// alone, as a raise says nothing about the key record (tla/README.md, change 17).
    func backgroundFocusChanged(_ id: WindowID?, report: AXReport) {
        guard !sessionLocked else { return }
        run(intake.heardInBackground(id.map(KeyWindow.window) ?? .noWindow, from: report.pid, receivedAt: report.received,
                                     activationRead: report.activationRead, intent: session.intent, reports: &reports))
    }

    func focusedWindowChanged(_ id: WindowID?, report: AXReport) {
        if id == nil, report.pid == getpid() { emptyWorkspaceKeyed = .now }
        run(intake.heard(id.map(KeyWindow.window) ?? .noWindow, from: report.pid, receivedAt: report.received,
                         activationRead: report.activationRead, facts: reportFacts, reports: &reports, misses: &misses))
    }

    func windowPlaced(_ id: WindowID) {
        run(intake.placed(id, facts: reportFacts, reports: &reports, misses: &misses))
    }

    /// The intake holds `intake`, `reports` and `misses` while it runs these closures, so none
    /// of them may touch those.
    var reportFacts: KeyReportIntake.Facts {
        KeyReportIntake.Facts(
            workspace: { self.session.workspace(of: $0) }, isShown: { self.session.isShown($0) },
            isParked: { self.session.isParked($0) }, closedByApp: { self.session.parkReason(of: $0) == .closedByApp },
            wasConcealed: { self.hiding.wasConcealed($0, at: $1) }, leftScreen: { self.inventory.leftScreen($0) },
            app: { self.owner[$0] ?? self.inventory.windows[$0]?.pid },
            intent: session.intent, locked: sessionLocked, recovered: needsResync, mouseFollowsFocus: mouseFollowsFocus,
            pointer: pointerReadings,
            userPressedJustBefore: { UserInput.userPressedJustBefore() },
            launchedSinceEmptyWorkspaceKeyed: {
                NSRunningApplication(processIdentifier: $0)?.launchDate.map { $0 > self.emptyWorkspaceKeyed } == true
            },
            userCause: { self.userCause(of: $0, at: $1) },
            note: { self.log($0) })
    }

    /// Only with Input Monitoring, which a listen-only tap for keys needs, so Kosmos never asks
    /// for it here (docs/focus.md).
    func makeInputTap() {
        guard inputTap == nil, managing, CGPreflightListenEventAccess() else { return }
        inputTap = InputTap()
    }

    /// Why a change `app` made at `stamp` is the user's, or nil when no input of his could have.
    func userCause(of app: pid_t, at stamp: ContinuousClock.Instant) -> OwnInput.Cause? {
        guard let inputTap else { return .unheard }
        return inputTap.cause(of: app, at: stamp)
    }

    func run(_ action: KeyReportIntake.Action) {
        switch action {
        case .none:
            break
        case .requestFocus(let retry):
            requestFocus(session.intent, retry: retry)
        case .adopt(let window, let bringsPointer):
            let plan = session.adopt(window)
            touch(window)
            // A new generation, so a request still queued cannot key its window after the
            // user's choice (tla/Kosmos.tla, Adopt).
            requestFocus(.window(window))
            if bringsPointer { centerPointer() }
            // The pointer went where the floating check puts a floating window.
            execute(plan, floatingCheck: bringsPointer && session.isFloating(window))
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

    private func log(_ note: KeyReportIntake.Note) {
        func since(_ held: KeyReportIntake.Report) -> Double { (ContinuousClock.now - held.received).milliseconds }
        switch note {
        case .missed(let key, let miss):
            controllerLog.notice("focus request missed: \(String(describing: key), privacy: .public) again, \(String(describing: miss), privacy: .public)")
        case .verdict(let key, let verdict, let activationRead):
            controllerLog.debug("focus report \(String(describing: key), privacy: .public)\(activationRead ? " (activation read)" : "", privacy: .public): \(String(describing: verdict), privacy: .public)")
        case .replaced(let held, let key):
            controllerLog.notice("""
                held focus report \(String(describing: held.key), privacy: .public): replaced by \
                \(String(describing: key), privacy: .public) after \(since(held), format: .fixed(precision: 3)) ms
                """)
        case .heldWindowLeft(let held):
            controllerLog.notice("held focus report \(String(describing: held.key), privacy: .public): dropped, its window left, after \(since(held), format: .fixed(precision: 3)) ms")
        case .heldWhileLocked(let held):
            controllerLog.notice("held focus report \(String(describing: held.key), privacy: .public): dropped, the session is locked, after \(since(held), format: .fixed(precision: 3)) ms")
        case .heldDecided(let held, let previous, let left, let at):
            controllerLog.notice("""
                held focus report \(String(describing: held.key), privacy: .public): \
                \(previous) \(left ? "left" : "stayed", privacy: .public) after \((at - held.received).milliseconds, format: .fixed(precision: 3)) ms
                """)
        case .followed(let report, let cause):
            controllerLog.notice("""
                following \(String(describing: report.key), privacy: .public) of \(self.appName(report.reporter), privacy: .public): \
                \(self.describe(cause), privacy: .public)
                """)
        case .notTheUsers(let report):
            controllerLog.notice("""
                \(String(describing: report.key), privacy: .public) of \(self.appName(report.reporter), privacy: .public) \
                came with no key or click of the user's: its workspace stays hidden and the focus goes back
                """)
        }
    }

    func appName(_ pid: pid_t) -> String {
        NSRunningApplication(processIdentifier: pid)?.localizedName ?? processName(pid)
    }

    /// The input behind a follow, for the log.
    private func describe(_ cause: OwnInput.Cause) -> String {
        func press(_ press: OwnInput.Press) -> String {
            switch press {
            case .key(let pid): "a key to \(appName(pid))"
            case .click(let pid): "a click on \(appName(pid))"
            case .unseenKey: "a key the input tap never saw (a hotkey, or Secure Input)"
            }
        }
        func ms(_ ago: Duration) -> String { String(format: "%.0f ms", ago.milliseconds) }
        return switch cause {
        case .inApp(let made, let ago): "\(press(made)) \(ms(ago)) before"
        case .opener(let made, let ago, let beforeLaunch): "\(press(made)) \(ms(ago)) before \(beforeLaunch ? "its launch" : "it")"
        case .unheard: "the input tap hears nothing, so every change counts as the user's"
        }
    }
}
