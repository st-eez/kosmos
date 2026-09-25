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
    /// The app that reported `focused`.
    private var focusedApp: pid_t?
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
                onOrderChange?(change.window, change.app, change.orderedIn, change.frame, change.at)
            }
            awaitingUnlockSweep = true
        }
    }
    private var heldOrder = HeldOrder()
    /// Windows first seen while locked, with their rows. The unlock sweep admits them; until
    /// then they are watched, so their order changes are held as they happen.
    private var arrivedWhileLocked: [UInt32: WindowRow] = [:]
    /// Known windows destroyed while locked, or whose app exited then. The unlock sweep
    /// removes them, and no event was missed.
    private var removedWhileLocked: Set<UInt32> = []
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
    /// in (false), with its frame, and when: what a switch between native tabs is made of.
    var onOrderChange: (@MainActor (UInt32, pid_t, Bool, CGRect, ContinuousClock.Instant) -> Void)?
    /// A managed window entered (true) or left (false) native fullscreen, and when its Space
    /// membership started to change.
    var onFullscreenChange: (@MainActor (UInt32, Bool, ContinuousClock.Instant) -> Void)?
    /// A managed window moved or resized, with its frame before and now, and when the
    /// `.changed` event that reported it came, or nil: a Space change, as a reveal makes, a
    /// creation or a sweep can read a new frame too.
    var onFrameChange: (@MainActor (UInt32, CGRect, CGRect, ContinuousClock.Instant?) -> Void)?

    func worker(_ pid: pid_t) -> AppWorker? { apps.worker(pid) }

    /// The app's bundle identifier and name, for window rules.
    func appIdentity(_ pid: pid_t) -> (bundleID: String?, name: String?) {
        if let identity = apps.identity(pid) { return identity }
        let app = NSRunningApplication(processIdentifier: pid)
        return (app?.bundleIdentifier, app?.localizedName)
    }
    private var watchPending = false
    /// Windows that events changed while a sweep was running. The sweep's snapshot is older
    /// than those events, so it skips them. Nil when no sweep is running.
    private var touchedDuringSweep: Set<UInt32>?
    /// A sweep was asked for while one ran. The running sweep's snapshot may be older than
    /// what asked, such as the last Space event of a burst, so one more runs after it.
    private var sweepAgain = false
    private var swept = false
    /// The windows the first sweep found, which were there before Kosmos launched.
    private var atLaunch: Set<UInt32> = []
    private(set) var missedByEvents = 0
    /// When a sweep last counted each window as missed by events. An event for one within
    /// `lateBound` is logged, as it may be the event for the change the sweep read, late.
    private var countedMissed: [UInt32: ContinuousClock.Instant] = [:]
    private static let lateBound: Duration = .seconds(1)
    /// Whether each process is a regular app, false for a process LaunchServices does not
    /// know, such as JankyBorders. LaunchServices answers each read with a synchronous XPC
    /// call, which a sample of workspace switches caught on the main thread at every window
    /// event and at every row of a sweep (2026-09-24), so each process is read once: from the
    /// running apps at start, as it launches, or at its first window. Its exit source drops
    /// it: NSWorkspace reports no exit of a background-only or LSUIElement app, and pids come
    /// round again, about every 7 hours on the development Mac.
    ///
    /// Ceiling: an app that changes its activation policy while it runs keeps the policy read
    /// first, as it keeps the Accessibility worker Apps gave it by its policy at launch.
    /// Observing each app's activationPolicy with key-value observing would follow a change.
    private var regularApps: [pid_t: Bool] = [:]
    private var exitSources: [pid_t: any DispatchSourceProcess] = [:]
    /// Apps whose launch found them regular after their windows were left out, until the
    /// sweep that admits those windows, which then counts none of them as missed by events.
    private var launchedLate: Set<pid_t> = []
    /// What the inventory does after applying a window's row read for an event.
    private enum FollowUp: Sendable {
        case none
        /// Ask Accessibility about the window if its facts are unknown.
        case readIfUnknown
        /// Its Space membership changed at that time.
        case spaceMembership(ContinuousClock.Instant)
        /// A `.changed` event came at that time: it moved, resized, or was ordered in, out
        /// or again.
        case changed(at: ContinuousClock.Instant)
    }
    private enum PendingEvent: Sendable {
        /// Read the window's row, apply it, then the follow-up.
        case read(UInt32, FollowUp)
        case destroyed(UInt32)
        case appExited(pid_t)
    }
    /// Window events waiting for the next read, in the order they came. Sweeps read on
    /// `reads` too, so every result reaches the main actor in read order (DESIGN.md, section
    /// 5.1).
    private var pending: [PendingEvent] = []
    private let reads = DispatchQueue(label: "kosmos.inventory.reads", qos: .userInitiated)

    /// WindowServer tracking needs no permission and starts at once.
    func start() {
        SkyLight.subscribe { [weak self] event in self?.handle(event) }
        // NSRunningApplication(processIdentifier:) returned nil for a running app at startup
        // (Apps), so the running apps come from their list.
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
        // Events drive the inventory. Launch, a Space change, an unlock and a wake sweep as a
        // backstop, as yabai and rift do; there is no timer (DESIGN.md, section 5.1).
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

    /// Whether the first sweep found the window: it was there before Kosmos launched.
    func wasThereAtLaunch(_ id: UInt32) -> Bool { atLaunch.contains(id) }

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
            // WindowServer can report the window before its app's worker knows it.
            enqueue(.read(id, .readIfUnknown))
        case .answering:
            readIfUnknown(windows.filter { $0.value.pid == report.pid }.keys)
        case .windowDestroyed(let id):
            // AX alone never removes a window; WindowServer decides.
            enqueue(.read(id, .none))
        case .focusedWindowChanged(let id):
            // The worker knows a window its app reports focused.
            if let id { readIfUnknown([id]) }
            // Repeats still go to the controller, which counts echoes. No key window is logged
            // again when another app reports it, as an app with no window after Kosmos's empty
            // workspace window.
            if id != focused || (id == nil && report.pid != focusedApp) {
                focused = id
                focusedApp = report.pid
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
        if let id = event.window, let counted = countedMissed.removeValue(forKey: id) {
            let after = ContinuousClock.now - counted
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
        case .spaceMembership(let id):
            enqueue(.read(id, .spaceMembership(.now)))
        case .destroyed(let id):
            enqueue(.destroyed(id))
        case .spacesChanged:
            spacesChanged = true
            sweep()
        case .frontAppChanged:
            break
        }
    }

    /// Holds the event for the read after this run loop turn. A window it names, or a known
    /// window of an app that exited, counts as changed during a running sweep from now, as
    /// the sweep's snapshot may predate the change.
    private func enqueue(_ event: PendingEvent) {
        switch event {
        case .read(let id, _), .destroyed(let id): touchedDuringSweep?.insert(id)
        case .appExited(let pid): touchedDuringSweep?.formUnion(windows.filter { $0.value.pid == pid }.keys)
        }
        if pending.isEmpty {
            // Queued after the events already on the main queue, such as the rest of
            // SkyLight's batch, so one read covers them.
            DispatchQueue.main.async { MainActor.assumeIsolated { self.flushReads() } }
        }
        pending.append(event)
    }

    /// Reads the rows of every window the waiting events name in one query on `reads`, then
    /// applies the events in the order they came.
    private func flushReads() {
        guard !pending.isEmpty else { return }
        let events = pending
        pending = []
        let ids = Set(events.compactMap { event -> UInt32? in
            guard case .read(let id, _) = event else { return nil }
            return id
        })
        reads.async {
            let rows = SkyLight.rows(Array(ids))
            DispatchQueue.main.async { MainActor.assumeIsolated { self.applyReads(events, rows) } }
        }
    }

    private func applyReads(_ events: [PendingEvent], _ rows: [WindowRow]) {
        let rows = Dictionary(rows.map { ($0.id, $0) }) { first, _ in first }
        for event in events {
            switch event {
            case .read(let id, let followUp):
                if let row = rows[id] {
                    if case .changed(let at) = followUp { apply(row, changed: at) } else { apply(row) }
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

    /// `changed`: when the `.changed` event that asked for the read came.
    private func apply(_ row: WindowRow, changed: ContinuousClock.Instant? = nil) {
        touchedDuringSweep?.insert(row.id)
        guard ownedByRegularApp(row) else { return }
        guard !sessionLocked || windows[row.id] != nil else {
            // The unlock sweep admits it. Its order changes are held till then.
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
        if old?.orderedIn == true, !row.orderedIn, isManaged(row.id) { checkOrderedOut(row.id) }
        // Shown now, as the second window an app launched hidden restored, with no report of
        // its own.
        if old?.orderedIn == false, row.orderedIn { readIfUnknown([row.id]) }
        if let old, old.frame != row.frame, isManaged(row.id) { onFrameChange?(row.id, old.frame, row.frame, changed) }
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

    /// Keeps whether the process is a regular app until it exits. A process that exited
    /// before its source started reports its exit at once (checked on macOS 27).
    private func remember(_ pid: pid_t, regular: Bool) {
        regularApps[pid] = regular
        // WindowServer names pid 0 as the owner of some windows (2 of 34 rows on the
        // development Mac), and dispatch aborts on a process source for pid 0 or less. Such a
        // pid is no app: its false stays cached and never needs dropping.
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

    /// An app that turns out regular at its launch may have had windows left out before, as
    /// not regular or unknown to LaunchServices; a sweep admits them.
    private func launched(_ pid: pid_t, regular: Bool) {
        let wasRegular = regularApps[pid]
        remember(pid, regular: regular)
        guard regular, wasRegular == false else { return }
        launchedLate.insert(pid)
        sweep()
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
    /// The queries can block during a Space transition, so they run off the main thread,
    /// after the reads for events already waiting.
    func sweep() {
        guard !sessionLocked else { return }
        guard touchedDuringSweep == nil else { sweepAgain = true; return }
        touchedDuringSweep = []
        flushReads()
        let tracked = Array(windows.keys) + arrivedWhileLocked.keys
        reads.async {
            let listed = SkyLight.allWindowIDs()
            let unlisted = Set(tracked).subtracting(listed)
            let rows = SkyLight.rows(listed + unlisted)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.finishSweep(rows) }
            }
        }
    }

    /// Ceiling: an event handled after this, for a change the sweep's snapshot already had,
    /// came late and still counts as missed. Such an event within `lateBound` is logged, so
    /// the count can be corrected by eye.
    private func finishSweep(_ rows: [WindowRow]) {
        let touched = touchedDuringSweep ?? []
        touchedDuringSweep = nil
        defer { if sweepAgain { sweepAgain = false; sweep() } }
        guard !sessionLocked else { return }   // taken before the lock; the unlock sweeps again
        let rows = rows.filter { !touched.contains($0.id) }
        let seen = Set(rows.map(\.id))
        countedMissed = countedMissed.filter { ContinuousClock.now - $0.value < Self.lateBound }
        // Windows the lock held back were reported, and so were those of an app found regular
        // only at its launch, so the sweep does not count them.
        for row in rows where windows[row.id] == nil && ownedByRegularApp(row) {
            if swept, arrivedWhileLocked[row.id] == nil, !launchedLate.contains(row.pid) {
                countMissed(row.id)
                inventoryLog.notice("sweep found \(row.id), missed by events")
            }
            apply(row)
        }
        for id in windows.keys where !seen.contains(id) && !touched.contains(id) {
            if !removedWhileLocked.contains(id) {
                countMissed(id)
                inventoryLog.notice("sweep lost \(id), missed by events")
            }
            remove(id, reason: "absent from sweep")
        }
        // A known window whose order or candidate status the sweep corrects is one an event
        // missed too.
        for row in rows {
            guard let old = windows[row.id] else { continue }
            apply(row)
            guard let new = windows[row.id], new.orderedIn != old.orderedIn || isCandidate(new) != isCandidate(old) else { continue }
            countMissed(row.id)
            inventoryLog.notice("""
                sweep corrected \(row.id), missed by events: \(self.appName(row.pid), privacy: .public) \
                ordered in \(old.orderedIn) to \(new.orderedIn), level \(old.level) to \(new.level), \
                parent \(old.parent) to \(new.parent)
                """)
        }
        // Accessibility lists no window on a Space that is not shown, such as another
        // fullscreen Space, so only the sweep after a Space change asks again, and only
        // for windows ordered in. The others wait for a focus report or their unhide. When
        // another sweep follows this one, that sweep asks instead, later in the Space change.
        if spacesChanged, !sweepAgain {
            spacesChanged = false
            readIfUnknown(windows.filter { $0.value.orderedIn }.keys)
        }
        // A sweep that follows was asked for after this one's snapshot, so it may be the one
        // that finds a late app's windows.
        if !sweepAgain { launchedLate = [] }
        if !swept { atLaunch = seen }
        swept = true
        if awaitingUnlockSweep {
            awaitingUnlockSweep = false
            arrivedWhileLocked = [:]
            removedWhileLocked = []
            heldOrder.swept()
            // No window counted as closed and kept since the lock: check each one still out,
            // now that the switches the lock held have paired.
            for (id, row) in windows where !row.orderedIn && isManaged(id) { checkOrderedOut(id) }
        }
    }

    private func countMissed(_ id: UInt32) {
        missedByEvents += 1
        countedMissed[id] = .now
    }
}
