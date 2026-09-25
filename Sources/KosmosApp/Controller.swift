import AppKit
import KosmosCore
import KosmosSkyLight
import os

private let controllerLog = Logger(subsystem: "io.github.st-eez.kosmos", category: "controller")
private let signposter = OSSignposter(subsystem: "io.github.st-eez.kosmos", category: .pointsOfInterest)

/// Carries out the Session's plans: frame writes through the app workers, reveals and
/// conceals through Hiding, and focus through the focus queue once the switch is confirmed
/// (DESIGN.md, section 4.3; tla/Kosmos.tla).
@MainActor
final class Controller {
    private var session: Session
    private var ledger = FrameLedger()
    private var reports = FocusReports<ContinuousClock.Instant>()
    private var misses = FocusMisses<ContinuousClock.Instant>()
    private let inventory: Inventory
    private let hiding: Hiding
    /// What an empty workspace keys (DESIGN.md, section 5.4).
    private let emptyWorkspace: EmptyWorkspaceWindow
    private let focusQueue: FocusQueue
    private let bar = BarPush()
    /// Bumped by every switch; a switch confirmed after a newer one does not focus.
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
    /// Switches between native tabs, and the tabs that hold no place.
    private var tabSwitches = TabSwitches()
    private var tabs = TabGroups()
    /// The last key report of a window with no place, decided again if a tab switch gives
    /// that window a place: macOS can report the new tab key before the switch pairs.
    private var unplacedKey: KeyReport?
    /// Tabs a switch placed on a hidden workspace, until the batch that conceals them
    /// completes, their workspace is shown, or another tab replaces them. macOS keyed such a
    /// tab by the user's or the app's choice, so its report counts as one of a concealed
    /// window, and the tab deselected before it did not depart: it is followed at once.
    private var placedHidden: Set<WindowID> = []
    /// The key window macOS last reported. Too old to skip a focus request against, which the
    /// focus queue decides when the request runs.
    private var key: KeyWindow?
    /// A report whose verdict waits for the departure of the window key before it
    /// (tla/Kosmos.tla, Hold).
    private var held = HeldReport<KeyReport>()
    /// A departure that waits for macOS's report of the next key window: the key window that
    /// left, and the number of the departure's timer.
    private var awaitingKey: (window: WindowID, number: Int)?
    private var departures = 0
    /// Set after a batch that did not conceal what it should have; the next switch conceals
    /// every window of every hidden workspace again.
    private var needsResync = false
    /// False while another tiling window manager runs: Kosmos then only observes.
    let managing: Bool
    /// Window rules, first match wins.
    var rules: [WindowRule] = []
    /// Move the pointer to the focus the keyboard moved (Command.movesPointer).
    var mouseFollowsFocus = false
    /// The config's settings; the `focus-follows-mouse` command changes `enabled` until the
    /// next load.
    var focusFollowsMouse = FocusFollowsMouse() {
        didSet {
            // Creating the tap may ask for Input Monitoring, so it waits until focus follows
            // mouse is first turned on.
            if focusFollowsMouse.enabled, managing, pointer == nil {
                pointer = PointerTap { [weak self] entered, stamp in self?.pointerEntered(entered, at: stamp) }
                pointer?.setMonitors(session.monitors)
            }
            pointer?.setEnabled(focusFollowsMouse.enabled)
        }
    }
    private var pointer: PointerTap?
    /// The active display profile, for the bar.
    private(set) var profile: String?
    /// Each connected display as the bar numbers it, read with the displays.
    private var barDisplays: [DisplayID: BarSnapshot.Display]
    var publish: (@MainActor (Data) -> Void)?
    /// Called with a description when the private focus path turns off, and with nil when it
    /// turns back on.
    var onFocusProblem: (@MainActor (String?) -> Void)?
    /// While the session is locked or switched out, Kosmos writes no frames, runs no hides,
    /// requests no focus and takes no command; `resync` catches up (DESIGN.md, section 5.1).
    private var sessionLocked: Bool { inventory.sessionLocked }

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
        inventory.onManagedChange = { [weak self] id, pid, managed in self?.managedChanged(id, pid: pid, managed) }
        inventory.onReport = { [weak self] report in self?.handle(report) }
        inventory.onFullscreenChange = { [weak self] id, entered, since in self?.fullscreenChanged(id, entered, since: since) }
        inventory.onKeptOrderedOut = { [weak self] id in self?.keptOrderedOut(id) }
        inventory.onOrderChange = { [weak self] id, pid, orderedIn, frame, at in
            self?.orderChanged(id, pid: pid, orderedIn, frame: frame, at: at)
        }
        inventory.onAppHidden = { [weak self] pid, hidden, at in hidden ? self?.appHidden(pid) : self?.appUnhidden(pid, at: at) }
        inventory.onFrameChange = { [weak self] id, frame in self?.frameChanged(id, to: frame) }
    }

    /// Applies a config reload, an unlock, a wake or a display change: the profile's
    /// workspaces and rules, and each display with its gaps (DESIGN.md, sections 5.1 and
    /// 5.13), then resyncs every window.
    func apply(_ setup: Setup, barDisplays: [DisplayID: BarSnapshot.Display]) {
        rules = setup.rules
        profile = setup.profile
        self.barDisplays = barDisplays
        let displaysBefore = session.monitors
        session.reconfigure(names: setup.workspaces, monitors: setup.monitors, assigned: setup.workspaceDisplays,
                            merge: setup.mergeWorkspaces)
        pointer?.setMonitors(session.monitors)
        let shown = session.monitors.map { "\($0.id): \(session.workspace(shownOn: $0.id) ?? "none")" }
        controllerLog.notice("""
            profile \(setup.profile ?? "base", privacy: .public), workspace on each display \
            \(shown.joined(separator: ", "), privacy: .public), focused \(self.session.focusedWorkspace, privacy: .public)
            """)
        // macOS can move windows while the session is locked or the displays sleep, and
        // moves those of a display that leaves; the ledger would take them for placed. Each
        // window's frame is written again.
        ledger = FrameLedger()
        resync(displaysChanged: session.monitors != displaysBefore)
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

    /// Runs one command. Returns the exit code and the text for the CLI.
    func run(_ arguments: [String], received: ContinuousClock.Instant, from source: CommandSource) -> (code: Int32, text: String) {
        switch arguments {
        case ["state"]:
            return (0, String(decoding: stateJSON(), as: UTF8.self))
        case ["list-workspaces"]:
            return (0, session.names.map { $0 == session.focusedWorkspace ? "\($0) *" : $0 }.joined(separator: "\n"))
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
        case .success(.focusFollowsMouse(let change)):
            focusFollowsMouse.enabled = switch change {
            case .on: true
            case .off: false
            case .toggle: !focusFollowsMouse.enabled
            }
            return (0, "")
        case .success(let command):
            if let missing = session.missingWorkspace(in: command) {
                return (1, "no workspace \(missing); the workspaces are \(session.names.joined(separator: " "))")
            }
            reports.commandExecuted(receivedAt: received)
            if let plan = session.perform(command) {
                execute(plan, since: received, fromCommand: true, movePointer: movesPointer(after: command, from: source))
            }
            return (0, "")
        }
    }

    /// Lays the shown workspaces out on their areas as they are now, and every other
    /// workspace too when the displays changed, conceals and reveals every window again,
    /// requests the focus intent and publishes the state. With the same displays, the other
    /// workspaces are laid out when they are shown.
    private func resync(displaysChanged: Bool) {
        guard managing else { return publishState() }
        // Reports received before now are older than the focus this asks for again, and an
        // echo in flight at the lock was dropped with the other reports while locked.
        reports.forgetRequests()
        reports.commandExecuted(receivedAt: .now)
        var plan = Session.Plan()
        // A concealed window left on a display that is gone would come back off screen from
        // recovery, so after a display change hidden workspaces are laid out on theirs now.
        for name in session.names where displaysChanged || session.isShown(name) {
            plan.frames.merge(session.frames(of: name)) { current, _ in current }
        }
        let shown = session.shownWorkspaces
        plan.show = shown.flatMap { session.windows(of: $0) }
        plan.hide = session.names.filter { !session.isShown($0) }.flatMap { session.windows(of: $0) }
        plan.focus = intent
        execute(plan)
    }

    // MARK: Events

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
            place(id, pid: pid, ruled: true)
        } else if session.workspace(of: id) != nil, inventory.hasOrderedOutWindows(pid, besides: id) {
            // Perhaps the selected tab closed before the next tab came in, in native
            // fullscreen too: its place waits for that tab for the pairing window.
            after(TabSwitches.window) { $0.forget(id, pid: pid) }
        } else {
            forget(id, pid: pid)
        }
    }

    /// Gives a window a place of its own: on the workspace a rule names, when `ruled`, or
    /// the shown one. Already minimized, in native fullscreen or hidden with its app, as at
    /// launch or as a tab that lost its group, it waits parked for its return, with no frame
    /// and no concealing. A minimized or fullscreen window of a hidden app returns on its
    /// own, not when the app unhides.
    private func place(_ id: WindowID, pid: pid_t, ruled: Bool) {
        let app = inventory.appIdentity(pid)
        let rule = ruled ? rules.first { $0.matches(appID: app.bundleID, appName: app.name) } : nil
        // A window there at launch joins the workspace of the display under it; a later one
        // joins the focused workspace, as in AeroSpace (DESIGN.md, section 5.13).
        let center = inventory.wasThereAtLaunch(id) ? inventory.windows[id].map { CGPoint(x: $0.frame.midX, y: $0.frame.midY) } : nil
        var plan = session.add(id, to: rule?.workspace, at: center)
        if rule?.float == true { plan.frames.merge(session.float(id).frames) { _, new in new } }
        if let reason = ParkReason.atAdmission(fullscreen: inventory.fullscreen.contains(id),
                                               minimized: inventory.isMinimized(id),
                                               appHidden: NSRunningApplication(processIdentifier: pid)?.isHidden == true) {
            if reason == .fullscreen { fullscreenParked.insert(id) }
            if reason == .appHidden { hiddenApps[pid, default: []].append(id) }
            plan.frames = session.park([id]).frames
            plan.hide.removeAll { $0 == id }
        }
        // Reported key before it had a place, as at launch: that report was dropped.
        if inventory.focused == id, session.workspace(of: id).map(session.isShown) == true { session.adopt(id) }
        execute(plan)
    }

    /// The window is gone for good.
    private func forget(_ id: WindowID, pid: pid_t) {
        owner[id] = nil
        recent.removeAll { $0 == id }
        hiddenApps[pid]?.removeAll { $0 == id }
        fullscreenParked.remove(id)
        closedByApp.remove(id)
        tabs.forget(id)
        placedHidden.remove(id)
        ledger.forget(id)
        hiding.forgetHistory(of: id)
        execute(session.remove(id))
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

    /// A candidate window with `frame` was ordered in or out, or destroyed. A window of an app
    /// ordered in as another with its frame is ordered out or destroyed is a switch between
    /// native tabs. A window ordered in with no tab leaving, a hidden member or one its app
    /// had closed and kept, is back a pairing window later if it is still ordered in: a
    /// hidden member dragged out of its group takes a place of its own, and a closed window
    /// returns to its place, and Kosmos follows it. A reopened Settings window returns
    /// 250 ms late for that.
    private func orderChanged(_ id: WindowID, pid: pid_t, _ orderedIn: Bool, frame: CGRect, at: ContinuousClock.Instant) {
        if let change = tabSwitches.ordered(id, in: orderedIn, frame: frame, app: pid, at: at),
           tabSwitched(from: change.old, to: change.new, frame: frame) {
            return
        }
        guard orderedIn, tabs.hidden.contains(id) || closedByApp.contains(id) else { return }
        after(TabSwitches.window) { controller in
            guard controller.inventory.windows[id]?.orderedIn == true else { return }
            if controller.closedByApp.remove(id) != nil {
                controller.returned([id], follow: id, at: at)
            } else if controller.tabs.detached(id), let pid = controller.owner[id] {
                controller.place(id, pid: pid, ruled: false)
            }
        }
    }

    /// The selected tab changed from `old` to `new`: `new` takes the place of `old`, with no
    /// reflow and no follow, and `old` waits out of the session as a hidden member
    /// (DESIGN.md, section 5.5). A tab not admitted yet takes the place once it is. False
    /// when `old` holds no place. `frame` is the tabs' frame.
    private func tabSwitched(from deselected: WindowID, to new: WindowID, frame: CGRect?) -> Bool {
        let old: WindowID
        switch tabs.switched(from: deselected, to: new, admitted: owner[new] != nil,
                             placed: { self.session.workspace(of: $0) != nil },
                             sharesFrame: { frame != nil && self.inventory.windows[$0]?.frame == frame }) {
        case .none: return false
        case .pending: return true
        case .replace(let holder): old = holder
        }
        // Parked as closed by its app before the switch took effect, as when the new tab's
        // admission outlasts the kept rule's second: the place returns for the new tab, which
        // is on screen. The replace's plan lays the place out, so the unpark's is dropped.
        if closedByApp.remove(old) != nil { _ = session.unpark([old], follow: nil) }
        guard let plan = session.replace(old, with: new) else { return false }
        placedHidden.remove(old)
        if plan.hide.contains(new) { placedHidden.insert(new) }
        controllerLog.info("tab \(new) replaces \(old)")
        tabs.replaced(old, with: new)
        // Parked as closed by its app, as a window Merge All Windows made a tab.
        closedByApp.remove(new)
        // A switch inside a native fullscreen group: the new tab is the one in fullscreen.
        if fullscreenParked.remove(old) != nil { fullscreenParked.insert(new) }
        // A deselected tab leaves every Space, the holding Space too (kosmos-probe tabs), and
        // the tab selected lands on its ordinary Space, whatever Kosmos had concealed: the
        // plan conceals it afresh when its place is on a hidden workspace.
        hiding.forget([old, new])
        ledger.forget(new)
        if key == .window(old) { key = .window(new) }
        execute(plan)
        // macOS reported the new tab key before it had a place. It is the user's or the
        // app's choice, followed if the place is on a hidden workspace; the window key
        // before it is the tab deselected, which did not depart. A tab in native fullscreen
        // is key in its own Space, as any parked window.
        if let report = unplacedKey, report.key == .window(new), !session.isParked(new) {
            unplacedKey = nil
            placedHidden.remove(new)
            decidePlaced(KeyReport(key: report.key, received: report.received, pid: report.pid, previous: report.previous,
                                   concealed: session.workspace(of: new).map { !session.isShown($0) } ?? false, miss: report.miss),
                         keyLeft: .stayed)
        }
        return true
    }

    /// Its app ordered the window out and kept it, as a closed NSWindowController window: it
    /// parks as a minimized window does, and returns when the app orders it in again
    /// (orderChanged). Removing it would lose its place, and the inventory would not admit
    /// it again, since it stays managed. A deselected tab has left the session already.
    private func keptOrderedOut(_ id: WindowID) {
        guard session.workspace(of: id) != nil, !session.isParked(id) else { return }
        controllerLog.info("\(id) closed and kept by its app: parked")
        closedByApp.insert(id)
        depart([id])
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
    /// leaves, the workspace's next window, or the empty workspace's, is focused now, or after
    /// macOS's report of the next key window when the key window left too (DepartureFocus). A
    /// report that does not come within the departure bound, as when an app keeps no key
    /// window, has the departure focus then. The bound outlasts macOS's key change after a
    /// minimize, which ends its animation first.
    private func depart(_ windows: [WindowID]) {
        let focusLeft = session.focused.map(windows.contains) == true
        execute(session.park(windows))
        switch DepartureFocus.decide(focusLeft: focusLeft, key: key, departing: windows, left: inventory.leftScreen) {
        case .none:
            break
        case .now:
            requestFocus(intent)
        case .afterKeyReport:
            guard case .window(let keyWindow)? = key else { break }
            departures += 1
            let number = departures
            awaitingKey = (keyWindow, number)
            after(Inventory.departureBound) { controller in
                guard controller.awaitingKey?.number == number else { return }
                controller.awaitingKey = nil
                controller.requestFocus(controller.intent)
            }
        }
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

    /// A floating window of a shown workspace moved or resized. The frame ledger records
    /// where it is, since the floating check compares its targets with it. Dragged onto a
    /// display showing another workspace, the window joins that workspace, so the check
    /// leaves it there (Session.dragged). A change while a write of Kosmos's is in flight is
    /// that write's. A drag needs the left button down on the key window, as AeroSpace's
    /// isManipulatedWithMouse checks, so macOS moving the windows of a display that leaves
    /// is none (DESIGN.md, section 5.13).
    private func frameChanged(_ id: WindowID, to frame: CGRect) {
        guard managing, !sessionLocked, !ledger.isWriting(id), session.shownFloatingWindows.contains(id) else { return }
        ledger.observe(id, frame: frame)
        guard key == .window(id), NSEvent.pressedMouseButtons == 1, let plan = session.dragged(id, to: frame) else { return }
        controllerLog.info("\(id) dragged to workspace \(self.session.workspace(of: id) ?? "?", privacy: .public)")
        execute(plan)
    }

    private func handle(_ report: AXReport) {
        switch report.kind {
        case .backgroundFocus(let id):
            // An app that is not front changed its own focused window, as after AXRaise in
            // it: no key window report, and never the last one seen. It can still be
            // Kosmos's echo, and is otherwise ignored (tla/Kosmos.tla, Observe). It leaves the
            // kill switch's count alone: a raise's report says nothing about the key record.
            guard !sessionLocked else { return }
            _ = reports.consumeEcho(id.map(KeyWindow.window) ?? .none, receivedAt: report.received)
        case .focusedWindowChanged(let id):
            let reported: KeyWindow = id.map(KeyWindow.window) ?? .none
            let previous: WindowID? = if case .window(let window)? = key, window != id { window } else { nil }
            let repeated = key == reported
            key = reported
            guard !sessionLocked else { return }   // resync requests the intent again
            // macOS's report of the next key window, which a departure waited for. Kosmos's
            // own echo is not it: a window keyed during a minimize's animation leaves macOS
            // nothing to key when it ends, so the wait runs to its bound and focuses.
            if let previous, awaitingKey?.window == previous, !reports.isEcho(reported, receivedAt: report.received) {
                awaitingKey = nil
            }
            let miss = reports.miss(reported, app: id.flatMap { owner[$0] ?? inventory.windows[$0]?.pid },
                                    repeated: repeated, receivedAt: report.received)
            if miss != .none {
                controllerLog.notice("focus request missed: \(String(describing: reported), privacy: .public) again, \(String(describing: miss), privacy: .public)")
            }
            // Dialogs and panels are not managed; their focus is theirs. A parked window is
            // key in its own fullscreen Space, or just before it returns, which follows it.
            // A tab with no place yet is decided when it takes one.
            if let id, session.workspace(of: id) == nil || session.isParked(id) {
                unplacedKey = session.workspace(of: id) == nil
                    ? KeyReport(key: reported, received: report.received, pid: report.pid, previous: previous,
                                concealed: false, miss: miss) : nil
                // A native fullscreen window Kosmos keyed, as when the pointer entered it:
                // the report is that request's echo.
                if session.isParked(id), reports.consumeEcho(reported, receivedAt: report.received) {
                    misses.reported(reported, pid: report.pid, receivedAt: report.received, echo: true)
                }
                return
            }
            unplacedKey = nil
            if held.holds(reported, repeated: repeated) { return }
            // The window key before this report left the screen just now: macOS keyed this
            // window after that one closed, minimized or hid (DESIGN.md, section 5.4).
            // Concealing a window leaves it ordered in, so a concealed window counts only if
            // it left too. classify reads it only when the verdict depends on it. After a
            // switch the read waited on WindowServer's Space transaction.
            let placed = id.map { placedHidden.remove($0) != nil } ?? false
            decidePlaced(KeyReport(key: reported, received: report.received, pid: report.pid, previous: previous,
                                   concealed: placed || id.map { hiding.wasConcealed($0, at: report.received) } ?? false, miss: miss),
                         keyLeft: placed ? .stayed : previous.map { inventory.leftScreen($0) ? .left : .unknown } ?? .stayed)
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
        case .windowCreated, .windowDestroyed, .answering:
            break
        }
    }

    /// A key window report as classification reads it.
    private struct KeyReport {
        let key: KeyWindow
        let received: ContinuousClock.Instant
        /// The app that reported it.
        let pid: pid_t
        /// The window key before it, when that was another window.
        let previous: WindowID?
        /// The reported window was concealed at the report's stamp.
        let concealed: Bool
        /// Whether it is a miss of Kosmos's own request.
        let miss: Miss
    }

    /// How long a report waits to learn whether the window key before it left. macOS keyed
    /// the next app before WindowServer ordered a hidden app's window out, which the
    /// departures probe measured 17 ms after the hide. Every follow of a Command-Tab waits
    /// this long.
    private static let grace: Duration = .milliseconds(100)

    /// Decides the key window report of a window with a place. The kill switch counts it, and
    /// a report that is no echo answers the app's public requests (DESIGN.md, section 5.4).
    private func decidePlaced(_ report: KeyReport, keyLeft: @autoclosure () -> Departure) {
        let echo = reports.isEcho(report.key, receivedAt: report.received)
        misses.reported(report.key, pid: report.pid, receivedAt: report.received, echo: echo)
        if !echo { reports.publicRequestsAnswered(by: report.pid, receivedAt: report.received) }
        decide(report, keyLeft: keyLeft())
    }

    /// Acts on a key window report. A report whose verdict depends on a departure that is
    /// not known yet is held until the departure arrives or the grace ends
    /// (tla/Kosmos.tla, Adopt and Hold).
    private func decide(_ report: KeyReport, keyLeft: @autoclosure () -> Departure) {
        let id: WindowID? = if case .window(let window) = report.key { window } else { nil }
        // After a failed batch, recovery showed the windows of hidden workspaces, so a click
        // reaches them (needsResync).
        let verdict = reports.classify(report.key, receivedAt: report.received,
                                       onShownWorkspace: id.flatMap(session.workspace(of:)).map(session.isShown) ?? false,
                                       concealed: report.concealed, recovered: needsResync, miss: report.miss, keyLeft: keyLeft())
        controllerLog.debug("focus report \(String(describing: report.key), privacy: .public): \(String(describing: verdict), privacy: .public)")
        // A newer activation of a window ends a held report. Kosmos's own echo and a report
        // of no key window leave it held.
        if id != nil, verdict != .echo, let ended = held.end() {
            controllerLog.notice("""
                held focus report \(String(describing: ended.key), privacy: .public): replaced by \
                \(String(describing: report.key), privacy: .public) after \(Self.ms(ContinuousClock.now - ended.received), privacy: .public) ms
                """)
        }
        switch verdict {
        case .echo, .ignore:
            break
        case .undecided:
            let number = held.hold(report, of: report.key)
            after(Self.grace) { controller in
                if let report = controller.held.expire(number) { controller.decideHeld(report) }
            }
        case .reassert:
            requestFocus(intent, retry: report.miss == .retry)
        case .adopt(let window):
            session.adopt(window)
            touch(window)
            // A new generation, so a request of Kosmos's still queued cannot key its window
            // after the user's choice; the worker finds this one key already and records
            // nothing (tla/Kosmos.tla, Adopt).
            requestFocus(.window(window))
            // Command-Tab to a window away from the pointer brings the pointer along; a click,
            // on the window or the Dock, leaves it.
            if mouseFollowsFocus, Self.keyPressedLast() { centerPointer() }
            publishState()
        case .follow(let window):
            touch(window)
            // A workspace switch, which brings the pointer along only to another display.
            let plan = session.follow(window)
            execute(plan, movePointer: mouseFollowsFocus && Self.keyPressedLast() && focusAwayFromPointer)
        }
    }

    /// Decides a held report once the grace ends, by what the inventory says then of the
    /// window key before it. Every outcome is logged, to tell whether any report came before
    /// the first word of its departure.
    private func decideHeld(_ report: KeyReport) {
        let after = Self.ms(ContinuousClock.now - report.received)
        // The reported window left or stopped being managed meanwhile.
        if case .window(let id) = report.key, session.workspace(of: id) == nil || session.isParked(id) {
            controllerLog.notice("held focus report \(String(describing: report.key), privacy: .public): dropped, its window left, after \(after, privacy: .public) ms")
            return
        }
        guard let previous = report.previous else { return }
        let left = inventory.leftScreen(previous)
        controllerLog.notice("""
            held focus report \(String(describing: report.key), privacy: .public): \
            \(previous) \(left ? "left" : "stayed", privacy: .public) after \(after, privacy: .public) ms
            """)
        decide(report, keyLeft: left ? .left : .stayed)
    }

    /// Runs `body` on the main actor after `delay`.
    private func after(_ delay: Duration, _ body: @escaping @MainActor (Controller) -> Void) {
        Task { [weak self] in
            try? await Task.sleep(for: delay)
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

    /// `since` is when the command arrived, for the switch timing log. `movePointer` centers
    /// the pointer on the focus.
    private func execute(_ plan: Session.Plan, since received: ContinuousClock.Instant = .now, fromCommand: Bool = false,
                         movePointer: Bool = false) {
        guard managing, !sessionLocked, !plan.isEmpty else { return publishState() }
        writeFrames(plan.frames)
        if movePointer { centerPointer() }
        var show = plan.show, hide = plan.hide
        if needsResync && !(show.isEmpty && hide.isEmpty) {
            show = session.shownWorkspaces.flatMap { session.windows(of: $0) }
            hide = session.names.filter { !session.isShown($0) }.flatMap { session.windows(of: $0) }
            needsResync = false
        }
        if show.isEmpty && hide.isEmpty {
            if plan.focus != nil { requestFocus(intent, fromCommand: fromCommand) }
            bringFloatingHome()
        } else {
            placedHidden.subtract(show)   // their workspace is shown
            switchGeneration += 1
            let generation = switchGeneration
            let interval = signposter.beginInterval("switch", id: signposter.makeSignpostID())
            let submitted = ContinuousClock.now
            // A window revealed with no ordinary Space goes to its display's (DESIGN.md, section 5.3).
            let displays = Dictionary(uniqueKeysWithValues: show.compactMap { id in
                session.workspace(of: id).map { (id, session.monitor(of: $0).id) }
            })
            // The windows to conceal that lose their ordinary Space, by each app's window
            // focused last (Session.stripped).
            let strip = session.stripped(hide) { window in owner[window].flatMap { pid in recent.last { owner[$0] == pid } } }
            hiding.apply(show: show, on: displays, hide: hide, stripping: strip) { [weak self] outcome, timing in
                guard let self else { return }
                self.placedHidden.subtract(hide)   // the conceal that placed them hidden is done
                signposter.endInterval("switch", interval)
                let bridge = ContinuousClock.now - submitted, total = ContinuousClock.now - received
                controllerLog.notice("""
                    switch to \(self.session.focusedWorkspace, privacy: .public): \(show.count) shown, \(hide.count) hidden \
                    (\(timing.stripped) stripped), \
                    before bridge \(Self.ms(submitted - received), privacy: .public) ms, bridge \(Self.ms(bridge), privacy: .public) ms \
                    (queued \(Self.ms(timing.queued), privacy: .public), sent \(Self.ms(timing.sent), privacy: .public), \
                    confirmed \(Self.ms(timing.confirmed), privacy: .public) \(timing.barrier.map { $0 ? "by barrier" : "by read" } ?? "without reads", privacy: .public), \
                    recovered \(Self.ms(timing.recovered), privacy: .public), back \(Self.ms(timing.returned), privacy: .public)), \
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
                self.requestFocus(self.intent, fromCommand: fromCommand)
                // Revealed now, the floating windows can be seen where they are. A switch
                // checks only here, after its focus request, and a stale switch's reveal is
                // checked by the switch that replaced it.
                self.bringFloatingHome()
            }
        }
        publishState()
    }

    private static func ms(_ duration: Duration) -> String {
        String(format: "%.3f", Double(duration.components.attoseconds) / 1e15 + Double(duration.components.seconds) * 1000)
    }

    /// Floating windows of shown workspaces that sit on a display showing another workspace
    /// go to their workspace's display, from where WindowServer has them now
    /// (Session.floatingFrames). A concealed one reads as off every display and waits for
    /// its reveal. The read waits on WindowServer, so it runs only with a floating window
    /// shown, and never before a switch's batch is sent or its focus requested; the log
    /// gives each read's time, for the desk.
    private func bringFloatingHome() {
        let windows = session.shownFloatingWindows
        guard !windows.isEmpty else { return }
        let start = ContinuousClock.now
        let frames = Dictionary(SkyLight.rows(windows).map { ($0.id, $0.frame) }) { first, _ in first }
        let targets = session.floatingFrames(at: frames)
        controllerLog.info("floating check: \(windows.count) windows read in \(Self.ms(ContinuousClock.now - start), privacy: .public) ms, \(targets.count) moved")
        writeFrames(targets)
    }

    private func writeFrames(_ targets: [WindowID: CGRect]) {
        guard !sessionLocked else { return }
        let writes = ledger.writes(for: targets)
        for (pid, group) in Dictionary(grouping: writes, by: { owner[$0.key] ?? 0 }) where pid != 0 {
            let batch = Dictionary(uniqueKeysWithValues: group.map { ($0.key, (write: $0.value, target: targets[$0.key]!)) })
            inventory.worker(pid)?.enqueueFrames(batch)
        }
    }

    /// Every focus request goes through here. `fromCommand`: a command asked for it. `retry`:
    /// it follows a miss, which the kill switch then counts once.
    private func requestFocus(_ target: KeyWindow, fromCommand: Bool = false, retry: Bool = false) {
        // While observing, the other window manager owns focus too.
        guard managing, !sessionLocked else { return }
        // Focusing a desktop window takes the user out of a fullscreen Space: only a command
        // does that, not a window closing or hiding behind it, nor an unhide that conceals
        // windows.
        guard fromCommand || !inFullscreenSpace else { return }
        // A window that just left the screen, before Kosmos heard: fronting it would
        // unminimize it or unhide its app. Its departure focuses.
        if case .window(let id) = target, inventory.leftScreen(id) { return }
        // The focus queue skips a target that is key already, checked when the request runs:
        // the key window last reported here can be older than a request still in flight.
        let pid: pid_t?
        let privately: Bool
        switch target {
        case .window(let id):
            pid = owner[id]
            privately = focusQueue.killSwitch.isOn
            touch(id)
        case .none:
            // Kosmos's own window, which only the private path can key. The wrong window
            // count judges key records to other apps' windows, so only a crash inside a
            // private call keeps this one from being keyed (DESIGN.md, section 5.4).
            pid = getpid()
            privately = focusQueue.killSwitch.offReason != .crashed
            emptyWorkspace.place(on: session.monitor(of: session.focusedWorkspace).frame)
        }
        guard let pid else { return }
        let concealed = if case .window(let id) = target { hiding.isConcealed(id) } else { false }
        focusQueue.request(target, pid: pid, worker: inventory.worker(pid), privately: privately,
                           concealed: concealed, generation: focusQueue.newGeneration(),
                           performing: { [weak self] stamp, path in
                               self?.performing(target, pid: pid, path: path, retry: retry, at: stamp)
                           },
                           dropped: { [weak self] stamp in
                               self?.reports.requestDropped(target, at: stamp)
                               self?.misses.requestDropped(at: stamp)
                           })
    }

    /// A call that changes the key window to `target` is about to be made: records the echo
    /// that will come back, inexact for the public activation, and counts the private key
    /// record toward the kill switch (DESIGN.md, section 5.4).
    private func performing(_ target: KeyWindow, pid: pid_t, path: FocusPath, retry: Bool,
                            at stamp: ContinuousClock.Instant) {
        reports.focusRequested(target, app: pid, at: stamp, publicly: path == .activation)
        guard path == .keyRecord, focusQueue.killSwitch.isOn, case .window(let id) = target,
              misses.willRequest(id, pid: pid, at: stamp, retry: retry) else { return }
        focusQueue.killSwitch.turnOff(.wrongWindows)
        controllerLog.fault("private focus keyed another window \(FocusMisses<ContinuousClock.Instant>.limit) times in a row; focus uses the public path")
        onFocusProblem?(focusProblem)
    }

    /// Centers the pointer on the focused window, or on the focused workspace's display when
    /// that has no window, as Hyprland's `focusmonitor` does, unless the pointer is inside
    /// already, as with AeroSpace's `move-mouse window-lazy-center`. A tile's frame is the
    /// layout's after the change, the one Kosmos is writing, and a floating window's the last
    /// one the inventory heard, so nothing waits on WindowServer (DESIGN.md, section 5.11).
    private func centerPointer() {
        let frame: CGRect? = if let window = session.focused {
            session.frames(of: session.focusedWorkspace)[window] ?? inventory.windows[window]?.frame
        } else {
            session.monitor(of: session.focusedWorkspace).frame
        }
        guard let frame, !frame.isEmpty, let location = CGEvent(source: nil)?.location, !frame.contains(location) else { return }
        CGWarpMouseCursorPosition(CGPoint(x: frame.midX, y: frame.midY))
        pointer?.warped()
    }

    /// Whether mouse-follows-focus centers the pointer on the focus after `command`, which
    /// the session has carried out.
    private func movesPointer(after command: Command, from source: CommandSource) -> Bool {
        mouseFollowsFocus && command.movesPointer(from: source, toAnotherDisplay: focusAwayFromPointer)
    }

    /// The focused workspace is on another display than the pointer.
    private var focusAwayFromPointer: Bool {
        CGEvent(source: nil).map { session.focusIsOnAnotherDisplay(than: $0.location) } ?? false
    }

    /// Whether a key press came after the last click, from the times the session's event
    /// state keeps, which reading takes no event tap.
    private static func keyPressedLast() -> Bool {
        let since = { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }
        let key = since(.keyDown), click = min(since(.leftMouseDown), since(.rightMouseDown))
        pointerLog.debug("activation: key \(key, format: .fixed(precision: 3)) s ago, click \(click, format: .fixed(precision: 3)) s ago")
        return key < click
    }

    // MARK: Focus follows mouse

    /// How long the pointer rests in a window before the window takes focus. Zero focuses it
    /// as the pointer enters, as Hyprland's `follow_mouse = 1` does, although each focus of
    /// another app's window costs macOS about 94 ms of CPU (DESIGN.md, sections 2 and 5.11).
    private static let dwell: Duration = .zero

    /// The pointer moved into a window, the one WindowServer found under it, or onto another
    /// display, at `stamp` (DESIGN.md, section 5.11). The window takes focus through the same
    /// path as a focus command when FocusFollowsMouse.skip allows it.
    private func pointerEntered(_ entered: PointerGate.Entered, at stamp: ContinuousClock.Instant) {
        after(Self.dwell) { controller in
            // The pointer left the window during the dwell, or moved on before this ran.
            guard !controller.sessionLocked, controller.pointer?.window == entered.window else { return }
            controller.focusUnderPointer(entered, at: stamp)
        }
    }

    private func focusUnderPointer(_ entered: PointerGate.Entered, at stamp: ContinuousClock.Instant) {
        let window = entered.window
        let fullscreen = fullscreenParked.contains(window)
        if let skip = focusFollowsMouse.skip(window, in: session, fullscreen: fullscreen, key: key,
                                             app: owner[window].map(inventory.appIdentity),
                                             stale: reports.isStale(stamp)) {
            // Onto a display whose shown workspace is empty: that workspace takes the focus as
            // `workspace` gives it, keying the empty workspace window there, and the pointer
            // stays where it is.
            if skip == .notTiled, let display = entered.display,
               let name = focusFollowsMouse.emptyWorkspace(entered: display, in: session),
               let plan = session.perform(.workspace(.named(name))) {
                pointerLog.info("pointer focuses empty workspace \(name, privacy: .public)")
                reports.commandExecuted(receivedAt: stamp)
                execute(plan, fromCommand: true)
                return
            }
            pointerLog.debug("pointer in \(window): \(String(describing: skip), privacy: .public)")
            return
        }
        pointerLog.info("pointer focuses \(window)")
        // A focus follows mouse focus is a command for the window, stamped when the pointer
        // entered it: reports of the user's activations before it are stale, and its echo is
        // consumed like any other. It never moves the pointer.
        reports.commandExecuted(receivedAt: stamp)
        // A native fullscreen window stays parked, and the session's focus stays where it
        // was, as when the user clicks the window.
        if !fullscreen { session.adopt(window) }
        // The window is on screen under the pointer, so keying it takes no display out of a
        // native fullscreen Space: it passes the gate as a command does, and a fullscreen
        // window key on another display leaves this one free.
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

    /// One snapshot for the bar and for `kosmos subscribe` (DESIGN.md, section 5.12).
    private func publishState() {
        let data = stateJSON()
        bar.publish(data)
        publish?(data)
    }

    /// The bar snapshot as JSON, also printed by `kosmos state` for a bar that starts late.
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
