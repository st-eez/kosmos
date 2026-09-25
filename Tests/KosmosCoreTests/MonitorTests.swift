import CoreGraphics
import Testing
@testable import KosmosCore

@Suite struct ArrangementTests {
    @Test func eachDisplayShowsItsFirstWorkspaceAndTheFirstHasTheFocus() {
        let s = desk()
        #expect(s.monitors.map(\.id) == [1, 2, 3])   // left to right
        #expect(s.shownWorkspaces == ["5", "1", "8"])
        #expect(s.focusedWorkspace == "1")
        #expect(s.focusedDisplay == 2)
    }

    @Test func freeWorkspacesFillDisplaysWithNoneAssigned() {
        let s = desk(["1": 2])
        #expect(s.shownWorkspaces == ["2", "1", "3"])
        // A free hidden workspace is laid out on the focused display.
        #expect(s.monitor(of: "4").id == 2)
    }

    @Test func aDisplayNoWorkspaceCanGoToShowsNone() {
        let s = desk(["1": 2, "2": 2], names: ["1", "2"])
        #expect(s.shownWorkspaces == ["1"])
        #expect(s.isShown("1") && !s.isShown("2"))
    }

    @Test func hiddenWorkspacesAreLaidOutOnTheirDisplay() {
        var s = desk()
        _ = s.add(10, to: "6"); _ = s.add(11, to: "6")
        _ = s.add(20, to: "9")
        #expect(within(s.frames(of: "6"), Desk.left))
        #expect(within(s.frames(of: "9"), Desk.builtIn))
    }

    @Test func aNewWindowJoinsTheWorkspaceOfTheDisplayUnderIt() {
        var s = desk()
        #expect(s.add(10, at: CGPoint(x: -500, y: 500)).hide.isEmpty)
        #expect(s.workspace(of: 10) == "5")
        _ = s.add(11, at: CGPoint(x: 900, y: 1500))
        #expect(s.workspace(of: 11) == "8")
        // A rule wins, and a window under no display joins the focused workspace.
        #expect(s.add(12, to: "6", at: CGPoint(x: -500, y: 500)).hide == [12])
        _ = s.add(13, at: CGPoint(x: 5000, y: 5000))
        #expect(s.workspace(of: 13) == "1")
    }
}

@Suite struct DisplayCommandTests {
    @Test func aWorkspaceAnotherDisplayShowsOnlyTakesTheFocus() {
        var s = desk()
        _ = s.add(10); _ = s.add(50, to: "5")
        let plan = s.perform(.workspace(.named("5")))!
        #expect(plan.show.isEmpty && plan.hide.isEmpty && plan.frames.isEmpty)
        #expect(plan.focus == .window(50))
        #expect(s.focusedWorkspace == "5" && s.focusedDisplay == 1)
        #expect(s.perform(.workspaceBackAndForth)?.focus == .window(10))
        #expect(s.focusedDisplay == 2)
    }

    @Test func aHiddenWorkspaceShowsOnItsOwnDisplay() {
        var s = desk()
        _ = s.add(10); _ = s.add(50, to: "5"); _ = s.add(60, to: "6")
        let plan = s.perform(.workspace(.named("6")))!
        #expect(plan.hide == [50] && plan.show == [60])
        #expect(within(plan.frames, Desk.left))
        #expect(s.shownWorkspaces == ["6", "1", "8"])
        #expect(s.focusedDisplay == 1)
    }

    @Test func anEmptyWorkspaceOnAnotherDisplayFocusesNoWindow() {
        var s = desk()
        _ = s.add(10)
        #expect(s.perform(.workspace(.named("8")))?.focus == .noWindow)
        #expect(s.focused == nil)
    }

    @Test func nextAndPreviousWalkTheFocusedDisplay() {
        var s = desk()
        var walked: [String] = []
        for _ in 0..<4 {
            _ = s.perform(.workspace(.next))
            walked.append(s.focusedWorkspace)
        }
        #expect(walked == ["2", "3", "4", "1"])
        _ = s.perform(.workspace(.named("5")))
        _ = s.perform(.workspace(.previous))
        #expect(s.focusedWorkspace == "7")
    }

    @Test func aFreeWorkspaceShowsOnTheFocusedDisplay() {
        var s = desk(Desk.home.filter { $0.key != "4" })
        _ = s.perform(.workspace(.named("5")))
        let plan = s.perform(.workspace(.named("4")))!
        #expect(s.shownWorkspaces == ["4", "1", "8"])
        #expect(plan.focus == .noWindow)
        // It walks with the left panel's workspaces now, and with the main panel's there.
        _ = s.perform(.workspace(.next))
        #expect(s.focusedWorkspace == "5")
    }

