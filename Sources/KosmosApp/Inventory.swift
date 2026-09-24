import AppKit
import KosmosCore
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
    /// Windows in a native fullscreen Space.
    private(set) var fullscreen: Set<UInt32> = []
    /// How long a departure counts as just now, for the report of the next key window and
    /// for focus requests. After a minimize, the next key window was reported 0.73 s after
    /// Accessibility reported the minimize (the live log with the departures probe).
    static let departureBound: Duration = .seconds(1)
    /// When windows left the screen: closed, minimized, or hidden with their app.
    private var departures = DepartureLog(bound: departureBound)
    /// When each window's Space membership first changed since its fullscreen state was last
    /// read. A window leaving fullscreen leaves its Space before it joins the desktop's, and
    /// its return dates from the first of those events.
    private var spaceChangedAt: [UInt32: ContinuousClock.Instant] = [:]
    /// Space queries for fullscreen checks, in the order the events asked for them.
    private let spaceQueue = DispatchQueue(label: "kosmos.spaces", qos: .userInitiated)
    private lazy var apps = Apps { [weak self] report in self?.handle(report) }
    /// A window became managed (true) or stopped being managed (false).
    var onManagedChange: (@MainActor (UInt32, pid_t, Bool) -> Void)?
    /// Focus, minimize and frame reports, after the inventory has seen them.
    var onReport: (@MainActor (AXReport) -> Void)?
    /// While the session is locked or switched out, no window is admitted or removed and no
    /// sweep runs; the sweep after the unlock catches up (DESIGN.md, section 5.1). Updates to
    /// known windows still apply. Order changes are held with their times and reported at
    /// the unlock (HeldOrder). The Controller reads it too.
    var sessionLocked = false {
        didSet {
            guard oldValue, !sessionLocked else { return }
            for change in heldOrder.unlocked() {
                onOrderChange?(change.window, change.app, change.orderedIn, change.at)
            }
            awaitingUnlockSweep = true
        }
    }
    private var heldOrder = HeldOrder()
    /// Windows first seen while locked, and their apps. The unlock sweep admits them; until
    /// then they are watched, so their order changes are held as they happen.
    private var arrivedWhileLocked: [UInt32: pid_t] = [:]
    /// From the unlock until the sweep after it, which admits and removes the windows the
    /// lock held back.
    private var awaitingUnlockSweep = false
    /// A Space was created or destroyed, or the active Space changed, since the last sweep.
    private var spacesChanged = false
    /// An app hid (true) or came back (false), after the inventory recorded it, and when
    /// NSWorkspace said so.
    var onAppHidden: (@MainActor (pid_t, Bool, ContinuousClock.Instant) -> Void)?
    /// A managed window still ordered out a second after it left, for none of the reasons
    /// with their own reports: its app closed it and kept it, as NSWindowController does, or
    /// deselected its native tab.
    var onKeptOrderedOut: (@MainActor (UInt32) -> Void)?
    /// A candidate window was ordered in (true) or out (false), or destroyed while ordered
    /// in (false), and when: what a switch between native tabs is made of.
    var onOrderChange: (@MainActor (UInt32, pid_t, Bool, ContinuousClock.Instant) -> Void)?
    /// A managed window entered (true) or left (false) native fullscreen, and when its Space
    /// membership started to change.
    var onFullscreenChange: (@MainActor (UInt32, Bool, ContinuousClock.Instant) -> Void)?

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
        for (name, hidden) in [(NSWorkspace.didHideApplicationNotification, true), (NSWorkspace.didUnhideApplicationNotification, false)] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                let pid = app.processIdentifier
                let received = ContinuousClock.now
                MainActor.assumeIsolated { self?.appHidden(pid, hidden, at: received) }
            }
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

    /// Whether the window is minimized, as Accessibility read it with the window's other
    /// facts and as each minimize report since says.
    func isMinimized(_ id: UInt32) -> Bool { ax[id]?.minimized == true }

    /// Kosmos's own window became key, for an empty workspace: the key window report no
    /// worker sends, as Kosmos keeps none for itself. It names no window.
    func ownWindowKeyed(at stamp: ContinuousClock.Instant) {
        handle(AXReport(pid: getpid(), kind: .focusedWindowChanged(nil), received: stamp))
    }

    private func handle(_ report: AXReport) {
        switch report.kind {
        case .windowCreated(let id):
            refresh(id)
            // WindowServer can report the window before its app's worker knows it.
            readIfUnknown([id])
        case .answering:
            readIfUnknown(windows.filter { $0.value.pid == report.pid }.keys)
        case .windowDestroyed(let id):
            // AX alone never removes a window; WindowServer decides.
            refresh(id)
        case .focusedWindowChanged(let id):
            // The worker knows a window its app reports focused.
            if let id { readIfUnknown([id]) }
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
            ax[id]?.minimized = minimized
            if minimized, windows[id]?.orderedIn == true { departures.left(id, at: .now) } else if !minimized { departures.returned(id) }
            // A minimized window can report another subrole (Activity Monitor says AXDialog),
            // so its role is judged again only once it is back.
            if !minimized, let row = windows[id] { readAX([id], pid: row.pid) }
        case .backgroundFocus(let id):
            if let id { readIfUnknown([id]) }
        case .framesApplied:
            break
        }
        onReport?(report)
    }

    /// Reads windows of one app in one job on its worker, which lists the app's windows
    /// again at most once for them.
    private func readAX(_ ids: [UInt32], pid: pid_t) {
        guard let worker = apps.worker(pid) else { return }
        Task {
            let infos = await worker.info(ids)
            for id in ids {
                // Known before the window is managed, so a window that is already fullscreen
                // is parked at once and never tiled.
                setFullscreen(id, await fullscreenState(id))
                setAX(id, infos[id])
            }
        }
    }

    /// Candidates whose facts no read has returned yet, one job for each app. Terminal,
    /// launched hidden, restored a window that no read answered for and no creation report
    /// named while it stayed hidden (live log, September 24, 2026): its unhide, a focus
    /// report naming the window, its order-in or Space change, and the sweep after a Space
    /// change read it again (DESIGN.md, section 5.1).
    private func readIfUnknown(_ ids: some Sequence<UInt32>) {
        var unknown: [pid_t: [UInt32]] = [:]
        for id in ids {
            guard ax[id] == nil, let row = windows[id], isCandidate(row) else { continue }
            unknown[row.pid, default: []].append(id)
        }
        for (pid, ids) in unknown { readAX(ids, pid: pid) }
    }

    /// A native fullscreen window moves to a Space of its own, which SkyLight reports as a
    /// Space membership change (the fullscreen probe in kosmos-probe). Accessibility has no
    /// notification for it.
    private func fullscreenState(_ id: UInt32) async -> Bool? {
        await withCheckedContinuation { continuation in
            spaceQueue.async { continuation.resume(returning: Displays.isFullscreen(id)) }
        }
    }

    private func setFullscreen(_ id: UInt32, _ state: Bool?) {
        guard let state, windows[id] != nil else { return }
        let since = spaceChangedAt.removeValue(forKey: id) ?? .now
        let changed = state ? fullscreen.insert(id).inserted : fullscreen.remove(id) != nil
        guard changed, isManaged(id) else { return }
        inventoryLog.info("\(id) \(state ? "entered" : "left", privacy: .public) native fullscreen")
        onFullscreenChange?(id, state, since)
    }

    /// Whether the window left the screen within the departure bound: it closed, minimized,
    /// or hid with its app. WindowServer may have ordered it out in an event not handled
    /// yet, which counts as now.
    func leftScreen(_ id: UInt32) -> Bool {
        if let left = departures.justLeft(id, at: .now) { return left }
        guard windows[id]?.orderedIn == true else { return false }
        guard let row = SkyLight.rows([id]).first else { return true }
        return !row.orderedIn
    }

    /// A managed window left the screen. Concealing a window leaves it ordered in (the reveal
    /// probe), and a minimize, a hide and native fullscreen have their own reports. The
    /// second outlasts a fullscreen transition, which takes a window off its Space for about
    /// 0.5 s. While the session is locked, and until the sweep after the unlock, no window
    /// counts as closed, as none is removed: whether the lock screen orders windows out is
    /// unmeasured. That sweep checks every window still ordered out again.
    private func checkOrderedOut(_ id: UInt32) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, !self.sessionLocked, !self.awaitingUnlockSweep, let row = self.windows[id], !row.orderedIn, self.isManaged(id), !self.isMinimized(id),
                  NSRunningApplication(processIdentifier: row.pid)?.isHidden != true,
                  !self.fullscreen.contains(id) else { return }
            self.onKeptOrderedOut?(id)
        }
    }

    /// Whether the app has a candidate window ordered out besides `window`, as a native tab
    /// group's deselected tabs are.
    func hasOrderedOutWindows(_ pid: pid_t, besides window: UInt32) -> Bool {
        windows.values.contains { $0.pid == pid && $0.id != window && !$0.orderedIn && isCandidate($0) }
    }

    /// An app hid or came back. Its windows leave or return with it, and the controller hears
    /// of it after the record changed.
    private func appHidden(_ pid: pid_t, _ hidden: Bool, at received: ContinuousClock.Instant) {
        inventoryLog.info("\(self.appName(pid), privacy: .public) \(hidden ? "hid" : "unhid", privacy: .public)")
        for (id, row) in windows where row.pid == pid {
            if !hidden { departures.returned(id) } else if row.orderedIn { departures.left(id, at: .now) }
        }
        if !hidden { readIfUnknown(windows.filter { $0.value.pid == pid }.keys) }
        onAppHidden?(pid, hidden, received)
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
        case .created(let id), .changed(let id):
            refresh(id)
        case .spaceMembership(let id):
            refresh(id)
            // It may join the shown Space, where Accessibility lists it.
            readIfUnknown([id])
            if let row = windows[id], isCandidate(row) {
                if spaceChangedAt[id] == nil { spaceChangedAt[id] = .now }
                Task { setFullscreen(id, await fullscreenState(id)) }
            }
        case .destroyed(let id):
            remove(id, reason: "destroyed")
        case .spacesChanged:
            spacesChanged = true
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
        guard !sessionLocked || windows[row.id] != nil else {
            // The unlock sweep admits it. Its order changes are held till then.
            if arrivedWhileLocked.updateValue(row.pid, forKey: row.id) == nil { scheduleWatch() }
            if isCandidate(row) {
                _ = heldOrder.ordered(row.id, app: row.pid, in: row.orderedIn, was: nil, at: .now, locked: true)
            }
            return
        }
        let old = windows.updateValue(row, forKey: row.id)
        if old == nil { scheduleWatch() }
        departures.ordered(row.id, in: row.orderedIn, was: old?.orderedIn, at: .now)
        // A new tab can be seen first already ordered in.
        if isCandidate(row),
           heldOrder.ordered(row.id, app: row.pid, in: row.orderedIn, was: old?.orderedIn, at: .now, locked: sessionLocked) {
            onOrderChange?(row.id, row.pid, row.orderedIn, .now)
        }
        if old?.orderedIn == true, !row.orderedIn, isManaged(row.id) { checkOrderedOut(row.id) }
        // Shown now, as the second window an app launched hidden restored, with no report of
        // its own.
        if old?.orderedIn == false, row.orderedIn { readIfUnknown([row.id]) }
        if old.map(isCandidate) != isCandidate(row) {
            if isCandidate(row) { readAX([row.id], pid: row.pid) }
            inventoryLog.info("""
                \(row.id) \(self.isCandidate(row) ? "is" : "is not", privacy: .public) a candidate: pid \(row.pid) \
                \(self.appName(row.pid), privacy: .public) level \(row.level) parent \(row.parent)
                """)
        } else if old != row {
            inventoryLog.debug("changed \(row.id) orderedIn \(row.orderedIn) frame \(String(describing: row.frame), privacy: .public)")
        }
    }

    private func remove(_ id: UInt32, reason: StaticString) {
        guard !sessionLocked else {
            // The unlock sweep removes it. Its order change is held now, with its time.
            if let row = windows[id], isCandidate(row) {
                _ = heldOrder.removed(id, app: row.pid, orderedIn: row.orderedIn, at: .now, locked: true)
            } else if let pid = arrivedWhileLocked.removeValue(forKey: id) {
                _ = heldOrder.removed(id, app: pid, orderedIn: false, at: .now, locked: true)
            }
            return
        }
        touchedDuringSweep?.insert(id)
        let wasManaged = isManaged(id)
        guard let row = windows.removeValue(forKey: id) else { return }
        ax[id] = nil
        fullscreen.remove(id)
        spaceChangedAt[id] = nil
        if row.orderedIn { departures.left(id, at: .now) }
        // Before the removal, so a tab that replaces this one takes its place.
        if isCandidate(row), heldOrder.removed(id, app: row.pid, orderedIn: row.orderedIn, at: .now, locked: false) {
            onOrderChange?(id, row.pid, false, .now)
        }
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
                SkyLight.watch(Array(Set(self.windows.keys).union(self.arrivedWhileLocked.keys)))
            }
        }
    }

    /// Diffs every window WindowServer knows against the inventory. The Space list omits
    /// windows that are on no Space, such as one created but not yet shown, so tracked
    /// windows missing from it are queried directly before they count as gone, and so are
    /// windows first seen while locked, which an unlock sweep admits even when ordered out.
    /// The queries can block during a Space transition, so they run off the main thread.
    func sweep() {
        guard !sessionLocked, touchedDuringSweep == nil else { return }
        touchedDuringSweep = []
        let tracked = Array(windows.keys) + arrivedWhileLocked.keys
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
        // Accessibility lists no window on a Space that is not shown, such as another
        // fullscreen Space, so only the sweep after a Space change asks again, and only
        // for windows ordered in. The others wait for a focus report or their unhide.
        if spacesChanged {
            spacesChanged = false
            readIfUnknown(windows.filter { $0.value.orderedIn }.keys)
        }
        swept = true
        if awaitingUnlockSweep {
            awaitingUnlockSweep = false
            arrivedWhileLocked = [:]
            heldOrder.swept()
            // No window counted as closed and kept since the lock: check each one still out,
            // now that the switches the lock held have paired.
            for (id, row) in windows where !row.orderedIn && isManaged(id) { checkOrderedOut(id) }
        }
    }
}
