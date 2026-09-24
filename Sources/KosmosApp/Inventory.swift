import AppKit
import KosmosSkyLight
import os

private let inventoryLog = Logger(subsystem: "io.github.st-eez.kosmos", category: "inventory")

/// Every window of a regular app, tracked from WindowServer events. Only WindowServer
/// evidence or app exit removes a window (DESIGN.md, section 5.1). Whether a window could be
/// tiled is a property of its row: apps such as Helium change a window's level while it
/// lives, and dropping it would lose it until the next sweep.
///
/// Observer mode: nothing here changes a window. The sweep counts what the events missed,
/// which is the measurement this milestone exists for.
@MainActor
final class Inventory {
    private(set) var windows: [UInt32: WindowRow] = [:]
    /// Accessibility facts for windows whose app's worker knows them.
    private var ax: [UInt32: AXWindowInfo] = [:]
    private(set) var focused: UInt32?
    private lazy var apps = Apps { [weak self] report in self?.handle(report) }
    /// A window became managed (true) or stopped being managed (false).
    var onManagedChange: (@MainActor (UInt32, pid_t, Bool) -> Void)?
    /// Focus, minimize and frame reports, after the inventory has seen them.
    var onReport: (@MainActor (AXReport) -> Void)?
    /// While the session is locked or switched out, no window is admitted or removed and no
    /// sweep runs; the sweep after the unlock catches up (DESIGN.md, section 5.1). Updates to
    /// known windows still apply. The Controller reads it too.
    var sessionLocked = false

    func worker(_ pid: pid_t) -> AppWorker? { apps.worker(pid) }

    /// The app's bundle identifier and name, for window rules.
    func appIdentity(_ pid: pid_t) -> (bundleID: String?, name: String?) {
        if let identity = apps.identity(pid) { return identity }
        let app = NSRunningApplication(processIdentifier: pid)
        return (app?.bundleIdentifier, app?.localizedName)
    }
    private var watchPending = false
    private var sweepTimer: Timer?
    /// Windows that events changed while a sweep was running. The sweep's snapshot is older
    /// than those events, so it skips them. Nil when no sweep is running.
    private var touchedDuringSweep: Set<UInt32>?
    private var swept = false
    private(set) var missedByEvents = 0