    @Test func focusMonitorFindsDisplaysByDirectionOrderNumberAndName() {
        var s = desk()
        func focusing(_ target: Command.MonitorTarget, wrap: Bool = false) -> String? {
            var copy = s
            return copy.perform(.focusMonitor(target, wrapAround: wrap)).map { _ in copy.focusedWorkspace }
        }
        #expect(focusing(.direction(.left)) == "5")
        #expect(focusing(.direction(.right)) == nil)
        #expect(focusing(.direction(.right), wrap: true) == "5")
        #expect(focusing(.direction(.down)) == "8")
        #expect(focusing(.direction(.up)) == nil)
        #expect(focusing(.next) == "8")
        #expect(focusing(.previous) == "5")
        #expect(focusing(.number(1)) == "5")
        #expect(focusing(.number(2)) == nil)   // already focused
        #expect(focusing(.number(4)) == nil)
        _ = s.perform(.focusMonitor(.direction(.down), wrapAround: false))
        #expect(s.perform(.focusMonitor(.direction(.up), wrapAround: false)) != nil)
        #expect(s.focusedWorkspace == "1")
    }

    @Test func aDisplayBelowAndLeftIsStillBelow() {
        let low = Monitor(id: 4, frame: CGRect(x: -300, y: 1080, width: 1512, height: 982))
        var s = Session(names: ["1", "2"], monitors: [Desk.main, low], assigned: ["1": 2, "2": 4])
        #expect(s.perform(.focusMonitor(.direction(.down), wrapAround: false)) != nil)
        #expect(s.focusedWorkspace == "2")
    }

    @Test func moveNodeToMonitorMovesTheWindowToTheShownWorkspaceThere() {
        var s = desk()
        _ = s.add(10); _ = s.add(11)
        _ = s.add(50, to: "5"); _ = s.add(51, to: "5")
        s.adopt(11)
        let plan = s.perform(.moveNodeToMonitor(.direction(.left), focusFollowsWindow: false, wrapAround: false))!
        #expect(s.workspace(of: 11) == "5")
        #expect(plan.show.isEmpty && plan.hide.isEmpty)
        // Moving left, it enters the left panel by its right edge.
        #expect(s.workspaces["5"]!.tree == "h[50 51 11]")
        #expect(within(plan.frames.filter { $0.key != 10 }, Desk.left))
        #expect(plan.frames[10] == Desk.main.area.insetBy(dx: 10, dy: 10))
        #expect(plan.focus == .window(10))
        #expect(s.focusedWorkspace == "1")
    }

    @Test func moveNodeToMonitorFollowsTheWindowOnRequest() {
        var s = desk()
        _ = s.add(10); _ = s.add(11)
        _ = s.add(50, to: "5")
        s.adopt(10)
        let plan = s.perform(.moveNodeToMonitor(.direction(.left), focusFollowsWindow: true, wrapAround: false))!
        #expect(plan.focus == .window(10))
        #expect(s.focusedWorkspace == "5")
        // Entering the main panel by its left edge, it lands first.
        _ = s.perform(.moveNodeToMonitor(.direction(.right), focusFollowsWindow: true, wrapAround: false))
        #expect(s.workspaces["1"]!.tree == "h[10 11]")
    }

    @Test func aHiddenWindowMovedToAnotherDisplaysShownWorkspaceIsRevealed() {
        var s = desk()
        _ = s.add(10); _ = s.add(60, to: "6")
        let plan = s.perform(.moveNodeToWorkspace(.named("5"), focusFollowsWindow: true, window: 60))!
        #expect(plan.show == [60] && plan.hide.isEmpty)
        #expect(plan.focus == .window(60) && s.focusedWorkspace == "5")
    }

    @Test func moveNodeToMonitorByNumberReachesAnyDisplay() {
        var s = desk()
        _ = s.add(10)
        _ = s.perform(.moveNodeToMonitor(.number(3), focusFollowsWindow: false, wrapAround: false))
        #expect(s.workspace(of: 10) == "8")
        #expect(s.perform(.moveNodeToMonitor(.number(3), focusFollowsWindow: false, wrapAround: false, window: 10)) == nil)
    }

