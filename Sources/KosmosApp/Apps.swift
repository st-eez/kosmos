import AppKit
import CKosmos
import os

private let appsLog = Logger(subsystem: "io.github.st-eez.kosmos", category: "apps")

@MainActor
final class Apps {
    private var workers: [pid_t: AppWorker] = [:]
    /// Kept from each app's NSRunningApplication, as NSRunningApplication(processIdentifier:)
    /// returned nil for a running app at startup (docs/inventory.md).
    private var identities: [pid_t: (bundleID: String?, name: String?)] = [:]
    private let report: @MainActor (AXReport) -> Void

    init(report: @escaping @MainActor (AXReport) -> Void) {
        self.report = report
    }

    func start() {
        // Covers the elements copied out of an app's attributes too (docs/geometry.md).
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), AppWorker.timeout)
        for app in NSWorkspace.shared.runningApplications { add(app) }
        // The key window at launch produces no notification; ask for it.
        if let front = NSWorkspace.shared.frontmostApplication { activated(front.processIdentifier, received: .now) }
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated { self?.add(app) }
        }
        center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            MainActor.assumeIsolated { self?.remove(pid) }
        }
        center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            let received = ContinuousClock.now
            MainActor.assumeIsolated { self?.activated(pid, received: received) }
        }
    }

    func worker(_ pid: pid_t) -> AppWorker? { workers[pid] }

    func identity(_ pid: pid_t) -> (bundleID: String?, name: String?)? { identities[pid] }

    private func add(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard app.activationPolicy == .regular, workers[pid] == nil else { return }
        let name = app.localizedName ?? String(pid)
        let worker = AppWorker(pid: pid, name: name, report: report)
        workers[pid] = worker
        identities[pid] = (app.bundleIdentifier, app.localizedName)
        Task {
            // Apps answer Accessibility some time after launch (docs/inventory.md).
            for attempt in 1...10 {
                if await worker.start() {
                    appsLog.debug("\(name, privacy: .public) observed after \(attempt) attempts")
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
            let reason = await worker.startFailure
            appsLog.error("\(name, privacy: .public) did not start in 1 s (\(reason, privacy: .public)); asking every 0.5 s")
            await worker.askLater()
        }
    }

    private func remove(_ pid: pid_t) {
        identities[pid] = nil
        guard let worker = workers.removeValue(forKey: pid) else { return }
        Task { await worker.stop() }
    }

    /// The read waits behind the worker's other jobs, so the app can have left the front by
    /// the time it answers, and its report is then a background one
    /// (tla/Kosmos.tla, ObserveSplit).
    ///
    /// Ceiling: when an older request of Kosmos's fronted another app before the read ran,
    /// the user's activation of this app is lost with the read. The spec's rules that keep
    /// such a read are the upgrade (docs/focus.md, Deferred).
    private func activated(_ pid: pid_t, received: ContinuousClock.Instant) {
        guard let worker = workers[pid] else { return }
        let report = self.report
        Task {
            // Nil when the app did not answer.
            guard let window = await worker.focusedWindow() else { return }
            let kind: AXReport.Kind = kosmos_front_pid() == pid ? .focusedWindowChanged(window) : .backgroundFocus(window)
            report(AXReport(pid: pid, kind: kind, received: received, activationRead: true))
        }
    }
}
