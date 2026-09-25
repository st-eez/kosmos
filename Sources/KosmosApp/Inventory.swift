import AppKit
import KosmosCore
import KosmosSkyLight
import os

private let inventoryLog = Logger(subsystem: "io.github.st-eez.kosmos", category: "inventory")

/// Every window of a regular app, tracked from WindowServer events. Only WindowServer
/// evidence or app exit removes a window, and one that stops being a candidate stays
/// (docs/inventory.md).
@MainActor
final class Inventory {
    private(set) var windows: [UInt32: WindowRow] = [:]
    private var ax: [UInt32: AXWindowInfo] = [:]
    private(set) var focused: UInt32?
    private var focusReporter: pid_t?
    private(set) var fullscreen: Set<UInt32> = []
    /// Outlasts macOS's report of the next key window after a minimize, 0.73 s (docs/focus.md).
    static let departureBound: Duration = .seconds(1)
    private var departures = DepartureLog(bound: departureBound)
    /// A window leaving fullscreen leaves its Space before it joins the desktop's, and its
    /// return dates from the first of those changes (docs/tree.md).
    private var spaceChangedAt: [UInt32: ContinuousClock.Instant] = [:]
    private let spaceQueue = DispatchQueue(label: "kosmos.spaces", qos: .userInitiated)
    private lazy var apps = Apps { [weak self] report in self?.handle(report) }
    var onManagedChange: (@MainActor (_ window: UInt32, _ pid: pid_t, _ managed: Bool) -> Void)?
    /// Each worker report, after the inventory has applied it.
    var onReport: (@MainActor (AXReport) -> Void)?
    /// While locked, no window is admitted or removed, no sweep runs, and order changes wait
    /// for the unlock (docs/inventory.md).
    var sessionLocked = false {
        didSet {
            guard oldValue, !sessionLocked else { return }
            for change in heldOrder.unlocked() {
                onOrderChange?(change.window, change.app, change.orderedIn, change.frame, change.at)
            }
            awaitingUnlockSweep = true
        }
    }
    private var heldOrder = HeldOrder()
    private var arrivedWhileLocked: [UInt32: WindowRow] = [:]
    private var removedWhileLocked: Set<UInt32> = []
    private var awaitingUnlockSweep = false
    private var spacesChangedSinceSweep = false
    /// A native fullscreen transition creates Spaces around its order-out (docs/tree.md).
    private(set) var spacesChangedAt: ContinuousClock.Instant?
    /// Called after the inventory recorded the departure or return of the app's windows.
    var onAppHidden: (@MainActor (_ pid: pid_t, _ hidden: Bool, _ received: ContinuousClock.Instant) -> Void)?
    /// A managed window still ordered out at its look for none of the reasons with their own
    /// reports, as a closed NSWindowController window its app keeps (docs/tree.md).
    var onKeptOrderedOut: (@MainActor (_ window: UInt32, _ orderedOut: ContinuousClock.Instant) -> Void)?
    /// A destroyed candidate window counts as ordered out. Native tab switches are made of
    /// these (docs/tree.md).
    var onOrderChange: (@MainActor (_ window: UInt32, _ pid: pid_t, _ orderedIn: Bool, _ frame: CGRect,
                                    _ at: ContinuousClock.Instant) -> Void)?
    var onFullscreenChange: (@MainActor (_ window: UInt32, _ entered: Bool, _ spaceChangeBegan: ContinuousClock.Instant) -> Void)?
    /// `changedAt` is nil for a frame read for a creation, a sweep, or a Space change such as
    /// a reveal.
    var onFrameChange: (@MainActor (_ window: UInt32, _ old: CGRect, _ new: CGRect, _ changedAt: ContinuousClock.Instant?) -> Void)?
    /// Its app raising a managed window leaves the window's border below it (docs/borders.md).
    var onReordered: (@MainActor (_ window: UInt32) -> Void)?
    /// A managed window's level or corner radius changed, which its border takes.
    var onStyleChange: (@MainActor () -> Void)?

    func worker(_ pid: pid_t) -> AppWorker? { apps.worker(pid) }