    @Test func aFloatingWindowOnADisplayShowingAnotherWorkspaceGoesToItsOwn() {
        var s = desk()
        _ = s.add(10, floating: true)
        _ = s.add(50, to: "5", floating: true)
        _ = s.add(60, to: "6", floating: true)
        #expect(s.shownFloatingWindows.sorted() == [10, 50])
        let onMain = CGRect(x: 100, y: 100, width: 400, height: 300)
        // 10 is home on the main panel, 50 goes to the left panel at the same place, and 60's
        // workspace is hidden.
        #expect(s.floatingFrames(at: [10: onMain, 50: onMain, 60: onMain]) == [50: CGRect(x: -1820, y: 100, width: 400, height: 300)])
        _ = s.perform(.moveNodeToMonitor(.direction(.left), focusFollowsWindow: false, wrapAround: false, window: 10))
        #expect(s.floatingFrames(at: [10: onMain]) == [10: CGRect(x: -1820, y: 100, width: 400, height: 300)])
        // Onto a smaller display it keeps its relative place and stays inside, measured from
        // the display it is on.
        _ = s.perform(.moveNodeToMonitor(.number(3), focusFollowsWindow: false, wrapAround: false, window: 10))
        #expect(s.floatingFrames(at: [10: CGRect(x: 960, y: 540, width: 400, height: 300)])
                == [10: CGRect(x: 956, y: 1571, width: 400, height: 300)])
        #expect(s.floatingFrames(at: [10: CGRect(x: -1920, y: 540, width: 400, height: 300)])
                == [10: CGRect(x: 200, y: 1571, width: 400, height: 300)])
        #expect(s.floatingFrames(at: [10: CGRect(x: -500, y: -1000, width: 3000, height: 3000)])[10]?.size == Desk.builtIn.area.size)
        // A window off every display, as a concealed one reads, stays.
        #expect(s.floatingFrames(at: [10: CGRect(x: 100_000, y: 100_000, width: 400, height: 300)]).isEmpty)
    }

    @Test func aFloatingWindowDraggedOntoAnotherDisplayJoinsItsWorkspace() {
        var s = desk()
        _ = s.add(10, floating: true)
        _ = s.add(11)
        _ = s.add(60, to: "6", floating: true)
        s.adopt(10)
        let onMain = CGRect(x: 100, y: 100, width: 400, height: 300)
        let onLeft = CGRect(x: -1000, y: 100, width: 400, height: 300)
        // On its own display or on none, it stays, and so do a tiled window and a floating
        // window of a hidden workspace.
        #expect(s.dragged(10, to: onMain) == nil)
        #expect(s.dragged(10, to: CGRect(x: 100_000, y: 100_000, width: 400, height: 300)) == nil)
        #expect(s.dragged(11, to: onLeft) == nil)
        #expect(s.dragged(60, to: onMain) == nil)
        let plan = s.dragged(10, to: onLeft)
        #expect(plan != nil && plan?.show == [] && plan?.hide == [] && plan?.focus == nil)
        #expect(s.workspace(of: 10) == "5" && s.workspaces["5"]!.floating == [10])
        #expect(s.focusedWorkspace == "5" && s.focused == 10)
        #expect(s.floatingFrames(at: [10: onLeft]).isEmpty)
    }

    @Test func aTiledWindowResizedByItsEdgesGoesBackToItsTile() {
        var s = desk()
        _ = s.add(10); _ = s.add(11); _ = s.add(50, to: "5"); _ = s.add(20, to: "2")
        // 20's workspace is hidden, as after a switch during the resize.
        var tiles = s.frames(of: "1")
        tiles.merge(s.frames(of: "5")) { current, _ in current }
        #expect(s.released([10, 50, 20]).frames == tiles)
        s.adopt(11)
        _ = s.perform(.layout(.toggleFloating))
        #expect(s.released([11]).frames.isEmpty)
    }

    @Test func focusAcrossMonitorsCrossesAtTheEdgeOnly() {
        var s = desk()
        _ = s.add(10); _ = s.add(11)
        _ = s.add(50, to: "5")
        s.adopt(11)
        #expect(s.perform(.focus(.left, boundaries: .allMonitors))?.focus == .window(10))
        #expect(s.focusedWorkspace == "1")
        #expect(s.perform(.focus(.left))?.focus == nil)   // at the edge, within the workspace
        #expect(s.perform(.focus(.left, boundaries: .allMonitors))?.focus == .window(50))
        #expect(s.focusedWorkspace == "5")
        // From an empty workspace, too, to the main panel's last focus.
        _ = s.perform(.workspace(.named("8")))
        #expect(s.perform(.focus(.up, boundaries: .allMonitors))?.focus == .window(10))
    }

    @Test func focusAcrossMonitorsCrossesOnlyPastTheFloatingWindows() {
        var s = desk()
        _ = s.add(10); _ = s.add(11); _ = s.add(12, floating: true); _ = s.add(13, floating: true)
        _ = s.add(50, to: "5"); _ = s.add(51, to: "5", floating: true)
        _ = s.park([13])
        let between = CGRect(x: 760, y: 300, width: 400, height: 400)
        let frames: [WindowID: CGRect] = [12: CGRect(x: 0, y: 300, width: 400, height: 400), 13: between, 51: between]
        // A parked window and another workspace's floating window count nowhere, whatever
        // their frames.
        s.adopt(10)
        #expect(s.perform(.focus(.right, boundaries: .allMonitors), frame: { frames[$0] })?.focus == .window(11))
        s.adopt(10)
        #expect(s.perform(.focus(.left, boundaries: .allMonitors), frame: { frames[$0] })?.focus == .window(12))
        #expect(s.focusedWorkspace == "1")
        #expect(s.perform(.focus(.left, boundaries: .allMonitors), frame: { frames[$0] })?.focus == .window(50))
        #expect(s.focusedWorkspace == "5")
    }

    @Test func moveAcrossMonitorsTakesTheWindowOverTheEdgeAndFollowsIt() {
        var s = desk()
        _ = s.add(11); _ = s.add(10)
        s.adopt(10)
        #expect(s.perform(.move(.left, boundaries: .allMonitors)) != nil)
        #expect(s.workspace(of: 10) == "1")
        #expect(s.workspaces["1"]!.tree == "h[10 11]")
        let plan = s.perform(.move(.left, boundaries: .allMonitors))!
        #expect(s.workspace(of: 10) == "5")
        #expect(s.focusedWorkspace == "5")
        #expect(plan.hide.isEmpty && plan.show.isEmpty)
        // A lone window crosses too, and past the outermost display only when it wraps.
        #expect(s.perform(.move(.left, boundaries: .allMonitors)) == nil)
        #expect(s.perform(.move(.left, boundaries: .allMonitorsWrapping)) != nil)
        #expect(s.workspace(of: 10) == "1")
        _ = s.perform(.layout(.toggleFloating))
        #expect(s.perform(.move(.left, boundaries: .allMonitors)) == nil)
    }

    @Test func moveAcrossMonitorsCrossesWhereNoContainerAboveRunsAlong() {
        // No display is above the main panel, so the window wraps to the built-in display below.
        var s = desk()
        _ = s.add(10); _ = s.add(13); _ = s.add(12); _ = s.add(11)
        #expect(s.workspaces["1"]!.tree == "h[10 11 12 13]")
        s.adopt(11)
        #expect(s.perform(.move(.up, boundaries: .allMonitorsWrapping)) != nil)
        #expect(s.workspace(of: 11) == "8" && s.focusedWorkspace == "8")
        #expect(s.workspaces["1"]!.tree == "h[10 12 13]")
        s.adopt(13)
        #expect(s.perform(.move(.up, boundaries: .allMonitors)) == nil)
        #expect(s.workspaces["1"]!.tree == "h[10 12 13]")
    }
}

