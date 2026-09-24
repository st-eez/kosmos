import CoreGraphics
import Testing
@testable import KosmosCore

// Steve's desk (DESIGN.md, section 5.13): the left panel, the main panel at the origin, and
// the built-in display below, with 10 point outer gaps.
private let gaps = Gaps(outer: Insets(top: 10, left: 10, bottom: 10, right: 10))
private let left = Monitor(id: 1, frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080), gaps: gaps)
private let main = Monitor(id: 2, frame: CGRect(x: 0, y: 0, width: 1920, height: 1080), gaps: gaps)
private let builtIn = Monitor(id: 3, frame: CGRect(x: 200, y: 1080, width: 1512, height: 982), gaps: gaps)
private let names = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"]
private let home: [String: DisplayID] = ["1": 2, "2": 2, "3": 2, "4": 2, "5": 1, "6": 1, "7": 1, "8": 3, "9": 3, "0": 3]

private func desk(_ assigned: [String: DisplayID] = home, names: [String] = names) -> Session {
    Session(names: names, monitors: [builtIn, main, left], assigned: assigned)
}

private func within(_ frames: [WindowID: CGRect], _ monitor: Monitor) -> Bool {
    !frames.isEmpty && frames.values.allSatisfy { monitor.area.insetBy(dx: 9, dy: 9).contains($0) }
}

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
        #expect(within(s.frames(of: "6"), left))
        #expect(within(s.frames(of: "9"), builtIn))
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
        // Back and forth returns to the main panel the same way.
        #expect(s.perform(.workspaceBackAndForth)?.focus == .window(10))
        #expect(s.focusedDisplay == 2)
    }

    @Test func aHiddenWorkspaceShowsOnItsOwnDisplay() {
        var s = desk()
        _ = s.add(10); _ = s.add(50, to: "5"); _ = s.add(60, to: "6")
        let plan = s.perform(.workspace(.named("6")))!
        #expect(plan.hide == [50] && plan.show == [60])
        #expect(within(plan.frames, left))
        #expect(s.shownWorkspaces == ["6", "1", "8"])
        #expect(s.focusedDisplay == 1)
    }

    @Test func anEmptyWorkspaceOnAnotherDisplayFocusesNoWindow() {
        var s = desk()
        _ = s.add(10)
        #expect(s.perform(.workspace(.named("8")))?.focus == KeyWindow.none)
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
        var s = desk(home.filter { $0.key != "4" })
        _ = s.perform(.workspace(.named("5")))
        let plan = s.perform(.workspace(.named("4")))!
        #expect(s.shownWorkspaces == ["4", "1", "8"])
        #expect(plan.focus == KeyWindow.none)
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
        var s = Session(names: ["1", "2"], monitors: [main, low], assigned: ["1": 2, "2": 4])
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
        #expect(within(plan.frames.filter { $0.key != 10 }, left))
        #expect(plan.frames[10] == main.area.insetBy(dx: 10, dy: 10))
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
        // Entering from the right into a horizontal root by moving right lands first.
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
        _ = s.add(10); _ = s.float(10)
        _ = s.add(50, to: "5"); _ = s.float(50)
        _ = s.add(60, to: "6"); _ = s.float(60)
        #expect(s.shownFloatingWindows.sorted() == [10, 50])
        let onMain = CGRect(x: 100, y: 100, width: 400, height: 300)
        // 10 on the main panel is home; 50 there too, and it goes to the left panel at the
        // same place; 60's workspace is hidden, so it is left alone.
        #expect(s.floatingFrames(at: [10: onMain, 50: onMain, 60: onMain]) == [50: CGRect(x: -1820, y: 100, width: 400, height: 300)])
        // As after move-node-to-monitor: 10 now belongs on the left panel.
        _ = s.perform(.moveNodeToMonitor(.direction(.left), focusFollowsWindow: false, wrapAround: false, window: 10))
        #expect(s.floatingFrames(at: [10: onMain]) == [10: CGRect(x: -1820, y: 100, width: 400, height: 300)])
        // Onto a smaller display it keeps its relative place and stays inside, measured from
        // the display it is on.
        _ = s.perform(.moveNodeToMonitor(.number(3), focusFollowsWindow: false, wrapAround: false, window: 10))
        #expect(s.floatingFrames(at: [10: CGRect(x: 960, y: 540, width: 400, height: 300)])
                == [10: CGRect(x: 956, y: 1571, width: 400, height: 300)])
        #expect(s.floatingFrames(at: [10: CGRect(x: -1920, y: 540, width: 400, height: 300)])
                == [10: CGRect(x: 200, y: 1571, width: 400, height: 300)])
        #expect(s.floatingFrames(at: [10: CGRect(x: -500, y: -1000, width: 3000, height: 3000)])[10]?.size == builtIn.area.size)
        // A window off every display, as a concealed one reads, stays.
        #expect(s.floatingFrames(at: [10: CGRect(x: 100_000, y: 100_000, width: 400, height: 300)]).isEmpty)
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
        // A floating window stays.
        _ = s.perform(.layout(.toggleFloating))
        #expect(s.perform(.move(.left, boundaries: .allMonitors)) == nil)
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
        #expect(within(plan.frames, left))
    }

    @Test func removingTheFocusOfAnUnfocusedDisplayRequestsNothing() {
        var s = desk()
        _ = s.add(10); _ = s.add(50, to: "5"); _ = s.add(51, to: "5")
        #expect(s.remove(50).focus == nil)
        #expect(s.remove(10).focus == KeyWindow.none)
    }
}

