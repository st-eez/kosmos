import AppKit
import KosmosCore
import KosmosSkyLight
import os

private let controllerLog = Logger(subsystem: "io.github.st-eez.kosmos", category: "controller")
private let signposter = OSSignposter(subsystem: "io.github.st-eez.kosmos", category: .pointsOfInterest)

/// Turns commands, the inventory's window events and key window reports, mouse presses,
/// modifier drags and pointer movement into Session changes. Carries out the Session's plans
/// through the app workers, Hiding, the focus queue and Slides, and publishes each change to
/// the bar and the borders (docs/overview.md, section 4.3; tla/Kosmos.tla).
@MainActor
final class Controller {
    private var session: Session
    private var ledger = FrameLedger()
    private var reports = FocusReports()
    private var misses = FocusMisses()
    private let inventory: Inventory
    private let hiding: Hiding
    private let emptyWorkspace: EmptyWorkspaceWindow
    private let focusQueue: FocusQueue
    private let bar = BarPush()
    private var switchGeneration = 0
    private var owner: [WindowID: pid_t] = [:]
    /// Newest last.
    private var recent: [WindowID] = []
    /// The windows of each hidden app, parked until it unhides.
    private var hiddenApps: [pid_t: [WindowID]] = [:]
    private var fullscreenParked: Set<WindowID> = []
    /// Parked, as their app ordered them out and kept them (docs/tree.md).
    private var closedByApp: Set<WindowID> = []
    private var tabSwitches = TabSwitches()
    private var tabs = TabGroups()
    /// The last key report of a window with no place, or parked as closed and kept, decided
    /// when the window takes a place (docs/focus.md).
    private var unplacedKey: KeyReport?
    /// Admitted on a shown workspace before their apps keyed them (AdmissionFocus.awaitKey).
    /// A report within `keyAfterAdmission` brings the pointer (docs/focus-follows-mouse.md).
    private var admittedUnkeyed: [WindowID: ContinuousClock.Instant] = [:]
    private static let keyAfterAdmission: Duration = .seconds(ActivationInput.maxAge)
    /// Windows admitted to a hidden workspace, and tabs a switch placed on one, until their
    /// conceal lands. macOS keyed such a window by the user's or the app's choice, so its
    /// report is followed (docs/focus.md).
    private var placedHidden: [WindowID: Placed] = [:]
    private enum Placed { case admitted, tab }
    /// Too old to skip a focus request against; the focus queue checks as the request runs.
    private var keyHistory = KeyHistory()
    private var key: KeyWindow? { keyHistory.key }
    /// A Date, to compare with app launch dates.
    private var emptyWorkspaceKeyed = Date.distantPast
    private var held = HeldReport<KeyReport>()
    /// A departure waiting for macOS's report of the next key window (DepartureFocus).
    private var awaitingKey: (window: WindowID, number: Int)?
    private var departureNumber = 0
    private var needsResync = false
    /// Tiled windows the left button moved or resized without lifting them, which go back
    /// to their tiles at its mouse up. A resize by the edges never lifts (docs/geometry.md).
    private var mouseMoved: [WindowID: (before: CGRect, resized: Bool)] = [:]
    private var leftButton = LeftButton()
    private var clickedWindow = 0
    /// False while another tiling window manager runs: Kosmos then only observes.
    let managing: Bool
    var rules: [WindowRule] = []
    var mouseFollowsFocus = false
    /// The `focus-follows-mouse` command changes `enabled` until the next config load.
    var focusFollowsMouse = FocusFollowsMouse() {
        didSet { updatePointerTap() }
    }
    private var pointer: PointerTap?
    /// A tap made without Input Monitoring may hear nothing (docs/focus-follows-mouse.md).
    private var pointerListens = false
    var wantsPointer: Bool { focusFollowsMouse.enabled && managing }
    var onInputMonitoringMissing: (@MainActor () -> Void)?
    var mouseModifier: KeyCombo.Modifiers? {
        didSet { updateDragTap() }
    }
    private var dragTap: DragTap?
    private var modifierDrag: ModifierDrag?
    private var dragging: Bool { !session.lifted.isEmpty || modifierDrag != nil }
    private(set) var profile: String?
    private var barDisplays: [DisplayID: BarSnapshot.Display]
    var publish: (@MainActor (Data) -> Void)?
    var onFocusProblem: (@MainActor (String?) -> Void)?
    /// While locked, Kosmos writes no frames, hides nothing, requests no focus and takes no
    /// command; resync catches up (docs/inventory.md).
    private var sessionLocked: Bool { inventory.sessionLocked }
    /// Kept once made, as the recovery record holds its Spaces.
    private var slides: Slides?
    var animations = false {
        didSet {
            if animations, managing, slides == nil {
                slides = Slides(hiding: hiding)
                slides?.onChange = { [weak self] in self?.updateBorders() }
            }
            if !animations { slides?.endAll("as animations turned off") }
        }
    }
    var borders: BorderSettings? = BorderSettings() {
        didSet { if borders != oldValue { updateBorders() } }
    }
    private let borderWindows = Borders()