@Suite struct StrippingTests {
    @Test func aConcealedWindowIsStrippedWhenItsAppsLatestWindowIsOnAnotherDisplay() {
        var s = desk()
        _ = s.add(10); _ = s.add(50, to: "5"); _ = s.add(60, to: "6"); _ = s.add(20, to: "2")
        // One app owns 10, 20 and 60, and 10 is its window focused last.
        let latest: (WindowID) -> WindowID? = { [10, 20, 60].contains($0) ? 10 : nil }
        // 60, concealed on the left panel away from 10, is stripped. 20, concealed on 10's
        // main panel, keeps its Space, and so does 50, another app's.
        #expect(s.stripped([20, 50, 60], latest: latest) == [60])
        // Once 10 is minimized, nothing of the app shows, and nothing is stripped.
        _ = s.park([10])
        #expect(s.stripped([20, 60], latest: latest).isEmpty)
        let one = Session(names: ["1", "2"], display: Desk.main.frame)
        #expect(one.stripped([1, 2], latest: { _ in 1 }).isEmpty)
    }
}

@Suite struct DisplayFocusTests {
    @Test func adoptingAWindowOnAnotherDisplayFocusesThatDisplay() {
        var s = desk()
        _ = s.add(10); _ = s.add(50, to: "5"); _ = s.add(60, to: "6")
        s.adopt(50)
        #expect(s.focusedWorkspace == "5" && s.focused == 50)
        // A window of a hidden workspace is only focused within it.
        s.adopt(60)
        #expect(s.focusedWorkspace == "5")
        #expect(s.perform(.workspaceBackAndForth)?.focus == .window(10))
    }