@Suite struct ReconfigureTests {
    @Test func closingTheLidMovesTheBuiltInWorkspacesToTheMainPanel() {
        var s = desk()
        _ = s.add(80, to: "8")
        _ = s.perform(.workspace(.named("8")))
        var assigned = home
        for name in ["8", "9", "0"] { assigned[name] = 2 }
        s.reconfigure(names: names, monitors: [left, main], assigned: assigned, merge: [:])
        // The focused workspace keeps the focus, on its new display.
        #expect(s.focusedWorkspace == "8" && s.focused == 80)
        #expect(s.shownWorkspaces == ["5", "8"])
        #expect(within(s.frames(of: "8"), main))
        // Opening it again: 8 goes back, and the main panel shows its first workspace.
        s.reconfigure(names: names, monitors: [builtIn, left, main], assigned: home, merge: [:])
        #expect(s.shownWorkspaces == ["5", "1", "8"])
        #expect(s.focusedWorkspace == "8" && s.focusedDisplay == 3)
    }

    @Test func eachDisplayKeepsItsWorkspaceWhereItMayStay() {
        var s = desk()
        _ = s.perform(.workspace(.named("7")))
        _ = s.perform(.workspace(.named("3")))
        s.reconfigure(names: names, monitors: [left, main, builtIn], assigned: home, merge: [:])
        #expect(s.shownWorkspaces == ["7", "3", "8"])
    }

    @Test func aDisplayThatLeavesTakesAFreeFocusedWorkspaceToTheOneFocusedBefore() {
        var s = Session(names: ["a", "b", "c"], monitors: [main, left])
        _ = s.perform(.workspace(.named("b")))   // on the left panel
        #expect(s.focusedDisplay == 1)
        s.reconfigure(names: ["a", "b", "c"], monitors: [main], assigned: [:], merge: [:])
        #expect(s.shownWorkspaces == ["b"])
        #expect(s.focusedWorkspace == "b")
    }

    @Test func aFreeFocusedWorkspaceNoDisplayShowsGoesToTheDisplayFocusedBefore() {
        var s = Session(names: ["a", "b", "c"], monitors: [main, left])
        _ = s.perform(.focusMonitor(.direction(.left), wrapAround: false))
        _ = s.perform(.workspace(.named("c")))   // on the left panel, in place of b
        #expect(s.shownWorkspaces == ["c", "a"])
        s.reconfigure(names: ["a", "b"], monitors: [main, left], assigned: [:], merge: ["c": "b"])
        // c merged into b, which no display showed, and b takes the left panel, focused
        // before, where the main display would have taken it from a.
        #expect(s.focusedWorkspace == "b" && s.focusedDisplay == 1)
        #expect(s.shownWorkspaces == ["b", "a"])
    }

