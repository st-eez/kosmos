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
    private var misses = FocusMisses<ContinuousClock.Instant>()
    private let inventory: Inventory
    private let hiding: Hiding
    private let focusQueue = FocusQueue()
    private let bar = BarPush()
    /// Bumped by every switch; a switch whose barrier returns after a newer one does not focus.
    private var switchGeneration = 0
    private var owner: [WindowID: pid_t] = [:]
    /// Window ids by most recent focus, newest last.
    private var recent: [WindowID] = []
    /// The key window macOS last reported.
    private var key: KeyWindow?
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
    /// The display the session tiles, as the bar numbers it. Read at launch and at each
    /// resync, as the session's display is.
    private var barDisplay: BarSnapshot.Display
    var publish: (@MainActor (Data) -> Void)?
    /// Called with a description when the private focus path turns off, and with nil when it
    /// turns back on.
    var onFocusProblem: (@MainActor (String?) -> Void)?
    /// While the session is locked or switched out, Kosmos writes no frames, runs no hides,
    /// requests no focus and takes no command; `resync` catches up (DESIGN.md, section 5.1).
    private var sessionLocked: Bool { inventory.sessionLocked }

    init(inventory: Inventory, hiding: Hiding, names: [String], gaps: Gaps, managing: Bool) {
        self.inventory = inventory
        self.hiding = hiding
        self.managing = managing
        session = Session(names: names, display: Controller.displayRect(), gaps: gaps)
        barDisplay = Controller.barDisplay()
        inventory.onManagedChange = { [weak self] id, pid, managed in self?.managedChanged(id, pid: pid, managed) }
        inventory.onReport = { [weak self] report in self?.handle(report) }
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

    /// Why the private focus path is off, for the status item, or nil while it is on.
    var focusProblem: String? {
        switch focusQueue.killSwitch.offReason {
        case .crashed?: "Private focus is off after a crash inside it, until kosmos reload-config"
        case .wrongWindows?: "Private focus is off after \(FocusMisses<ContinuousClock.Instant>.limit) wrong windows in a row, until kosmos reload-config"
        case nil: nil
        }
    }

    /// A config reload turns the private focus path back on (DESIGN.md, section 5.4).
    func turnOnPrivateFocus() {
        guard focusQueue.killSwitch.offReason != nil else { return }
        focusQueue.killSwitch.turnOn()
        misses = FocusMisses()
        controllerLog.notice("private focus is on again")
        onFocusProblem?(nil)
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
        case .success where sessionLocked:
            return (1, "the session is locked")
        case .success(let command):
            reports.commandExecuted(receivedAt: received)
            if let plan = session.perform(command) { execute(plan, since: received, fromCommand: true) }
            return (0, "")
        }
    }

    /// After an unlock, or a wake while unlocked: reads the main display again, lays the shown
    /// workspace out on its area as it is now, conceals and reveals every window again,
    /// requests the focus intent and publishes the state. Other workspaces are laid out when
    /// they are shown.
    func resync() {
        // With no display at all, the ones read before stay.
        let display = Controller.displayRect()
        if display != .zero {
            barDisplay = Controller.barDisplay()
            if display != session.display {
                controllerLog.notice("display area is now \(String(describing: display), privacy: .public)")
                session.display = display
            }
        }
        guard managing else { return publishState() }
        // Reports received before now are older than the focus this asks for again.
        reports.commandExecuted(receivedAt: .now)
        var plan = Session.Plan()
        plan.frames = session.frames(of: session.visible)
        plan.show = session.windows(of: session.visible)
        plan.hide = session.names.filter { $0 != session.visible }.flatMap { session.windows(of: $0) }
        plan.focus = intent
        execute(plan)
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
            // Reported key before it was managed, as at launch: that report was dropped.
            if inventory.focused == id, session.workspace(of: id) == session.visible { session.adopt(id) }
            execute(plan)
        } else {
            owner[id] = nil
            recent.removeAll { $0 == id }
            ledger.forget(id)
            execute(session.remove(id))
        }
    }

    private func handle(_ report: AXReport) {
        switch report.kind {
        case .focusedWindowChanged(let id):
            let reported: KeyWindow = id.map(KeyWindow.window) ?? .none
            key = reported
            guard !sessionLocked else { return }   // resync requests the intent again
            // Dialogs and panels are not managed; their focus is theirs.
            if let id, session.workspace(of: id) == nil { return }
            let verdict = reports.classify(reported, receivedAt: report.received,
                                           onCurrentWorkspace: id.map { session.workspace(of: $0) == session.visible } ?? false,
                                           wasHidden: id.map(hiding.isConcealed) ?? false)
            controllerLog.debug("focus report \(String(describing: reported), privacy: .public): \(String(describing: verdict), privacy: .public)")
            misses.reported(reported, pid: report.pid, receivedAt: report.received, echo: verdict == .echo)
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
            execute(session.park(id))
        case .minimized(let id, false):
            // A restored window returns to its own workspace, and Kosmos follows it there
            // (DESIGN.md, section 5.5).
            var plan = session.unpark(id)
            if let home = session.workspace(of: id), home != session.visible {
                let frames = plan.frames
                plan = session.follow(id)
                plan.frames.merge(frames) { new, _ in new }
            }
            execute(plan)
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
        case .windowCreated, .windowDestroyed, .answering:
            break
        }
    }

    // MARK: Plans

    private var intent: KeyWindow { session.focused.map(KeyWindow.window) ?? .none }

    /// `since` is when the command arrived, for the switch timing log.
    private func execute(_ plan: Session.Plan, since received: ContinuousClock.Instant = .now, fromCommand: Bool = false) {
        guard managing, !sessionLocked, !plan.isEmpty else { return publishState() }
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
        guard !sessionLocked else { return }
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
                : group.max { (recent.lastIndex(of: $0) ?? -1) < (recent.lastIndex(of: $1) ?? -1) }
            for window in group { kinds[window] = window == selected ? .keepOrdinary : .exclusive }
        }
        return kinds
    }

    private func requestFocus(_ target: KeyWindow, movePointer: Bool = false) {
        guard !sessionLocked else { return }
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
        let privately = focusQueue.killSwitch.isOn
        focusQueue.request(target, pid: pid, worker: inventory.worker(pid), privately: privately,
                           generation: focusQueue.newGeneration(),
                           performing: { [weak self] stamp in self?.performing(target, pid: pid, privately: privately, at: stamp) },
                           dropped: { [weak self] stamp in
                               self?.reports.requestDropped(target, at: stamp)
                               self?.misses.requestDropped(at: stamp)
                           })
    }

    /// The focus queue is about to key `target`: records the echo that will come back, and
    /// counts a private request toward the kill switch (DESIGN.md, section 5.4).
    private func performing(_ target: KeyWindow, pid: pid_t, privately: Bool, at stamp: ContinuousClock.Instant) {
        reports.focusRequested(target, at: stamp)
        guard privately, focusQueue.killSwitch.isOn, case .window(let id) = target,
              misses.willRequest(id, pid: pid, at: stamp) else { return }
        focusQueue.killSwitch.turnOff(.wrongWindows)
        controllerLog.fault("private focus keyed another window \(FocusMisses<ContinuousClock.Instant>.limit) times in a row; focus uses the public path")
        onFocusProblem?(focusProblem)
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