    @Test func followingAWindowOnAnotherDisplaysShownWorkspaceConcealsNothing() {
        var s = desk()
        _ = s.add(10); _ = s.add(50, to: "5"); _ = s.add(60, to: "6")
        let plan = s.follow(50)
        #expect(plan.show.isEmpty && plan.hide.isEmpty)
        #expect(s.focusedWorkspace == "5")
        #expect(s.follow(60).hide == [50])
        #expect(s.shownWorkspaces == ["6", "1", "8"])
    }

    @Test func aWindowReturningToAnotherDisplayIsFollowedThere() {
        var s = desk()
        _ = s.add(10); _ = s.add(50, to: "5"); _ = s.add(51, to: "5")
        _ = s.park([50])
        let plan = s.unpark([50], follow: 50)
        #expect(s.focusedWorkspace == "5")
        #expect(plan.show.isEmpty && plan.hide.isEmpty)
        #expect(within(plan.frames, Desk.left))
    }

    @Test func removingTheFocusOfAnUnfocusedDisplayRequestsNothing() {
        var s = desk()
        _ = s.add(10); _ = s.add(50, to: "5"); _ = s.add(51, to: "5")
        #expect(s.remove(50).focus == nil)
        #expect(s.remove(10).focus == .noWindow)
    }
}