    func appIdentity(_ pid: pid_t) -> (bundleID: String?, name: String?) {
        if let identity = apps.identity(pid) { return identity }
        let app = NSRunningApplication(processIdentifier: pid)
        return (app?.bundleIdentifier, app?.localizedName)
    }
    private var watchPending = false
    /// Nil while no sweep runs. A sweep skips these, as its snapshot predates their events.
    private var touchedDuringSweep: Set<UInt32>?
    private var sweepAgain = false
    private var swept = false
    private var presentAtStart: Set<UInt32> = []
    private var markedMissed: [UInt32: ContinuousClock.Instant] = [:]
    private static let lateBound: Duration = .seconds(1)
    /// Read once for each process, as each read is a synchronous LaunchServices call, and
    /// dropped by its exit source (docs/inventory.md).
    ///
    /// Ceiling: an app that changes its activation policy while it runs keeps the first one.
    /// Observing activationPolicy with key-value observing would follow a change.
    private var regularApps: [pid_t: Bool] = [:]
    private var exitSources: [pid_t: any DispatchSourceProcess] = [:]
    private var foundRegularAtLaunch: Set<pid_t> = []
    private enum FollowUp: Sendable {
        case none
        case readIfUnknown
        case spaceMembership(ContinuousClock.Instant)
        case changed(at: ContinuousClock.Instant)
    }
    private enum PendingEvent: Sendable {
        case read(UInt32, FollowUp)
        case destroyed(UInt32)
        case appExited(pid_t)
    }
    private var pending: [PendingEvent] = []
    /// Sweeps read here too, so every result reaches the main actor in read order
    /// (docs/inventory.md).
    private let reads = DispatchQueue(label: "kosmos.inventory.reads", qos: .userInitiated)
    private var looks = ClosedAndKept.Looks()