    @Test func theLaptopProfileMergesTheWorkspacesItLeavesOut() {
        var s = desk()
        _ = s.add(10); _ = s.add(60, to: "6"); _ = s.add(61, to: "6")
        _ = s.add(70, to: "7"); _ = s.float(70)
        _ = s.add(71, to: "7"); _ = s.park([71])
        _ = s.perform(.workspace(.named("7")))
        let laptop = ["1", "2", "3", "4", "5"]
        s.reconfigure(names: laptop, monitors: [builtIn], assigned: Dictionary(uniqueKeysWithValues: laptop.map { ($0, 3) }),
                      merge: ["6": "1", "7": "2", "8": "3", "9": "4", "0": "5"])
        #expect(s.names == laptop)
        #expect(s.workspaces["1"]!.tree == "h[10 60 61]")
        #expect(s.workspace(of: 70) == "2" && s.workspaces["2"]!.floating == [70])
        #expect(s.workspace(of: 71) == "2" && s.isParked(71))
        // The focused workspace merged into 2, which keeps the focus on the built-in display.
        #expect(s.focusedWorkspace == "2" && s.shownWorkspaces == ["2"])
        #expect(within(s.frames(of: "1"), builtIn))
        // Back at the desk, the merged windows return to their workspaces as they were,
        // floating or parked, except one the user moved meanwhile.
        _ = s.perform(.moveNodeToWorkspace(.named("3"), focusFollowsWindow: false, window: 61))
        s.reconfigure(names: names, monitors: [builtIn, left, main], assigned: home, merge: [:])
        #expect(s.workspaces["6"]!.tree == "h[60]" && s.workspace(of: 61) == "3")
        #expect(s.workspaces["7"]!.floating == [70] && s.isParked(71) && s.workspace(of: 71) == "7")
        #expect(s.workspaces["1"]!.root.windows == [10])
        // Each display shows what it showed before the laptop profile, and the focus stays.
        #expect(s.shownWorkspaces == ["7", "2", "8"])
        _ = s.unpark([71], follow: nil)
        #expect(s.workspaces["7"]!.tree == "h[71]")
    }

    @Test func aMergedWorkspaceComesBackAsItWas() {
        var s = desk()
        _ = s.perform(.workspace(.named("6")))
        _ = s.add(60); _ = s.add(61)
        s.adopt(61)
        _ = s.add(62)
        s.adopt(62)
        _ = s.perform(.joinWith(.left))
        s.adopt(60)
        _ = s.perform(.resize(.width, by: 300))
        s.adopt(62)
        _ = s.add(63, to: "6")
        #expect(s.workspaces["6"]!.tree == "h[60 v[61 62 63]]")
        let frames = s.frames(of: "6")
        let laptop = ["1", "2", "3", "4", "5"]
        s.reconfigure(names: laptop, monitors: [builtIn], assigned: Dictionary(uniqueKeysWithValues: laptop.map { ($0, 3) }),
                      merge: ["6": "1"])
        #expect(s.workspaces["1"]!.root.windows == [60, 61, 62, 63])
        // Meanwhile 60 minimizes, 61 closes and 63 moves to 3.
        _ = s.park([60])
        _ = s.remove(61)
        _ = s.perform(.moveNodeToWorkspace(.named("3"), focusFollowsWindow: false, window: 63))
        s.reconfigure(names: names, monitors: [builtIn, left, main], assigned: home, merge: [:])
        // 6 is back on the left panel with its tree, shares and focus, less the window that
        // closed and the one that moved, and 60 still parked where it stood.
        #expect(s.shownWorkspaces == ["6", "1", "8"])
        #expect(s.workspaces["6"]!.tree == "h[62]" && s.isParked(60) && s.workspace(of: 63) == "3")
        #expect(s.workspaces["6"]!.focusedWindow == 62)
        _ = s.unpark([60], follow: nil)
        #expect(s.workspaces["6"]!.tree == "h[60 62]")
        #expect(s.frames(of: "6")[60] == frames[60])
    }

    @Test func aFlapMovesTheMergedWindowsBackAtOnce() {
        var s = desk()
        _ = s.add(60, to: "6")
        s.reconfigure(names: ["1", "2", "3", "4", "5"], monitors: [builtIn], assigned: [:], merge: ["6": "1"])
        #expect(s.workspace(of: 60) == "1")
        s.reconfigure(names: names, monitors: [builtIn, left, main], assigned: home, merge: [:])
        #expect(s.workspace(of: 60) == "6")
        #expect(s.workspaces["1"]!.root.windows.isEmpty)
    }

