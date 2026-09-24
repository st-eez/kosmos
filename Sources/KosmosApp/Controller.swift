import AppKit
import KosmosCore
import KosmosSkyLight
import os

private let controllerLog = Logger(subsystem: "io.github.st-eez.kosmos", category: "controller")
private let signposter = OSSignposter(subsystem: "io.github.st-eez.kosmos", category: .pointsOfInterest)

/// Carries out the Session's plans: frame writes through the app workers, reveals and
/// conceals through Hiding, and focus through the focus queue once the switch's barrier
/// confirms it (DESIGN.md, section 4.3; tla/Kosmos.tla).
@MainActor
final class Controller {
    private var session: Session
    private var ledger = FrameLedger()
    private var reports = FocusReports<ContinuousClock.Instant>()
    private let inventory: Inventory
    private let hiding: Hiding
    private let focusQueue = FocusQueue()
    private let bar = BarPush()
    /// Bumped by every switch; a switch whose barrier returns after a newer one does not focus.
    private var switchGeneration = 0
    private var owner: [WindowID: pid_t] = [:]
    /// Window ids by most recent focus, newest last.
    private var recent: [WindowID] = []
    /// The windows each hidden app had tiled or floating, parked until it is unhidden.
    private var hiddenApps: [pid_t: [WindowID]] = [:]
    /// Windows parked while they are in native fullscreen.
    private var fullscreenParked: Set<WindowID> = []
    /// Windows parked because their app ordered them out and kept them.
    private var closedByApp: Set<WindowID> = []
    /// The key window macOS last reported.
    private var key: KeyWindow?
    /// A report whose verdict waits for the departure of the window key before it
    /// (tla/Kosmos.tla, Hold).
    private var held = HeldReport<KeyReport>()
    /// A departure that waits for macOS's report of the next key window: the key window that
    /// left, and the number of the departure's grace timer.
    private var awaitingKey: (window: WindowID, number: Int)?
    private var departures = 0
    /// A focus request found its window gone from the screen, so the window's departure
    /// focuses again (tla/Kosmos.tla, RequestFocus).
    private var refocus = false
    /// Set after a batch that did not conceal what it should have; the next switch conceals
    /// every window of every hidden workspace again.
    private var needsResync = false
    /// False while another tiling window manager runs: Kosmos then only observes.
    let managing: Bool
    /// Window rules, first match wins.
    var rules: [WindowRule] = []
    /// Move the pointer into a window that a command focused.
    var mouseFollowsFocus = false
    /// The active display profile, for the bar.
    var profile: String?
    /// The display the session tiles, as the bar numbers it. Read at launch, as the session's
    /// display is.
    private let barDisplay: BarSnapshot.Display
    var publish: (@MainActor (Data) -> Void)?

