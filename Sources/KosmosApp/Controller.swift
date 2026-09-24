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
    /// The key window macOS last reported.
    private var key: KeyWindow?
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
            // Already in native fullscreen or hidden with its app, as at launch: it waits
            // parked for its return, with no frame and no concealing. A fullscreen window
            // of a hidden app returns when it leaves fullscreen, not when the app unhides.
            let fullscreen = inventory.fullscreen.contains(id)
            let hidden = !fullscreen && NSRunningApplication(processIdentifier: pid)?.isHidden == true
            if fullscreen || hidden {
                if fullscreen { fullscreenParked.insert(id) } else { hiddenApps[pid, default: []].append(id) }
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
            ledger.forget(id)
            var plan = session.remove(id)
            // Kosmos's focus moved to a window behind the one in native fullscreen, which
            // is still key. Focusing a window of the desktop would take the user out of the
            // fullscreen Space; the fullscreen window brings the focus back when it leaves.
            if case .window(let keyed)? = key, fullscreenParked.contains(keyed) { plan.focus = nil }
            execute(plan)
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

    /// Windows back from minimizing, hiding or fullscreen return to their places, and Kosmos
    /// follows `follow` to its workspace. A command received after the return wins, as over
    /// a stale Command-Tab (DESIGN.md, section 5.5; tla/Kosmos.tla, Rejoin).
    private func returned(_ windows: [WindowID], follow: WindowID?, at stamp: ContinuousClock.Instant) {
        execute(session.unpark(windows, follow: reports.isStale(stamp) ? nil : follow))
    }

    /// Minimized, or hidden with their app (tla/Kosmos.tla, Depart). macOS keys another
    /// window itself, and that report has Kosmos keep its workspace and focus it again.
    /// Focusing here first could put Kosmos's own echo between the departure and that
    /// report. Only when a focus request found these windows already gone does the
    /// departure focus the workspace's next window, or Finder.
    private func depart(_ windows: [WindowID]) {
        let focusLeft = session.focused.map(windows.contains) == true
        execute(session.park(windows))
        if focusLeft, refocus { requestFocus(intent) }
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
            // A keyed window that did not hide with the app is not followed from here. A
            // minimized one whose Dock thumbnail unhid the app follows by its own return,
            // and a fullscreen one keeps macOS on its Space.
            let follow = keyed.flatMap { session.workspace(of: $0) != nil ? $0 : nil } ?? mostRecent(windows)
            returned(windows, follow: follow, at: received)
        }
    }

    private func handle(_ report: AXReport) {
        switch report.kind {
        case .focusedWindowChanged(let id):
            let reported: KeyWindow = id.map(KeyWindow.window) ?? .none
            // The window key before this report left the screen just now, and Kosmos did
            // not conceal it: macOS keyed this window after that one closed, minimized or
            // hid (DESIGN.md, section 5.4). The bound covers macOS's delay: after a
            // minimize, the new key window was reported 0.73 s after the minimize.
            var keyLeft = false
            if case .window(let previous)? = key, previous != id,
               session.workspace(of: previous).map({ $0 == session.visible || session.isParked(previous) }) ?? true {
                keyLeft = inventory.leftScreen(previous, within: .seconds(1))
            }
            key = reported
            // Dialogs and panels are not managed; their focus is theirs. A parked window is
            // key in its own fullscreen Space, or just before it returns, which follows it.
            if let id, session.workspace(of: id) == nil || session.isParked(id) { return }
            let verdict = reports.classify(reported, receivedAt: report.received,
                                           onCurrentWorkspace: id.map { session.workspace(of: $0) == session.visible } ?? false,
                                           wasHidden: id.map(hiding.isConcealed) ?? false, keyLeft: keyLeft)
            controllerLog.debug("focus report \(String(describing: reported), privacy: .public): \(String(describing: verdict), privacy: .public)")
            switch verdict {
            case .echo, .ignore:
                break
            case .reassert:
                requestFocus(intent)
            case .adopt(let window):
                session.adopt(window)
                touch(window)
                publishState()
            case .follow(let window):
                touch(window)
                execute(session.follow(window))
            }
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

    // MARK: Plans

    private var intent: KeyWindow { session.focused.map(KeyWindow.window) ?? .none }

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
            if plan.focus != nil { requestFocus(intent, movePointer: movePointer) }
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
                self.requestFocus(self.intent, movePointer: movePointer)
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

    private func requestFocus(_ target: KeyWindow, movePointer: Bool = false) {
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