    /// WindowServer tracking needs no permission and starts at once.
    func start() {
        SkyLight.subscribe { [weak self] event in self?.handle(event) }
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            MainActor.assumeIsolated { self?.appExited(pid) }
        }
        sweepTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sweep() }
        }
        sweep()
    }

    /// Starts the per-app Accessibility workers. Needs the Accessibility grant. Each worker
    /// reports `answering` once it starts, and its app's windows are read then.
    func startAccessibility() {
        apps.start()
    }

    /// A window is managed when it is a candidate and Accessibility calls it a standard
    /// window. Dialog and popup heuristics come with tiling.
    func isManaged(_ id: UInt32) -> Bool {
        guard let row = windows[id] else { return false }
        return isCandidate(row) && ax[id]?.subrole == kAXStandardWindowSubrole
    }

    private func handle(_ report: AXReport) {
        switch report.kind {
        case .windowCreated(let id):
            refresh(id)
            // WindowServer can report the window before its app's worker knows it.
            readIfUnknown(id)
        case .answering:
            for (id, row) in windows where row.pid == report.pid { readIfUnknown(id) }
        case .windowDestroyed(let id):
            // AX alone never removes a window; WindowServer decides.
            refresh(id)
        case .focusedWindowChanged(let id):
            // Repeats still go to the controller, which counts echoes.
            if id != focused {
                focused = id
                let name = appName(report.pid)
                if let id {
                    inventoryLog.info("focus \(id) \(name, privacy: .public) managed \(self.isManaged(id))")
                } else {
                    inventoryLog.info("focus none \(name, privacy: .public)")
                }
            }
        case .minimized(let id, let minimized):
            inventoryLog.info("\(id) \(minimized ? "minimized" : "restored", privacy: .public)")
            // A minimized window can report another subrole (Activity Monitor says AXDialog),
            // so its role is judged again only once it is back.
            if !minimized, let row = windows[id] { readAX(id, pid: row.pid) }
        case .framesApplied, .backgroundFocus:
            break
        }
        onReport?(report)
    }

    private func readAX(_ id: UInt32, pid: pid_t) {
        guard let worker = apps.worker(pid) else { return }
        Task {
            let info = await worker.info(id)
            setAX(id, info)
        }
    }

    /// A candidate whose facts no read has returned yet.
    private func readIfUnknown(_ id: UInt32) {
        guard ax[id] == nil, let row = windows[id], isCandidate(row) else { return }
        readAX(id, pid: row.pid)
    }

    /// Nil info means the app did not answer; what was known stays (DESIGN.md, section 5.1).
    private func setAX(_ id: UInt32, _ info: AXWindowInfo?) {
        guard let info, let pid = windows[id]?.pid else { return }
        let wasManaged = isManaged(id)
        ax[id] = info
        if isManaged(id) != wasManaged {
            onManagedChange?(id, pid, isManaged(id))
            inventoryLog.info("""
                \(id) \(self.isManaged(id) ? "managed" : "not managed", privacy: .public): \
                \(self.appName(self.windows[id]?.pid ?? 0), privacy: .public) \
                role \(info.role ?? "-", privacy: .public) subrole \(info.subrole ?? "-", privacy: .public)
                """)
        }
    }

    private func handle(_ event: WindowServerEvent) {
        inventoryLog.debug("event \(String(describing: event), privacy: .public)")
        switch event {
        case .created(let id), .changed(let id), .spaceMembership(let id):
            refresh(id)
        case .destroyed(let id):
            remove(id, reason: "destroyed")
        case .spacesChanged:
            sweep()
        case .frontAppChanged:
            break
        }
    }

    /// Reads one window's row (about 0.01 ms) and admits, updates or drops it.
    private func refresh(_ id: UInt32) {
        guard let row = SkyLight.rows([id]).first else {
            remove(id, reason: "gone")
            return
        }
        apply(row)
    }

    private func apply(_ row: WindowRow) {
        touchedDuringSweep?.insert(row.id)
        guard ownedByRegularApp(row), !sessionLocked || windows[row.id] != nil else { return }
        let old = windows.updateValue(row, forKey: row.id)
        if old == nil { scheduleWatch() }
        if old.map(isCandidate) != isCandidate(row) {
            if isCandidate(row) { readAX(row.id, pid: row.pid) }
            inventoryLog.info("""
                \(row.id) \(self.isCandidate(row) ? "is" : "is not", privacy: .public) a candidate: pid \(row.pid) \
                \(self.appName(row.pid), privacy: .public) level \(row.level) parent \(row.parent)
                """)
        } else if old != row {
            inventoryLog.debug("changed \(row.id) orderedIn \(row.orderedIn) frame \(String(describing: row.frame), privacy: .public)")
        }
    }

    private func remove(_ id: UInt32, reason: StaticString) {
        guard !sessionLocked else { return }
        touchedDuringSweep?.insert(id)
        let wasManaged = isManaged(id)
        guard let row = windows.removeValue(forKey: id) else { return }
        ax[id] = nil
        if wasManaged { onManagedChange?(id, row.pid, false) }
        inventoryLog.info("removed \(id): \(reason, privacy: .public)")
        scheduleWatch()
    }

    private func appExited(_ pid: pid_t) {
        for (id, row) in windows where row.pid == pid { remove(id, reason: "app exited") }
    }

    private func ownedByRegularApp(_ row: WindowRow) -> Bool {
        NSRunningApplication(processIdentifier: row.pid)?.activationPolicy == .regular
    }

    /// Parentless level 0 windows. Accessibility role checks come with the per-app workers.
    private func isCandidate(_ row: WindowRow) -> Bool {
        row.parent == 0 && row.level == 0
    }

    private func appName(_ pid: pid_t) -> String {
        appIdentity(pid).name ?? "?"
    }

    /// Sends the whole watch list once per run loop turn, however many windows changed.
    private func scheduleWatch() {
        guard !watchPending else { return }
        watchPending = true
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.watchPending = false
                SkyLight.watch(Array(self.windows.keys))
            }
        }
    }

    /// Diffs every window WindowServer knows against the inventory. The Space list omits
    /// windows that are on no Space, such as one created but not yet shown, so tracked
    /// windows missing from it are queried directly before they count as gone. The queries
    /// can block during a Space transition, so they run off the main thread.
    func sweep() {
        guard !sessionLocked, touchedDuringSweep == nil else { return }
        touchedDuringSweep = []
        let tracked = Array(windows.keys)
        DispatchQueue.global(qos: .utility).async {
            let listed = SkyLight.allWindowIDs()
            let unlisted = Set(tracked).subtracting(listed)
            let rows = SkyLight.rows(listed + unlisted)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.finishSweep(rows) }
            }
        }
    }

    private func finishSweep(_ rows: [WindowRow]) {
        let touched = touchedDuringSweep ?? []
        touchedDuringSweep = nil
        guard !sessionLocked else { return }   // taken before the lock; the unlock sweeps again
        let rows = rows.filter { !touched.contains($0.id) }
        let seen = Set(rows.map(\.id))
        for row in rows where ownedByRegularApp(row) && windows[row.id] == nil {
            if swept { missedByEvents += 1; inventoryLog.notice("sweep found \(row.id), missed by events") }
            apply(row)
        }
        for id in windows.keys where !seen.contains(id) && !touched.contains(id) {
            missedByEvents += 1
            inventoryLog.notice("sweep lost \(id), missed by events")
            remove(id, reason: "absent from sweep")
        }
        for row in rows where windows[row.id] != nil { apply(row) }
        swept = true
    }
}