    init(inventory: Inventory, hiding: Hiding, names: [String], gaps: Gaps, managing: Bool) {
        self.inventory = inventory
        self.hiding = hiding
        self.managing = managing
        session = Session(names: names, display: Controller.displayRect(), gaps: gaps)
        barDisplay = Controller.barDisplay()
        inventory.onManagedChange = { [weak self] id, pid, managed in self?.managedChanged(id, pid: pid, managed) }
        inventory.onReport = { [weak self] report in self?.handle(report) }
        inventory.onFullscreenChange = { [weak self] id, entered, since in self?.fullscreenChanged(id, entered, since: since) }
        inventory.onOrderedOut = { [weak self] id, out, at in self?.orderedOutChanged(id, out, at: at) }
        let center = NSWorkspace.shared.notificationCenter
        for (name, hidden) in [(NSWorkspace.didHideApplicationNotification, true), (NSWorkspace.didUnhideApplicationNotification, false)] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                let pid = app.processIdentifier
                MainActor.assumeIsolated { hidden ? self?.appHidden(pid) : self?.appUnhidden(pid) }
            }
        }
    }

    /// Runs one command. Returns the exit code and the text for the CLI.
    var workspaceNames: [String] { session.names }

    /// Applies new gaps and rules after a config reload. A changed workspace list takes a
    /// restart.
    func reconfigure(gaps: Gaps, rules: [WindowRule]) {
        self.rules = rules
        session.gaps = gaps
        guard managing else { return }   // another window manager owns the frames
        writeFrames(session.frames(of: session.visible))
    }

    func run(_ arguments: [String], received: ContinuousClock.Instant) -> (code: Int32, text: String) {
        switch arguments {
        case ["state"]:
            return (0, String(decoding: stateJSON(), as: UTF8.self))
        case ["list-workspaces"]:
            return (0, session.names.map { $0 == session.visible ? "\($0) *" : $0 }.joined(separator: "\n"))
        case ["list-windows"]:
            let lines = session.names.flatMap { name in
                session.windows(of: name).map { id in
                    let app = owner[id].flatMap { NSRunningApplication(processIdentifier: $0)?.localizedName } ?? "?"
                    return "\(id) \(name) \(app)\(id == session.focused ? " *" : "")"
                }
            }
            return (0, lines.joined(separator: "\n"))
        default:
            break
        }
        switch Command.parse(arguments) {
        case .failure(let error):
            return (1, error.message)
        case .success where !managing:
            // Changing the model without moving windows would leave the two apart.
            return (1, "observing only while another window manager runs")
        case .success(let command):
            reports.commandExecuted(receivedAt: received)
            if let plan = session.perform(command) { execute(plan, since: received, fromCommand: true) }
            return (0, "")
        }
    }

    /// The main display's visible area in the top left origin coordinates Accessibility uses.
    static func displayRect() -> CGRect {
        guard let main = NSScreen.main, let primary = NSScreen.screens.first else { return .zero }
        let visible = main.visibleFrame
        return CGRect(x: visible.minX, y: primary.frame.height - visible.maxY, width: visible.width, height: visible.height)
    }

    /// The main display, the one `displayRect()` measures, by SketchyBar's number for it.
    static func barDisplay() -> BarSnapshot.Display {
        guard let main = NSScreen.main else { return BarSnapshot.Display(id: 1, name: "Display") }
        let number = BarSnapshot.displayNumber(uuid: DisplayIdentity.uuid(of: main.displayID),
                                               active: DisplayIdentity.active().count, managed: DisplayIdentity.managed())
        return BarSnapshot.Display(id: number, name: main.localizedName)
    }

    // MARK: Events

    private func managedChanged(_ id: WindowID, pid: pid_t, _ managed: Bool) {
        if managed {
            owner[id] = pid
            let app = inventory.appIdentity(pid)
            let rule = rules.first { $0.matches(appID: app.bundleID, appName: app.name) }
            var plan = session.add(id, to: rule?.workspace)
            if rule?.float == true { plan.frames.merge(session.float(id).frames) { _, new in new } }
            // Already minimized, in native fullscreen or hidden with its app, as at launch:
            // it waits parked for its return, with no frame and no concealing. A minimized or
            // fullscreen window of a hidden app returns on its own, not when the app unhides.
            if let reason = ParkReason.atAdmission(fullscreen: inventory.fullscreen.contains(id),
                                                   minimized: inventory.isMinimized(id),
                                                   appHidden: NSRunningApplication(processIdentifier: pid)?.isHidden == true) {
                if reason == .fullscreen { fullscreenParked.insert(id) }
                if reason == .appHidden { hiddenApps[pid, default: []].append(id) }
                plan.frames = session.park([id]).frames
                plan.hide.removeAll { $0 == id }
            }
            // Reported key before it was managed, as at launch: that report was dropped.
            if inventory.focused == id, session.workspace(of: id) == session.visible { session.adopt(id) }
            execute(plan)
        } else {
            owner[id] = nil
            recent.removeAll { $0 == id }
            hiddenApps[pid]?.removeAll { $0 == id }
            fullscreenParked.remove(id)
            closedByApp.remove(id)
            ledger.forget(id)
            execute(session.remove(id))
            if let report = held.departed([id]) { decideHeld(report, departed: true) }
        }
    }

    /// A window in native fullscreen is on a Space of its own: parked, Kosmos neither
    /// conceals it nor writes its frame. When it leaves, it returns to its workspace.
    /// `since` is when it started to leave its Space.
    private func fullscreenChanged(_ id: WindowID, _ entered: Bool, since: ContinuousClock.Instant) {
        if entered {
            guard !session.isParked(id) else { return }
            fullscreenParked.insert(id)
            execute(session.park([id]))
        } else if fullscreenParked.remove(id) != nil {
            // macOS restores the frame it had; write the tile's frame again all the same.
            ledger.forget(id)
            returned([id], follow: id, at: since)
        }
    }

    /// Its app ordered the window out and kept it, as a closed NSWindowController window: it
    /// parks as a minimized window does, and when the app orders it in again it returns to
    /// its place and Kosmos follows it there. Removing it would lose its place, and the
    /// inventory would not admit it again, since it stays managed.
    private func orderedOutChanged(_ id: WindowID, _ out: Bool, at received: ContinuousClock.Instant) {
        if out {
            guard session.workspace(of: id) != nil, !session.isParked(id) else { return }
            closedByApp.insert(id)
            depart([id])
        } else if closedByApp.remove(id) != nil {
            returned([id], follow: id, at: received)
        }
    }

    /// Windows back from minimizing, hiding or fullscreen return to their places, and Kosmos
    /// follows `follow` to its workspace. A command received after the return wins, as over
    /// a stale Command-Tab, and its focus is requested again: macOS keyed the returning
    /// window (DESIGN.md, section 5.5; tla/Kosmos.tla, Rejoin).
    private func returned(_ windows: [WindowID], follow: WindowID?, at stamp: ContinuousClock.Instant) {
        let stale = reports.isStale(stamp)
        var plan = session.unpark(windows, follow: stale ? nil : follow)
        if stale { plan.focus = intent }
        execute(plan)
    }

    /// Minimized, or hidden with their app (tla/Kosmos.tla, Depart). When Kosmos's focus
    /// leaves, the workspace's next window, or Finder, is focused now, or after macOS's
    /// report of the next key window when the key window left too (DepartureFocus). A
    /// report that does not come within the grace, as when an app keeps no key window, has
    /// the departure focus then.
    private func depart(_ windows: [WindowID]) {
        let focusLeft = session.focused.map(windows.contains) == true
        execute(session.park(windows))
        switch DepartureFocus.decide(focusLeft: focusLeft, refocus: refocus, key: key, departing: windows,
                                     left: { self.inventory.leftScreen($0, within: .seconds(1)) }) {
        case .none:
            break
        case .now:
            requestFocus(intent)
        case .afterKeyReport:
            guard case .window(let keyWindow)? = key else { break }
            departures += 1
            let number = departures
            awaitingKey = (keyWindow, number)
            afterGrace { controller in
                guard controller.awaitingKey?.number == number else { return }
                controller.awaitingKey = nil
                controller.requestFocus(controller.intent)
            }
        }
        if let report = held.departed(windows) { decideHeld(report, departed: true) }
    }

    /// An app hid its windows: they leave the layout, and switches leave them alone.
    private func appHidden(_ pid: pid_t) {
        let windows = owner.filter { $0.value == pid && session.workspace(of: $0.key) != nil && !session.isParked($0.key) }.map(\.key)
        guard !windows.isEmpty else { return }
        hiddenApps[pid, default: []] += windows
        depart(windows)
    }

    /// The app is back: its windows return to their places, and Kosmos follows the one the
    /// app keys, or else its most recently focused one, to its workspace.
    private func appUnhidden(_ pid: pid_t) {
        guard hiddenApps[pid]?.isEmpty == false else { return }
        let received = ContinuousClock.now
        Task {
            let keyed = await inventory.worker(pid)?.focusedWindow()
            // Hidden again while the worker answered: the windows wait for the next unhide.
            guard NSRunningApplication(processIdentifier: pid)?.isHidden != true,
                  let windows = hiddenApps.removeValue(forKey: pid), !windows.isEmpty else { return }
            returned(windows, follow: session.followOnUnhide(windows, keyed: keyed, fallback: mostRecent(windows)),
                     at: received)
        }
    }

    private func handle(_ report: AXReport) {
        switch report.kind {
        case .focusedWindowChanged(let id):
            let reported: KeyWindow = id.map(KeyWindow.window) ?? .none
            let previous: WindowID? = if case .window(let window)? = key, window != id { window } else { nil }
            let repeated = key == reported
            key = reported
            // macOS's report of the next key window, which a departure waited for.
            if let previous, awaitingKey?.window == previous { awaitingKey = nil }
            // Dialogs and panels are not managed; their focus is theirs. A parked window is
            // key in its own fullscreen Space, or just before it returns, which follows it.
            if let id, session.workspace(of: id) == nil || session.isParked(id) { return }
            // The held window again, as after a miss: the same activation, still held.
            if repeated, held.report?.key == reported { return }
            // The window key before this report left the screen just now: macOS keyed this
            // window after that one closed, minimized or hid (DESIGN.md, section 5.4). The
            // bound covers macOS's delay: after a minimize, the new key window was reported
            // 0.73 s after the minimize. Concealing a window leaves it ordered in, so a
            // concealed window counts only if it left too.
            let keyLeft: Departure = previous.map { inventory.leftScreen($0, within: .seconds(1)) ? .left : .unknown } ?? .stayed
            decide(KeyReport(key: reported, received: report.received, previous: previous, repeated: repeated,
                             concealed: id.map(hiding.isConcealed) ?? false), keyLeft: keyLeft)
        case .minimized(let id, true):
            depart([id])
        case .minimized(let id, false):
            returned([id], follow: id, at: report.received)
        case .framesApplied(let results):
            for result in results {
                ledger.confirm(result.id, target: result.target, readBack: result.readBack)
                // A window that kept more than it was given refused the size: that is its
                // minimum on that axis (DESIGN.md, section 5.2). A few points of slack keep
                // apps that round their size from reading as a refusal.
                let wider = result.readBack.width > result.target.width + 2
                let taller = result.readBack.height > result.target.height + 2
                if wider || taller {
                    controllerLog.notice("""
                        minimum for \(result.id): asked \(Int(result.target.width))x\(Int(result.target.height)), \
                        kept \(Int(result.readBack.width))x\(Int(result.readBack.height))
                        """)
                    execute(session.setMinimum(result.id, CGSize(width: wider ? result.readBack.width : 0,
                                                                 height: taller ? result.readBack.height : 0)))
                }
            }
        case .windowCreated, .windowDestroyed, .titleChanged:
            break
        }
    }

    /// A key window report as classification reads it.
    private struct KeyReport {
        let key: KeyWindow
        let received: ContinuousClock.Instant
        /// The window key before it, when that was another window.
        let previous: WindowID?
        /// It names the key window Kosmos last heard of.
        let repeated: Bool
        /// The reported window was concealed when it became key.
        let concealed: Bool
    }

    /// How long a report waits to learn whether the window key before it left. macOS keyed
    /// the next app before WindowServer ordered a hidden app's window out, which the
    /// departures probe measured 17 ms after the hide. Every follow of a Command-Tab waits
    /// this long.
    private static let grace: Duration = .milliseconds(100)

    /// Acts on a key window report. A report whose verdict depends on a departure that is
    /// not known yet is held until the departure arrives or the grace ends
    /// (tla/Kosmos.tla, Adopt and Hold).
    private func decide(_ report: KeyReport, keyLeft: Departure) {
        let id: WindowID? = if case .window(let window) = report.key { window } else { nil }
        // After a failed batch, recovery showed the windows of hidden workspaces, and a click
        // reaches one as Command-Tab reaches a concealed one.
        let verdict = reports.classify(report.key, receivedAt: report.received,
                                       onCurrentWorkspace: id.map { session.workspace(of: $0) == session.visible } ?? false,
                                       reachable: report.concealed || needsResync, repeated: report.repeated,
                                       shownSibling: report.concealed ? id.flatMap(shownSibling) : nil, keyLeft: keyLeft)
        controllerLog.debug("focus report \(String(describing: report.key), privacy: .public): \(String(describing: verdict), privacy: .public)")
        // A newer activation of a window ends a held report. Kosmos's own echo and a report
        // of no key window leave it held.
        if id != nil, verdict != .echo { held.end() }
        switch verdict {
        case .echo, .ignore:
            break
        case .undecided:
            guard let previous = report.previous else { break }
            let number = held.hold(report, previous: previous)
            afterGrace { controller in
                if let report = controller.held.expire(number) { controller.decideHeld(report, departed: false) }
            }
        case .reassert:
            requestFocus(intent)
        case .adopt(let window):
            session.adopt(window)
            touch(window)
            publishState()
        case .follow(let window):
            touch(window)
            execute(session.follow(window))
        case .redirect(let window):
            session.adopt(window)
            requestFocus(.window(window))
            publishState()
        }
    }

    /// The most recently focused window on the shown workspace of the app that owns
    /// `window`, where Command-Tab to that app lands (DESIGN.md, section 5.3).
    private func shownSibling(of window: WindowID) -> WindowID? {
        guard let pid = owner[window] else { return nil }
        return mostRecent(session.windows(of: session.visible).filter { owner[$0] == pid })
    }

    /// Decides a held report: when the window key before it departs, or when the grace ends,
    /// by what WindowServer says of that window then.
    private func decideHeld(_ report: KeyReport, departed: Bool) {
        // The reported window left or stopped being managed meanwhile.
        if case .window(let id) = report.key, session.workspace(of: id) == nil || session.isParked(id) { return }
        guard let previous = report.previous else { return }
        let left = departed || inventory.leftScreen(previous, within: .seconds(1))
        controllerLog.notice("""
            held focus report \(String(describing: report.key), privacy: .public): \
            \(previous) \(left ? "left" : "stayed", privacy: .public) \
            after \(Self.ms(ContinuousClock.now - report.received), privacy: .public) ms
            """)
        decide(report, keyLeft: left ? .left : .stayed)
    }

    /// Runs `body` on the main actor once the grace ends.
    private func afterGrace(_ body: @escaping @MainActor (Controller) -> Void) {
        Task { [weak self] in
            try? await Task.sleep(for: Self.grace)
            if let self { body(self) }
        }
    }

    // MARK: Plans

    private var intent: KeyWindow { session.focused.map(KeyWindow.window) ?? .none }

    /// macOS shows a native fullscreen window's Space: that window is key, or a panel or
    /// dialog of its app is.
    private var inFullscreenSpace: Bool {
        let keyWindow: WindowID? = if case .window(let id)? = key { id } else { nil }
        return showsFullscreenSpace(key: key, keyManaged: keyWindow.map { session.workspace(of: $0) != nil } ?? false,
                                    keyApp: keyWindow.flatMap { owner[$0] ?? inventory.windows[$0]?.pid },
                                    fullscreen: Dictionary(uniqueKeysWithValues: fullscreenParked.compactMap { id in owner[id].map { (id, $0) } }))
    }

    /// `since` is when the command arrived, for the switch timing log.
    private func execute(_ plan: Session.Plan, since received: ContinuousClock.Instant = .now, fromCommand: Bool = false) {
        guard managing, !plan.isEmpty else { return publishState() }
        writeFrames(plan.frames)
        var show = plan.show, hide = plan.hide
        if needsResync && !(show.isEmpty && hide.isEmpty) {
            show = session.windows(of: session.visible)
            hide = session.names.filter { $0 != session.visible }.flatMap { session.windows(of: $0) }
            needsResync = false
        }
        let movePointer = fromCommand && mouseFollowsFocus
        if show.isEmpty && hide.isEmpty {
            if plan.focus != nil { requestFocus(intent, movePointer: movePointer, fromCommand: fromCommand) }
        } else {
            switchGeneration += 1
            let generation = switchGeneration
            let interval = signposter.beginInterval("switch", id: signposter.makeSignpostID())
            let submitted = ContinuousClock.now
            hiding.apply(show: show, hide: concealment(of: hide)) { [weak self] outcome in
                guard let self else { return }
                signposter.endInterval("switch", interval)
                let bridge = ContinuousClock.now - submitted, total = ContinuousClock.now - received
                controllerLog.notice("""
                    switch to \(self.session.visible, privacy: .public): \(show.count) shown, \(hide.count) hidden, \
                    before bridge \(Self.ms(submitted - received), privacy: .public) ms, bridge \(Self.ms(bridge), privacy: .public) ms, \
                    total \(Self.ms(total), privacy: .public) ms, \(String(describing: outcome), privacy: .public)
                    """)
                switch outcome {
                case .confirmed: break
                case .revealedOnly:
                    controllerLog.error("guardian not ready: windows were revealed but not concealed")
                    self.needsResync = true
                case .failed:
                    controllerLog.error("switch not confirmed; recovery ran")
                    self.needsResync = true
                    return
                }
                // A newer switch focuses for itself (tla/Kosmos.tla, Resume).
                guard generation == self.switchGeneration else { return }
                self.requestFocus(self.intent, movePointer: movePointer, fromCommand: fromCommand)
            }
        }
        publishState()
    }

    private static func ms(_ duration: Duration) -> String {
        String(format: "%.3f", Double(duration.components.attoseconds) / 1e15 + Double(duration.components.seconds) * 1000)
    }

    private func writeFrames(_ targets: [WindowID: CGRect]) {
        let writes = ledger.writes(for: targets)
        for (pid, group) in Dictionary(grouping: writes, by: { owner[$0.key] ?? 0 }) where pid != 0 {
            let batch = Dictionary(uniqueKeysWithValues: group.map { ($0.key, (write: $0.value, target: targets[$0.key]!)) })
            inventory.worker(pid)?.enqueueFrames(batch)
        }
    }

    /// Each app's most recently focused hidden window keeps its ordinary Space membership
    /// so Command-Tab picks it, unless the app has a window on the shown workspace; every
    /// other concealed window loses it (DESIGN.md, section 5.3).
    private func concealment(of windows: [WindowID]) -> [WindowID: Hiding.Conceal] {
        let shownApps = Set(session.windows(of: session.visible).compactMap { owner[$0] })
        var kinds: [WindowID: Hiding.Conceal] = [:]
        for (pid, group) in Dictionary(grouping: windows, by: { owner[$0] ?? 0 }) {
            let selected = shownApps.contains(pid) ? nil
                : mostRecent(group)
            for window in group { kinds[window] = window == selected ? .keepOrdinary : .exclusive }
        }
        return kinds
    }

    /// Every focus request goes through here. `fromCommand`: a command asked for it.
    private func requestFocus(_ target: KeyWindow, movePointer: Bool = false, fromCommand: Bool = false) {
        // Focusing a desktop window takes the user out of a fullscreen Space: only a command
        // does that, not a window closing or hiding behind it, nor an unhide that conceals
        // windows.
        guard fromCommand || !inFullscreenSpace else { return }
        // A window that just left the screen, before Kosmos heard: fronting it would
        // unminimize it or unhide its app. Its departure focuses again.
        if case .window(let id) = target, inventory.leftScreen(id, within: .seconds(1)) {
            refocus = true
            return
        }
        refocus = false
        if movePointer, case .window(let id) = target { centerPointer(on: id) }
        guard target != key else { return }   // already key: activating again costs the system work
        let pid: pid_t?
        switch target {
        case .window(let id):
            pid = owner[id]
            touch(id)
        case .none:
            pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first?.processIdentifier
        }
        guard let pid else { return }
        let stamp = ContinuousClock.now
        reports.focusRequested(target, at: stamp)
        focusQueue.request(target, pid: pid, generation: focusQueue.newGeneration()) { [weak self] in
            self?.reports.requestDropped(target, at: stamp)
        }
    }

    /// Moves the pointer to the window's center unless it is already inside the window,
    /// as AeroSpace's `move-mouse window-lazy-center` does.
    private func centerPointer(on window: WindowID) {
        guard let frame = SkyLight.rows([window]).first?.frame, !frame.isEmpty,
              let pointer = CGEvent(source: nil)?.location, !frame.contains(pointer) else { return }
        CGWarpMouseCursorPosition(CGPoint(x: frame.midX, y: frame.midY))
    }

    private func touch(_ window: WindowID) {
        recent.removeAll { $0 == window }
        recent.append(window)
    }

    private func mostRecent(_ windows: [WindowID]) -> WindowID? {
        windows.max { (recent.lastIndex(of: $0) ?? -1) < (recent.lastIndex(of: $1) ?? -1) }
    }

    /// One snapshot for the bar and for `kosmos subscribe` (DESIGN.md, section 5.12).
    private func publishState() {
        let data = stateJSON()
        bar.publish(data)
        publish?(data)
    }

    /// The bar snapshot as JSON, also printed by `kosmos state` for a bar that starts late.
    private func stateJSON() -> Data {
        let snapshot = session.barSnapshot(
            profile: profile, display: barDisplay,
            app: { [owner, inventory] id in owner[id].flatMap { inventory.appIdentity($0).name } },
            frame: { [inventory] id in inventory.windows[id]?.frame })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(snapshot)) ?? Data("{}".utf8)
    }
}
