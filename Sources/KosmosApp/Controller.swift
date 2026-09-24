import AppKit
import KosmosCore
import os

private let controllerLog = Logger(subsystem: "io.github.st-eez.kosmos", category: "controller")

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
    /// The key window macOS last reported.
    private var key: KeyWindow?
    /// False while another tiling window manager runs: Kosmos then only observes.
    let managing: Bool
    var publish: (@MainActor (Data) -> Void)?

    init(inventory: Inventory, hiding: Hiding, names: [String], managing: Bool) {
        self.inventory = inventory
        self.hiding = hiding
        self.managing = managing
        session = Session(names: names, display: Controller.displayRect())
        inventory.onManagedChange = { [weak self] id, pid, managed in self?.managedChanged(id, pid: pid, managed) }
        inventory.onReport = { [weak self] report in self?.handle(report) }
    }

    /// Runs one command. Returns the exit code and the text for the CLI.
    func run(_ arguments: [String], received: ContinuousClock.Instant) -> (code: Int32, text: String) {
        switch Command.parse(arguments) {
        case .failure(let error):
            return (1, error.message)
        case .success(let command):
            reports.commandExecuted(receivedAt: received)
            if let plan = session.perform(command) { execute(plan) }
            return (0, "")
        }
    }

    /// The main display's visible area in the top left origin coordinates Accessibility uses.
    static func displayRect() -> CGRect {
        guard let main = NSScreen.main, let primary = NSScreen.screens.first else { return .zero }
        let visible = main.visibleFrame
        return CGRect(x: visible.minX, y: primary.frame.height - visible.maxY, width: visible.width, height: visible.height)
    }

    // MARK: Events

    private func managedChanged(_ id: WindowID, pid: pid_t, _ managed: Bool) {
        if managed {
            owner[id] = pid
            execute(session.add(id))
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
            // Dialogs and panels are not managed; their focus is theirs.
            if let id, session.workspace(of: id) == nil { return }
            let verdict = reports.classify(reported, receivedAt: report.received,
                                           onCurrentWorkspace: id.map { session.workspace(of: $0) == session.visible } ?? false,
                                           wasHidden: id.map(hiding.isConcealed) ?? false)
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
        case .minimized(let id, let minimized):
            execute(minimized ? session.park(id) : session.unpark(id))
        case .framesApplied(let results):
            for result in results { ledger.confirm(result.id, target: result.target, readBack: result.readBack) }
        case .windowCreated, .windowDestroyed, .titleChanged:
            break
        }
    }

    // MARK: Plans

    private var intent: KeyWindow { session.focused.map(KeyWindow.window) ?? .none }

    private func execute(_ plan: Session.Plan) {
        guard managing, !plan.isEmpty else { return publishState() }
        writeFrames(plan.frames)
        if plan.show.isEmpty && plan.hide.isEmpty {
            if plan.focus != nil { requestFocus(intent) }
        } else {
            switchGeneration += 1
            let generation = switchGeneration
            hiding.apply(show: plan.show, hide: concealment(of: plan.hide)) { [weak self] confirmed in
                guard let self else { return }
                if !confirmed { controllerLog.error("switch not confirmed; windows restored") }
                // A newer switch focuses for itself (tla/Kosmos.tla, Resume).
                guard confirmed, generation == self.switchGeneration else { return }
                self.requestFocus(self.intent)
            }
        }
        publishState()
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
                : group.max { (recent.lastIndex(of: $0) ?? -1) < (recent.lastIndex(of: $1) ?? -1) }
            for window in group { kinds[window] = window == selected ? .keepOrdinary : .exclusive }
        }
        return kinds
    }

    private func requestFocus(_ target: KeyWindow) {
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

    private func touch(_ window: WindowID) {
        recent.removeAll { $0 == window }
        recent.append(window)
    }

    /// One snapshot for the bar and for `kosmos subscribe`.
    private func publishState() {
        let workspaces = session.names.map { name -> [String: Any] in
            ["name": name, "windows": session.windows(of: name).count, "visible": name == session.visible]
        }
        var state: [String: Any] = ["workspaces": workspaces, "visible": session.visible]
        if let focused = session.focused { state["focused"] = Int(focused) }
        guard let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]) else { return }
        bar.publish(data)
        publish?(data)
    }
}
