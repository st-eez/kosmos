import AppKit
import os

private let appsLog = Logger(subsystem: "io.github.st-eez.kosmos", category: "apps")

/// One Accessibility worker per regular app, created at launch and dropped at exit.
@MainActor
final class Apps {
    private var workers: [pid_t: AppWorker] = [:]
    /// Each app's bundle identifier and name, kept from its NSRunningApplication:
    /// NSRunningApplication(processIdentifier:) returned nil for a running app at startup.
    private var identities: [pid_t: (bundleID: String?, name: String?)] = [:]
    private let report: @MainActor (AXReport) -> Void

    init(report: @escaping @MainActor (AXReport) -> Void) {
        self.report = report
    }

    func start() {
        // Covers every element, including ones copied out of an app's attributes, which do
        // not take their app element's timeout (paneru's finding, wm-research geometry note).
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
            // Apps answer Accessibility some time after launch: retry for about a second,
            // as yabai and Hammerspoon do, then every 0.5 s.
            for attempt in 1...10 {
                if await worker.start() {
                    appsLog.debug("\(name, privacy: .public) observed after \(attempt) attempts")
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
            appsLog.error("\(name, privacy: .public) did not answer Accessibility in 1 s; asking every 0.5 s")
            await worker.askLater()
        }
    }

    private func remove(_ pid: pid_t) {
        identities[pid] = nil
        guard let worker = workers.removeValue(forKey: pid) else { return }
        Task { await worker.stop() }
    }

    /// An activation names only the app, so the app's worker reads its focused window.
    private func activated(_ pid: pid_t, received: ContinuousClock.Instant) {
        guard let worker = workers[pid] else { return }
        let report = self.report
        Task {
            // Unknown when the app did not answer: then nothing is reported.
            guard let window = await worker.focusedWindow() else { return }
            report(AXReport(pid: pid, kind: .focusedWindowChanged(window), received: received))
        }
    }
}
