import AppKit
import KosmosCore
import KosmosRecovery
import KosmosSkyLight
import os

let controllerLog = Logger(subsystem: "io.github.st-eez.kosmos", category: "controller")
private let signposter = OSSignposter(subsystem: "io.github.st-eez.kosmos", category: .pointsOfInterest)

/// Turns commands, the inventory's window events and key window reports, mouse presses,
/// modifier drags and pointer movement into Session changes. Carries out the Session's plans
/// through the app workers, Hiding, the focus queue and Slides, and publishes each change to
/// the bar and the borders (docs/overview.md, section 4.3; tla/Kosmos.tla).
@MainActor
final class Controller {
    var session: Session
    var ledger = FrameLedger()
    var reports = FocusReports()
    var misses = FocusMisses()
    let inventory: Inventory
    let hiding: Hiding
    /// One for each display, made again when it is off its display's corner (docs/focus.md).
    private var emptyWorkspaces: [DisplayID: EmptyWorkspaceWindow] = [:]
    private let focusQueue = FocusQueue()
    private let bar = BarPush()
    /// Batches wait here for their windows' writes, and writes for their windows' conceals
    /// (docs/hiding.md).
    private var order = BatchOrder()
    private var switches: [Int: Switch] = [:]
    private var recheckAt: ContinuousClock.Instant?
    var owner: [WindowID: pid_t] = [:]
    /// Newest last.
    var recent: [WindowID] = []
    var tabSwitches = TabSwitches()
    var tabs = TabGroups()
    var intake = KeyReportIntake(ownApp: getpid())
    var key: KeyWindow? { intake.key }
    /// A Date, to compare with app launch dates.
    var emptyWorkspaceKeyed = Date.distantPast
    var needsResync = false
    /// Tiled windows the left button moved or resized without lifting them, which go back
    /// to their tiles at its mouse up. A resize by the edges never lifts (docs/geometry.md).
    var mouseMoved: [WindowID: (before: CGRect, resized: Bool)] = [:]
    var leftButton = LeftButton()
    var clickedWindow = 0
    /// False while another tiling window manager runs: Kosmos then only observes.
    let managing: Bool
    var rules: [WindowRule] = []
    var mouseFollowsFocus = false
    /// The `focus-follows-mouse` command changes `enabled` until the next config load.
    var focusFollowsMouse = FocusFollowsMouse() {
        didSet { updatePointerTap() }
    }
    var pointer: PointerTap?
    /// A tap made without Input Monitoring may hear nothing (docs/focus-follows-mouse.md).
    var pointerListens = false
    var wantsPointer: Bool { focusFollowsMouse.enabled && managing }
    var onInputMonitoringMissing: (@MainActor () -> Void)?
    var mouseModifier: KeyCombo.Modifiers? {
        didSet { updateDragTap() }
    }
    var dragTap: DragTap?
    var modifierDrag: ModifierDrag?
    var dragging: Bool { !session.lifted.isEmpty || modifierDrag != nil }
    private(set) var profile: String?
    private var barDisplays: [DisplayID: BarSnapshot.Display]
    var publish: (@MainActor (Data) -> Void)?
    var onFocusProblem: (@MainActor (String?) -> Void)?
    /// While locked, Kosmos writes no frames, hides nothing, requests no focus and takes no
    /// command; resync catches up (docs/inventory.md).
    var sessionLocked: Bool { inventory.sessionLocked }
    /// Kept once made, as the recovery record holds its Spaces.
    var slides: Slides?
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
    let borderWindows = Borders()
    /// Windows whose app refused their tile, with the flashes of each under way
    /// (docs/borders.md).
    private var flashes: [WindowID: Int] = [:]
    /// Each tile where the last plan left it, so a window whose tile moves under a frame it
    /// keeps flashes too (docs/borders.md).
    private var tiles: [WindowID: CGRect] = [:]
    /// Nil while observing only, as the layout is another window manager's, or when the
    /// WindowServer is unread (docs/tree.md).
    private let windowServer: ProcessIdentity?
    private var layoutWritePending = false

