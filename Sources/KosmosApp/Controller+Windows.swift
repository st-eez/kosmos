import AppKit
import KosmosCore
import os

extension Controller {
    func handle(_ event: Inventory.Event) {
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
            let landed = ledger.seen(id, frame: frame)
            if landed { sendReadyBatches() }
            frameChanged(id, from: old, to: frame, changedAt: changedAt, landed: landed)
            updateBorders()
        case .reordered(let id):
            borderWindows.raise(id)
        case .minimumChange(let id, let minimum):
            execute(session.constrain(id, to: minimum))
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
            place(id, pid: pid, .admitted)
        } else {
            unmanaged(id, pid: pid, at: .now)
        }
    }

    /// Perhaps a selected tab closed: its place waits for the next tab, or for the admission of
    /// a tab that claims it, decided again when each wait ends, as a look is (docs/tree.md).
    private func unmanaged(_ id: WindowID, pid: pid_t, at unmanagedAt: ContinuousClock.Instant) {
        guard !inventory.isManaged(id) else { return }
        if session.workspace(of: id) != nil,
           let wait = ClosedAndKept.hold(orderedOut: unmanagedAt, claimed: tabs.isClaimed(id),
                                         sibling: inventory.hasOrderedOutWindows(pid, besides: id),
                                         spacesChanged: nil, at: .now) {
            after(wait) { $0.unmanaged(id, pid: pid, at: unmanagedAt) }
            return
        }
        forget(id)
    }

    /// A tab dragged out of its group keeps out of its rule's workspace, and a window its app
    /// closed and kept opens again as a new window does (docs/tree.md).
    private enum Arrival { case admitted, detached, reopened }

    /// A window already minimized, in native fullscreen or hidden with its app waits parked,
    /// and a minimized or fullscreen one returns on its own, not when its app unhides. A
    /// reopened window opens as a new window does (docs/tree.md).
    private func place(_ id: WindowID, pid: pid_t, _ arrival: Arrival) {
        let app = inventory.appIdentity(pid)
        let rule = rules.first { $0.matches(appID: app.bundleID, appName: app.name) }
        // A window there at launch joins the workspace of the display under it; a later one
        // joins the focused workspace, as in AeroSpace (docs/displays.md).
        let atLaunch = arrival != .reopened && inventory.wasThereAtLaunch(id)
        let center = atLaunch ? inventory.windows[id].map { CGPoint(x: $0.frame.midX, y: $0.frame.midY) } : nil
        let floats = rule?.float == true, workspace = arrival == .detached ? nil : rule?.workspace
        let minimum = inventory.windows[id]?.minimum ?? .zero
        let reason = ParkReason.atAdmission(fullscreen: inventory.fullscreen.contains(id), minimized: inventory.isMinimized(id),
                                            appHidden: NSRunningApplication(processIdentifier: pid)?.isHidden == true)
        let saved = session.savedWorkspace(of: id)
        let placed: Session.Plan? = arrival == .reopened
            ? session.reopen(id, to: workspace, floating: floats, minimum: minimum, parked: reason)
            : session.add(id, to: workspace, at: center, floating: floats, minimum: minimum, parked: reason)
        guard var plan = placed else { return }
        let floating = session.isFloating(id)
        if let saved {
            controllerLog.info("\(id) back on \(saved, privacy: .public) as the saved layout had it\(floating ? ", floating" : "", privacy: .public)")
        } else if floating, let frame = inventory.windows[id]?.frame {
            controllerLog.info("\(id) floats by rule at its own frame, \(Int(frame.width))x\(Int(frame.height)) at \(Int(frame.minX)), \(Int(frame.minY))")
        }
        let (focus, bringsPointer) = intake.admit(id, atLaunch: atLaunch, at: .now, facts: reportFacts, reports: reports)
        if focus == .adopt { session.adopt(id) }
        // A report that keyed the window before it had a place follows it in this plan's switch,
        // so its hidden workspace shows it without a conceal first (docs/focus.md).
        var action = intake.placed(id, facts: reportFacts, reports: &reports, misses: &misses)
        var movePointer = bringsPointer
        if case .follow(id, let followPointer) = action {
            touch(id)
            (plan, movePointer, action) = (session.follow(id), bringsPointer || followPointer, .none)
        }
        execute(plan, movePointer: movePointer, floatingCheck: floating, popping: atLaunch ? nil : id)
        run(action)
    }

    private func forget(_ id: WindowID) {
        owner[id] = nil
        recent.removeAll { $0 == id }
        tabs.forget(id)
        intake.forgetPlacedHidden([id])
        ledger.forget(id)
        hiding.forgetClosed(id)
        execute(session.remove(id))
    }

    /// A native fullscreen window is on a Space of its own, so it parks (docs/tree.md).
    private func fullscreenChanged(_ id: WindowID, _ entered: Bool, spaceChangeBegan: ContinuousClock.Instant) {
        if entered {
            execute(session.park([id], because: .fullscreen))
        } else if session.parkReason(of: id) == .fullscreen {
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
        let closed = session.parkReason(of: id) == .closedByApp
        guard orderedIn, tabs.hidden.contains(id) || closed else { return }
        // Ceiling: a window that waits and is no tab switch stays at its old place for the
        // pairing window, then slides; measuring the pairing window sets the wait (docs/tree.md).
        if closed, !inventory.hasOrderedInWindow(pid, at: frame, besides: id) {
            return reopen(id, pid: pid)
        }
        after(TabSwitches.window) { controller in
            guard controller.inventory.windows[id]?.orderedIn == true else { return }
            if controller.session.parkReason(of: id) == .closedByApp {
                controller.reopen(id, pid: pid)
            } else if controller.tabs.detached(id), let pid = controller.owner[id] {
                controller.place(id, pid: pid, .detached)
            }
        }
    }

    /// An ordered out window leaves every Space, the holding Space too, so a conceal from
    /// before it closed would fail the next batch's confirmation.
    private func reopen(_ id: WindowID, pid: pid_t) {
        ledger.forget(id)
        hiding.forgetClosed(id)
        place(id, pid: pid, .reopened)
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
        let parked = session.parkReason(of: old) == .closedByApp
        if parked { _ = session.unpark([old], follow: nil) }
        guard let plan = session.replace(old, with: new, minimum: inventory.windows[new]?.minimum ?? .zero) else { return false }
        controllerLog.info("tab \(new) replaces \(old)\(parked ? ", after \(old) parked as closed and kept" : "", privacy: .public)")
        tabs.replaced(old, with: new)
        // A deselected tab leaves every Space, and the tab selected lands on its ordinary
        // Space whatever was concealed (kosmos-probe tabs); the plan conceals it afresh.
        hiding.forget([old, new])
        ledger.forget(new)
        intake.tabReplaced(old, with: new, concealing: plan.hide.contains(new))
        execute(plan)
        // macOS can report the new tab key before it has a place: the user's or the app's
        // choice, whose key window before it, the deselected tab, did not depart (docs/tree.md).
        windowPlaced(new)
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
        depart([id], because: .closedByApp, remaining: owner[id].map { inventory.otherWindows(of: $0, besides: id) } ?? [])
    }

    /// A command received after the return wins, and its focus is requested again, as macOS
    /// keyed the returning window (docs/tree.md; tla/Kosmos.tla, Rejoin).
    private func returned(_ windows: [WindowID], follow: WindowID?, at stamp: ContinuousClock.Instant) {
        let stale = reports.isStale(stamp)
        var plan = session.unpark(windows, follow: stale ? nil : follow)
        if stale { plan.focus = session.intent }
        // A Dock click or Command-Tab that brings it back picks it away from the pointer.
        execute(plan, movePointer: movesPointer(after: .returned(followed: follow != nil && !stale)))
    }

    /// When the key window left too and macOS has a window to key, the focus waits for its
    /// report of the next key window, up to the departure bound (tla/Kosmos.tla, Depart).
    private func depart(_ windows: [WindowID], because reason: ParkReason, remaining: [DepartureFocus.OtherWindow]? = nil) {
        let focusLeft = session.focused.map(windows.contains) == true
        execute(session.park(windows, because: reason))
        switch DepartureFocus.decide(focusLeft: focusLeft, key: key, departing: windows, left: inventory.leftScreen,
                                     remaining: remaining) {
        case .none:
            break
        case .now:
            requestFocus(session.intent)
        case .afterKeyReport:
            guard case .window(let keyWindow)? = key else { break }
            let number = intake.awaitNextKey(after: keyWindow)
            after(Inventory.departureBound) { controller in
                if controller.intake.boundEnds(number) { controller.requestFocus(controller.session.intent) }
            }
        }
    }

    /// A window the user drags parks too, where it stood.
    private func appHidden(_ pid: pid_t) {
        let windows = owner.filter { id, app in
            app == pid && session.workspace(of: id) != nil && (!session.isParked(id) || session.lifted.contains(id))
        }.map(\.key)
        guard !windows.isEmpty else { return }
        depart(windows, because: .appHidden)
    }

    private func appUnhidden(_ pid: pid_t, at received: ContinuousClock.Instant) {
        func hidden() -> [WindowID] { session.parked(because: .appHidden).filter { owner[$0] == pid } }
        guard !hidden().isEmpty else { return }
        Task {
            // An app that does not answer names no window, and the fallback is followed.
            let keyed = await inventory.worker(pid)?.focusedWindow() ?? nil
            let windows = hidden()
            // Hidden again while the worker answered: the windows wait for the next unhide.
            guard NSRunningApplication(processIdentifier: pid)?.isHidden != true, !windows.isEmpty else { return }
            returned(windows, follow: session.followOnUnhide(windows, keyed: keyed, fallback: mostRecent(windows)),
                     at: received)
        }
    }

    private func handle(_ report: AXReport) {
        switch report.kind {
        case .backgroundFocus(let id):
            backgroundFocusChanged(id, report: report)
        case .focusedWindowChanged(let id):
            focusedWindowChanged(id, report: report)
        case .minimized(let id, true):
            depart([id], because: .minimized)
        case .minimized(let id, false):
            returned([id], follow: id, at: report.received)
        case .frameApplied(let id, let target, let readBack):
            let asked = "asked \(Int(target.width))x\(Int(target.height)), kept \(Int(readBack.width))x\(Int(readBack.height))"
            // Concealed or on a hidden workspace, a window refused once at most, and its
            // retry waits for the reveal (docs/geometry.md). Ceiling: a window a failed batch
            // left concealed on a shown workspace is written every 100 ms while it refuses,
            // until a switch reveals it. Upgrade: writeTileAgain skips concealed windows, and
            // the switch that reveals them (needsResync) writes their tiles.
            if hiding.isConcealed(id) || session.workspace(of: id).map(session.isShown) != true {
                ledger.forgetLargerReadBack(id)
            }
            slides?.confirmed(id, target: target, readBack: readBack)
            switch ledger.confirm(id, target: target, readBack: readBack, at: .now) {
            case .took:
                break
            case .refused:
                controllerLog.info("\(id) \(asked, privacy: .public); its tile is written again")
                after(.milliseconds(100)) { $0.writeTileAgain(id) }
            case .minimum(let size):
                controllerLog.notice("minimum for \(id): \(asked, privacy: .public)")
                execute(session.setMinimum(id, size))
            }
            // WindowServer can take the frame before the read back comes (docs/hiding.md).
            if let row = inventory.windows[id] { ledger.seen(id, frame: row.frame) }
            sendReadyBatches()
        case .framesDropped(let ids):
            // Forgotten, so their targets are not pending for good and the next writes are whole.
            for id in ids { ledger.forget(id) }
            sendReadyBatches()
        case .windowCreated, .windowDestroyed, .answering:
            break
        }
    }

    /// 100 ms after a first larger read back, as the window's next change event can come
    /// inside a live resize step still queued (docs/geometry.md).
    private func writeTileAgain(_ id: WindowID) {
        guard mouseMoved[id] == nil, let name = session.workspace(of: id), session.isShown(name) else { return }
        writeFrames(session.frames(of: name))
    }
}