/// Runs random operations on three displays, carries out each plan on a model of the screen,
/// and checks after each step what docs/displays.md promises.
@Test(arguments: 1...12 as ClosedRange<UInt64>)
func randomDisplayOperationsKeepTheScreenRight(seed: UInt64) {
    var random = SplitMix64(state: seed)
    let displays = [Desk.left, Desk.main, Desk.builtIn]
    let profiles: [(names: [String], assigned: [String: DisplayID], merge: [String: String])] = [
        (Desk.names, Desk.home, [:]),
        (["1", "2", "3", "4", "5"], ["1": 3, "2": 3, "3": 3, "4": 3, "5": 3], ["6": "1", "7": "2", "8": "3", "9": "4", "0": "5"]),
        (Desk.names, ["1": 2, "2": 2, "5": 1], [:]),   // the rest free
    ]
    var s = desk()
    var assigned = Desk.home
    var concealed: Set<WindowID> = []
    var nextWindow: WindowID = 1

    // The frames the app has written, as the plans and the resyncs give them.
    var written: [WindowID: CGRect] = [:]

    func carryOut(_ plan: Session.Plan?) {
        guard let plan else { return }
        #expect(Set(plan.show).isDisjoint(with: plan.hide), "seed \(seed)")
        let floating = Set(s.names.flatMap { s.workspaces[$0]!.floating })
        #expect(floating.isDisjoint(with: plan.frames.keys), "seed \(seed): a frame for a floating window")
        concealed.subtract(plan.show)
        concealed.formUnion(plan.hide)
        written.merge(plan.frames) { _, new in new }
    }

    for step in 0..<3000 {
        let windows = s.names.flatMap { s.workspaces[$0]!.root.windows + s.workspaces[$0]!.floating + s.workspaces[$0]!.parked.map(\.window) }
        let window = windows.randomElement(using: &random)
        let name = s.names.randomElement(using: &random)!
        let target: Command.MonitorTarget = [.direction(.left), .direction(.right), .direction(.up), .direction(.down),
                                             .next, .previous, .number(Int.random(in: 1...3, using: &random))].randomElement(using: &random)!
        let wrap = Bool.random(using: &random)
        let operation = Int.random(in: 0..<30, using: &random)
        switch operation {
        case 0..<4:
            guard windows.count < 30 else { break }
            let point = CGPoint(x: CGFloat.random(in: -2000...2000, using: &random), y: CGFloat.random(in: 0...2100, using: &random))
            carryOut(s.add(nextWindow, to: Bool.random(using: &random) ? name : nil, at: point,
                           floating: Int.random(in: 0..<4, using: &random) == 0))
            nextWindow += 1
        case 4: if let window { carryOut(s.remove(window)); concealed.remove(window); written[window] = nil }
        case 5: if let window { carryOut(s.park([window])) }
        case 6: if let window { carryOut(s.unpark([window], follow: Bool.random(using: &random) ? window : nil)) }
        case 7: if let window, let home = s.workspace(of: window), s.isShown(home) { s.adopt(window) }
        case 8: if let window, let home = s.workspace(of: window), !s.isShown(home), !s.isParked(window) { carryOut(s.follow(window)) }
        case 9..<12: carryOut(s.perform(.workspace(.named(name))))
        case 12: carryOut(s.perform(.workspace(Bool.random(using: &random) ? .next : .previous)))
        case 13: carryOut(s.perform(.workspaceBackAndForth))
        case 14: carryOut(s.perform(.moveNodeToWorkspace(.named(name), focusFollowsWindow: Bool.random(using: &random), window: window)))
        case 15: carryOut(s.perform(.focusMonitor(target, wrapAround: wrap)))
        case 16: carryOut(s.perform(.moveNodeToMonitor(target, focusFollowsWindow: Bool.random(using: &random), wrapAround: wrap, window: window)))
        case 17, 18:
            let direction = [Direction.left, .right, .up, .down].randomElement(using: &random)!
            let boundaries: Command.Boundaries = wrap ? .allMonitorsWrapping : .allMonitors
            carryOut(s.perform(Bool.random(using: &random) ? .focus(direction, boundaries: boundaries) : .move(direction, boundaries: boundaries)))
        case 19: carryOut(s.perform(.layout(.toggleFloating)))
        case 20:
            // A tab switch, to a new tab or to a window with a place of its own. Both tabs
            // leave the holding Space, as Controller.tabSwitched has it.
            guard let window else { break }
            let new = Bool.random(using: &random) ? windows.randomElement(using: &random)! : nextWindow
            guard new != window else { break }
            if new == nextWindow { nextWindow += 1 }
            concealed.subtract([window, new])
            carryOut(s.replace(window, with: new))
        case 21: if let window { carryOut(s.lift(window)) }
        case 22: if let window { carryOut(s.reopen(window, to: Bool.random(using: &random) ? name : nil, floating: wrap)) }
        case 23, 24:
            let size = CGSize(width: CGFloat.random(in: 0...900, using: &random), height: CGFloat.random(in: 0...700, using: &random))
            if let window { carryOut(operation == 23 ? s.setMinimum(window, size) : s.sizeObserved(window, size)) }
        case 25:
            let frame = CGRect(x: CGFloat.random(in: -2500...2500, using: &random), y: CGFloat.random(in: -200...2000, using: &random),
                               width: 400, height: 300)
            if let window { carryOut(s.dragged(window, to: frame)) }
        case 26:
            // The left button comes up anywhere, off every display too.
            carryOut(s.drop(at: CGPoint(x: CGFloat.random(in: -2500...2500, using: &random), y: CGFloat.random(in: -200...2300, using: &random))))
            #expect(s.lifted.isEmpty, "seed \(seed) step \(step)")
        default:
            // A display change or a forced profile, and the resync after it.
            let profile = profiles.randomElement(using: &random)!
            var connected = displays.filter { _ in Bool.random(using: &random) }
            if connected.isEmpty { connected = [displays.randomElement(using: &random)!] }
            assigned = profile.assigned.filter { _, id in connected.contains { $0.id == id } }
            let before = s.monitors
            s.reconfigure(names: profile.names, monitors: connected, assigned: assigned, merge: profile.merge)
            carryOut(s.resyncPlan(layingOutHidden: s.monitors != before))
        }

        let shown = s.shownWorkspaces
        #expect(Set(shown).count == shown.count, "seed \(seed) step \(step)")
        #expect(s.isShown(s.focusedWorkspace), "seed \(seed) step \(step)")
        for name in shown {
            let display = s.monitor(of: name).id
            #expect(assigned[name] == nil || assigned[name] == display, "seed \(seed) step \(step): \(name) on \(display)")
            let area = s.monitor(of: name).area
            for window in s.workspaces[name]!.root.windows {
                #expect(written[window].map(area.contains) == true,
                        "seed \(seed) step \(step) operation \(operation): \(window) of \(name) off its display")
            }
        }
        for name in s.names {
            for window in s.windows(of: name) {
                #expect(concealed.contains(window) == !s.isShown(name),
                        "seed \(seed) step \(step) operation \(operation): \(window) on \(name)")
            }
        }
        #expect(s.validate().isEmpty, "seed \(seed) step \(step) operation \(operation): \(s.validate())")
    }
}