    func start() {
        SkyLight.subscribe { [weak self] event in self?.handle(event) }
        // NSRunningApplication(processIdentifier:) returned nil for a running app at startup
        // (docs/inventory.md).
        for app in NSWorkspace.shared.runningApplications {
            remember(app.processIdentifier, regular: app.activationPolicy == .regular)
        }
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier, regular = app.activationPolicy == .regular
            MainActor.assumeIsolated { self?.launched(pid, regular: regular) }
        }
        center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            MainActor.assumeIsolated { self?.enqueue(.appExited(pid)) }
        }
        for (name, hidden) in [(NSWorkspace.didHideApplicationNotification, true), (NSWorkspace.didUnhideApplicationNotification, false)] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                let pid = app.processIdentifier
                let received = ContinuousClock.now
                MainActor.assumeIsolated { self?.appHidden(pid, hidden, at: received) }
            }
        }
        sweep()
    }

    /// Needs the Accessibility grant.
    func startAccessibility() {
        apps.start()
    }

    func isManaged(_ id: UInt32) -> Bool {
        guard let row = windows[id] else { return false }
        return isCandidate(row) && ax[id]?.subrole == kAXStandardWindowSubrole
    }

    func wasThereAtLaunch(_ id: UInt32) -> Bool { presentAtStart.contains(id) }

    func isMinimized(_ id: UInt32) -> Bool { ax[id]?.minimized == true }

    /// The key window report for Kosmos's own window, which no worker sends.
    func ownWindowKeyed(at stamp: ContinuousClock.Instant) {
        handle(AXReport(pid: getpid(), kind: .focusedWindowChanged(nil), received: stamp))
    }

    private func handle(_ report: AXReport) {
        switch report.kind {
        case .windowCreated(let id):
            // WindowServer can report the window before its app's worker knows it.
            enqueue(.read(id, .readIfUnknown))
        case .answering:
            readIfUnknown(windows.filter { $0.value.pid == report.pid }.keys)
        case .windowDestroyed(let id):
            // AX alone never removes a window (docs/inventory.md).
            enqueue(.read(id, .none))
        case .focusedWindowChanged(let id):
            // The worker knows a window its app reports focused.
            if let id { readIfUnknown([id]) }
            // Repeats still go to the controller, which counts echoes.
            if id != focused || (id == nil && report.pid != focusReporter) {
                focused = id
                focusReporter = report.pid
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
        case .framesApplied, .framesDropped:
            break
        }
        onReport?(report)
    }

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

    private func readIfUnknown(_ ids: some Sequence<UInt32>) {
        var unknown: [pid_t: [UInt32]] = [:]
        for id in ids {
            guard ax[id] == nil, let row = windows[id], isCandidate(row) else { continue }
            unknown[row.pid, default: []].append(id)
        }
        for (pid, ids) in unknown { readAX(ids, pid: pid) }
    }

    /// Accessibility has no notification for native fullscreen, which SkyLight reports as a
    /// Space membership change (docs/tree.md).
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

    /// Within the departure bound. A window ordered out in an event not handled yet counts
    /// as leaving now.
    func leftScreen(_ id: UInt32) -> Bool {
        if let left = departures.justLeft(id, at: .now) { return left }
        guard windows[id]?.orderedIn == true else { return false }
        guard let row = SkyLight.rows([id]).first else { return true }
        return !row.orderedIn
    }

    private func readApplied() {
        for (id, orderedOut) in looks.readApplied(eventsWaiting: !pending.isEmpty) where isKeptOrderedOut(id) {
            onKeptOrderedOut?(id, orderedOut)
        }
    }

    /// None counts until the sweep after an unlock: whether the lock screen orders windows out
    /// is unmeasured (docs/tree.md).
    func isKeptOrderedOut(_ id: UInt32) -> Bool {
        guard !sessionLocked, !awaitingUnlockSweep, let row = windows[id], !row.orderedIn, isManaged(id), !isMinimized(id)
        else { return false }
        return NSRunningApplication(processIdentifier: row.pid)?.isHidden != true && !fullscreen.contains(id)
    }

    func hasOrderedOutWindows(_ pid: pid_t, besides window: UInt32) -> Bool {
        windows.values.contains { $0.pid == pid && $0.id != window && !$0.orderedIn && isCandidate($0) }
    }

    func otherWindows(of pid: pid_t, besides window: UInt32) -> [DepartureFocus.OtherWindow] {
        windows.values.filter { $0.pid == pid && $0.id != window && isCandidate($0) }
            .map { DepartureFocus.OtherWindow(orderedIn: $0.orderedIn, minimized: isMinimized($0.id)) }
    }

    private func appHidden(_ pid: pid_t, _ hidden: Bool, at received: ContinuousClock.Instant) {
        inventoryLog.info("\(self.appName(pid), privacy: .public) \(hidden ? "hid" : "unhid", privacy: .public)")
        for (id, row) in windows where row.pid == pid {
            if !hidden { departures.returned(id) } else if row.orderedIn { departures.left(id, at: .now) }
        }
        if !hidden { readIfUnknown(windows.filter { $0.value.pid == pid }.keys) }
        onAppHidden?(pid, hidden, received)
    }

    /// Nil info means the app did not answer, and what was known stays (docs/inventory.md).
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
        if let id = event.window, let marked = markedMissed.removeValue(forKey: id) {
            let after = ContinuousClock.now - marked
            if after < Self.lateBound {
                inventoryLog.notice("""
                    event \(String(describing: event), privacy: .public) came \
                    \(after.formatted(.units(allowed: [.milliseconds], fractionalPart: .show(length: 1))), privacy: .public) \
                    after the sweep counted \(id) missed by events: it may have been late
                    """)
            }
        }
        switch event {
        case .created(let id):
            enqueue(.read(id, .none))
        case .changed(let id):
            enqueue(.read(id, .changed(at: .now)))
        case .reordered(let id):
            enqueue(.read(id, .changed(at: .now)))
            if isManaged(id) { onReordered?(id) }
        case .spaceMembership(let id):
            enqueue(.read(id, .spaceMembership(.now)))
        case .destroyed(let id):
            enqueue(.destroyed(id))
        case .spacesChanged:
            spacesChangedSinceSweep = true
            spacesChangedAt = .now
            sweep()
        case .frontAppChanged:
            break
        }
    }

    /// The windows the event names count as changed during a running sweep from now, as the
    /// sweep's snapshot may predate the change.
    private func enqueue(_ event: PendingEvent) {
        switch event {
        case .read(let id, _), .destroyed(let id): touchedDuringSweep?.insert(id)
        case .appExited(let pid): touchedDuringSweep?.formUnion(windows.filter { $0.value.pid == pid }.keys)
        }
        if pending.isEmpty {
            // Queued after the events already on the main queue, such as the rest of
            // SkyLight's batch, so one read covers them.
            onMain { self.flushReads() }
        }
        pending.append(event)
    }

    private func flushReads() {
        guard !pending.isEmpty else { return }
        let events = pending
        pending = []
        let ids = Set(events.compactMap { event -> UInt32? in
            guard case .read(let id, _) = event else { return nil }
            return id
        })
        looks.readAsked()
        reads.async {
            let rows = SkyLight.rows(Array(ids), cornerRadii: true)
            onMain { self.applyReads(events, rows) }
        }
    }

    private func applyReads(_ events: [PendingEvent], _ rows: [WindowRow]) {
        defer { readApplied() }
        let rows = Dictionary(rows.map { ($0.id, $0) }) { first, _ in first }
        for event in events {
            switch event {
            case .read(let id, let followUp):
                if let row = rows[id] {
                    if case .changed(let at) = followUp { apply(row, changedAt: at) } else { apply(row) }
                } else {
                    remove(id, reason: "gone")
                }
                follow(followUp, id)
            case .destroyed(let id):
                remove(id, reason: "destroyed")
            case .appExited(let pid):
                appExited(pid)
            }
        }
    }

    private func follow(_ followUp: FollowUp, _ id: UInt32) {
        switch followUp {
        case .none, .changed:
            break
        case .readIfUnknown:
            readIfUnknown([id])
        case .spaceMembership(let changed):
            // It may join the shown Space, where Accessibility lists it.
            readIfUnknown([id])
            if let row = windows[id], isCandidate(row) {
                if spaceChangedAt[id] == nil { spaceChangedAt[id] = changed }
                Task { setFullscreen(id, await fullscreenState(id)) }
            }
        }
    }

    private func apply(_ row: WindowRow, changedAt: ContinuousClock.Instant? = nil) {
        touchedDuringSweep?.insert(row.id)
        guard ownedByRegularApp(row) else { return }
        guard !sessionLocked || windows[row.id] != nil else {
            if arrivedWhileLocked.updateValue(row, forKey: row.id) == nil { scheduleWatch() }
            if isCandidate(row) {
                _ = heldOrder.ordered(row.id, app: row.pid, in: row.orderedIn, was: nil, frame: row.frame,
                                      at: .now, locked: true)
            }
            return
        }
        let old = windows.updateValue(row, forKey: row.id)
        if old == nil { scheduleWatch() }
        departures.ordered(row.id, in: row.orderedIn, was: old?.orderedIn, at: .now)
        // A new tab can be seen first already ordered in.
        if isCandidate(row),
           heldOrder.ordered(row.id, app: row.pid, in: row.orderedIn, was: old?.orderedIn, frame: row.frame,
                             at: .now, locked: sessionLocked) {
            onOrderChange?(row.id, row.pid, row.orderedIn, row.frame, .now)
        }
        // Perhaps closed and kept: a conceal leaves a window ordered in, and a minimize, a hide
        // and native fullscreen have their own reports (docs/tree.md).
        if old?.orderedIn == true, !row.orderedIn, isManaged(row.id) { looks.orderedOut(row.id, at: .now) }
        // An app launched hidden restores its second window with no report (docs/inventory.md).
        if old?.orderedIn == false, row.orderedIn { readIfUnknown([row.id]) }
        if let old, old.frame != row.frame, isManaged(row.id) { onFrameChange?(row.id, old.frame, row.frame, changedAt) }
        if let old, old.level != row.level || old.cornerRadius != row.cornerRadius, isManaged(row.id) { onStyleChange?() }
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
            if windows[id] != nil { removedWhileLocked.insert(id) }
            if let row = windows[id], isCandidate(row) {
                _ = heldOrder.removed(id, app: row.pid, orderedIn: row.orderedIn, frame: row.frame, at: .now, locked: true)
            } else if let row = arrivedWhileLocked.removeValue(forKey: id) {
                _ = heldOrder.removed(id, app: row.pid, orderedIn: false, frame: row.frame, at: .now, locked: true)
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
        if isCandidate(row),
           heldOrder.removed(id, app: row.pid, orderedIn: row.orderedIn, frame: row.frame, at: .now, locked: false) {
            onOrderChange?(id, row.pid, false, row.frame, .now)
        }
        if wasManaged { onManagedChange?(id, row.pid, false) }
        inventoryLog.info("removed \(id): \(reason, privacy: .public)")
        scheduleWatch()
    }

    private func appExited(_ pid: pid_t) {
        for (id, row) in windows where row.pid == pid { remove(id, reason: "app exited") }
    }

    private func ownedByRegularApp(_ row: WindowRow) -> Bool {
        if let regular = regularApps[row.pid] { return regular }
        let regular = NSRunningApplication(processIdentifier: row.pid)?.activationPolicy == .regular
        remember(row.pid, regular: regular)
        return regular
    }

    /// A process that exited before its source started reports its exit at once (macOS 27).
    private func remember(_ pid: pid_t, regular: Bool) {
        regularApps[pid] = regular
        // WindowServer names pid 0 as the owner of some windows, and dispatch aborts on a
        // process source for pid 0 or less. Such a pid's false stays cached.
        guard pid > 0, exitSources[pid] == nil else { return }
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.regularApps[pid] = nil
                self?.exitSources.removeValue(forKey: pid)?.cancel()
            }
        }
        exitSources[pid] = source
        source.resume()
    }

    private func launched(_ pid: pid_t, regular: Bool) {
        let wasRegular = regularApps[pid]
        remember(pid, regular: regular)
        guard regular, wasRegular == false else { return }
        foundRegularAtLaunch.insert(pid)
        sweep()
    }

    private func isCandidate(_ row: WindowRow) -> Bool {
        row.parent == 0 && row.level == 0
    }

    private func appName(_ pid: pid_t) -> String {
        appIdentity(pid).name ?? "?"
    }

    private func scheduleWatch() {
        guard !watchPending else { return }
        watchPending = true
        onMain {
            self.watchPending = false
            SkyLight.watch(Array(Set(self.windows.keys).union(self.arrivedWhileLocked.keys)))
        }
    }

    /// The Space list omits windows on no Space, so tracked windows missing from it are read
    /// directly. The reads can block during a Space transition (docs/inventory.md).
    func sweep() {
        guard !sessionLocked else { return }
        guard touchedDuringSweep == nil else { sweepAgain = true; return }
        touchedDuringSweep = []
        flushReads()
        let tracked = Array(windows.keys) + arrivedWhileLocked.keys
        looks.readAsked()
        reads.async {
            let listed = SkyLight.allWindowIDs()
            let unlisted = Set(tracked).subtracting(listed)
            let rows = SkyLight.rows(listed + unlisted, cornerRadii: true)
            onMain { self.finishSweep(rows) }
        }
    }

    /// Ceiling: an event handled after this for a change the snapshot already had came late,
    /// and its window is still logged as missed; the late event's own log line tells them apart.
    private func finishSweep(_ rows: [WindowRow]) {
        let touched = touchedDuringSweep ?? []
        touchedDuringSweep = nil
        defer { if sweepAgain { sweepAgain = false; sweep() } }
        defer { readApplied() }
        guard !sessionLocked else { return }   // taken before the lock; the unlock sweeps again
        let rows = rows.filter { !touched.contains($0.id) }
        let seen = Set(rows.map(\.id))
        markedMissed = markedMissed.filter { ContinuousClock.now - $0.value < Self.lateBound }
        for row in rows where windows[row.id] == nil && ownedByRegularApp(row) {
            let reported = arrivedWhileLocked[row.id] != nil || foundRegularAtLaunch.contains(row.pid)
            if swept, !reported {
                markMissed(row.id)
                inventoryLog.notice("sweep found \(row.id), missed by events")
            }
            apply(row)
        }
        for id in windows.keys where !seen.contains(id) && !touched.contains(id) {
            if !removedWhileLocked.contains(id) {
                markMissed(id)
                inventoryLog.notice("sweep lost \(id), missed by events")
            }
            remove(id, reason: "absent from sweep")
        }
        for row in rows {
            guard let old = windows[row.id] else { continue }
            apply(row)
            guard let new = windows[row.id], new.orderedIn != old.orderedIn || isCandidate(new) != isCandidate(old) else { continue }
            markMissed(row.id)
            inventoryLog.notice("""
                sweep corrected \(row.id), missed by events: \(self.appName(row.pid), privacy: .public) \
                ordered in \(old.orderedIn) to \(new.orderedIn), level \(old.level) to \(new.level), \
                parent \(old.parent) to \(new.parent)
                """)
        }
        // Accessibility lists no window on a Space that is not shown, so only the last sweep of
        // a Space change asks again, for the windows ordered in (docs/inventory.md).
        if spacesChangedSinceSweep, !sweepAgain {
            spacesChangedSinceSweep = false
            readIfUnknown(windows.filter { $0.value.orderedIn }.keys)
        }
        // A sweep that follows was asked for after this snapshot, and may find the late windows.
        if !sweepAgain { foundRegularAtLaunch = [] }
        if !swept { presentAtStart = seen }
        swept = true
        if awaitingUnlockSweep {
            awaitingUnlockSweep = false
            arrivedWhileLocked = [:]
            removedWhileLocked = []
            heldOrder.swept()
            // None counted as closed and kept while locked. The held tab switches have paired now.
            for (id, row) in windows where !row.orderedIn && isManaged(id) { looks.orderedOut(id, at: .now) }
        }
    }

    private func markMissed(_ id: UInt32) {
        markedMissed[id] = .now
    }
}