    init(inventory: Inventory, hiding: Hiding, setup: Setup, barDisplays: [DisplayID: BarSnapshot.Display], managing: Bool) {
        self.inventory = inventory
        self.hiding = hiding
        self.managing = managing
        let emptyWorkspace = EmptyWorkspaceWindow()
        emptyWorkspace.onKey = { [weak inventory] stamp in inventory?.ownWindowKeyed(at: stamp) }
        self.emptyWorkspace = emptyWorkspace
        focusQueue = FocusQueue(emptyWorkspace: emptyWorkspace.target)
        session = Session(names: setup.workspaces, monitors: setup.monitors, assigned: setup.workspaceDisplays)
        rules = setup.rules
        profile = setup.profile
        self.barDisplays = barDisplays
        inventory.onEvent = { [weak self] event in self?.handle(event) }
        borderWindows.onAccentChange = { [weak self] in self?.updateBorders() }
        // AppKit calls a global monitor's handler on the main thread.
        _ = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let point = event.cgEvent?.location else { return }
            // A global event has no window, so its location is on the screen.
            let location = event.locationInWindow
            MainActor.assumeIsolated { self?.leftMouseDown(at: point, location: location) }
        }
        _ = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            let point = event.cgEvent?.location
            MainActor.assumeIsolated { self?.leftMouseUpHeard(at: point) }
        }
    }

    func apply(_ setup: Setup, barDisplays: [DisplayID: BarSnapshot.Display]) {
        slides?.endAll("at a reload, a display change, a wake or an unlock")
        rules = setup.rules
        profile = setup.profile
        self.barDisplays = barDisplays
        let displaysBefore = session.monitors
        session.reconfigure(names: setup.workspaces, monitors: setup.monitors, assigned: setup.workspaceDisplays,
                            merge: setup.mergeWorkspaces)
        pointer?.setMonitors(session.monitors)
        dragTap?.setMonitors(session.monitors)
        let shown = session.monitors.map { "\($0.id): \(session.workspace(shownOn: $0.id) ?? "none")" }
        controllerLog.notice("""
            profile \(setup.profile ?? "base", privacy: .public), workspace on each display \
            \(shown.joined(separator: ", "), privacy: .public), focused \(self.session.focusedWorkspace, privacy: .public)
            """)
        // macOS can move windows while locked or asleep, and moves a leaving display's, so
        // every frame is written again.
        ledger = FrameLedger()
        resync(displaysChanged: session.monitors != displaysBefore)
    }

    /// The tap is made again after a refusal, or when it predates an Input Monitoring grant
    /// (docs/focus-follows-mouse.md).
    private func updatePointerTap() {
        let listening = CGPreflightListenEventAccess()
        if !listening { pointerListens = false }
        if wantsPointer, pointer == nil || (listening && !pointerListens) { makePointerTap(listening: listening) }
        pointer?.setEnabled(focusFollowsMouse.enabled)
        if wantsPointer, !listening { onInputMonitoringMissing?() }
    }

    func renewPointerTapAfterGrant() {
        guard CGPreflightListenEventAccess() else { pointerListens = false; return }
        guard wantsPointer, !pointerListens else { return }
        makePointerTap(listening: true)
        pointer?.setEnabled(true)
    }

    private func makePointerTap(listening: Bool) {
        pointer?.stop()
        pointer = PointerTap { [weak self] entered, stamp in self?.pointerEntered(entered, at: stamp) }
        pointer?.setMonitors(session.monitors)
        pointerListens = listening
    }

    /// Turned off at a reload, the tap stays and begins no drag (docs/modifier-drags.md).
    private func updateDragTap() {
        if dragTap == nil, managing, mouseModifier != nil {
            dragTap = DragTap { [weak self] outcome, stamp in self?.dragHeard(outcome, at: stamp) }
            dragTap?.setWindows(draggable)
            dragTap?.setMonitors(session.monitors)
        }
        dragTap?.setModifiers(mouseModifier)
    }

    private var draggable: Set<WindowID> { Set(session.shownWorkspaces.flatMap { session.windows(of: $0) }) }

    var hasFocusedWindow: Bool { session.focused != nil }

    func refocus() {
        requestFocus(session.intent)
    }

    var focusProblem: String? {
        switch focusQueue.killSwitch.offReason {
        case .crashed?: "Private focus is off after a crash inside it, until kosmos reload-config"
        case .wrongWindows?: "Private focus is off after \(FocusMisses.limit) wrong windows in a row, until kosmos reload-config"
        case nil: nil
        }
    }

    func turnOnPrivateFocus() {
        guard focusQueue.killSwitch.offReason != nil else { return }
        focusQueue.killSwitch.turnOn()
        misses = FocusMisses()
        controllerLog.notice("private focus is on again")
        onFocusProblem?(nil)
    }

    func run(_ arguments: [String], received: ContinuousClock.Instant, from source: CommandSource) -> (code: Int32, text: String) {
        switch arguments {
        case ["state"]:
            return (0, String(decoding: stateJSON(), as: UTF8.self))
        case ["list-workspaces"]:
            return (0, session.names.map { $0 == session.focusedWorkspace ? "\($0) *" : $0 }.joined(separator: "\n"))
        case ["list-windows"]:
            let lines = session.names.flatMap { name in
                session.windows(of: name).map { id in
                    let app = owner[id].flatMap { inventory.appIdentity($0).name } ?? "?"
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
        case .success(.focusFollowsMouse(let change)):
            focusFollowsMouse.enabled = switch change {
            case .on: true
            case .off: false
            case .toggle: !focusFollowsMouse.enabled
            }
            if focusFollowsMouse.enabled, pointer == nil {
                return (1, """
                    focus follows mouse gets no pointer movement: macOS refused Kosmos's event tap. \
                    Allow Kosmos in System Settings, Privacy & Security, Input Monitoring, then run \
                    kosmos focus-follows-mouse on
                    """)
            }
            return (0, "")
        case .success(let command):
            if let missing = session.missingWorkspace(in: command) {
                return (1, "no workspace \(missing); the workspaces are \(session.names.joined(separator: " "))")
            }
            reports.commandExecuted(receivedAt: received)
            // Floating windows' frames as the inventory last heard them, so nothing waits on
            // WindowServer.
            if let plan = session.perform(command, frame: { [inventory] in inventory.windows[$0]?.frame }) {
                execute(plan, since: received, fromCommand: true, movePointer: movesPointer(after: command, from: source))
            }
            return (0, "")
        }
    }

    private func resync(displaysChanged: Bool) {
        forgetPresses()
        guard managing else { return publishState() }
        // Reports before now are older than the focus asked for again, and an echo in flight
        // at the lock was dropped with the reports while locked.
        reports.forgetRequests()
        reports.commandExecuted(receivedAt: .now)
        // A concealed window left on a display that is gone would come back off screen from
        // recovery, so after a display change hidden workspaces are laid out on theirs now.
        var plan = session.resyncPlan(layingOutHidden: displaysChanged)
        plan.focus = session.intent
        execute(plan)
    }

    // MARK: Events

    private func handle(_ event: Inventory.Event) {
        switch event {
        case .managedChange(let id, let pid, let managed):
            managedChanged(id, pid: pid, managed)
        case .report(let report):
            handle(report)
        case .appHidden(let pid, true, _):
            appHidden(pid)
        case .appHidden(let pid, false, let received):
            appUnhidden(pid, at: received)
        case .keptOrderedOut(let id, let orderedOut):
            keptOrderedOut(id, orderedOut: orderedOut)
        case .orderChange(let id, let pid, let orderedIn, let frame, let at):
            orderChanged(id, pid: pid, orderedIn, frame: frame, at: at)
            updateBorders()
        case .fullscreenChange(let id, let entered, let spaceChangeBegan):
            fullscreenChanged(id, entered, spaceChangeBegan: spaceChangeBegan)
        case .frameChange(let id, let old, let frame, let changedAt):
            frameChanged(id, from: old, to: frame, changedAt: changedAt)
            updateBorders()
        case .reordered(let id):
            borderWindows.raise(id)
        case .styleChange:
            updateBorders()
        }
    }

    private func managedChanged(_ id: WindowID, pid: pid_t, _ managed: Bool) {
        if managed {
            owner[id] = pid
            // A deselected tab waits as a hidden member. A tab selected before now, as a new
            // tab is, takes its group's place.
            switch tabs.admitting(id) {
            case .hidden: return
            case .takes(let old): if tabSwitched(from: old, to: id, frame: inventory.windows[id]?.frame) { return }
            case .own: break
            }
            place(id, pid: pid, ruleWorkspace: true, reopened: false)
        } else if session.workspace(of: id) != nil, inventory.hasOrderedOutWindows(pid, besides: id) {
            // Perhaps a selected tab closed before the next tab came in: its place waits a
            // pairing window for that tab (docs/tree.md).
            after(TabSwitches.window) { controller in
                if !controller.inventory.isManaged(id) { controller.forget(id, pid: pid) }
            }
        } else {
            forget(id, pid: pid)
        }
    }

    /// A window already minimized, in native fullscreen or hidden with its app waits parked,
    /// and a minimized or fullscreen one returns on its own, not when its app unhides.
    /// `reopened`: a window closed and kept, ordered in again, opens as a new window does
    /// (docs/tree.md).
    private func place(_ id: WindowID, pid: pid_t, ruleWorkspace: Bool, reopened: Bool) {
        let app = inventory.appIdentity(pid)
        let rule = rules.first { $0.matches(appID: app.bundleID, appName: app.name) }
        // A window there at launch joins the workspace of the display under it; a later one
        // joins the focused workspace, as in AeroSpace (docs/displays.md).
        let atLaunch = !reopened && inventory.wasThereAtLaunch(id)
        let center = atLaunch ? inventory.windows[id].map { CGPoint(x: $0.frame.midX, y: $0.frame.midY) } : nil
        let floats = rule?.float == true, workspace = ruleWorkspace ? rule?.workspace : nil
        let placed: Session.Plan? = reopened ? session.reopen(id, to: workspace, floating: floats)
                                             : session.add(id, to: workspace, at: center, floating: floats)
        guard var plan = placed else { return }
        if floats, let frame = inventory.windows[id]?.frame {
            controllerLog.info("\(id) floats by rule at its own frame, \(Int(frame.width))x\(Int(frame.height)) at \(Int(frame.minX)), \(Int(frame.minY))")
        }
        if let reason = ParkReason.atAdmission(fullscreen: inventory.fullscreen.contains(id),
                                               minimized: inventory.isMinimized(id),
                                               appHidden: NSRunningApplication(processIdentifier: pid)?.isHidden == true) {
            if reason == .fullscreen { fullscreenParked.insert(id) }
            if reason == .appHidden { hiddenApps[pid, default: []].append(id) }
            plan.frames = session.park([id]).frames
            plan.hide.removeAll { $0 == id }
        }
        let report = unplacedKey.flatMap { $0.key == .window(id) ? $0 : nil }
        if report != nil { unplacedKey = nil }
        let keyed = key == .window(id), shown = session.workspace(of: id).map(session.isShown) == true
        let focus = AdmissionFocus.decide(keyed: keyed, shown: shown, parked: session.isParked(id),
                                          atLaunch: atLaunch, locked: sessionLocked)
        switch focus {
        case .adopt: session.adopt(id)
        case .awaitKey: admittedUnkeyed[id] = .now
        case .placedHidden: placedHidden[id] = .admitted
        case .none: break
        }
        // A new window its app keyed brings the pointer on any display
        // (docs/focus-follows-mouse.md).
        let new = !atLaunch
        execute(plan, movePointer: mouseFollowsFocus && focus == .adopt && new && !UserInput.leftButtonDown,
                floatingCheck: floats, popping: new ? id : nil)
        // The follow's switch reveals the window the plan conceals.
        if focus == .placedHidden, var report {
            placedHidden[id] = nil
            report.concealed = true
            report.admitted = true
            decidePlaced(report, keyLeft: .stayed)
        }
    }

    private func forget(_ id: WindowID, pid: pid_t) {
        owner[id] = nil
        recent.removeAll { $0 == id }
        hiddenApps[pid]?.removeAll { $0 == id }
        fullscreenParked.remove(id)
        closedByApp.remove(id)
        tabs.forget(id)
        placedHidden[id] = nil
        ledger.forget(id)
        hiding.forgetClosed(id)
        execute(session.remove(id))
    }

    /// A native fullscreen window is on a Space of its own, so it parks (docs/tree.md).
    private func fullscreenChanged(_ id: WindowID, _ entered: Bool, spaceChangeBegan: ContinuousClock.Instant) {
        if entered {
            // Parked as closed and kept, as when its transition posted no Space event near its
            // order-out: it changes reason.
            if closedByApp.remove(id) != nil {
                fullscreenParked.insert(id)
                return
            }
            guard !session.isParked(id) || session.lifted.contains(id) else { return }
            fullscreenParked.insert(id)
            execute(session.park([id]))
        } else if fullscreenParked.remove(id) != nil {
            // macOS restores the frame it had; write the tile's frame again all the same.
            ledger.forget(id)
            returned([id], follow: id, at: spaceChangeBegan)
        }
    }

    /// A window ordered in as another of its app with its frame leaves is a native tab
    /// switch. A hidden tab ordered in with no tab leaving is back a pairing window later. So
    /// is a window closed and kept while another window of its app is ordered in at its frame,
    /// as only that window's order-out can still pair, and otherwise it reopens now
    /// (docs/tree.md).
    private func orderChanged(_ id: WindowID, pid: pid_t, _ orderedIn: Bool, frame: CGRect, at: ContinuousClock.Instant) {
        // Measures the tab pairing window; remove once a day of Ghostty and Finder tabs sets it (docs/tree.md).
        controllerLog.info("\(id) ordered \(orderedIn ? "in" : "out", privacy: .public), app \(self.inventory.appIdentity(pid).name ?? String(pid), privacy: .public)")
        if let change = tabSwitches.ordered(id, in: orderedIn, frame: frame, app: pid, at: at),
           tabSwitched(from: change.old, to: change.new, frame: frame) {
            return
        }
        guard orderedIn, tabs.hidden.contains(id) || closedByApp.contains(id) else { return }
        // Ceiling: a window that waits and is no tab switch shows at its old place for the
        // wait; a pool Space could hold it transparent (docs/tree.md).
        if closedByApp.contains(id), !inventory.hasOrderedInWindow(pid, at: frame, besides: id) {
            return reopen(id, pid: pid)
        }
        after(TabSwitches.window) { controller in
            guard controller.inventory.windows[id]?.orderedIn == true else { return }
            if controller.closedByApp.contains(id) {
                controller.reopen(id, pid: pid)
            } else if controller.tabs.detached(id), let pid = controller.owner[id] {
                controller.place(id, pid: pid, ruleWorkspace: false, reopened: false)
            }
        }
    }

    /// An ordered out window leaves every Space, the holding Space too, so a conceal from
    /// before it closed would fail the next batch's confirmation.
    private func reopen(_ id: WindowID, pid: pid_t) {
        closedByApp.remove(id)
        ledger.forget(id)
        hiding.forgetClosed(id)
        place(id, pid: pid, ruleWorkspace: true, reopened: true)
    }

    /// `new` takes the deselected tab's place with no reflow and no follow, once admitted
    /// (docs/tree.md). False when the deselected tab holds no place.
    private func tabSwitched(from deselected: WindowID, to new: WindowID, frame: CGRect?) -> Bool {
        let old: WindowID
        switch tabs.switched(from: deselected, to: new, admitted: owner[new] != nil,
                             placed: { self.session.workspace(of: $0) != nil },
                             sharesFrame: { frame != nil && self.inventory.windows[$0]?.frame == frame }) {
        case .none: return false
        case .pending:
            controllerLog.info("tab \(new) takes the place of \(deselected) once admitted")
            return true
        case .replace(let holder): old = holder
        }
        // Parked as closed and kept before the switch took effect, as when the new tab's
        // admission outlasted the claimed tab's wait. The replace's plan lays the place out.
        let parked = closedByApp.remove(old) != nil
        if parked { _ = session.unpark([old], follow: nil) }
        guard let plan = session.replace(old, with: new) else { return false }
        placedHidden[old] = nil
        if plan.hide.contains(new) { placedHidden[new] = .tab }
        controllerLog.info("tab \(new) replaces \(old)\(parked ? ", after \(old) parked as closed and kept" : "", privacy: .public)")
        tabs.replaced(old, with: new)
        // Parked as closed by its app, as a window Merge All Windows made a tab.
        closedByApp.remove(new)
        // A switch inside a native fullscreen group: the new tab is the one in fullscreen.
        if fullscreenParked.remove(old) != nil { fullscreenParked.insert(new) }
        // A deselected tab leaves every Space, and the tab selected lands on its ordinary
        // Space whatever was concealed (kosmos-probe tabs); the plan conceals it afresh.
        hiding.forget([old, new])
        ledger.forget(new)
        if key == .window(old) { keyHistory.key = .window(new) }
        execute(plan)
        // macOS can report the new tab key before it has a place: the user's or the app's
        // choice, whose key window before it, the deselected tab, did not depart (docs/tree.md).
        if var report = unplacedKey, report.key == .window(new), !session.isParked(new) {
            unplacedKey = nil
            placedHidden[new] = nil
            report.concealed = session.workspace(of: new).map { !session.isShown($0) } ?? false
            decidePlaced(report, keyLeft: .stayed)
        }
        return true
    }

    /// Parked, not removed: removing it would lose the place a tab switch gives the next tab,
    /// and the inventory would not admit it again while it stays managed (docs/tree.md).
    private func keptOrderedOut(_ id: WindowID, orderedOut: ContinuousClock.Instant) {
        guard session.workspace(of: id) != nil, !session.isParked(id) || session.lifted.contains(id) else { return }
        if let wait = ClosedAndKept.hold(orderedOut: orderedOut, claimed: tabs.isClaimed(id),
                                         sibling: owner[id].map { inventory.hasOrderedOutWindows($0, besides: id) } ?? false,
                                         spacesChanged: inventory.spacesChangedAt, at: .now) {
            after(wait) { controller in
                if controller.inventory.isKeptOrderedOut(id) { controller.keptOrderedOut(id, orderedOut: orderedOut) }
            }
            return
        }
        controllerLog.info("\(id) closed and kept by its app: parked \((ContinuousClock.now - orderedOut).milliseconds, format: .fixed(precision: 3)) ms after it was seen ordered out")
        closedByApp.insert(id)
        depart([id], remaining: owner[id].map { inventory.otherWindows(of: $0, besides: id) } ?? [])
    }

    /// A command received after the return wins, and its focus is requested again, as macOS
    /// keyed the returning window (docs/tree.md; tla/Kosmos.tla, Rejoin).
    private func returned(_ windows: [WindowID], follow: WindowID?, at stamp: ContinuousClock.Instant) {
        let stale = reports.isStale(stamp)
        var plan = session.unpark(windows, follow: stale ? nil : follow)
        if stale { plan.focus = session.intent }
        // A Dock click or Command-Tab that brings it back picks it away from the pointer.
        execute(plan, movePointer: mouseFollowsFocus && follow != nil && !stale && pickedAwayFromPointer())
    }

    /// When the key window left too and macOS has a window to key, the focus waits for its
    /// report of the next key window, up to the departure bound (tla/Kosmos.tla, Depart).
    private func depart(_ windows: [WindowID], remaining: [DepartureFocus.OtherWindow]? = nil) {
        let focusLeft = session.focused.map(windows.contains) == true
        execute(session.park(windows))
        switch DepartureFocus.decide(focusLeft: focusLeft, key: key, departing: windows, left: inventory.leftScreen,
                                     remaining: remaining) {
        case .none:
            break
        case .now:
            requestFocus(session.intent)
        case .afterKeyReport:
            guard case .window(let keyWindow)? = key else { break }
            departureNumber += 1
            let number = departureNumber
            awaitingKey = (keyWindow, number)
            after(Inventory.departureBound) { controller in
                guard controller.awaitingKey?.number == number else { return }
                controller.awaitingKey = nil
                controller.requestFocus(controller.session.intent)
            }
        }
    }

    /// A window the user drags parks too, where it stood.
    private func appHidden(_ pid: pid_t) {
        let windows = owner.filter { id, app in
            app == pid && session.workspace(of: id) != nil && (!session.isParked(id) || session.lifted.contains(id))
        }.map(\.key)
        guard !windows.isEmpty else { return }
        hiddenApps[pid, default: []] += windows
        depart(windows)
    }

    private func appUnhidden(_ pid: pid_t, at received: ContinuousClock.Instant) {
        guard hiddenApps[pid]?.isEmpty == false else { return }
        Task {
            // An app that does not answer names no window, and the fallback is followed.
            let keyed = await inventory.worker(pid)?.focusedWindow() ?? nil
            // Hidden again while the worker answered: the windows wait for the next unhide.
            guard NSRunningApplication(processIdentifier: pid)?.isHidden != true,
                  let windows = hiddenApps.removeValue(forKey: pid), !windows.isEmpty else { return }
            returned(windows, follow: session.followOnUnhide(windows, keyed: keyed, fallback: mostRecent(windows)),
                     at: received)
        }
    }

    /// Judged as of `changedAt`, as the inventory applies a change after an off main read.
    /// The key tiled window lifts only once it moved whole past TitleBarDrag.dragThreshold, so
    /// a click that jitters the title bar does not lift it (docs/geometry.md, docs/displays.md).
    private func frameChanged(_ id: WindowID, from old: CGRect, to frame: CGRect, changedAt: ContinuousClock.Instant?) {
        guard managing, !sessionLocked, !ledger.isWriting(id), !hiding.isConcealed(id),
              let name = session.workspace(of: id), session.isShown(name), !session.isParked(id) else { return }
        if let changedAt, ledger.isWriting(id, at: changedAt) {
            ledger.observeAfterConfirm(id, frame: frame)
            return
        }
        let button = changedAt.map { leftButton.state(at: $0) } ?? .up
        // The user moves or resizes it, unless the change is its own write landing after the
        // read back, as the other tiles' reflow at a lift lands while the user drags.
        if button != .up { slides?.changedInPress(id, to: frame) }
        ledger.observe(id, frame: frame)
        // Seen smaller than its minimum, the window loses it. During a press, the mouse up
        // lays its workspace out.
        let smaller = session.sizeObserved(id, frame.size)
        if !smaller.isEmpty { controllerLog.notice("\(id) seen at \(Int(frame.width))x\(Int(frame.height)), below its minimum") }
        guard button != .up else {
            if !smaller.isEmpty { execute(smaller) }
            return
        }
        if session.shownFloatingWindows.contains(id) {
            guard key == .window(id), let plan = session.dragged(id, to: frame) else { return }
            controllerLog.info("\(id) dragged to workspace \(self.session.workspace(of: id) ?? "?", privacy: .public)")
            execute(plan)
            return
        }
        guard button == .down else {
            // The mouse up sent back what the press had moved by then, each with a write this
            // change would count as, so this window was not among them.
            controllerLog.info("\(id) changed during a press that has ended goes back to its tile")
            ledger.forget(id)
            execute(session.released([id]))
            return
        }
        let press = mouseMoved[id]
        let before = press?.before ?? old
        // WindowServer can apply a resize by the left or top edge as a move first, so the
        // pointer on a resize border marks one too. Read here, as reading it as each event
        // came would read it at every change event a switch posts.
        let onBorder = press == nil && CGEvent(source: nil).map { TitleBarDrag.onResizeBorder($0.location, of: frame) } == true
        let resized = press?.resized == true || onBorder || frame.size != before.size
        if !resized, key == .window(id), hypot(frame.minX - before.minX, frame.minY - before.minY) > TitleBarDrag.dragThreshold,
           let plan = session.lift(id) {
            mouseMoved[id] = nil
            controllerLog.info("\(id) lifted from workspace \(name, privacy: .public)")
            execute(plan)
        } else {
            mouseMoved[id] = (before, resized)
        }
    }

    /// A hotkey ends a drag where the pointer is before its command runs, as Hyprland does
    /// (docs/displays.md and docs/modifier-drags.md).
    func endDrag() {
        dragTap?.endIfReleased()
        if modifierDrag != nil {
            controllerLog.info("hotkey during a modifier drag: it ends where the pointer is")
            return finishDrag(at: nil)
        }
        guard dragging else { return }
        controllerLog.info("hotkey during a drag: the window drops where the pointer is")
        leftMouseUp(at: nil)
    }

    /// `location` is `point` in AppKit's coordinates. kosmos_make_key posts a mouse down far
    /// past every display with no mouse up, so a press off every display is left out. The
    /// window clicked is found as the press lands: an autohiding Dock can hide before its app
    /// reports a key window (docs/focus-follows-mouse.md).
    private func leftMouseDown(at point: CGPoint, location: NSPoint) {
        // The live test reads whether the monitor hears a press the drag tap took. During a
        // right drag the left button's presses reach the app and count here.
        guard modifierDrag?.grab.button != .left else {
            controllerLog.info("left mouse down heard during a left modifier drag: left out")
            return
        }
        var display: CGDirectDisplayID = 0, count: UInt32 = 0
        let onDisplay = CGGetDisplaysWithPoint(point, 1, &display, &count) == .success && count > 0
        controllerLog.debug("left mouse down at \(point.x), \(point.y)\(onDisplay ? "" : ", off every display: left out", privacy: .public)")
        clickedWindow = 0
        guard onDisplay else { return }
        leftButton.pressed(at: .now)
        if mouseFollowsFocus { clickedWindow = NSWindow.windowNumber(at: location, belowWindowWithWindowNumber: 0) }
    }

    /// At a lock and a resync: a press whose mouse up Kosmos never heard would count as on
    /// until the next click. The resync lays out the windows the presses moved.
    func forgetPresses() {
        leftButton = LeftButton()
        mouseMoved = [:]
        modifierDrag = nil
        dragTap?.endIfReleased()
    }

    /// During a left modifier drag its own end drops the window (finishDrag), so a mouse up
    /// heard here drops nothing twice.
    private func leftMouseUpHeard(at point: CGPoint?) {
        leftButton.released(at: .now)
        guard modifierDrag?.grab.button != .left else {
            controllerLog.info("left mouse up heard during a left modifier drag: left out")
            return
        }
        leftMouseUp(at: point)
    }

    /// `point`: nil for where the pointer is.
    private func leftMouseUp(at point: CGPoint?) {
        guard managing, !sessionLocked else { return }
        let moved = Set(mouseMoved.keys)
        let released = session.lifted.union(moved)
        guard !released.isEmpty else { return }
        mouseMoved = [:]
        // Whole frame writes: the ledger holds a lifted window's frame from before the drag,
        // and a resize can have gone on past the last frame it heard of.
        for id in released { ledger.forget(id) }
        if !session.lifted.isEmpty, let point = point ?? CGEvent(source: nil)?.location {
            let dropped = session.lifted
            let plan = session.drop(at: point)
            controllerLog.info("dropped \(dropped.sorted().map(String.init).joined(separator: " "), privacy: .public) at \(Int(point.x)), \(Int(point.y))")
            execute(plan)
        }
        if !moved.isEmpty {
            controllerLog.info("left mouse up: \(moved.count) tiled windows moved or resized with the button down go back to their tiles")
            execute(session.released(moved))
        }
    }

    /// 100 ms after a first larger read back, as the window's next change event can come
    /// inside a live resize step still queued (docs/geometry.md).
    private func writeTileAgain(_ id: WindowID) {
        guard mouseMoved[id] == nil, let name = session.workspace(of: id), session.isShown(name) else { return }
        writeFrames(session.frames(of: name))
    }

    private func handle(_ report: AXReport) {
        switch report.kind {
        case .backgroundFocus(let id):
            backgroundFocusChanged(id, report: report)
        case .focusedWindowChanged(let id):
            focusedWindowChanged(id, report: report)
        case .minimized(let id, true):
            // Parked as closed and kept if its order-out was looked at first: it is minimized
            // instead.
            closedByApp.remove(id)
            depart([id])
        case .minimized(let id, false):
            returned([id], follow: id, at: report.received)
        case .framesApplied(let results):
            for result in results {
                let asked = "asked \(Int(result.target.width))x\(Int(result.target.height)), kept \(Int(result.readBack.width))x\(Int(result.readBack.height))"
                // Concealed or on a hidden workspace, a window refused once at most, and its
                // retry waits for the reveal (docs/geometry.md). Ceiling: a window a failed batch
                // left concealed on a shown workspace is written every 100 ms while it refuses,
                // until a switch reveals it. Upgrade: writeTileAgain skips concealed windows, and
                // the switch that reveals them (needsResync) writes their tiles.
                if hiding.isConcealed(result.id) || session.workspace(of: result.id).map(session.isShown) != true {
                    ledger.forgetLargerReadBack(result.id)
                }
                slides?.confirmed(result.id, target: result.target, readBack: result.readBack)
                switch ledger.confirm(result.id, target: result.target, readBack: result.readBack, at: .now) {
                case .took:
                    break
                case .refused:
                    controllerLog.info("\(result.id) \(asked, privacy: .public); its tile is written again")
                    after(.milliseconds(100)) { $0.writeTileAgain(result.id) }
                case .minimum(let size):
                    controllerLog.notice("minimum for \(result.id): \(asked, privacy: .public)")
                    execute(session.setMinimum(result.id, size))
                }
            }
        case .framesDropped(let ids):
            // Forgotten, so their targets are not pending for good and the next writes are whole.
            for id in ids { ledger.forget(id) }
        case .windowCreated, .windowDestroyed, .answering:
            break
        }
    }

    /// Never the key window, but it can be Kosmos's echo. It leaves the kill switch's count
    /// alone, as a raise says nothing about the key record (tla/README.md, change 17).
    private func backgroundFocusChanged(_ id: WindowID?, report: AXReport) {
        guard !sessionLocked else { return }
        _ = reports.consumeEcho(id.map(KeyWindow.window) ?? .noWindow, receivedAt: report.received)
    }

    private func focusedWindowChanged(_ id: WindowID?, report: AXReport) {
        let reported: KeyWindow = id.map(KeyWindow.window) ?? .noWindow
        let repeated = key == reported
        let previous: WindowID? = if case .window(let window)? = keyHistory.heard(reported), window != id { window } else { nil }
        if id == nil, report.pid == getpid() { emptyWorkspaceKeyed = .now }
        guard !sessionLocked else { return }   // resync requests the intent again
        admittedUnkeyed = admittedUnkeyed.filter { report.received - $0.value < Self.keyAfterAdmission }
        let keyedAfterAdmission = id.flatMap { admittedUnkeyed.removeValue(forKey: $0) } != nil
        // The report a departure waited for, unless it is Kosmos's echo: a window keyed
        // during a minimize's animation leaves macOS nothing to key when it ends.
        if let previous, awaitingKey?.window == previous, !reports.isEcho(reported, receivedAt: report.received) {
            awaitingKey = nil
        }
        let miss = reports.miss(reported, app: id.flatMap { owner[$0] ?? inventory.windows[$0]?.pid },
                                repeated: repeated, receivedAt: report.received)
        if miss != .none {
            controllerLog.notice("focus request missed: \(String(describing: reported), privacy: .public) again, \(String(describing: miss), privacy: .public)")
        }
        // An unmanaged window's focus is its own, and a parked one is key in its fullscreen
        // Space or just before it returns. A window with no place, or closed and kept, is
        // decided when it takes one.
        if let id, session.workspace(of: id) == nil || session.isParked(id) {
            unplacedKey = session.workspace(of: id) == nil || closedByApp.contains(id)
                ? KeyReport(key: reported, received: report.received, reporter: report.pid, previous: previous,
                            concealed: false, miss: miss) : nil
            // Kosmos keyed a native fullscreen window, as for hover focus: this is its echo.
            if session.isParked(id), reports.consumeEcho(reported, receivedAt: report.received) {
                misses.reported(reported, pid: report.pid, receivedAt: report.received, echo: true)
            }
            return
        }
        unplacedKey = nil
        if held.holds(reported, repeated: repeated) { return }
        // Whether the key window before this report just left the screen is read only when
        // the verdict needs it, as the read can wait on a switch's Space transaction.
        // Concealment is judged at the stamp (docs/focus.md; tla/README.md, change 22).
        let placed = id.flatMap { placedHidden.removeValue(forKey: $0) }
        decidePlaced(KeyReport(key: reported, received: report.received, reporter: report.pid, previous: previous,
                               concealed: placed != nil || id.map { hiding.wasConcealed($0, at: report.received) } ?? false,
                               miss: miss, admitted: keyedAfterAdmission || placed == .admitted),
                     keyLeft: placed != nil ? .stayed : previous.map { inventory.leftScreen($0) ? .left : .unknown } ?? .stayed)
    }

    private struct KeyReport {
        let key: KeyWindow
        let received: ContinuousClock.Instant
        let reporter: pid_t
        /// The key window before it, when that was another window.
        let previous: WindowID?
        /// At the report's stamp.
        var concealed: Bool
        let miss: Miss
        /// Its app keyed it as Kosmos admitted it after launch, so following or adopting it
        /// brings the pointer (docs/focus-follows-mouse.md).
        var admitted = false
    }

    /// How long a report waits to learn whether the key window before it left: WindowServer
    /// ordered a hidden app's window out 17 ms after the hide (docs/tree.md). Every follow
    /// of a Command-Tab waits this long.
    private static let grace: Duration = .milliseconds(100)

    private func decidePlaced(_ report: KeyReport, keyLeft: @autoclosure () -> Departure) {
        let echo = reports.isEcho(report.key, receivedAt: report.received)
        misses.reported(report.key, pid: report.reporter, receivedAt: report.received, echo: echo)
        if !echo { reports.publicRequestsAnswered(by: report.reporter, receivedAt: report.received) }
        decide(report, keyLeft: keyLeft())
    }

    /// A report whose verdict waits on a departure is held until it arrives or the grace ends
    /// (tla/Kosmos.tla, Adopt and Hold).
    private func decide(_ report: KeyReport, keyLeft: @autoclosure () -> Departure) {
        let id: WindowID? = if case .window(let window) = report.key { window } else { nil }
        // After a failed batch, recovery showed the windows of hidden workspaces, so a click
        // reaches them (needsResync).
        let verdict = reports.classify(report.key, receivedAt: report.received,
                                       onShownWorkspace: id.flatMap(session.workspace(of:)).map(session.isShown) ?? false,
                                       concealed: report.concealed, recovered: needsResync, miss: report.miss, keyLeft: keyLeft())
        controllerLog.debug("focus report \(String(describing: report.key), privacy: .public): \(String(describing: verdict), privacy: .public)")
        if id != nil, verdict != .echo, let ended = held.end() {
            controllerLog.notice("""
                held focus report \(String(describing: ended.key), privacy: .public): replaced by \
                \(String(describing: report.key), privacy: .public) after \((ContinuousClock.now - ended.received).milliseconds, format: .fixed(precision: 3)) ms
                """)
        }
        switch verdict {
        case .echo:
            break
        case .ignore:
            // macOS or an app fronted an app with no key window on an empty workspace: the
            // empty workspace keys its window again, so Cmd-Q reaches no app. After a click, a
            // Command-Tab or an app's launch it is the user's choice (docs/focus.md).
            guard report.key == .noWindow, report.reporter != getpid(), session.focused == nil, !UserInput.userPressedJustBefore(),
                  NSRunningApplication(processIdentifier: report.reporter)?.launchDate.map({ $0 > emptyWorkspaceKeyed }) != true
            else { break }
            controllerLog.notice("\(self.inventory.appIdentity(report.reporter).name ?? String(report.reporter), privacy: .public) has no key window on an empty workspace; keying its window again")
            requestFocus(.noWindow)
        case .undecided:
            let number = held.hold(report, of: report.key)
            after(Self.grace) { controller in
                if let report = controller.held.expire(number) { controller.decideHeld(report) }
            }
        case .reassert:
            requestFocus(session.intent, retry: report.miss == .retry)
        case .adopt(let window):
            session.adopt(window)
            touch(window)
            // A new generation, so a request still queued cannot key its window after the
            // user's choice (tla/Kosmos.tla, Adopt).
            requestFocus(.window(window))
            // Command-Tab or a Dock click brings the pointer, and a click on the window leaves
            // it (docs/focus-follows-mouse.md).
            if mouseFollowsFocus, report.admitted ? !UserInput.leftButtonDown : pickedAwayFromPointer() { centerPointer() }
            publishState()
        case .follow(let window):
            touch(window)
            // The pointer goes to a window Command-Tab, a launcher or a Dock click names, on its
            // own display too, and to a new window admitted to a hidden workspace
            // (docs/focus-follows-mouse.md).
            let plan = session.follow(window)
            execute(plan, movePointer: mouseFollowsFocus && (report.admitted ? !UserInput.leftButtonDown : pickedAwayFromPointer()))
        }
    }

    /// Every outcome is logged, to tell whether any report came before the first word of its
    /// departure.
    private func decideHeld(_ report: KeyReport) {
        let after = (ContinuousClock.now - report.received).milliseconds
        if case .window(let id) = report.key, session.workspace(of: id) == nil || session.isParked(id) {
            controllerLog.notice("held focus report \(String(describing: report.key), privacy: .public): dropped, its window left, after \(after, format: .fixed(precision: 3)) ms")
            return
        }
        // A later report moved the key window on, as Kosmos's own echo does when an app it
        // activated keys its last key window first and then the requested one.
        if report.key != key {
            controllerLog.notice("held focus report \(String(describing: report.key), privacy: .public): dropped, \(String(describing: self.key), privacy: .public) is key now, after \(after, format: .fixed(precision: 3)) ms")
            return
        }
        guard let previous = report.previous else { return }
        let left = inventory.leftScreen(previous)
        controllerLog.notice("""
            held focus report \(String(describing: report.key), privacy: .public): \
            \(previous) \(left ? "left" : "stayed", privacy: .public) after \(after, format: .fixed(precision: 3)) ms
            """)
        decide(report, keyLeft: left ? .left : .stayed)
    }

    private func after(_ delay: Duration, _ body: @escaping @MainActor (Controller) -> Void) {
        Task { [weak self] in
            try? await Task.sleep(for: delay)
            if let self { body(self) }
        }
    }

    // MARK: Plans

    private var inFullscreenSpace: Bool {
        let keyWindow: WindowID? = if case .window(let id)? = key { id } else { nil }
        return showsFullscreenSpace(key: key, keyManaged: keyWindow.map { session.workspace(of: $0) != nil } ?? false,
                                    keyApp: keyWindow.flatMap { owner[$0] ?? inventory.windows[$0]?.pid },
                                    fullscreen: Dictionary(uniqueKeysWithValues: fullscreenParked.compactMap { id in owner[id].map { (id, $0) } }))
    }

    /// `floatingCheck` runs the floating check for an empty plan too, as a floating window
    /// admitted to a workspace with no tiles plans nothing.
    private func execute(_ plan: Session.Plan, since received: ContinuousClock.Instant = .now, fromCommand: Bool = false,
                         movePointer: Bool = false, floatingCheck: Bool = false, popping: WindowID? = nil) {
        slides?.keep({ self.session.isVisible($0) }, fullscreen: fullscreenDisplays)
        guard managing, !sessionLocked, !plan.isEmpty || floatingCheck else { return publishState() }
        // A size refused while hidden is no limit of the app's: the write that shows the
        // window is a first attempt, retried until the reveal lands (docs/geometry.md).
        for id in plan.show { ledger.forgetLargerReadBack(id) }
        writeFrames(plan.frames, sliding: motions(for: plan, popping: popping))
        if movePointer { centerPointer() }
        var show = plan.show, hide = plan.hide
        if needsResync && !(show.isEmpty && hide.isEmpty) {
            let resync = session.resyncPlan(layingOutHidden: false)
            (show, hide) = (resync.show, resync.hide)
            needsResync = false
        }
        if show.isEmpty && hide.isEmpty {
            if plan.focus != nil { requestFocus(session.intent, fromCommand: fromCommand) }
            bringFloatingHome()
        } else {
            for id in show { placedHidden[id] = nil }   // their workspace is shown
            switchGeneration += 1
            let generation = switchGeneration
            let interval = signposter.beginInterval("switch", id: signposter.makeSignpostID())
            let submitted = ContinuousClock.now
            // A window revealed with no ordinary Space goes to its display's (docs/hiding.md).
            let displays = Dictionary(uniqueKeysWithValues: show.compactMap { id in
                session.workspace(of: id).map { (id, session.monitor(of: $0).id) }
            })
            // The windows to conceal that lose their ordinary Space, by each app's window
            // focused last (Session.stripped).
            let strip = session.stripped(hide) { window in owner[window].flatMap { pid in recent.last { owner[$0] == pid } } }
            hiding.apply(show: show, on: displays, hide: hide, stripping: strip) { [weak self] outcome, timing in
                guard let self else { return }
                for id in hide { self.placedHidden[id] = nil }   // the conceal that placed them hidden is done
                self.updateBorders()
                signposter.endInterval("switch", interval)
                let bridge = ContinuousClock.now - submitted, total = ContinuousClock.now - received
                controllerLog.notice("""
                    switch to \(self.session.focusedWorkspace, privacy: .public): \(show.count) shown, \(hide.count) hidden \
                    (\(timing.stripped) stripped), \
                    before bridge \((submitted - received).milliseconds, format: .fixed(precision: 3)) ms, bridge \(bridge.milliseconds, format: .fixed(precision: 3)) ms \
                    (queued \(timing.queued.milliseconds, format: .fixed(precision: 3)), sent \(timing.sent.milliseconds, format: .fixed(precision: 3)), \
                    confirmed \(timing.confirmed.milliseconds, format: .fixed(precision: 3)) \(timing.barrier.map { $0 ? "by barrier" : "by read" } ?? "without reads", privacy: .public), \
                    recovered \(timing.recovered.milliseconds, format: .fixed(precision: 3)), back \(timing.returned.milliseconds, format: .fixed(precision: 3))), \
                    total \(total.milliseconds, format: .fixed(precision: 3)) ms, \(String(describing: outcome), privacy: .public)
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
                self.requestFocus(self.session.intent, fromCommand: fromCommand)
                // Only after the focus request. A stale switch's reveal is checked by the switch
                // that replaced it.
                self.bringFloatingHome()
            }
        }
        publishState()
    }

    /// The read waits on WindowServer, so it runs only with a floating window shown, and
    /// never before a switch's focus request. A concealed window reads as off every display
    /// and waits for its reveal (docs/displays.md). A window the modifier drags goes where
    /// the drag puts it, as WindowServer can lag its last write.
    private func bringFloatingHome() {
        let windows = session.shownFloatingWindows.filter { $0 != modifierDrag?.grab.window }
        guard !windows.isEmpty else { return }
        let start = ContinuousClock.now
        let frames = Dictionary(SkyLight.rows(windows).map { ($0.id, $0.frame) }) { first, _ in first }
        let targets = session.floatingFrames(at: frames)
        controllerLog.info("floating check: \(windows.count) windows read in \((ContinuousClock.now - start).milliseconds, format: .fixed(precision: 3)) ms, \(targets.count) moved")
        writeFrames(targets)
    }

    private func writeFrames(_ targets: [WindowID: CGRect], sliding: [WindowID: Slides.Motion] = [:]) {
        guard !sessionLocked else { return }
        let writes = ledger.writes(for: targets)
        slides?.writing(Dictionary(uniqueKeysWithValues: writes.keys.map { ($0, targets[$0]!) }), sliding: sliding)
        for (pid, group) in Dictionary(grouping: writes, by: { owner[$0.key] }) {
            guard let worker = pid.flatMap(inventory.worker) else {
                for (id, _) in group { ledger.forget(id) }
                continue
            }
            worker.enqueueFrames(Dictionary(uniqueKeysWithValues: group.map { ($0.key, (write: $0.value, target: targets[$0.key]!)) }))
        }
    }

    /// A drag's own writes, the 100 ms retry and floating windows brought home do not come
    /// through here, and jump (docs/geometry.md).
    private func motions(for plan: Session.Plan, popping: WindowID?) -> [WindowID: Slides.Motion] {
        guard animations, slides != nil else { return [:] }
        let show = Set(plan.show), held = modifierDrag?.grab.window, fullscreen = fullscreenDisplays
        var motions: [WindowID: Slides.Motion] = [:]
        for id in plan.frames.keys where session.isVisible(id) && !show.contains(id) && !hiding.isConcealed(id) && id != held
            && !session.lifted.contains(id) && mouseMoved[id] == nil {
            guard let name = session.workspace(of: id), let pid = owner[id], inventory.worker(pid)?.answers == true else { continue }
            let display = session.monitor(of: name).id
            guard !fullscreen.contains(display) else { continue }
            // Where WindowServer has the window, read before the ledger takes the write as sent,
            // and unknown while a write of Kosmos's still moves it.
            let from = ledger.isWriting(id) ? nil : inventory.windows[id]?.frame
            motions[id] = Slides.Motion(from: from, display: display, pop: id == popping)
        }
        return motions
    }

    /// A Space of the pool shows whatever Space its display shows, so a slide there would draw
    /// over the fullscreen app. Ceiling: such a display other than the key window's slides
    /// nothing while it shows its desktop Space; reading each display's current Space would
    /// tell them apart (docs/geometry.md).
    private var fullscreenDisplays: Set<DisplayID> {
        func display(of id: WindowID) -> DisplayID? {
            inventory.windows[id].flatMap { row in
                session.monitors.first { $0.frame.contains(CGPoint(x: row.frame.midX, y: row.frame.midY)) }?.id
            }
        }
        let displays = Set(fullscreenParked.compactMap(display))
        guard !displays.isEmpty, case .window(let id)? = key, !inFullscreenSpace, let desktop = display(of: id)
        else { return displays }
        return displays.subtracting([desktop])
    }

    func endSlides() {
        slides?.endAll("at quit")
    }

    /// `retry`: it follows a miss, which the kill switch then counts once.
    private func requestFocus(_ target: KeyWindow, fromCommand: Bool = false, retry: Bool = false) {
        guard managing, !sessionLocked else { return }
        // Focusing a desktop window takes the user out of a fullscreen Space, which only a
        // command may do.
        guard fromCommand || !inFullscreenSpace else { return }
        // A window that just left the screen, before Kosmos heard: fronting it would
        // unminimize it or unhide its app. Its departure focuses.
        if case .window(let id) = target, inventory.leftScreen(id) { return }
        let pid: pid_t?
        let privately: Bool
        switch target {
        case .window(let id):
            pid = owner[id]
            privately = focusQueue.killSwitch.isOn
            touch(id)
        case .noWindow:
            // Only the private path keys Kosmos's own window, and only a crash inside it keeps
            // the path from this window (docs/focus.md).
            pid = getpid()
            privately = focusQueue.killSwitch.offReason != .crashed
            emptyWorkspace.place(on: session.monitor(of: session.focusedWorkspace).frame)
        }
        guard let pid else { return }
        let concealed = if case .window(let id) = target { hiding.isConcealed(id) } else { false }
        focusQueue.request(target, pid: pid, worker: inventory.worker(pid), privately: privately, concealed: concealed,
                           performing: { [weak self] stamp, path in
                               self?.performing(target, pid: pid, path: path, retry: retry, at: stamp)
                           },
                           forgetRecord: { [weak self] stamp in
                               self?.reports.requestDropped(target, at: stamp)
                               self?.misses.requestDropped(at: stamp)
                           })
    }

    /// Runs just before a call that changes the key window, so the echo is recorded before
    /// its report can come (docs/focus.md).
    private func performing(_ target: KeyWindow, pid: pid_t, path: FocusPath, retry: Bool,
                            at stamp: ContinuousClock.Instant) {
        reports.focusRequested(target, app: pid, at: stamp, publicly: path == .activation)
        guard path == .keyRecord, focusQueue.killSwitch.isOn, case .window(let id) = target,
              misses.willRequest(id, pid: pid, at: stamp, retry: retry) else { return }
        focusQueue.killSwitch.turnOff(.wrongWindows)
        controllerLog.fault("private focus keyed another window \(FocusMisses.limit) times in a row; focus uses the public path")
        onFocusProblem?(focusProblem)
    }

    /// Only when the pointer is outside, as AeroSpace's `window-lazy-center`. The frame is the
    /// layout's or the inventory's, read from no other process (docs/focus-follows-mouse.md).
    private func centerPointer() {
        guard !dragging else { return }
        let frame: CGRect? = if let window = session.focused {
            session.frames(of: session.focusedWorkspace)[window] ?? inventory.windows[window]?.frame
        } else {
            session.monitor(of: session.focusedWorkspace).frame
        }
        guard let frame, !frame.isEmpty, let location = CGEvent(source: nil)?.location, !frame.contains(location) else { return }
        CGWarpMouseCursorPosition(CGPoint(x: frame.midX, y: frame.midY))
        pointer?.warped()
    }

    private func movesPointer(after command: Command, from source: CommandSource) -> Bool {
        mouseFollowsFocus && command.movesPointer(from: source, toAnotherDisplay: focusAwayFromPointer)
    }

    private var focusAwayFromPointer: Bool {
        CGEvent(source: nil).map { session.focusIsOnAnotherDisplay(than: $0.location) } ?? false
    }

    private func pickedAwayFromPointer() -> Bool {
        let input = ActivationInput(key: UserInput.secondsSince(.keyDown), leftClick: UserInput.secondsSince(.leftMouseDown),
                                    rightClick: UserInput.secondsSince(.rightMouseDown), moved: UserInput.secondsSince(.mouseMoved))
        let dock = UserInput.isDock(clickedWindow)
        pointerLog.debug("""
            activation: key \(input.key, format: .fixed(precision: 3)) s ago, left click \(input.leftClick, format: .fixed(precision: 3)) s ago \
            \(dock ? "on" : "off", privacy: .public) the Dock, right click \(input.rightClick, format: .fixed(precision: 3)) s ago, \
            pointer moved \(input.moved, format: .fixed(precision: 3)) s ago
            """)
        return input.bringsPointer(onDock: dock)
    }

    // MARK: Modifier drags

    /// Each movement is carried as it comes, and AppWorker merges the writes a busy app has not
    /// taken yet (docs/modifier-drags.md).
    private func dragHeard(_ outcome: DragGate.Outcome, at stamp: ContinuousClock.Instant) {
        if let end = outcome.ended { dragEnded(end) }
        if let grab = outcome.began { dragBegan(grab, at: stamp) }
        if let point = outcome.moved, modifierDrag != nil {
            dragLog.debug("movement carried \((ContinuousClock.now - stamp).milliseconds, format: .fixed(precision: 3)) ms after the tap saw it")
            carryDrag(to: point)
        }
    }

    /// The window takes the focus, as Hyprland's dragBegin does, through a command stamped when
    /// the tap saw the press. A press on a window no longer tiled or floating on a shown
    /// workspace is taken all the same.
    private func dragBegan(_ grab: DragGate.Grab, at stamp: ContinuousClock.Instant) {
        guard let frame = inventory.windows[grab.window]?.frame, let drag = session.beginDrag(grab, frame: frame) else {
            dragLog.info("modifier press on \(grab.window): no tiled or floating window of a shown workspace, nothing to drag")
            return
        }
        modifierDrag = drag
        slides?.end(grab.window, "as a modifier drag took it")
        // A Dock click before this press no longer brings the pointer (pickedAwayFromPointer).
        clickedWindow = 0
        dragLog.info("""
            modifier drag of \(grab.window) with the \(grab.button == .left ? "left" : "right", privacy: .public) button, \
            \(drag.floating ? "floating" : "tiled", privacy: .public), edges \(String(describing: drag.edges), privacy: .public)
            """)
        reports.commandExecuted(receivedAt: stamp)
        session.adopt(grab.window)
        requestFocus(.window(grab.window), fromCommand: true)
        publishState()
    }

    /// Each movement writes frames and nothing else, as a plan would read the floating
    /// windows' frames from WindowServer each time (bringFloatingHome).
    private func carryDrag(to point: CGPoint) {
        guard var drag = modifierDrag else { return }
        let window = drag.grab.window
        // Gone from the screen since, it is no longer the user's to drag.
        guard session.lifted.contains(window) || session.isVisible(window) else {
            dragLog.info("\(window) left during its modifier drag")
            modifierDrag = nil
            return
        }
        guard let delta = drag.delta(to: point) else { return }
        modifierDrag = drag
        switch drag.grab.button {
        case .left:
            if !drag.floating, !session.lifted.contains(window) {
                guard let plan = session.lift(window) else {
                    modifierDrag = nil
                    return
                }
                dragLog.info("\(window) lifted from workspace \(self.session.workspace(of: window) ?? "?", privacy: .public)")
                execute(plan)
            }
            writeDragFrame(drag, drag.moved(by: delta))
        case .right:
            if drag.floating {
                writeDragFrame(drag, session.resized(drag, by: delta))
            } else if let plan = session.dragEdges(drag, by: delta) {
                writeFrames(plan.frames)
            }
        }
    }

    private func writeDragFrame(_ drag: ModifierDrag, _ frame: CGRect) {
        writeFrames([drag.grab.window: frame])
        guard drag.floating, let plan = session.dragged(drag.grab.window, to: frame) else { return }
        dragLog.info("\(drag.grab.window) dragged to workspace \(self.session.workspace(of: drag.grab.window) ?? "?", privacy: .public)")
        execute(plan)
    }

    /// Also for a mouse up the tap missed, or a press WindowServer passed on (DragGate.timedOut).
    private func dragEnded(_ end: DragGate.End) {
        guard modifierDrag?.grab == end.grab else { return }
        carryDrag(to: end.point)
        finishDrag(at: end.point)
    }

    private func finishDrag(at point: CGPoint?) {
        guard let drag = modifierDrag else { return }
        modifierDrag = nil
        if session.lifted.contains(drag.grab.window) { leftMouseUp(at: point) }
        publishState()
    }

    // MARK: Focus follows mouse

    /// Focuses at once, through the same path as a focus command (docs/focus-follows-mouse.md).
    private func pointerEntered(_ entered: PointerGate.Entered, at stamp: ContinuousClock.Instant) {
        // The pointer moved on before this ran. While a window is lifted the pointer is the user's.
        guard !sessionLocked, !dragging, pointer?.window == entered.window else { return }
        let window = entered.window
        let fullscreen = fullscreenParked.contains(window)
        let skip = focusFollowsMouse.skip(window, in: session, fullscreen: fullscreen, key: key,
                                          app: owner[window].map(inventory.appIdentity), stale: reports.isStale(stamp))
        // Onto the desktop of a display whose workspace is empty, that workspace takes the
        // focus. Only then is the window's level read from WindowServer.
        let emptyWorkspace = skip == .notTiled ? entered.display.flatMap { display in
            focusFollowsMouse.emptyWorkspace(entered: display, overDesktop: window == 0 || SkyLight.rows([window]).first
                .map { FocusFollowsMouse.isDesktop(level: $0.level) } == true, in: session)
        } : nil
        if let skip, emptyWorkspace == nil {
            pointerLog.debug("pointer in \(window): \(String(describing: skip), privacy: .public)")
            return
        }
        if let holder = UserInput.keyHolderApartFromFront() {
            pointerLog.debug("""
                pointer in \(window): \(NSRunningApplication(processIdentifier: holder)?.localizedName ?? String(holder), privacy: .public) \
                holds the key window apart from the front app
                """)
            return
        }
        if let emptyWorkspace {
            guard let plan = session.perform(.workspace(.named(emptyWorkspace))) else { return }
            pointerLog.info("pointer focuses empty workspace \(emptyWorkspace, privacy: .public)")
            reports.commandExecuted(receivedAt: stamp)
            execute(plan, fromCommand: true)
            return
        }
        pointerLog.info("pointer focuses \(window)")
        // A command for the window, stamped when the pointer entered it, so the reports of
        // activations before it are stale.
        reports.commandExecuted(receivedAt: stamp)
        // A native fullscreen window stays parked, and the session's focus stays where it
        // was, as when the user clicks the window.
        if !fullscreen { session.adopt(window) }
        // The window is on screen under the pointer, so keying it takes no display out of a
        // native fullscreen Space.
        requestFocus(.window(window), fromCommand: true)
        publishState()
    }

    private func touch(_ window: WindowID) {
        recent.removeAll { $0 == window }
        recent.append(window)
    }

    private func mostRecent(_ windows: [WindowID]) -> WindowID? {
        windows.max { (recent.lastIndex(of: $0) ?? -1) < (recent.lastIndex(of: $1) ?? -1) }
    }

    /// Every change of the model ends here, so the drag tap's windows and the borders follow it.
    private func publishState() {
        let data = stateJSON()
        bar.publish(data)
        publish?(data)
        dragTap?.setWindows(draggable)
        updateBorders()
    }

    /// A locked session keeps its borders until the resync after the unlock (docs/borders.md).
    private func updateBorders() {
        guard !sessionLocked else { return }
        guard managing, let borders else { return borderWindows.show([:]) }
        // One read of each slide, so a border's frame and alpha come from the same display frame.
        var sliding: [WindowID: (frame: CGRect, alpha: Double)] = [:]
        let shown = session.borders(borders, accent: borderWindows.accent) { id in
            guard !hiding.isConcealedOrConcealing(id), let row = inventory.windows[id], row.orderedIn else { return nil }
            sliding[id] = slides?.shown(id)
            return (sliding[id]?.frame ?? row.frame, row.cornerRadius)
        }
        borderWindows.show(shown.reduce(into: [:]) { result, entry in
            let slide = sliding[entry.key]
            result[entry.key] = Borders.Shown(border: entry.value, level: inventory.windows[entry.key]?.level ?? 0,
                                              alpha: slide?.alpha ?? 1, sliding: slide != nil)
        })
    }

    private func stateJSON() -> Data {
        let snapshot = session.barSnapshot(
            profile: profile, displays: barDisplays,
            app: { [owner, inventory] id in owner[id].flatMap { inventory.appIdentity($0).name } },
            frame: { [inventory] id in inventory.windows[id]?.frame })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(snapshot)) ?? Data("{}".utf8)
    }
}