    @Test func aCommandForAWorkspaceTheProfileLeftOutFailsUntilItReturns() {
        var s = desk()
        s.reconfigure(names: ["1", "2", "3", "4", "5"], monitors: [builtIn], assigned: [:], merge: [:])
        #expect(s.missingWorkspace(in: .workspace(.named("6"))) == "6")
        #expect(s.missingWorkspace(in: .moveNodeToWorkspace(.named("0"), focusFollowsWindow: false)) == "0")
        s.reconfigure(names: names, monitors: [builtIn, left, main], assigned: home, merge: [:])
        #expect(s.missingWorkspace(in: .workspace(.named("6"))) == nil)
    }

    @Test func aWorkspaceWithoutAMergeTargetGoesToTheFirst() {
        var s = Session(names: ["a", "b"], display: main.frame)
        _ = s.add(1, to: "b")
        _ = s.perform(.workspace(.named("b")))
        s.reconfigure(names: ["a"], monitors: [main], assigned: [:], merge: [:])
        #expect(s.workspace(of: 1) == "a")
        #expect(s.focusedWorkspace == "a" && s.focused == nil)
        #expect(s.perform(.workspaceBackAndForth) == nil)
    }
}

@Suite struct DisplayBarTests {
    @Test func everyDisplayAndEveryWorkspaceWithItsDisplay() {
        var s = desk()
        _ = s.add(10); _ = s.add(50, to: "5")
        s.adopt(50)
        let bar: [DisplayID: BarSnapshot.Display] = [1: .init(id: 2, name: "VG279QE5A (2)"), 2: .init(id: 1, name: "VG279QE5A (1)"),
                                                     3: .init(id: 3, name: "Built-in")]
        let snapshot = s.barSnapshot(profile: "home", displays: bar, app: { _ in "App" }, frame: { _ in nil })
        #expect(snapshot.displays.map(\.name) == ["VG279QE5A (2)", "VG279QE5A (1)", "Built-in"])
        #expect(snapshot.workspaces.map(\.display) == [1, 1, 1, 1, 2, 2, 2, 3, 3, 3])
        #expect(snapshot.workspaces.filter(\.shown).map(\.name) == ["1", "5", "8"])
        #expect(snapshot.workspaces.filter(\.focused).map(\.name) == ["5"])
        #expect(snapshot.focused?.workspace == "5")
        #expect(snapshot.workspaces[4].windows.first?.x == -1910)
    }
}

@Suite struct DisplayParseTests {
    @Test func parsesTheMonitorCommands() {
        let cases: [([String], Command)] = [
            (["focus", "left", "--boundaries", "all-monitors-outer-frame"], .focus(.left, boundaries: .allMonitors)),
            (["focus", "--boundaries", "workspace", "up"], .focus(.up)),
            (["move", "--boundaries", "all-monitors-outer-frame", "down"], .move(.down, boundaries: .allMonitors)),
            (["move", "--boundaries", "all-monitors-outer-frame", "--boundaries-action", "wrap-around-all-monitors", "left"],
             .move(.left, boundaries: .allMonitorsWrapping)),
            (["focus", "right", "--boundaries-action", "stop", "--boundaries", "all-monitors-outer-frame"],
             .focus(.right, boundaries: .allMonitors)),
            (["focus-monitor", "left"], .focusMonitor(.direction(.left), wrapAround: false)),
            (["focus-monitor", "--wrap-around", "next"], .focusMonitor(.next, wrapAround: true)),
            (["focus-monitor", "2"], .focusMonitor(.number(2), wrapAround: false)),
            (["move-node-to-monitor", "--wrap-around", "--focus-follows-window", "up"],
             .moveNodeToMonitor(.direction(.up), focusFollowsWindow: true, wrapAround: true)),
            (["move-node-to-monitor", "--window-id", "42", "prev"],
             .moveNodeToMonitor(.previous, focusFollowsWindow: false, wrapAround: false, window: 42)),
            (["profile", "home"], .profile("home")),
        ]
        for (arguments, command) in cases {
            #expect(Command.parse(arguments) == .success(command), "\(arguments)")
        }
    }

