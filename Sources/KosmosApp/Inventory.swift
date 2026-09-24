import AppKit
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
    private var watchPending = false
    private var sweepTimer: Timer?
    /// Windows that events changed while a sweep was running. The sweep's snapshot is older
    /// than those events, so it skips them. Nil when no sweep is running.
    private var touchedDuringSweep: Set<UInt32>?
    private var swept = false
    private(set) var missedByEvents = 0

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
        guard ownedByRegularApp(row) else { return }
        let old = windows.updateValue(row, forKey: row.id)
        if old == nil { scheduleWatch() }
        if old.map(isCandidate) != isCandidate(row) {
            inventoryLog.info("""
                \(row.id) \(self.isCandidate(row) ? "is" : "is not", privacy: .public) a candidate: pid \(row.pid) \
                \(self.appName(row.pid), privacy: .public) level \(row.level) parent \(row.parent)
                """)
        } else if old != row {
            inventoryLog.debug("changed \(row.id) orderedIn \(row.orderedIn) frame \(String(describing: row.frame), privacy: .public)")
        }
    }

    private func remove(_ id: UInt32, reason: StaticString) {
        touchedDuringSweep?.insert(id)
        guard windows.removeValue(forKey: id) != nil else { return }
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
        NSRunningApplication(processIdentifier: pid)?.localizedName ?? "?"
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
    private func sweep() {
        guard touchedDuringSweep == nil else { return }
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