    init(inventory: Inventory, hiding: Hiding, setup: Setup, barDisplays: [DisplayID: BarSnapshot.Display], managing: Bool) {
        self.inventory = inventory
        self.hiding = hiding
        self.managing = managing
        session = Session(names: setup.workspaces, monitors: setup.monitors, assigned: setup.workspaceDisplays)
        windowServer = managing ? ProcessIdentity.windowServer() : nil
        rules = setup.rules
        profile = setup.profile
        self.barDisplays = barDisplays
        inventory.onEvent = { [weak self] event in self?.handle(event) }
        borderWindows.onAccentChange = { [weak self] in self?.updateBorders() }
        watchLeftButton()
        for monitor in session.monitors { _ = emptyWorkspace(on: monitor) }
        restoreLayout()
    }

    /// Before the inventory admits any window (docs/tree.md).
    private func restoreLayout() {
        guard let windowServer, var saved = LayoutFile.load(under: windowServer) else { return }
        let count = saved.windows.count
        // A closed window would hold its tile until the next write, and one ordered out, as
        // minimized since, until the tree changes. A failed read keeps every window.
        if let open = Self.openRows(saved.windows.map(\.window)) {
            saved.windows.removeAll { open[$0.window] == nil }
            for index in saved.windows.indices where open[saved.windows[index].window]?.orderedIn == false {
                saved.windows[index].parked = true
            }
        } else {
            controllerLog.error("saved windows not read from WindowServer; each waits for its admission")
        }
        session.restore(saved)
        let shown = session.monitors.map { "\($0.id): \(session.workspace(shownOn: $0.id) ?? "none")" }
        controllerLog.notice("""
            saved layout restored: \(saved.windows.count) of its \(count) windows open, workspace on each display \
            \(shown.joined(separator: ", "), privacy: .public), focused \(self.session.focusedWorkspace, privacy: .public)
            """)
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
        for monitor in session.monitors { _ = emptyWorkspace(on: monitor) }
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

    /// Nil when the command ran, or else why it did not.
    func run(_ command: Command, received: ContinuousClock.Instant, from source: CommandSource) -> String? {
        guard !sessionLocked else { return "the session is locked" }
        if case .focusFollowsMouse(let change) = command {
            focusFollowsMouse.enabled = switch change {
            case .on: true
            case .off: false
            case .toggle: !focusFollowsMouse.enabled
            }
            if focusFollowsMouse.enabled, pointer == nil {
                return """
                    focus follows mouse gets no pointer movement: macOS refused Kosmos's event tap. \
                    Allow Kosmos in System Settings, Privacy & Security, Input Monitoring, then run \
                    kosmos focus-follows-mouse on
                    """
            }
            return nil
        }
        if let missing = session.missingWorkspace(in: command) {
            return "no workspace \(missing); the workspaces are \(session.names.joined(separator: " "))"
        }
        reports.commandExecuted(receivedAt: received)
        // Floating windows' frames as the inventory last heard them, so nothing waits on
        // WindowServer.
        if let plan = session.perform(command, frame: { [inventory] in inventory.windows[$0]?.frame }) {
            execute(plan, since: received, fromCommand: true, movePointer: movesPointer(after: .command(command, from: source)))
        }
        return nil
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

    func after(_ delay: Duration, _ body: @escaping @MainActor (Controller) -> Void) {
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
                                    fullscreen: Dictionary(uniqueKeysWithValues: session.parked(because: .fullscreen).compactMap { id in owner[id].map { (id, $0) } }))
    }

    /// `floatingCheck` runs the floating check for an empty plan too, as a floating window
    /// admitted to a workspace with no tiles plans nothing.
    func execute(_ plan: Session.Plan, since received: ContinuousClock.Instant = .now, fromCommand: Bool = false,
                         movePointer: Bool = false, floatingCheck: Bool = false, popping: WindowID? = nil) {
        slides?.keep({ self.session.isVisible($0) }, fullscreen: fullscreenDisplays)
        guard managing, !sessionLocked, !plan.isEmpty || floatingCheck else { return publishState() }
        let resyncs = needsResync && !(plan.show.isEmpty && plan.hide.isEmpty)
        let windows = resyncs ? session.resyncPlan(layingOutHidden: false) : plan
        let (show, hide) = (windows.show, windows.hide)
        if resyncs { needsResync = false }
        let entering = session.entering(show: show, hide: hide, frames: plan.frames.keys,
                                        concealed: hiding.isConcealedOrConcealing,
                                        display: { inventory.windows[$0].flatMap { display(under: $0.frame) } })
        // Before the writes, which wait for the batches that conceal their windows.
        var added: [Int] = []
        func add(show: [WindowID], hide: [WindowID]) {
            let number = order.add(show: show, hide: hide).number
            switches[number] = Switch(received: received, fromCommand: fromCommand)
            added.append(number)
        }
        if !entering.isEmpty { add(show: [], hide: entering) }
        if !(show.isEmpty && hide.isEmpty) {
            intake.forgetPlacedHidden(show)   // their workspace is shown
            add(show: show + entering.filter { !show.contains($0) }, hide: hide)
        }
        // A size refused while hidden is no limit of the app's: the write that shows the
        // window is a first attempt, retried until the reveal lands (docs/geometry.md).
        for id in plan.show { ledger.forgetLargerReadBack(id) }
        let written = writeFrames(plan.frames, sliding: motions(for: plan, popping: popping).filter { !entering.contains($0.key) })
        flashSpills(plan.frames, written: written)
        if movePointer { centerPointer() }
        if show.isEmpty && hide.isEmpty {
            if plan.focus != nil { requestFocus(session.intent, fromCommand: fromCommand) }
            bringFloatingHome()
        }
        sendReadyBatches()
        for number in added where switches[number] != nil { switches[number]!.held = .now }
        publishState()
    }

    private struct Switch {
        let received: ContinuousClock.Instant
        let fromCommand: Bool
        /// When the batch first waited for writes; nil for one sent in its command's turn.
        var held: ContinuousClock.Instant?
    }

    /// A batch whose revealed windows' writes are still landing waits, with every batch after
    /// it, until a row shows each write or the Accessibility timeout after it. A plain switch's
    /// windows have none, so its batch goes at once (docs/hiding.md).
    func sendReadyBatches() {
        guard !sessionLocked, order.isWaiting else { return }
        let now = ContinuousClock.now
        func landing(_ id: WindowID) -> Bool {
            // A backed off app's write waits for the app to answer again.
            ledger.isLanding(id, at: now) && hiding.isConcealedOrConcealing(id)
                && owner[id].flatMap(inventory.worker)?.answers != false
        }
        order.ready(landing: landing).forEach(send)
        // Checked again when the first write holding the batch times out.
        guard let next = order.next, let end = next.show.filter(landing).compactMap(ledger.landingEnds).min(),
              recheckAt.map({ end < $0 }) ?? true else { return }
        recheckAt = end
        after(end - now) { controller in
            if controller.recheckAt == end { controller.recheckAt = nil }
            controller.sendReadyBatches()
        }
    }

    private func send(_ batch: BatchOrder.Batch) {
        let (show, hide) = (batch.show, batch.hide)
        let context = switches.removeValue(forKey: batch.number)!
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
            self.intake.forgetPlacedHidden(hide)   // the conceal that placed them hidden is done
            // Sent only now, so each lands concealed.
            self.sendWrites(self.order.done(batch.number))
            self.sendReadyBatches()
            // Last, as a border's AppKit calls wait on WindowServer while it applies the batch and
            // would hold up the focus request (docs/borders.md).
            defer { self.updateBorders() }
            signposter.endInterval("switch", interval)
            let bridge = ContinuousClock.now - submitted, total = ContinuousClock.now - context.received
            controllerLog.notice("""
                switch to \(self.session.focusedWorkspace, privacy: .public): \(show.count) shown, \(hide.count) hidden \
                (\(timing.stripped) stripped), \
                before bridge \(((context.held ?? submitted) - context.received).milliseconds, format: .fixed(precision: 3)) ms, \
                \(context.held.map { String(format: "held %.3f ms, ", (submitted - $0).milliseconds) } ?? "", privacy: .public)bridge \(bridge.milliseconds, format: .fixed(precision: 3)) ms \
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
            guard batch.number == self.order.lastNumber else { return }
            self.requestFocus(self.session.intent, fromCommand: context.fromCommand)
            // Only after the focus request. A stale switch's reveal is checked by the switch
            // that replaced it.
            self.bringFloatingHome()
        }
    }

    /// The read waits on WindowServer, so it runs only with a floating window shown, and
    /// never before a switch's focus request. A concealed window's row gives its own frame,
    /// so it goes home as a revealed one would (docs/displays.md). A window the modifier drags
    /// goes where the drag puts it, as WindowServer can lag its last write.
    private func bringFloatingHome() {
        let windows = session.shownFloatingWindows.filter { $0 != modifierDrag?.grab.window }
        guard !windows.isEmpty else { return }
        let start = ContinuousClock.now
        let frames = Dictionary(SkyLight.rows(windows).map { ($0.id, $0.frame) }) { first, _ in first }
        let targets = session.floatingFrames(at: frames)
        controllerLog.info("floating check: \(windows.count) windows read in \((ContinuousClock.now - start).milliseconds, format: .fixed(precision: 3)) ms, \(targets.count) moved")
        writeFrames(targets)
    }

    /// The targets written, with those already in place left out.
    @discardableResult
    func writeFrames(_ targets: [WindowID: CGRect], sliding: [WindowID: Slides.Motion] = [:]) -> [WindowID: CGRect] {
        guard !sessionLocked else { return [:] }
        let entries = ledger.writes(for: targets).reduce(into: [WindowID: BatchOrder.Write]()) { entries, write in
            entries[write.key] = (write.value, targets[write.key]!)
        }
        slides?.writing(entries.mapValues(\.target), sliding: sliding)
        sendWrites(order.write(entries))
        return entries.mapValues(\.target)
    }

    /// A write that goes to no worker, or comes while locked, is forgotten, so its target is
    /// not left pending.
    private func sendWrites(_ writes: [WindowID: BatchOrder.Write]) {
        let now = ContinuousClock.now
        for (pid, group) in Dictionary(grouping: writes, by: { owner[$0.key] }) {
            guard !sessionLocked, let worker = pid.flatMap(inventory.worker) else {
                for (id, _) in group { ledger.forget(id) }
                continue
            }
            for (id, entry) in group { ledger.sent(id, target: entry.target, at: now) }
            worker.enqueueFrames(Dictionary(uniqueKeysWithValues: group.map { ($0.key, $0.value) }))
        }
    }

    /// A drag's own writes, the 100 ms retry and floating windows brought home do not come
    /// through here, and jump. `popping` pops only while still ordered out. A window a batch not
    /// yet done conceals would show above the desktop in its slide's Space (docs/geometry.md).
    private func motions(for plan: Session.Plan, popping: WindowID?) -> [WindowID: Slides.Motion] {
        guard animations, slides != nil else { return [:] }
        let show = Set(plan.show), held = modifierDrag?.grab.window, fullscreen = fullscreenDisplays
        var motions: [WindowID: Slides.Motion] = [:]
        for id in plan.frames.keys where session.isVisible(id) && !show.contains(id) && !hiding.isConcealed(id)
            && !order.conceals(id) && id != held && !session.lifted.contains(id) && mouseMoved[id] == nil {
            guard let name = session.workspace(of: id), let pid = owner[id], inventory.worker(pid)?.answers == true else { continue }
            let display = session.monitor(of: name).id
            guard !fullscreen.contains(display) else { continue }
            // Where WindowServer has the window, read before the ledger takes the write as sent,
            // and unknown while a write of Kosmos's still moves it.
            var from = ledger.isWriting(id) ? nil : inventory.windows[id]?.frame
            var pop = false
            // Read now, as the inventory's row can lag an order-in. Ceiling: an order-in after the
            // read shows until the pop's Space turns transparent; docs/geometry.md has the upgrade.
            if id == popping, let row = SkyLight.rows([id]).first { (from, pop) = (row.frame, !row.orderedIn) }
            if let from, let shownOn = self.display(under: from), fullscreen.contains(shownOn) { continue }
            motions[id] = Slides.Motion(from: from, display: display, pop: pop)
        }
        return motions
    }

    private func display(under frame: CGRect) -> DisplayID? {
        session.monitors.first { $0.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) }?.id
    }

    /// A Space of the pool shows whatever Space its display shows, so a slide to or from there
    /// would draw over the fullscreen app, as would a border ordered in before its Space move.
    /// Ceiling: such a display other than the key window's slides nothing while it shows its
    /// desktop Space; reading each display's current Space would tell them apart
    /// (docs/geometry.md, docs/borders.md).
    private var fullscreenDisplays: Set<DisplayID> {
        func display(of id: WindowID) -> DisplayID? { inventory.windows[id].flatMap { self.display(under: $0.frame) } }
        let displays = Set(session.parked(because: .fullscreen).compactMap(display))
        guard !displays.isEmpty, case .window(let id)? = key, !inFullscreenSpace, let desktop = display(of: id)
        else { return displays }
        return displays.subtracting([desktop])
    }

    func endSlides(_ why: String) {
        slides?.endAll(why)
    }

    /// `retry`: it follows a miss, which the kill switch then counts once.
    func requestFocus(_ target: KeyWindow, fromCommand: Bool = false, retry: Bool = false) {
        guard managing, !sessionLocked else { return }
        // Focusing a desktop window takes the user out of a fullscreen Space, which only a
        // command may do.
        guard fromCommand || !inFullscreenSpace else { return }
        // A window that just left the screen, before Kosmos heard: fronting it would
        // unminimize it or unhide its app. Its departure focuses.
        if case .window(let id) = target, inventory.leftScreen(id) { return }
        let pid: pid_t?
        let privately: Bool
        var emptyWorkspace: EmptyWorkspaceWindow.Target?
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
            emptyWorkspace = self.emptyWorkspace(on: session.monitor(of: session.focusedWorkspace))?.target
        }
        guard let pid else { return }
        let concealed = if case .window(let id) = target { hiding.isConcealed(id) } else { false }
        focusQueue.request(target, pid: pid, worker: inventory.worker(pid), privately: privately, concealed: concealed,
                           emptyWorkspace: emptyWorkspace,
                           performing: { [weak self] stamp, path in
                               self?.performing(target, pid: pid, path: path, retry: retry, at: stamp)
                           },
                           forgetRecord: { [weak self] stamp in
                               self?.reports.requestDropped(target, at: stamp)
                               self?.misses.requestDropped(at: stamp)
                           })
    }

    /// A window whose display moved is made again at its corner, never moved (docs/focus.md).
    private func emptyWorkspace(on monitor: Monitor) -> EmptyWorkspaceWindow? {
        guard !NSScreen.screens.isEmpty else { return nil }
        if let window = emptyWorkspaces[monitor.id], window.isPlaced(on: monitor.frame) { return window }
        emptyWorkspaces[monitor.id]?.close()
        let window = EmptyWorkspaceWindow(display: monitor.frame)
        window.onKey = { [weak inventory] stamp in inventory?.ownWindowKeyed(at: stamp) }
        emptyWorkspaces[monitor.id] = window
        return window
    }

    /// Runs just before a call that changes the key window, so the echo is recorded before
    /// its report can come (docs/focus.md).
    private func performing(_ target: KeyWindow, pid: pid_t, path: FocusPath, retry: Bool,
                            at stamp: ContinuousClock.Instant) {
        reports.focusRequested(target, app: pid, at: stamp, publicly: path == .activation, keyRecord: path == .keyRecord)
        guard path == .keyRecord, focusQueue.killSwitch.isOn, case .window(let id) = target,
              misses.willRequest(id, pid: pid, at: stamp, retry: retry) else { return }
        focusQueue.killSwitch.turnOff(.wrongWindows)
        controllerLog.fault("private focus keyed another window \(FocusMisses.limit) times in a row; focus uses the public path")
        onFocusProblem?(focusProblem)
    }

    func touch(_ window: WindowID) {
        recent.removeAll { $0 == window }
        recent.append(window)
    }

    func mostRecent(_ windows: [WindowID]) -> WindowID? {
        windows.max { (recent.lastIndex(of: $0) ?? -1) < (recent.lastIndex(of: $1) ?? -1) }
    }

    /// Every change of the model ends here, so the drag tap's windows, the borders and the saved
    /// layout follow it.
    func publishState() {
        let data = stateJSON()
        bar.publish(data)
        publish?(data)
        dragTap?.setWindows(draggable)
        updateBorders()
        writeLayoutSoon()
    }

    /// One write a second at most, a second after the first change since the last write, so
    /// a crash loses at most that second, and a switch at most sets the timer. The write drops
    /// the pending windows that closed first (docs/tree.md).
    private func writeLayoutSoon() {
        guard windowServer != nil, !layoutWritePending else { return }
        layoutWritePending = true
        after(.seconds(1)) { controller in
            controller.dropClosedPending()
            controller.writeLayout()
        }
    }

    /// A saved window that closed before Kosmos admitted it gives its tile up.
    private func dropClosedPending() {
        let pending = session.pendingWindows
        guard !pending.isEmpty, let open = Self.openRows(pending) else { return }
        let plan = session.forgetPending { open[$0] == nil }
        if !plan.isEmpty { execute(plan) }
    }

    /// The rows of the windows still open, leaving out one ordered out on no Space, as a window
    /// its app closed and kept, which opens as a new window. Nil when the query fails, which
    /// must not read as every window closed (docs/hiding.md).
    private static func openRows(_ windows: [WindowID]) -> [WindowID: WindowRow]? {
        guard let rows = SkyLight.readRows(windows) else { return nil }
        let open = rows.filter { $0.orderedIn || SkyLight.spaces(of: $0.id).map { !$0.isEmpty } ?? true }
        return Dictionary(open.map { ($0.id, $0) }) { first, _ in first }
    }

    func writeLayout(wait: Bool = false) {
        layoutWritePending = false
        guard let windowServer else { return }
        LayoutFile.write(session.savedLayout(), under: windowServer, wait: wait)
    }

    /// A locked session keeps its borders until the resync after the unlock (docs/borders.md).
    func updateBorders() {
        guard !sessionLocked else { return }
        guard managing, let borders else { return borderWindows.show([:]) }
        // One read of each slide, so a border's frame and alpha come from the same display frame.
        var sliding: [WindowID: (frame: CGRect, alpha: Double)] = [:]
        let shown = session.borders(borders, accent: borderWindows.accent, red: borderWindows.red,
                                    flashing: Set(flashes.keys)) { id in
            guard !hiding.isConcealed(id), !order.conceals(id), let row = inventory.windows[id], row.orderedIn else { return nil }
            sliding[id] = slides?.shown(id)
            return (sliding[id]?.frame ?? row.frame, row.cornerRadius)
        }
        borderWindows.show(shown.reduce(into: [:]) { result, entry in
            let slide = sliding[entry.key]
            result[entry.key] = Borders.Shown(border: entry.value, level: inventory.windows[entry.key]?.level ?? 0,
                                              alpha: slide?.alpha ?? 1, sliding: slide != nil)
        }, fullscreen: fullscreenDisplays)
    }

    /// Only plans come here, so the 100 ms retry never flashes, and a drag's plans record their
    /// tiles and flash nothing (docs/borders.md).
    func flashSpills(_ targets: [WindowID: CGRect], written: [WindowID: CGRect]) {
        let spilling = session.spilling(targets, written: Set(written.keys), tiles: &tiles) { [inventory] in
            inventory.windows[$0]?.frame
        }
        if !dragging { flash(spilling) }
    }

    /// Each border takes the warning color for 0.3 s, until the window's latest flash ends.
    private func flash(_ windows: Set<WindowID>) {
        guard !windows.isEmpty, borders != nil else { return }
        for id in windows { flashes[id, default: 0] += 1 }
        updateBorders()
        after(.milliseconds(300)) { controller in
            for id in windows { controller.flashes[id] = controller.flashes[id].flatMap { $0 > 1 ? $0 - 1 : nil } }
            controller.updateBorders()
        }
    }

    func appName(_ window: WindowID) -> String? {
        owner[window].flatMap { inventory.appIdentity($0).name }
    }

    func stateJSON() -> Data {
        let snapshot = session.barSnapshot(profile: profile, displays: barDisplays, app: appName,
                                           frame: { [inventory] id in inventory.windows[id]?.frame })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(snapshot)) ?? Data("{}".utf8)
    }
}