    @Test func rejectsWhatTheMonitorCommandsDoNotTake() {
        for arguments in [["focus", "left", "--boundaries"], ["focus", "left", "--boundaries", "all-monitors"],
                          ["move", "left", "--boundaries-action", "wrap-around-all-monitors"],
                          ["move", "left", "--boundaries", "all-monitors-outer-frame", "--boundaries-action", "fail"],
                          ["focus-monitor"], ["focus-monitor", "left", "right"], ["focus-monitor", "--wrap-around", "2"],
                          ["focus-monitor", "asus-main"], ["focus-monitor", "0"], ["move-workspace-to-monitor", "left"], ["focus-monitor", "--focus-follows-window", "left"],
                          ["focus-monitor", "--window-id", "4", "left"], ["move-node-to-monitor", "--window-id"],
                          ["profile"], ["profile", "a", "b"], ["profile", "--help"]] {
            guard case .failure = Command.parse(arguments) else {
                Issue.record("accepted \(arguments)")
                continue
            }
        }
    }
}

@Suite struct DisplayConfigTests {
    @Test func bindingsNameKnownProfiles() {
        let header = "config-version = 1\nworkspaces = ['1']\n[mode.main.binding]\nalt-b = "
        #expect(Config.load(header + "'profile p'\n[[profile]]\nname = 'p'\n").diagnostics.isEmpty)
        let bad = Config.load(header + "'profile q'\n[[profile]]\nname = 'p'\n")
        #expect(bad.config == nil)
        #expect(bad.diagnostics.map(\.message) == ["no profile named 'q'"])
    }
}

/// Runs random commands, focus changes, arrivals, departures and display changes on three
/// displays, carries out each plan's reveals and conceals on a model of the screen, and
/// checks after each step what DESIGN.md section 5.13 promises: every display shows at most
/// one workspace, one it may show; the focused workspace is shown; a window is concealed
/// exactly when its workspace is hidden, unless it is parked; and every tiled window of a
/// shown workspace lies on that workspace's display.
@Test(arguments: 1...12 as ClosedRange<UInt64>)
func randomDisplayOperationsKeepTheScreenRight(seed: UInt64) {
    var random = SplitMix64(state: seed)
    let displays = [left, main, builtIn]
    let profiles: [(names: [String], assigned: [String: DisplayID], merge: [String: String])] = [
        (names, home, [:]),
        (["1", "2", "3", "4", "5"], ["1": 3, "2": 3, "3": 3, "4": 3, "5": 3], ["6": "1", "7": "2", "8": "3", "9": "4", "0": "5"]),
        (names, ["1": 2, "2": 2, "5": 1], [:]),   // the rest free
    ]
    var s = desk()
    var assigned = home
    var concealed: Set<WindowID> = []
    var nextWindow: WindowID = 1

    // The frames the app has written, as the plans and the resyncs give them.
    var written: [WindowID: CGRect] = [:]

    func carryOut(_ plan: Session.Plan?) {
        guard let plan else { return }
        #expect(Set(plan.show).isDisjoint(with: plan.hide), "seed \(seed)")
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
        let operation = Int.random(in: 0..<23, using: &random)
        switch operation {
        case 0..<4:
            guard windows.count < 30 else { break }
            let point = CGPoint(x: CGFloat.random(in: -2000...2000, using: &random), y: CGFloat.random(in: 0...2100, using: &random))
            let plan = s.add(nextWindow, to: Bool.random(using: &random) ? name : nil, at: point)
            if Int.random(in: 0..<4, using: &random) == 0 { carryOut(s.float(nextWindow)) }
            carryOut(plan)
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
        default:
            // A display change or a forced profile, and the resync after it.
            let profile = profiles.randomElement(using: &random)!
            var connected = displays.filter { _ in Bool.random(using: &random) }
            if connected.isEmpty { connected = [displays.randomElement(using: &random)!] }
            assigned = profile.assigned.filter { _, id in connected.contains { $0.id == id } }
            let before = s.monitors
            s.reconfigure(names: profile.names, monitors: connected, assigned: assigned, merge: profile.merge)
            concealed = Set(s.names.filter { !s.isShown($0) }.flatMap { s.windows(of: $0) })
                .union(concealed.filter { s.isParked($0) })
            // As Controller.apply: the shown workspaces are laid out, and the hidden ones too
            // when the displays changed.
            for name in s.names where s.isShown(name) || s.monitors != before {
                written.merge(s.frames(of: name)) { _, new in new }
            }
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
    }
}
